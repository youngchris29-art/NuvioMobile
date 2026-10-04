import Combine
import XCTest
@testable import NuvioTV

/// beta.19-rc1 verdict (M5, BUG-138): `TextSwapModel`'s `receive` rules, driven on a fake clock. The
/// payload is a `String` whose identity is its first character, so `"A1"` → `"A2"` is a same-identity
/// gap-fill and `"A1"` → `"B1"` is a swap.
@MainActor
final class HeroTextSwapModelTests: XCTestCase {

    /// A deterministic `TextSwapModel.Schedule`: jobs run only when the test advances the clock, in
    /// due-time order, and a cancelled token never runs.
    @MainActor
    private final class FakeClock {
        private struct Job {
            let id: Int
            let due: TimeInterval
            let work: @MainActor () -> Void
        }

        private(set) var now: TimeInterval = 0
        private var jobs: [Job] = []
        private var cancelled = Set<Int>()
        private var nextId = 0

        /// Jobs still waiting to run.
        var pendingCount: Int { jobs.filter { !cancelled.contains($0.id) }.count }

        func schedule(_ after: TimeInterval, _ work: @escaping @MainActor () -> Void) -> AnyCancellable {
            nextId += 1
            let id = nextId
            jobs.append(Job(id: id, due: now + after, work: work))
            return AnyCancellable { [weak self] in
                MainActor.assumeIsolated { _ = self?.cancelled.insert(id) }
            }
        }

        func advance(_ seconds: TimeInterval) {
            let end = now + seconds
            while let next = jobs
                .filter({ !cancelled.contains($0.id) && $0.due <= end + 1e-9 })
                .min(by: { ($0.due, $0.id) < ($1.due, $1.id) }) {
                jobs.removeAll { $0.id == next.id }
                now = max(now, next.due)
                next.work()
            }
            now = end
        }
    }

    private var clock: FakeClock!

    override func setUp() async throws {
        clock = FakeClock()
    }

    private func makeModel(_ timing: TextSwapTiming = .classic) -> TextSwapModel<String> {
        let clock = self.clock!
        return TextSwapModel<String>(timing: timing,
                                     identity: { String($0.prefix(1)) },
                                     schedule: { after, work in clock.schedule(after, work) })
    }

    // MARK: -

    func testFirstPayloadShowsImmediately() {
        let model = makeModel()
        model.receive("A1", reduceMotion: false)
        XCTAssertEqual(model.shown, "A1")
        XCTAssertEqual(model.textOpacity, 1)
        XCTAssertEqual(model.phase, .idle)
        XCTAssertNil(model.opacityAnimation, "the first payload is not animated in")
        XCTAssertEqual(clock.pendingCount, 0)

        let seeded = makeModel()
        seeded.seed("B1")
        XCTAssertEqual(seeded.shown, "B1")
        XCTAssertEqual(seeded.textOpacity, 1)
        XCTAssertEqual(seeded.phase, .idle)
    }

    func testNewIdentityFadesOutSwapsFadesIn() {
        let model = makeModel()
        model.seed("A1")
        model.receive("B1", reduceMotion: false)

        // Classic has no pause: the old text starts fading out at once and is still the one shown.
        XCTAssertEqual(model.phase, .fadingOut)
        XCTAssertEqual(model.shown, "A1")
        XCTAssertEqual(model.pending, "B1")
        XCTAssertEqual(model.textOpacity, 0)
        XCTAssertNotNil(model.opacityAnimation)
        XCTAssertEqual(model.swaps, 0)

        clock.advance(0.11)
        XCTAssertEqual(model.shown, "A1", "never swapped before the fade-out completes")

        clock.advance(0.01)
        XCTAssertEqual(model.shown, "B1", "swapped while invisible, at the end of the fade-out")
        XCTAssertNil(model.pending)
        XCTAssertEqual(model.swaps, 1)
        XCTAssertEqual(model.phase, .fadingIn)
        XCTAssertEqual(model.textOpacity, 1)
        XCTAssertNotNil(model.opacityAnimation)

        clock.advance(0.12)
        XCTAssertEqual(model.phase, .idle)
        XCTAssertEqual(model.textOpacity, 1)
        XCTAssertEqual(clock.pendingCount, 0)
    }

