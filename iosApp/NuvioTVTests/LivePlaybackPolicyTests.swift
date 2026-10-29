import XCTest
@testable import NuvioTV

/// Unit tests for `Screens/Player/LivePlaybackPolicy.swift`: the reported-live signals, the
/// duration-growth live heuristic both engines sample once per tick, and the "never save resume for
/// a live stream" gate. Growth cases follow NuvioTV Android's `LivePlaybackUiPolicyTest`
/// (583eae818), in seconds, hardened against a VOD whose duration mpv refines after FILE_LOADED.
final class LivePlaybackPolicyTests: XCTestCase {

    /// Folds `(durationSec, positionSec, fromRequestedMedia)` readings for one media key, as the tick does.
    private func growth(_ readings: [(Double, Double, Bool)], mediaKey: String = "a",
                        from start: LivePlaybackPolicy.DurationGrowth = .init()) -> LivePlaybackPolicy.DurationGrowth {
        readings.reduce(start) { state, reading in
            LivePlaybackPolicy.nextDurationGrowth(state, mediaKey: mediaKey, durationSec: reading.0,
                                                  positionSec: reading.1, fromRequestedMedia: reading.2)
        }
    }

    /// A live stream: the duration grows by 6 s a reading and the position follows 10 s behind.
    private let liveReadings: [(Double, Double, Bool)] = [(30, 20, true), (36, 26, true), (42, 32, true), (48, 38, true)]

    // MARK: Duration growth

    func testFixedVodDurationDoesNotCountAsGrowing() {
        // A VOD's duration settles by a few seconds at most.
        XCTAssertFalse(growth([(1_320, 10, true), (1_320, 10.5, true), (1_325, 11, true)]).grew)
    }

    func testGrowingDurationAtTheEdgeMarksLive() {
        XCTAssertTrue(growth(liveReadings).grew)
    }

    func testTwoGrowingReadingsAreNotEnough() {
        let two = growth(Array(liveReadings.prefix(3)))
        XCTAssertFalse(two.grew)
        XCTAssertEqual(two.edgeGrowthReadings, 2)
        XCTAssertTrue(growth([liveReadings[3]], from: two).grew, "the third growing reading latches")
    }

    func testGrowthOfExactlyTheThresholdIsNotLive() {
        // Three growing readings at the edge, but only `liveDurationGrowthSec` past the first.
        let edge = LivePlaybackPolicy.liveDurationGrowthSec
        XCTAssertFalse(growth([(100, 90, true), (103, 93, true), (106, 96, true), (100 + edge, 100, true)]).grew)
    }

    func testAVodRefinedAwayFromTheEdgeIsNotLive() {
        // mpv refining an unindexed MPEG-TS duration after FILE_LOADED: big jumps, viewer near the start.
        XCTAssertFalse(growth([(1_200, 5, true), (1_500, 6, true), (1_800, 7, true), (2_700, 8, true)]).grew)
    }

    func testAVodRefinedOnceNearTheEndIsNotLive() {
        // Resumed near the end, the duration estimate jumps once and then stays put.
        XCTAssertFalse(growth([(2_700, 2_690, true), (2_760, 2_691, true), (2_760, 2_692, true), (2_760, 2_693, true)]).grew)
    }

    func testReadingsBeforeTheRequestedMediaAreSkipped() {
        // The previous file's 20 min is reported before the engine switches to a 45 min episode.
        let state = growth([(1_200, 0, false), (2_700, 10, true), (2_700, 11, true)])
        XCTAssertFalse(state.grew)
        XCTAssertEqual(state.firstDurationSec, 2_700)
    }

    func testZeroAndNonFiniteReadingsAreSkipped() {
        // mpv's property cache reads 0 before the duration arrives; AVPlayer's live duration is NaN.
        let state = growth([(0, 0, true), (.nan, 0, true), (.infinity, 0, true), (2_700, 10, true), (2_700, 11, true)])
        XCTAssertFalse(state.grew)
        XCTAssertEqual(state.firstDurationSec, 2_700)
    }

