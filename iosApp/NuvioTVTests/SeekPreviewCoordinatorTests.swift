import XCTest
import CoreGraphics
@testable import NuvioTV

/// GitHub #33: `SeekPreviewCoordinator`'s async orchestration with a fake still source whose
/// lookups suspend until the test resumes them, a recording sink and a manual clock / scheduler.
@MainActor
final class SeekPreviewCoordinatorTests: XCTestCase {

    // MARK: Fakes

    /// One shared, ordered log of what reached the sink and the source.
    @MainActor final class Log {
        var events: [String] = []
    }

    @MainActor final class RecordingSink: SeekPreviewSink {
        let log: Log
        var renders: [SeekPreviewRender] = []
        var refines: [(targetSec: Double, matchSec: Double?)] = []
        var decoderEnds = 0
        init(log: Log) { self.log = log }
        func publish(_ render: SeekPreviewRender) { renders.append(render) }
        func refine(targetSec: Double, matchSec: Double?) {
            refines.append((targetSec, matchSec))
            log.events.append("refine \(Int(targetSec))")
        }
        func endDecoderActivity() {
            decoderEnds += 1
            log.events.append("end")
        }
    }

    /// `match` and `nearest` suspend; the test answers each call in order.
    @MainActor final class FakeSeekPreviewSource: SeekPreviewSource {
        enum Kind: String { case match, nearest }
        struct Call {
            let kind: Kind
            let sec: Double
            let continuation: CheckedContinuation<SeekPreviewMatch?, Never>
        }
        let log: Log
        let name: String
        var pending: [Call] = []
        var calls: [(Kind, Double)] = []
        init(log: Log, name: String = "src") { self.log = log; self.name = name }

        func thumbnail(near sec: Double) async -> CGImage? { nil }
        func match(near sec: Double) async -> SeekPreviewMatch? { await suspend(.match, sec) }
        func nearest(to sec: Double) async -> SeekPreviewMatch? { await suspend(.nearest, sec) }

        private func suspend(_ kind: Kind, _ sec: Double) async -> SeekPreviewMatch? {
            await withCheckedContinuation { c in
                MainActor.assumeIsolated {
                    pending.append(Call(kind: kind, sec: sec, continuation: c))
                    calls.append((kind, sec))
                    log.events.append("\(kind.rawValue) \(Int(sec))")
                }
            }
        }
    }

    @MainActor final class ManualClock {
        var now: TimeInterval = 100
        var items: [(id: Int, at: TimeInterval, body: @MainActor () -> Void)] = []
        private var nextID = 0

        func schedule(_ delay: TimeInterval, _ body: @escaping @MainActor () -> Void) -> () -> Void {
            nextID += 1
            let id = nextID
            items.append((id, now + delay, body))
            return { [weak self] in self?.items.removeAll { $0.id == id } }
        }

        /// Moves the clock and runs every item that is due, in deadline order.
        func advance(to t: TimeInterval) {
            while let next = items.filter({ $0.at <= t }).min(by: { $0.at < $1.at }) {
                items.removeAll { $0.id == next.id }
                now = max(now, next.at)
                next.body()
            }
            now = t
        }
        func advance(by d: TimeInterval) { advance(to: now + d) }
    }

    private var log: Log!
    private var sink: RecordingSink!
    private var source: FakeSeekPreviewSource!
    private var clock: ManualClock!
    private var currentSource: SeekPreviewSource?
    private var coordinator: SeekPreviewCoordinator!

    private static let both = SeekPreviewCapability(fillsWatched: true, fillsUnwatched: true)

    override func setUp() async throws {
        log = Log()
        sink = RecordingSink(log: log)
        source = FakeSeekPreviewSource(log: log)
        currentSource = source
        clock = ManualClock()
        let clock = self.clock!
        coordinator = SeekPreviewCoordinator(sink: sink, source: { [unowned self] in self.currentSource },
                                             now: { clock.now }, schedule: clock.schedule)
    }

    private func image() -> CGImage { SeekPreviewStoreTests.image(width: 4) }

    private func frame(_ sec: Double) -> SeekPreviewMatch {
        SeekPreviewMatch(image: image(), sec: sec, origin: .decode)
    }

