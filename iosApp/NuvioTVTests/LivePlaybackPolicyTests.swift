import XCTest
@testable import NuvioTV

/// Unit tests for `Screens/Player/LivePlaybackPolicy.swift`: the reported-live signals, the
/// duration-growth live heuristic both engines sample once per tick, the undecided hold, and the
/// "never save resume for a live stream" gate. Growth cases follow NuvioTV Android's
/// `LivePlaybackUiPolicyTest` (583eae818), in seconds, hardened against a VOD whose duration mpv
/// refines after FILE_LOADED and against a live stream that is paused or rewound before it latches.
final class LivePlaybackPolicyTests: XCTestCase {
    typealias Policy = LivePlaybackPolicy

    /// Folds `(durationSec, nowSec, fromRequestedMedia)` readings for one media key, as the tick does.
    private func growth(_ readings: [(Double, Double, Bool)], mediaKey: String = "a",
                        from start: Policy.DurationGrowth = .init()) -> Policy.DurationGrowth {
        readings.reduce(start) { state, reading in
            Policy.nextDurationGrowth(state, mediaKey: mediaKey, durationSec: reading.0,
                                      nowSec: reading.1, fromRequestedMedia: reading.2)
        }
    }

    /// mpv's 0.5 s `refreshState` ticks from `start` to `end`, the duration given by the clock.
    private func ticks(_ start: Double, _ end: Double, _ duration: (Double) -> Double) -> [(Double, Double, Bool)] {
        stride(from: start, through: end, by: 0.5).map { (duration($0), $0, true) }
    }

    /// A live stream: 6 s segments, so the duration grows by 6 s every 6 s.
    private func liveDuration(_ t: Double, base: Double = 30) -> Double { base + 6 * (t / 6).rounded(.down) }

    /// The same, one reading per segment.
    private let liveReadings: [(Double, Double, Bool)] = [(30, 0, true), (36, 6, true), (42, 12, true), (48, 18, true)]

    // MARK: Duration growth

    func testFixedVodDurationDoesNotCountAsGrowing() {
        // A VOD's duration settles by a few seconds at most: held back briefly, then released.
        let settled = growth([(1_320, 0, true), (1_320, 1, true), (1_325, 2, true)])
        XCTAssertFalse(settled.grew)
        XCTAssertTrue(settled.undecided, "one growing reading holds progress back for a moment")
        let later = growth(ticks(2.5, 40) { _ in 1_325 }, from: settled)
        XCTAssertFalse(later.grew)
        XCTAssertFalse(later.undecided, "released once \(Policy.liveUndecidedHoldSec) s pass without growth")
    }

    func testGrowingDurationMarksLive() {
        XCTAssertTrue(growth(liveReadings).grew)
        XCTAssertTrue(growth(ticks(0, 18) { self.liveDuration($0) }).grew, "on mpv's 0.5 s ticks too")
    }

    func testTwoGrowingReadingsAreNotEnough() {
        let two = growth(Array(liveReadings.prefix(3)))
        XCTAssertFalse(two.grew)
        XCTAssertEqual(two.growthReadings, 2)
        XCTAssertTrue(two.undecided)
        XCTAssertTrue(growth([liveReadings[3]], from: two).grew, "the third growing reading latches")
    }

    func testGrowthOfExactlyTheThresholdIsNotLive() {
        // Three growing readings over 18 s, but only `liveDurationGrowthSec` past the anchor.
        let edge = Policy.liveDurationGrowthSec
        XCTAssertFalse(growth([(100, 0, true), (103, 6, true), (106, 12, true), (100 + edge, 18, true)]).grew)
    }

    func testSubSecondJitterNeverCounts() {
        // A VOD whose duration flips between 2700 and 2700.2 every tick for ten minutes: no growth,
        // so nothing is held back.
        let state = growth(ticks(0, 600) { Int($0 * 2) % 2 == 0 ? 2_700 : 2_700.2 })
        XCTAssertFalse(state.grew)
        XCTAssertEqual(state.growthReadings, 0)
        XCTAssertFalse(state.undecided)
        XCTAssertFalse(Policy.holdsProgress(reportsLive: false, growth: state))
        XCTAssertFalse(Policy.holdsResume(reportsLive: false, growth: state))
    }

    func testThreeQuickRefinementsDoNotLatch() {
        // Three small refinements 2 s apart: clock-paced, but too soon after the anchor to latch.
        let quick = growth([(2_700, 0, true), (2_704, 2, true), (2_708, 4, true), (2_712, 6, true)])
        XCTAssertEqual(quick.growthReadings, 3)
        XCTAssertFalse(quick.grew)
        XCTAssertTrue(quick.undecided)
        let later = growth(ticks(6.5, 60) { _ in 2_712 }, from: quick)
        XCTAssertFalse(later.grew, "a reading that does not grow never latches")
        XCTAssertFalse(later.undecided)
        XCTAssertFalse(Policy.holdsResume(reportsLive: false, growth: later))
    }