    func testSameIdentityIsSilentGapFill() {
        let model = makeModel()
        model.seed("A1")
        model.receive("A2", reduceMotion: false)
        XCTAssertEqual(model.shown, "A2", "a same-identity payload lands at once")
        XCTAssertEqual(model.phase, .idle)
        XCTAssertEqual(model.textOpacity, 1)
        XCTAssertEqual(model.swaps, 0)
        XCTAssertEqual(clock.pendingCount, 0, "a gap-fill schedules nothing")

        // Spec B's post-commit sharpen arriving during a fade-in (same identity as the new text):
        // content refresh only, the fade-in continues.
        model.receive("B1", reduceMotion: false)
        clock.advance(0.12)
        XCTAssertEqual(model.phase, .fadingIn)
        model.receive("B2", reduceMotion: false)
        XCTAssertEqual(model.shown, "B2")
        XCTAssertEqual(model.phase, .fadingIn)
        XCTAssertEqual(model.swaps, 1)
        clock.advance(0.12)
        XCTAssertEqual(model.phase, .idle)
    }

    func testRetargetDuringFadeOutKeepsOneSwap() {
        let model = makeModel()
        model.seed("A1")
        model.receive("B1", reduceMotion: false)
        clock.advance(0.05)
        model.receive("C1", reduceMotion: false)
        XCTAssertEqual(model.phase, .fadingOut)
        XCTAssertEqual(model.pending, "C1")

        clock.advance(0.07)
        XCTAssertEqual(model.shown, "C1", "the scheduled swap takes the newest payload")
        XCTAssertEqual(model.swaps, 1, "B1 is never shown")
        clock.advance(0.12)
        XCTAssertEqual(model.phase, .idle)
    }

    func testReturningToShownDuringFadeOutCancelsSwap() {
        let model = makeModel()
        model.seed("A1")
        model.receive("B1", reduceMotion: false)
        clock.advance(0.05)
        model.receive("A1", reduceMotion: false)

        XCTAssertNil(model.pending)
        XCTAssertEqual(model.shown, "A1")
        XCTAssertEqual(model.phase, .idle)
        XCTAssertEqual(model.textOpacity, 1, "the hidden text fades back in")
        XCTAssertNotNil(model.opacityAnimation)

        clock.advance(1)
        XCTAssertEqual(model.swaps, 0, "the cancelled swap never runs")
        XCTAssertEqual(model.shown, "A1")
    }

    func testRetargetDuringFadeInStartsNewFadeOut() {
        let model = makeModel()
        model.seed("A1")
        model.receive("B1", reduceMotion: false)
        clock.advance(0.12)
        XCTAssertEqual(model.phase, .fadingIn)

        clock.advance(0.05)
        model.receive("C1", reduceMotion: false)
        XCTAssertEqual(model.phase, .fadingOut)
        XCTAssertEqual(model.shown, "B1")
        XCTAssertEqual(model.pending, "C1")
        XCTAssertEqual(model.textOpacity, 0)

        clock.advance(0.12)
        XCTAssertEqual(model.shown, "C1")
        XCTAssertEqual(model.swaps, 2)
        XCTAssertEqual(model.phase, .fadingIn)
        clock.advance(0.12)
        XCTAssertEqual(model.phase, .idle)
    }

    func testReduceMotionSwapsInstantly() {
        let model = makeModel()
        model.seed("A1")
        model.receive("B1", reduceMotion: true)
        XCTAssertEqual(model.shown, "B1")
        XCTAssertEqual(model.textOpacity, 1)
        XCTAssertNil(model.opacityAnimation)
        XCTAssertEqual(model.phase, .idle)
        XCTAssertEqual(model.swaps, 1)
        XCTAssertEqual(clock.pendingCount, 0)

        // Reduce Motion turned on mid-fade: the swap in flight is dropped and the text lands at once.
        model.receive("C1", reduceMotion: false)
        clock.advance(0.05)
        model.receive("D1", reduceMotion: true)
        XCTAssertEqual(model.shown, "D1")
        XCTAssertEqual(model.textOpacity, 1)
        XCTAssertEqual(model.phase, .idle)
        clock.advance(1)
        XCTAssertEqual(model.shown, "D1")
    }