    /// Lets the lookup Tasks run up to their next suspension (or to completion).
    private func settle() async {
        for _ in 0..<30 { await Task.yield() }
    }

    /// Answers the oldest pending lookup call of `src` (default: the fake).
    private func answer(_ result: SeekPreviewMatch?, from src: FakeSeekPreviewSource? = nil,
                        file: StaticString = #filePath, line: UInt = #line) async {
        let s = src ?? source!
        await settle()
        guard !s.pending.isEmpty else { return XCTFail("no lookup pending", file: file, line: line) }
        let call = s.pending.removeFirst()
        call.continuation.resume(returning: result)
        await settle()
    }

    /// A miss: `match` and then `nearest` both return nil.
    private func answerMiss(from src: FakeSeekPreviewSource? = nil) async {
        await answer(nil, from: src)
        await answer(nil, from: src)
    }

    private var render: SeekPreviewRender { coordinator.render }

    // MARK: Stationary refresh (finding 2)

    func testStationaryHoldMissThenDecodeCompletionPublishes() async {
        coordinator.setSource(capability: Self.both, generation: 0)
        coordinator.gestureChanged(.hold(targetSec: 300))
        XCTAssertEqual(render.content, .placeholder)
        XCTAssertEqual(render.kind, .hold)
        await answerMiss()
        XCTAssertEqual(sink.refines.map(\.targetSec), [300])
        XCTAssertEqual(render.content, .placeholder)
        clock.advance(by: 0.5)
        // The keyframe the miss asked for arrives: the stationary hold asks again.
        coordinator.sourceContentChanged(atSec: 302)
        await settle()
        XCTAssertEqual(source.pending.count, 1, "a refresh lookup started")
        await answer(frame(302))
        XCTAssertEqual(render.content, .frame)
        XCTAssertEqual(render.frameSec, 302)
        XCTAssertNotNil(render.image)
    }

    /// Review r1-1: a seek to 105 s whose keyframe is at 60 s. The store's lookup tolerance never
    /// matches it, but the card accepts it (within 120 s), so the decoded keyframe still turns the
    /// stationary placeholder into a picture; a later insert no closer causes no lookup, a closer one does.
    func testStationaryHoldRefreshesForAKeyframe45SecondsAway() async {
        coordinator.setSource(capability: Self.both, generation: 0)
        coordinator.gestureChanged(.hold(targetSec: 105))
        await answerMiss()
        XCTAssertEqual(sink.refines.map(\.targetSec), [105])
        XCTAssertEqual(render.content, .placeholder)
        clock.advance(by: 0.5)
        coordinator.sourceContentChanged(atSec: 60)
        await settle()
        XCTAssertEqual(source.pending.map(\.sec), [105], "a refresh lookup started")
        await answer(nil)                  // match: 45 s is beyond the lookup tolerance
        await answer(frame(60))            // nearest: within the card's reach
        XCTAssertEqual(render.content, .frame)
        XCTAssertEqual(render.frameSec, 60)
        XCTAssertTrue(source.pending.isEmpty)
        XCTAssertEqual(sink.refines.map(\.targetSec), [105, 105], "the decoder may still fetch nearer")
        clock.advance(by: 0.5)
        coordinator.sourceContentChanged(atSec: 20)     // farther than the shown frame
        await settle()
        XCTAssertTrue(source.pending.isEmpty, "a farther insert causes no lookup")
        coordinator.sourceContentChanged(atSec: 150)    // as far, other side
        await settle()
        XCTAssertTrue(source.pending.isEmpty, "an insert no closer causes no lookup")
        coordinator.sourceContentChanged(atSec: 100)    // closer
        await settle()
        XCTAssertEqual(source.pending.map(\.sec), [105])
    }

    func testContentChangedFarFromTheTargetDoesNothing() async {
        coordinator.setSource(capability: Self.both, generation: 0)
        coordinator.gestureChanged(.hold(targetSec: 300))
        await answerMiss()
        clock.advance(by: 0.5)
        coordinator.sourceContentChanged(atSec: 450)
        await settle()
        XCTAssertTrue(source.pending.isEmpty)
        // After release the plan has no target: nothing runs.
        coordinator.gestureChanged(.none)
        coordinator.sourceContentChanged(atSec: 300)
        await settle()
        XCTAssertTrue(source.pending.isEmpty)
    }