    func testAVodRefinedInJumpsIsNotLive() {
        // mpv refining an unindexed MPEG-TS duration after FILE_LOADED: big jumps, far ahead of the clock.
        let state = growth([(1_200, 0, true), (1_500, 1, true), (1_800, 2, true), (2_700, 3, true)])
        XCTAssertFalse(state.grew)
        XCTAssertEqual(state.growthReadings, 0, "each jump starts the count over")
        XCTAssertFalse(state.undecided)
    }

    func testAVodRefinedOnceNearTheEndIsNotLive() {
        // Resumed near the end, the duration estimate jumps once and then stays put.
        XCTAssertFalse(growth([(2_700, 0, true), (2_760, 1, true), (2_760, 2, true), (2_760, 3, true)]).grew)
    }

    func testAVodSeekNearTheEndWithOneRefinementIsReleased() {
        // The viewer seeks near the end at 100 s and the estimate moves up once, by less than the
        // slack: one growing reading, held back for a moment, never live.
        let refined = growth(ticks(0, 110) { $0 < 100 ? 2_700 : 2_712 })
        XCTAssertFalse(refined.grew)
        XCTAssertTrue(refined.undecided)
        let later = growth(ticks(110.5, 200) { _ in 2_712 }, from: refined)
        XCTAssertFalse(later.grew)
        XCTAssertFalse(later.undecided)
    }

    func testSparseVodRefinementsNeverAddUp() {
        // Three small refinements minutes apart: growth that does not keep pace with the clock.
        let state = growth(ticks(0, 380) { 2_700 + 12 * ($0 / 100).rounded(.down) })
        XCTAssertFalse(state.grew)
        XCTAssertFalse(state.undecided)
    }

    func testAPausedLiveStreamStillLatches() {
        // Paused 3 s in, before the third growing reading. mpv keeps loading the live window, so the
        // duration grows with the clock while the position stays put: the position is no input.
        XCTAssertTrue(growth(ticks(0, 120) { self.liveDuration($0) }).grew)
        // If loading stalls while paused (8 s in, one segment grown), the count starts over and
        // latches once loading resumes at 63 s.
        let stalled = growth(ticks(0, 63) { self.liveDuration(min($0, 8)) })
        XCTAssertFalse(stalled.grew)
        XCTAssertTrue(growth(ticks(63.5, 90) { self.liveDuration($0 - 63, base: 36) }, from: stalled).grew,
                      "resumed: growth adds up again")
    }

    func testALiveStreamRewoundEarlyStillLatches() {
        // A seek back of minutes at 8 s: mpv drops its cache, the duration falls, then grows again.
        let rewound = growth(ticks(0, 8) { self.liveDuration($0) } + ticks(8.5, 40) { self.liveDuration($0 - 8, base: 12) })
        XCTAssertTrue(rewound.grew)
    }

    func testReadingsBeforeTheRequestedMediaAreSkipped() {
        // The previous file's 20 min is reported before the engine switches to a 45 min episode.
        let state = growth([(1_200, 0, false), (2_700, 1, true), (2_700, 2, true)])
        XCTAssertFalse(state.grew)
        XCTAssertEqual(state.anchorDurationSec, 2_700)
    }

    func testZeroAndNonFiniteReadingsAreSkipped() {
        // mpv's property cache reads 0 before the duration arrives; AVPlayer's live duration is NaN.
        let state = growth([(0, 0, true), (.nan, 1, true), (.infinity, 2, true), (2_700, 3, true), (2_700, 4, true),
                            (2_800, .nan, true)])
        XCTAssertFalse(state.grew)
        XCTAssertEqual(state.anchorDurationSec, 2_700)
        XCTAssertEqual(state.lastDurationSec, 2_700, "a reading without a clock is skipped too")
    }

    func testLiveLatchesWhenTheDurationLaterShrinks() {
        // Once live, a smaller reading (mpv trimming its cache after a seek back) does not clear it.
        XCTAssertTrue(growth([(12, 19, true), (12, 20, true)], from: growth(liveReadings)).grew)
    }

    func testANewMediaKeyStartsOver() {
        let live = growth(liveReadings)
        XCTAssertTrue(live.grew)
        let next = Policy.nextDurationGrowth(live, mediaKey: "b", durationSec: 2_700, nowSec: 20,
                                             fromRequestedMedia: true)
        XCTAssertFalse(next.grew)
        XCTAssertFalse(next.undecided)
        XCTAssertEqual(next.mediaKey, "b")
        XCTAssertEqual(next.anchorDurationSec, 2_700)
        XCTAssertEqual(next.growthReadings, 0)
    }

    // MARK: Undecided hold

