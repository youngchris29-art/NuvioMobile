import XCTest
@testable import NuvioTV

/// Unit tests for `Screens/Player/LivePlaybackPolicy.swift`: the duration-growth live heuristic
/// both engines sample once per tick, and the "never save resume for a live stream" gate. Cases
/// mirror NuvioTV Android's `LivePlaybackUiPolicyTest` (583eae818), in seconds.
final class LivePlaybackPolicyTests: XCTestCase {

    /// Folds `(durationSec, fromRequestedMedia)` readings for one media key, as the tick does.
    private func growth(_ readings: [(Double, Bool)], mediaKey: String = "a") -> LivePlaybackPolicy.DurationGrowth {
        readings.reduce(LivePlaybackPolicy.DurationGrowth()) { state, reading in
            LivePlaybackPolicy.nextDurationGrowth(state, mediaKey: mediaKey, durationSec: reading.0,
                                                  fromRequestedMedia: reading.1)
        }
    }

    // MARK: Duration growth

    func testFixedVodDurationDoesNotCountAsGrowing() {
        // A VOD's duration settles by a few seconds at most.
        XCTAssertFalse(growth([(1_320, true), (1_320, true), (1_325, true)]).grew)
    }

    func testGrowingDurationMarksLive() {
        XCTAssertTrue(growth([(8, true), (18, true), (32, true)]).grew)
    }

    func testGrowthOfExactlyTheThresholdIsNotLive() {
        XCTAssertFalse(growth([(100, true), (100 + LivePlaybackPolicy.liveDurationGrowthSec, true)]).grew)
    }

    func testReadingsBeforeTheRequestedMediaAreSkipped() {
        // The previous file's 20 min is reported before the engine switches to a 45 min episode.
        let state = growth([(1_200, false), (2_700, true), (2_700, true)])
        XCTAssertFalse(state.grew)
        XCTAssertEqual(state.firstDurationSec, 2_700)
    }

    func testZeroAndNonFiniteReadingsAreSkipped() {
        // mpv's property cache reads 0 before the duration arrives; AVPlayer's live duration is NaN.
        let state = growth([(0, true), (.nan, true), (.infinity, true), (2_700, true), (2_700, true)])
        XCTAssertFalse(state.grew)
        XCTAssertEqual(state.firstDurationSec, 2_700)
    }

    func testASeekBackwardsDoesNotFlipAFixedDurationToLive() {
        // A seek moves the position, never the duration: the readings stay put and the file stays VOD.
        XCTAssertFalse(growth([(2_700, true), (2_700, true), (2_700, true)]).grew)
    }

    func testLiveLatchesWhenTheDurationLaterShrinks() {
        // Once live, a smaller reading (mpv trimming its cache after a seek back) does not clear it.
        XCTAssertTrue(growth([(8, true), (46, true), (12, true), (12, true)]).grew)
    }

    func testANewMediaKeyStartsOver() {
        let live = growth([(8, true), (46, true)])
        XCTAssertTrue(live.grew)
        let next = LivePlaybackPolicy.nextDurationGrowth(live, mediaKey: "b", durationSec: 2_700, fromRequestedMedia: true)
        XCTAssertFalse(next.grew)
        XCTAssertEqual(next.mediaKey, "b")
        XCTAssertEqual(next.firstDurationSec, 2_700)
    }

    // MARK: Live and the save gate

    func testIndefiniteDurationIsLiveWithoutGrowth() {
        XCTAssertTrue(LivePlaybackPolicy.isLive(reportsLive: true, growth: .init()))
        XCTAssertFalse(LivePlaybackPolicy.isLive(reportsLive: false, growth: .init()))
        XCTAssertTrue(LivePlaybackPolicy.isLive(reportsLive: false, growth: growth([(8, true), (46, true)])))
    }

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