    // MARK: Completion ordering (finding 5, r2-5)

    func testCompletionAfterReleaseIsDroppedAndTheThrottleUntouched() async {
        coordinator.setSource(capability: Self.both, generation: 0)
        coordinator.gestureChanged(.hold(targetSec: 300))
        await settle()
        coordinator.gestureChanged(.none)
        XCTAssertEqual(sink.decoderEnds, 1)
        XCTAssertEqual(render.content, .none)
        XCTAssertTrue(render.capabilityAny)
        await answer(frame(300))
        XCTAssertEqual(source.pending.count, 0, "a stale result never runs nearest or a trailing lookup")
        XCTAssertEqual(render.content, .none)
        XCTAssertNil(render.frameSec)
        XCTAssertTrue(sink.refines.isEmpty)
        // The reset throttle starts a new hold's lookup at once (no stale `inFlight`).
        coordinator.gestureChanged(.hold(targetSec: 500))
        await settle()
        XCTAssertEqual(source.pending.map(\.sec), [500])
    }

    func testCompletionAfterReplacementRefinesOnlyTheNewTarget() async {
        coordinator.setSource(capability: Self.both, generation: 0)
        coordinator.gestureChanged(.hold(targetSec: 300))
        await settle()
        coordinator.gestureChanged(.hold(targetSec: 400))     // trailing sample while 300 is in flight
        clock.advance(by: 0.1)
        await answerMiss()
        XCTAssertTrue(sink.refines.isEmpty, "the thumbnailer is never sent to an obsolete target")
        XCTAssertEqual(source.pending.map(\.sec), [400], "the trailing lookup runs for the new target")
        await answerMiss()
        XCTAssertEqual(sink.refines.map(\.targetSec), [400])
    }

    func testRefinementRunsBeforeTheTrailingLookup() async {
        coordinator.setSource(capability: Self.both, generation: 0)
        coordinator.gestureChanged(.hold(targetSec: 300))
        await settle()
        coordinator.sourceContentChanged(atSec: 300)     // trailing, same target
        clock.advance(by: 0.1)
        await answerMiss()
        XCTAssertEqual(log.events, ["match 300", "nearest 300", "refine 300", "match 300"])
    }

    func testOutOfReachResultKeepsTheCardAPlaceholder() async {
        coordinator.setSource(capability: Self.both, generation: 0)
        coordinator.gestureChanged(.scrub(targetSec: 900))
        await answer(nil)
        await answer(frame(700))       // nearest, 200 s off
        XCTAssertEqual(render.content, .placeholder)
        XCTAssertNil(render.frameSec)
        XCTAssertEqual(sink.refines.map(\.targetSec), [900])
    }

    func testNoSourceFinishesAtOnce() async {
        currentSource = nil
        coordinator.setSource(capability: Self.both, generation: 0)
        coordinator.gestureChanged(.scrub(targetSec: 200))
        XCTAssertEqual(render.content, .placeholder)
        clock.advance(by: 0.1)
        coordinator.gestureChanged(.scrub(targetSec: 210))
        XCTAssertEqual(render.cardTargetSec, 210)
        XCTAssertTrue(clock.items.isEmpty, "no stuck throttle wait")
    }

    // MARK: Capability and source changes (finding 3, r2-1)

    func testCapabilityLossMidLookupThenLateResult() async {
        coordinator.setSource(capability: Self.both, generation: 0)
        coordinator.gestureChanged(.scrub(targetSec: 200))
        await settle()
        coordinator.setSource(capability: .none, generation: 0)
        XCTAssertEqual(sink.decoderEnds, 1)
        XCTAssertEqual(render.content, .timeOnly, "the scrub card keeps the time")
        await answer(frame(200))
        XCTAssertEqual(render.content, .timeOnly)
        XCTAssertNil(render.frameSec)
        XCTAssertTrue(sink.refines.isEmpty)
    }