    func testNoResumeSaveBeforeALiveStreamLatches() {
        // mpv's first save would run within 5 s of playing, before the first playlist refresh. A
        // first reading of one segment, the initial burst to 30 s (it re-anchors), then 6 s
        // segments: every tick until the latch holds resume saves back, so no entry is ever written.
        let readings = [(6.0, 0.0, true)] + ticks(0.5, 40) { self.liveDuration($0 - 0.5) }
        var state = Policy.DurationGrowth()
        for reading in readings where !state.grew {
            state = Policy.nextDurationGrowth(state, mediaKey: "a", durationSec: reading.0, nowSec: reading.1,
                                              fromRequestedMedia: true)
            XCTAssertTrue(Policy.holdsResume(reportsLive: false, growth: state), "no save at \(reading.1) s")
        }
        XCTAssertTrue(state.grew)
    }

    func testAVodsFirstResumeSaveComesAfterTheHold() {
        let hold = Policy.liveUndecidedHoldSec
        let early = growth(ticks(0, hold) { _ in 2_700 })
        XCTAssertFalse(Policy.holdsProgress(reportsLive: false, growth: early), "trackers are not held")
        XCTAssertTrue(Policy.holdsResume(reportsLive: false, growth: early))
        XCTAssertFalse(Policy.holdsResume(reportsLive: false, growth: growth(ticks(hold + 0.5, hold + 0.5) { _ in 2_700 },
                                                                             from: early)))
    }

    func testEarlyExitNearTheEdgeSendsZeroAndSavesNothing() {
        // Opened and closed 12 s into a live stream, 2 s behind the edge: not decided yet, but held.
        let undecided = growth(Array(liveReadings.prefix(3)))
        XCTAssertFalse(Policy.isLive(reportsLive: false, growth: undecided))
        let holds = Policy.holdsProgress(reportsLive: false, growth: undecided)
        XCTAssertTrue(holds)
        XCTAssertEqual(TrackerScrobblePolicy.stopPercent(positionSec: 40, durationSec: 42, isLive: holds), 0,
                       "a 95 % stop would mark it watched")
        XCTAssertFalse(Policy.shouldSaveResume(isLive: holds, positionSec: 40, durationSec: 42))
        XCTAssertTrue(Policy.holdsResume(reportsLive: false, growth: undecided))
    }

    func testHoldsProgressFollowsLiveAndUndecided() {
        XCTAssertTrue(Policy.holdsProgress(reportsLive: true, growth: .init()))
        XCTAssertTrue(Policy.holdsProgress(reportsLive: false, growth: growth(liveReadings)))
        XCTAssertFalse(Policy.holdsProgress(reportsLive: false, growth: .init()))
        XCTAssertFalse(Policy.holdsProgress(reportsLive: false, growth: growth(ticks(0, 60) { _ in 2_700 })))
    }

    // MARK: Reported live

    func testIndefiniteDurationIsLive() {
        XCTAssertTrue(Policy.reportsLive(indefiniteDuration: true))
        XCTAssertFalse(Policy.reportsLive())
    }

    func testMpvNotSeekableIsLiveOnlyOnceReported() {
        XCTAssertTrue(Policy.reportsLive(seekable: false), "a non-seekable stream with a fixed duration")
        XCTAssertFalse(Policy.reportsLive(seekable: true))
        XCTAssertFalse(Policy.reportsLive(seekable: nil), "not reported yet, or before FILE_LOADED")
    }

    func testReportedLiveNeedsNoGrowth() {
        XCTAssertTrue(Policy.isLive(reportsLive: true, growth: .init()))
        XCTAssertFalse(Policy.isLive(reportsLive: false, growth: .init()))
        XCTAssertTrue(Policy.isLive(reportsLive: false, growth: growth(liveReadings)))
    }

    // MARK: The save gate

    func testLiveNeverSavesResume() {
        XCTAssertFalse(Policy.shouldSaveResume(isLive: true, positionSec: 600, durationSec: 3_600))
        // Near the live edge reads as "completed": that must not be written either.
        XCTAssertFalse(Policy.shouldSaveResume(isLive: true, positionSec: 3_590, durationSec: 3_600))
    }

    func testNonLiveKeepsTheExistingSaveRule() {
        XCTAssertTrue(Policy.shouldSaveResume(isLive: false, positionSec: 600, durationSec: 3_600))
        XCTAssertTrue(Policy.shouldSaveResume(isLive: false, positionSec: 3_590, durationSec: 3_600))
        XCTAssertFalse(Policy.shouldSaveResume(isLive: false, positionSec: 1, durationSec: 3_600))
        XCTAssertFalse(Policy.shouldSaveResume(isLive: false, positionSec: 600, durationSec: 0))
        XCTAssertFalse(Policy.shouldSaveResume(isLive: false, positionSec: 600, durationSec: .nan))
    }
}