    func testASeekBackwardsDoesNotFlipAFixedDurationToLive() {
        // A seek moves the position, never the duration: the readings stay put and the file stays VOD.
        XCTAssertFalse(growth([(2_700, 2_600, true), (2_700, 300, true), (2_700, 301, true)]).grew)
    }

    func testLiveLatchesWhenTheDurationLaterShrinks() {
        // Once live, a smaller reading (mpv trimming its cache after a seek back) does not clear it.
        XCTAssertTrue(growth([(12, 5, true), (12, 6, true)], from: growth(liveReadings)).grew)
    }

    func testANewMediaKeyStartsOver() {
        let live = growth(liveReadings)
        XCTAssertTrue(live.grew)
        let next = LivePlaybackPolicy.nextDurationGrowth(live, mediaKey: "b", durationSec: 2_700, positionSec: 0,
                                                         fromRequestedMedia: true)
        XCTAssertFalse(next.grew)
        XCTAssertEqual(next.mediaKey, "b")
        XCTAssertEqual(next.firstDurationSec, 2_700)
        XCTAssertEqual(next.edgeGrowthReadings, 0)
    }

    // MARK: Reported live

    func testAChannelIsLiveWhateverTheEngineReports() {
        XCTAssertTrue(LivePlaybackPolicy.reportsLive(contentType: "channel"))
        XCTAssertTrue(LivePlaybackPolicy.reportsLive(contentType: "Channel", seekable: true),
                      "a channel with a fixed, seekable duration is still live")
        XCTAssertFalse(LivePlaybackPolicy.reportsLive(contentType: "movie"))
        XCTAssertFalse(LivePlaybackPolicy.reportsLive(contentType: "series", seekable: true))
    }

    func testIndefiniteDurationIsLive() {
        XCTAssertTrue(LivePlaybackPolicy.reportsLive(contentType: "movie", indefiniteDuration: true))
    }

    func testMpvNotSeekableIsLiveOnlyOnceReported() {
        XCTAssertTrue(LivePlaybackPolicy.reportsLive(contentType: "movie", seekable: false),
                      "a non-seekable stream with a fixed duration")
        XCTAssertFalse(LivePlaybackPolicy.reportsLive(contentType: "movie", seekable: nil),
                       "not reported yet, or before FILE_LOADED")
    }

    func testReportedLiveNeedsNoGrowth() {
        XCTAssertTrue(LivePlaybackPolicy.isLive(reportsLive: true, growth: .init()))
        XCTAssertFalse(LivePlaybackPolicy.isLive(reportsLive: false, growth: .init()))
        XCTAssertTrue(LivePlaybackPolicy.isLive(reportsLive: false, growth: growth(liveReadings)))
    }

    // MARK: The save gate

    func testLiveNeverSavesResume() {
        XCTAssertFalse(LivePlaybackPolicy.shouldSaveResume(isLive: true, positionSec: 600, durationSec: 3_600))
        // Near the live edge reads as "completed": that must not be written either.
        XCTAssertFalse(LivePlaybackPolicy.shouldSaveResume(isLive: true, positionSec: 3_590, durationSec: 3_600))
    }

    func testNonLiveKeepsTheExistingSaveRule() {
        XCTAssertTrue(LivePlaybackPolicy.shouldSaveResume(isLive: false, positionSec: 600, durationSec: 3_600))
        XCTAssertTrue(LivePlaybackPolicy.shouldSaveResume(isLive: false, positionSec: 3_590, durationSec: 3_600))
        XCTAssertFalse(LivePlaybackPolicy.shouldSaveResume(isLive: false, positionSec: 1, durationSec: 3_600))
        XCTAssertFalse(LivePlaybackPolicy.shouldSaveResume(isLive: false, positionSec: 600, durationSec: 0))
        XCTAssertFalse(LivePlaybackPolicy.shouldSaveResume(isLive: false, positionSec: 600, durationSec: .nan))
    }
}