    func testGainDuringAStationaryScrubRequestsAtOnce() async {
        coordinator.gestureChanged(.scrub(targetSec: 200))
        XCTAssertEqual(render.content, .timeOnly)
        await settle()
        XCTAssertTrue(source.calls.isEmpty, "no capability, no lookup")
        coordinator.setSource(capability: Self.both, generation: 0)
        await settle()
        XCTAssertEqual(source.pending.map(\.sec), [200])
        XCTAssertEqual(render.content, .placeholder)
    }

    func testLiveSourceGenerationChangeDuringAnAwaitDropsTheResult() async {
        var live = (capability: Self.both, generation: 1)
        coordinator.liveSource = { live }
        coordinator.sourceMayHaveChanged()
        coordinator.gestureChanged(.scrub(targetSec: 200))
        await settle()
        XCTAssertEqual(source.pending.count, 1)
        let ends = sink.decoderEnds
        live.generation = 2            // an Aether reload, no event
        clock.advance(by: 0.1)
        await answer(frame(200))
        XCTAssertNil(render.frameSec, "a frame from the old source generation is never accepted")
        XCTAssertEqual(sink.decoderEnds, ends + 1)
        XCTAssertEqual(source.pending.map(\.sec), [200], "the new generation asks again")
        await answer(frame(201))
        XCTAssertEqual(render.frameSec, 201)
    }

    func testLiveSourceIsReadOnEveryInput() async {
        var live = (capability: SeekPreviewCapability.none, generation: 0)
        coordinator.liveSource = { live }
        coordinator.gestureChanged(.scrub(targetSec: 200))
        XCTAssertEqual(render.content, .timeOnly)
        live.capability = Self.both
        coordinator.gestureChanged(.scrub(targetSec: 210))
        XCTAssertEqual(render.content, .placeholder)
        XCTAssertTrue(render.capabilityAny)
        await settle()
        XCTAssertEqual(source.pending.map(\.sec), [210])
    }

    func testLiveSourceIsReadBeforeAContentRefresh() async {
        var live = (capability: Self.both, generation: 0)
        coordinator.liveSource = { live }
        coordinator.gestureChanged(.hold(targetSec: 300))
        await answer(frame(300))
        XCTAssertEqual(render.content, .frame)
        live.capability = .none
        coordinator.sourceContentChanged(atSec: 300)
        XCTAssertEqual(render.content, .none, "a hold with no capability draws nothing")
        XCTAssertNil(render.frameSec)
    }

    /// Review r2-3: a live reconnect replaces the mpv store; a frame the old store holds at an
    /// overlapping time is never shown, and its late insert reaches nothing.
    func testMpvReconnectReplacesTheStore() async {
        let old = source!
        let fresh = FakeSeekPreviewSource(log: log, name: "fresh")
        coordinator.setSource(capability: Self.both, generation: 0)
        coordinator.gestureChanged(.scrub(targetSec: 300))
        await answer(frame(300), from: old)
        XCTAssertEqual(render.frameSec, 300)
        currentSource = fresh
        coordinator.setSource(capability: Self.both, generation: 1)
        XCTAssertNil(render.frameSec, "the old timeline's frame goes with the generation")
        XCTAssertEqual(render.content, .placeholder)
        await settle()
        XCTAssertEqual(fresh.pending.map(\.sec), [300], "the new store is asked at once")
        XCTAssertTrue(old.pending.isEmpty)
        await answerMiss(from: fresh)
        XCTAssertEqual(render.content, .placeholder)
    }

    // MARK: Clicks (finding 1)

    func testClickLandingDwellThenCardGone() async {
        coordinator.setSource(capability: Self.both, generation: 0)
        coordinator.clickIssued(targetSec: 110, generation: 5)
        XCTAssertEqual(render.kind, .landing)
        XCTAssertEqual(render.cardTargetSec, 110)
        XCTAssertEqual(render.content, .placeholder)
        await answer(frame(110))
        XCTAssertEqual(render.content, .frame)
        clock.advance(by: 0.2)
        coordinator.seekLanded(generation: 5)
        XCTAssertEqual(render.content, .frame, "the dwell holds the card after a fast landing")
        clock.advance(by: 0.9)
        XCTAssertEqual(render.kind, .landing)
        clock.advance(by: 0.15)            // 1.25 s after the click
        XCTAssertEqual(render.kind, .none)
        XCTAssertEqual(render.content, .none)
        XCTAssertEqual(sink.decoderEnds, 1)
        XCTAssertTrue(clock.items.isEmpty)
    }