    func testStagePauseRestartsOnRetarget() {
        let model = makeModel(.stage)
        model.seed("A1")
        model.receive("B1", reduceMotion: false)
        XCTAssertEqual(model.phase, .pausing)
        XCTAssertEqual(model.textOpacity, 1, "the text stays put through the pause")

        clock.advance(0.3)
        model.receive("C1", reduceMotion: false)
        XCTAssertEqual(model.phase, .pausing)
        XCTAssertEqual(model.pending, "C1")

        clock.advance(0.3)
        XCTAssertEqual(model.phase, .pausing, "the pause restarted at the retarget (0.3 + 0.3 < 0.3 + 0.45)")
        clock.advance(0.15)
        XCTAssertEqual(model.phase, .fadingOut)
        XCTAssertEqual(model.textOpacity, 0)

        // A retarget during the stage fade-out cancels the swap and restarts the pause; the text
        // stays hidden and is swapped straight in once the pause ends.
        clock.advance(0.05)
        model.receive("D1", reduceMotion: false)
        XCTAssertEqual(model.phase, .pausing)
        XCTAssertEqual(model.textOpacity, 0)
        clock.advance(0.44)
        XCTAssertEqual(model.shown, "A1")
        clock.advance(0.01)
        XCTAssertEqual(model.shown, "D1")
        XCTAssertEqual(model.swaps, 1, "B1 and C1 are never shown")
        XCTAssertEqual(model.phase, .fadingIn)
        clock.advance(0.2)
        XCTAssertEqual(model.phase, .idle)
    }

    func testNilClearsImmediately() {
        let model = makeModel()
        model.seed("A1")
        model.receive("B1", reduceMotion: false)
        model.receive(nil, reduceMotion: false)
        XCTAssertNil(model.shown)
        XCTAssertNil(model.pending)
        XCTAssertEqual(model.textOpacity, 1)
        XCTAssertEqual(model.phase, .idle)
        clock.advance(1)
        XCTAssertNil(model.shown, "the cancelled swap never runs")
        XCTAssertEqual(model.swaps, 0)

        // The next payload after a clear shows at once (nothing on screen to fade out).
        model.receive("C1", reduceMotion: false)
        XCTAssertEqual(model.shown, "C1")
        XCTAssertEqual(model.phase, .idle)
    }

    func testTimingsMatchTheSpec() {
        XCTAssertEqual(TextSwapTiming.classic, TextSwapTiming(pause: 0, fadeOut: 0.12, fadeIn: 0.12))
        XCTAssertEqual(TextSwapTiming.stage, TextSwapTiming(pause: 0.45, fadeOut: 0.15, fadeIn: 0.20))
    }

    #if DEBUG
    func testDebugLineSpelling() {
        let model = makeModel()
        model.seed("A1")
        model.receive("B1", reduceMotion: false)
        XCTAssertEqual(model.debugLine, "phase=out shown=A pending=B swaps=0")
        clock.advance(0.12)
        XCTAssertEqual(model.debugLine, "phase=in shown=B pending=- swaps=1")
    }

    func testLiveCounterTracksTheHighWaterMark() {
        HeroInfoLiveCounter.resetForTesting()
        defer { HeroInfoLiveCounter.resetForTesting() }
        HeroInfoLiveCounter.appear()
        HeroInfoLiveCounter.disappear()
        HeroInfoLiveCounter.appear()
        XCTAssertEqual(HeroInfoLiveCounter.max, 1, "a clean swap keeps one block alive")
        HeroInfoLiveCounter.appear()
        XCTAssertEqual(HeroInfoLiveCounter.max, 2, "a lingering block raises it to 2")
        HeroInfoLiveCounter.disappear()
        HeroInfoLiveCounter.disappear()
        HeroInfoLiveCounter.disappear()
        XCTAssertEqual(HeroInfoLiveCounter.live, 0, "never negative")
    }
    #endif
}
