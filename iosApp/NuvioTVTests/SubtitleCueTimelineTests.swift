import Combine
import CoreGraphics
import XCTest
import NuvioAether
@testable import NuvioTV

/// Aether (Phase 1), plan section 5: the overlay's cue store (`SubtitleCueTimeline`), the forced rule
/// (`SubtitleOverlayMode.resolve`), the ASS residue cleaner and the overlay model's publishing.
final class SubtitleCueTimelineTests: XCTestCase {

    private func cue(_ id: Int, _ start: Double, _ end: Double, _ text: String = "line",
                     forced: Bool = false) -> AetherCue {
        AetherCue(id: id, startSec: start, endSec: end, body: .text(text), isForced: forced)
    }

    private func bitmap(_ id: Int, _ start: Double, _ end: Double, forced: Bool) -> AetherCue {
        let ctx = CGContext(data: nil, width: 2, height: 2, bitsPerComponent: 8, bytesPerRow: 0,
                            space: CGColorSpaceCreateDeviceRGB(),
                            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        return AetherCue(id: id, startSec: start, endSec: end,
                         body: .image(ctx.makeImage()!, normalizedRect: CGRect(x: 0.1, y: 0.8, width: 0.8, height: 0.1),
                                      canvasSize: CGSize(width: 1920, height: 1080)),
                         isForced: forced)
    }

    private func ids(_ cues: [AetherCue]) -> [Int] { cues.map(\.id) }

    // MARK: Active cues

    func testOverlappingCuesAllShowInStartOrder() {
        let t = SubtitleCueTimeline(cues: [cue(3, 2, 6), cue(1, 1, 4), cue(2, 2, 3)])
        XCTAssertEqual(ids(t.active(atSourceSec: 2.5, delaySec: 0)), [1, 2, 3], "start, then id")
        XCTAssertEqual(ids(t.active(atSourceSec: 3.5, delaySec: 0)), [1, 3], "end is exclusive")
        XCTAssertEqual(ids(t.active(atSourceSec: 5, delaySec: 0)), [3])
    }

    func testGapsShowNothingAndBoundsAreHalfOpen() {
        let t = SubtitleCueTimeline(cues: [cue(1, 1, 2), cue(2, 5, 6)])
        XCTAssertEqual(ids(t.active(atSourceSec: 0.5, delaySec: 0)), [])
        XCTAssertEqual(ids(t.active(atSourceSec: 1, delaySec: 0)), [1], "start is inclusive")
        XCTAssertEqual(ids(t.active(atSourceSec: 2, delaySec: 0)), [])
        XCTAssertEqual(ids(t.active(atSourceSec: 3.5, delaySec: 0)), [])
        XCTAssertEqual(ids(t.active(atSourceSec: 7, delaySec: 0)), [])
    }

    func testLongCueStartedEarlyStillFoundBehindManyShortOnes() {
        var list = [cue(1, 0, 100)]
        for i in 0..<50 { list.append(cue(10 + i, Double(i) + 1, Double(i) + 1.5)) }
        let t = SubtitleCueTimeline(cues: list)
        XCTAssertEqual(ids(t.active(atSourceSec: 30.2, delaySec: 0)), [1, 39])
        XCTAssertEqual(ids(t.active(atSourceSec: 30.7, delaySec: 0)), [1])
    }

    func testPositiveDelayShowsLater() {
        let t = SubtitleCueTimeline(cues: [cue(1, 10, 12)])
        XCTAssertEqual(ids(t.active(atSourceSec: 10.2, delaySec: 0.5)), [], "not yet: 10.2 - 0.5 = 9.7")
        XCTAssertEqual(ids(t.active(atSourceSec: 10.5, delaySec: 0.5)), [1])
        XCTAssertEqual(ids(t.active(atSourceSec: 12.3, delaySec: 0.5)), [1], "ends at 12.5 on the clock")
        XCTAssertEqual(ids(t.active(atSourceSec: 12.5, delaySec: 0.5)), [])
    }

    func testNegativeDelayShowsEarlier() {
        let t = SubtitleCueTimeline(cues: [cue(1, 10, 12)])
        XCTAssertEqual(ids(t.active(atSourceSec: 8.5, delaySec: -1.5)), [1])
        XCTAssertEqual(ids(t.active(atSourceSec: 8.4, delaySec: -1.5)), [])
        XCTAssertEqual(ids(t.active(atSourceSec: 10.6, delaySec: -1.5)), [], "ends at 10.5 on the clock")
        XCTAssertNil(SubtitleCueTimeline.effectiveTime(sourceSec: .nan, delaySec: 0))
        XCTAssertEqual(t.active(atSourceSec: 11, delaySec: .infinity), [])
    }

    func testSeekBackShowsTheEarlierCueAgain() {
        var t = SubtitleCueTimeline(cues: [cue(1, 5, 7), cue(2, 60, 62)])
        XCTAssertEqual(ids(t.active(atSourceSec: 61, delaySec: 0)), [2])
        t.replace(cues: [cue(1, 5, 7), cue(2, 60, 62)], keepingActiveAtSourceSec: 61)
        XCTAssertEqual(ids(t.active(atSourceSec: 6, delaySec: 0)), [1], "a seek back is just an earlier question")
        // After the seek the engine window no longer holds cue 2; it is not carried (inactive at 6).
        XCTAssertTrue(t.replace(cues: [cue(1, 5, 7)], keepingActiveAtSourceSec: 6))
        XCTAssertEqual(ids(t.cues), [1])
    }

    // MARK: Forced rule

    func testForcedOnlyShowsForcedBitmapsOrEveryCueOfAForcedTrack() {
        var t = SubtitleCueTimeline(cues: [bitmap(1, 0, 10, forced: true), bitmap(2, 0, 10, forced: false),
                                           cue(3, 0, 10)])
        t.mode = .forcedOnly
        XCTAssertEqual(ids(t.active(atSourceSec: 1, delaySec: 0)), [1])
        t.trackIsForced = true
        XCTAssertEqual(ids(t.active(atSourceSec: 1, delaySec: 0)), [1, 2, 3])
        t.mode = .off
        XCTAssertEqual(ids(t.active(atSourceSec: 1, delaySec: 0)), [])
        t.mode = .all
        t.trackIsForced = false
        XCTAssertEqual(ids(t.active(atSourceSec: 1, delaySec: 0)), [1, 2, 3])
    }

    func testModeResolveMirrorsOffStaysOffAndTheForcedPlan() {
        typealias M = SubtitleOverlayMode
        XCTAssertEqual(M.resolve(primary: "en", useForcedSubtitles: false, hasSelectedTrack: false,
                                 userSelectedTrack: false, startPlanForcedOnly: false), .off)
        XCTAssertEqual(M.resolve(primary: "en", useForcedSubtitles: false, hasSelectedTrack: true,
                                 userSelectedTrack: false, startPlanForcedOnly: false), .all)
        XCTAssertEqual(M.resolve(primary: "none", useForcedSubtitles: true, hasSelectedTrack: true,
                                 userSelectedTrack: false, startPlanForcedOnly: true), .forcedOnly,
                       "Subtitles Off + Use Forced + a forced plan: forced cues still show")
        XCTAssertEqual(M.resolve(primary: "none", useForcedSubtitles: true, hasSelectedTrack: true,
                                 userSelectedTrack: false, startPlanForcedOnly: false), .off,
                       "Off without a forced plan: mpv sets sid=no, so nothing shows")
        XCTAssertEqual(M.resolve(primary: "", useForcedSubtitles: false, hasSelectedTrack: true,
                                 userSelectedTrack: false, startPlanForcedOnly: false), .off,
                       "blank counts as Off, and Off stays Off")
        XCTAssertEqual(M.resolve(primary: "none", useForcedSubtitles: false, hasSelectedTrack: true,
                                 userSelectedTrack: true, startPlanForcedOnly: false), .all,
                       "a track the user picks shows in full")
        XCTAssertEqual(M.resolve(primary: "en", useForcedSubtitles: true, hasSelectedTrack: true,
                                 userSelectedTrack: false, startPlanForcedOnly: true), .forcedOnly)
        XCTAssertEqual(M.resolve(primary: "en", useForcedSubtitles: false, hasSelectedTrack: true,
                                 userSelectedTrack: false, startPlanForcedOnly: true), .all,
                       "a forced plan needs Use Forced Subtitles")
    }

    // MARK: Replace and eviction

    func testReplaceCarriesTheActiveCueTheNewWindowDropped() {
        var t = SubtitleCueTimeline(cues: [cue(1, 0, 10), cue(2, 12, 14)])
        XCTAssertTrue(t.replace(cues: [cue(2, 12, 14), cue(3, 20, 22)], keepingActiveAtSourceSec: 5))
        XCTAssertEqual(ids(t.cues), [1, 2, 3], "cue 1 is on screen at 5 and stays")
        XCTAssertEqual(ids(t.active(atSourceSec: 5, delaySec: 0)), [1])
        // With a delay the carried cue is the one active at sourceSec - delay.
        var d = SubtitleCueTimeline(cues: [cue(1, 0, 2), cue(2, 3, 5)])
        d.replace(cues: [cue(3, 9, 10)], keepingActiveAtSourceSec: 5, delaySec: 1)
        XCTAssertEqual(ids(d.cues), [2, 3])
        // Without a time nothing is carried.
        var n = SubtitleCueTimeline(cues: [cue(1, 0, 10)])
        n.replace(cues: [cue(2, 20, 21)])
        XCTAssertEqual(ids(n.cues), [2])
    }

    func testEvictionDropsOldCuesButNeverTheActiveOne() {
        var t = SubtitleCueTimeline(cues: [cue(1, 0, 1), cue(2, 50, 400), cue(3, 380, 381)], retentionSec: 300)
        XCTAssertTrue(t.evict(atSourceSec: 390, delaySec: 0))
        XCTAssertEqual(ids(t.cues), [2, 3], "cue 1 ended 389 s before; cue 2 started 340 s before but is active")
        XCTAssertEqual(ids(t.active(atSourceSec: 390, delaySec: 0)), [2])
        XCTAssertFalse(t.evict(atSourceSec: 390, delaySec: 0), "nothing more to drop")
    }

    func testCapEvictsOldestEndingFirstAndKeepsActive() {
        var t = SubtitleCueTimeline(cues: [], maxCues: 3)
        t.replace(cues: [cue(1, 0, 100), cue(2, 1, 2), cue(3, 3, 4), cue(4, 60, 61), cue(5, 70, 71)],
                  keepingActiveAtSourceSec: 50)
        XCTAssertEqual(ids(t.cues), [1, 4, 5], "2 and 3 end first; 1 is active at 50 and stays")
    }

    func testReplaceKeepsIdentityAndReportsNoChangeForTheSameWindow() {
        var t = SubtitleCueTimeline()
        XCTAssertTrue(t.replace(cues: [cue(2, 5, 6), cue(1, 1, 2)]))
        XCTAssertEqual(ids(t.cues), [1, 2], "sorted")
        XCTAssertFalse(t.replace(cues: [cue(1, 1, 2), cue(2, 5, 6)]), "same ids and timing, any order: no change")
        XCTAssertFalse(t.replace(cues: [cue(1, 1, 2), cue(2, 5, 6), cue(2, 5, 6)]), "duplicates collapse by id")
        XCTAssertTrue(t.replace(cues: [cue(1, 1, 2), cue(2, 5, 7)]), "a retimed cue is a change")
        let before = t.active(atSourceSec: 5.5, delaySec: 0)
        t.replace(cues: [cue(1, 1, 2), cue(2, 5, 7), cue(3, 9, 10)])
        XCTAssertEqual(t.active(atSourceSec: 5.5, delaySec: 0), before, "growing the window keeps the shown ids")
    }

    // MARK: ASS residue

    func testDisplayTextStripsOverrideTagsAndMapsBreaks() {
        XCTAssertEqual(SubtitleCueText.display("{\\an8}{\\i1}Hello{\\i0}\\Nworld"), "Hello\nworld")
        XCTAssertEqual(SubtitleCueText.display("{\\pos(10,20)\\c&H00FFFF&}Sign"), "Sign")
        XCTAssertEqual(SubtitleCueText.display("a\\hb"), "a\u{00A0}b")
        XCTAssertEqual(SubtitleCueText.display("{\\an8}\\hText"), "\u{00A0}Text", "a hard space at a line edge stays")
        XCTAssertEqual(SubtitleCueText.display("  one \r\n\r\n two  "), "one\ntwo")
        XCTAssertEqual(SubtitleCueText.display("{note without tags}"), "{note without tags}")
        XCTAssertEqual(SubtitleCueText.display("{\\an2}"), "")
        XCTAssertTrue(SubtitleCueText.isTopAligned(8))
        XCTAssertFalse(SubtitleCueText.isTopAligned(2))
        XCTAssertFalse(SubtitleCueText.isTopAligned(nil))
    }

    // MARK: Overlay model

    @MainActor
    func testModelPublishesOnlyWhenTheShownCuesChange() {
        let clock = SubtitleOverlayManualClock(sourceSec: 0)
        let model = AetherSubtitleOverlayModel(timeSource: clock)
        var publishes = 0
        let sub = model.$activeCues.dropFirst().sink { _ in publishes += 1 }
        defer { sub.cancel() }
        model.setCues([cue(1, 1, 3), cue(2, 5, 6)])
        XCTAssertEqual(publishes, 0, "nothing on screen at 0")
        for k in 0..<10 { clock.sourceSec = 1 + Double(k) * 0.1 }    // ten ticks inside cue 1
        XCTAssertEqual(ids(model.activeCues), [1])
        XCTAssertEqual(publishes, 1, "one publish for the ten ticks")
        clock.sourceSec = 3.5
        XCTAssertEqual(ids(model.activeCues), [])
        model.setDelay(-2)                                         // 3.5 + 2 = 5.5: cue 2
        XCTAssertEqual(ids(model.activeCues), [2])
        XCTAssertEqual(publishes, 3)
    }

    @MainActor
    func testModelTrackSwitchDropsOldLinesAndModeOffHidesAll() {
        let clock = SubtitleOverlayManualClock(sourceSec: 2)
        let windows = PassthroughSubject<[AetherCue], Never>()
        let engineTrack = PassthroughSubject<Int?, Never>()
        let model = AetherSubtitleOverlayModel(timeSource: clock, cues: windows.eraseToAnyPublisher(),
                                               activeTrackID: engineTrack.eraseToAnyPublisher())
        engineTrack.send(1)
        model.setTrack(id: 1, isForced: false)
        windows.send([cue(101, 0, 10), cue(102, 20, 21)])          // embedded store ids
        XCTAssertEqual(ids(model.activeCues), [101])
        windows.send([cue(102, 20, 21)])                            // window slid: cue 101 carried
        XCTAssertEqual(ids(model.activeCues), [101])
        model.setTrack(id: 2, isForced: false)
        XCTAssertEqual(ids(model.activeCues), [], "the old track's line goes at once")
        windows.send([cue(101, 0, 10)])                             // a late window of the old track
        XCTAssertEqual(ids(model.activeCues), [], "windows for another engine track are dropped")
        engineTrack.send(2)
        windows.send([cue(0, 1, 4, "sidecar"), cue(1, 5, 6)])       // a sidecar numbers from 0
        XCTAssertEqual(ids(model.activeCues), [0], "low sidecar ids still show")
        engineTrack.send(3)
        model.setTrack(id: 3, isForced: false)
        windows.send([cue(0, 1, 3, "second sidecar")])             // another file, ids from 0 again
        XCTAssertEqual(ids(model.activeCues), [0])
        engineTrack.send(nil)
        model.setTrack(id: nil, isForced: false)
        windows.send([cue(9, 0, 10)])
        XCTAssertEqual(ids(model.activeCues), [], "no track, no cues")
        model.setTrack(id: 3, isForced: false)
        engineTrack.send(3)
        windows.send([cue(4, 0, 10)])
        model.setMode(.off)
        XCTAssertEqual(ids(model.activeCues), [])
        model.setMode(.all)
        XCTAssertEqual(ids(model.activeCues), [4])
        model.reset()
        XCTAssertEqual(ids(model.activeCues), [])
    }

    @MainActor
    func testModelWithoutAnEngineTrackGateAdoptsTheStartWindow() {
        let clock = SubtitleOverlayManualClock(sourceSec: 1)
        let model = AetherSubtitleOverlayModel(timeSource: clock)
        model.setCues([cue(7, 0, 5)])                               // cues before the host knows the id
        model.setTrack(id: 4, isForced: false)
        XCTAssertEqual(ids(model.activeCues), [7], "the first setTrack keeps what already arrived")
    }

    @MainActor
    func testModelSetTrackAfterTheEngineSwitchedAdoptsItsWindow() {
        let clock = SubtitleOverlayManualClock(sourceSec: 2)
        let windows = PassthroughSubject<[AetherCue], Never>()
        let engineTrack = PassthroughSubject<Int?, Never>()
        let model = AetherSubtitleOverlayModel(timeSource: clock, cues: windows.eraseToAnyPublisher(),
                                               activeTrackID: engineTrack.eraseToAnyPublisher())
        engineTrack.send(1)
        model.setTrack(id: 1, isForced: false)
        windows.send([cue(50, 0, 10)])
        // selectSubtitle(2) first: the engine sets the id and publishes a whole-file sidecar window in one go.
        engineTrack.send(2)
        windows.send([cue(0, 1, 4, "sidecar")])
        XCTAssertEqual(ids(model.activeCues), [50], "dropped by the gate until the host catches up")
        model.setTrack(id: 2, isForced: false)
        XCTAssertEqual(ids(model.activeCues), [0], "the engine's window for track 2 is adopted")
    }

    @MainActor
    func testFirstSetTrackDropsCuesOfTheEnginesOwnDefaultTrack() {
        let clock = SubtitleOverlayManualClock(sourceSec: 2)
        let windows = PassthroughSubject<[AetherCue], Never>()
        let engineTrack = PassthroughSubject<Int?, Never>()
        let model = AetherSubtitleOverlayModel(timeSource: clock, cues: windows.eraseToAnyPublisher(),
                                               activeTrackID: engineTrack.eraseToAnyPublisher())
        engineTrack.send(5)                                         // the engine's own default
        windows.send([cue(60, 0, 10)])
        XCTAssertEqual(ids(model.activeCues), [60], "no track set yet: shown as is")
        model.setTrack(id: 7, isForced: false)                      // the host's plan picks another
        XCTAssertEqual(ids(model.activeCues), [])
        engineTrack.send(7)
        windows.send([])                                            // the engine clears on the switch
        XCTAssertEqual(ids(model.activeCues), [], "nothing of track 5 is carried")
    }
}