    func testClickWithALookupPendingAtTheFallback() async {
        coordinator.setSource(capability: Self.both, generation: 0)
        coordinator.clickIssued(targetSec: 110, generation: 5)
        await settle()
        clock.advance(by: ClickPreviewLatch.fallbackSec)
        XCTAssertEqual(render.content, .none, "no landing reported: the fallback ends the card")
        await answer(frame(110))
        XCTAssertEqual(render.content, .none)
        XCTAssertNil(render.frameSec)
        XCTAssertTrue(sink.refines.isEmpty)
    }

    func testRepeatedClicksKeepOneCardAndCountEachClick() async {
        coordinator.setSource(capability: Self.both, generation: 0)
        coordinator.clickIssued(targetSec: 110, generation: 5)
        let first = render.episode
        clock.advance(by: 0.3)
        coordinator.clickIssued(targetSec: 120, generation: 6)
        XCTAssertEqual(render.episode, first + 1)
        XCTAssertEqual(render.cardTargetSec, 120)
        clock.advance(by: 0.3)
        coordinator.seekLanded(generation: 5)         // the first click's late landing
        XCTAssertEqual(render.cardTargetSec, 120, "an older landing never ends a newer card")
        coordinator.clickIssued(targetSec: 130, generation: 7)
        XCTAssertEqual(render.episode, first + 2)
        coordinator.seekLanded(generation: 7)
        clock.advance(by: 1.3)
        XCTAssertEqual(render.content, .none)
    }

    func testRejectedClickEndsItsCard() {
        coordinator.setSource(capability: Self.both, generation: 0)
        coordinator.clickIssued(targetSec: 110, generation: 5)
        coordinator.seekRejected(generation: 4)
        XCTAssertEqual(render.kind, .landing)
        coordinator.seekRejected(generation: 5)
        XCTAssertEqual(render.kind, .none)
    }

    func testHoldSupersedesTheClickCard() {
        coordinator.setSource(capability: Self.both, generation: 0)
        coordinator.clickIssued(targetSec: 110, generation: 5)
        coordinator.gestureChanged(.pending)
        XCTAssertEqual(render.kind, .landing, "a press before its first tick keeps the click's card")
        coordinator.gestureChanged(.hold(targetSec: 120))
        XCTAssertEqual(render.kind, .hold)
        XCTAssertEqual(render.cardTargetSec, 120)
        coordinator.gestureChanged(.none)
        XCTAssertEqual(render.kind, .none, "the latch was cleared by the hold")
    }

    func testScanHasNoCardAndClearsTheClick() {
        coordinator.setSource(capability: Self.both, generation: 0)
        coordinator.clickIssued(targetSec: 110, generation: 5)
        coordinator.gestureChanged(.scan)
        XCTAssertEqual(render.content, .none)
        coordinator.gestureChanged(.none)
        XCTAssertEqual(render.content, .none)
    }

    func testClickWithNoCapabilityIsTimeOnly() async {
        coordinator.clickIssued(targetSec: 110, generation: 5)
        XCTAssertEqual(render.content, .timeOnly)
        await settle()
        XCTAssertTrue(source.calls.isEmpty)
    }

    /// Review r2-4: a chapter seek from the Chapters tab clears the click's card when it is issued,
    /// whatever happens to either seek after.
    func testChapterTabSeekClearsTheClickCard() async {
        coordinator.setSource(capability: Self.both, generation: 0)
        coordinator.clickIssued(targetSec: 110, generation: 5)
        coordinator.dismissClick()
        XCTAssertEqual(render.content, .none)
        coordinator.seekLanded(generation: 5)          // the old click lands after the chapter seek
        coordinator.seekRejected(generation: 6)        // the chapter seek is refused
        clock.advance(by: 2)
        XCTAssertEqual(render.content, .none)
        XCTAssertTrue(clock.items.isEmpty)
    }

    /// Review r2 P2 #1: a Right click while mpv's percentage resume is still in flight (target
    /// unknown) has no known landing. `edgeClick` then issues the seek and calls `dismissClick`
    /// instead of `clickIssued`: no card at the stale position, and an earlier click's card goes.
    func testClickDuringAnUnknownTargetResumeShowsNoCard() async {
        coordinator.setSource(capability: Self.both, generation: 0)
        let first = ClickLanding.decide(.relative(10), positionSec: 100, inFlight: .none, durationSec: 1000,
                                        semantics: .mpvRelative).cardTargetSec
        XCTAssertEqual(first, 110)
        coordinator.clickIssued(targetSec: first!, generation: 5)
        XCTAssertEqual(render.kind, .landing)

        // The resume (generation 6, unknown target) is now in flight; the cached position is stale.
        XCTAssertNil(ClickLanding.decide(.relative(10), positionSec: 10, inFlight: .unknownTarget, durationSec: 0,
                                         semantics: .mpvRelative).cardTargetSec)
        coordinator.dismissClick()                     // what edgeClick does for a nil card target
        XCTAssertEqual(render.kind, .none)
        XCTAssertEqual(render.content, .none)
        XCTAssertNil(render.cardTargetSec, "no card at the stale position (0:20)")
        coordinator.seekLanded(generation: 5)
        coordinator.seekLanded(generation: 7)          // the click's own seek lands
        clock.advance(by: 2)
        XCTAssertEqual(render.kind, .none)
        XCTAssertTrue(clock.items.isEmpty)
    }

    // MARK: Teardown and Off

    func testTeardownWithTwoLookupsInFlight() async {
        coordinator.setSource(capability: Self.both, generation: 0)
        coordinator.gestureChanged(.hold(targetSec: 300))
        await settle()
        coordinator.gestureChanged(.none)                       // invalidates the first
        coordinator.gestureChanged(.hold(targetSec: 500))       // a second lookup in flight
        await settle()
        XCTAssertEqual(source.pending.map(\.sec), [300, 500])
        coordinator.clickIssued(targetSec: 510, generation: 9)
        coordinator.teardown()
        XCTAssertEqual(render.content, .none)
        let ends = sink.decoderEnds
        let published = sink.renders.count
        await answer(frame(300))
        await answer(frame(500))
        XCTAssertTrue(source.pending.isEmpty, "nothing runs after teardown")
        XCTAssertTrue(sink.refines.isEmpty)
        XCTAssertEqual(sink.renders.count, published)
        XCTAssertEqual(sink.decoderEnds, ends)
        coordinator.gestureChanged(.hold(targetSec: 700))
        coordinator.clickIssued(targetSec: 710, generation: 10)
        coordinator.sourceContentChanged(atSec: 700)
        await settle()
        XCTAssertTrue(source.pending.isEmpty)
        XCTAssertTrue(clock.items.isEmpty)
        XCTAssertEqual(render.content, .none)
    }

    func testOffModeScrubExitHasNoRequestEffects() async {
        coordinator.setSource(capability: .none, generation: 0)
        coordinator.gestureChanged(.scrub(targetSec: 100))
        XCTAssertEqual(render.content, .timeOnly)
        XCTAssertFalse(render.capabilityAny)
        coordinator.gestureChanged(.scrub(targetSec: 140))
        coordinator.gestureChanged(.none)
        await settle()
        XCTAssertEqual(render.content, .none)
        XCTAssertEqual(sink.decoderEnds, 0)
        XCTAssertTrue(source.calls.isEmpty)
        XCTAssertFalse(coordinator.previewActive)
    }

    func testPreviewActiveFollowsThePlan() {
        coordinator.setSource(capability: Self.both, generation: 0)
        XCTAssertFalse(coordinator.previewActive)
        coordinator.gestureChanged(.hold(targetSec: 10))
        XCTAssertTrue(coordinator.previewActive)
        coordinator.gestureChanged(.scan)
        XCTAssertFalse(coordinator.previewActive)
    }
}
