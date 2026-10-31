import XCTest
@testable import NuvioTV
import SharedCore

/// Unit tests for `ChapterSkipFeed` and `SkipIntervalSources` (`Screens/Player/ChapterSkipFeed.swift`):
/// transport chapters → shared `ChapterSkipIntervals` → merge with the provider fetch. The title
/// matcher itself is covered by the shared `ChapterSkipIntervalsTest`; these pin the Swift half.
@MainActor
final class ChapterSkipFeedTests: XCTestCase {

    private func chapter(_ sec: Double, _ title: String) -> TransportChapter {
        TransportChapter(title: title, sec: sec)
    }

    private func interval(_ start: Double, _ end: Double, _ type: String, _ provider: String = "introdb") -> SkipInterval {
        SkipInterval(startTime: start, endTime: end, type: type, provider: provider)
    }

    private func summary(_ intervals: [SkipInterval]) -> [String] {
        intervals.map { "\($0.type) \($0.startTime)-\($0.endTime) \($0.provider)" }
    }

    /// `chapters-named.mkv` (test plan D7): Recap 0:00–0:45, Opening 0:45–2:15, Episode, Ending
    /// 21:00 for 90 s, Preview; 23 minutes.
    private let named = [(0.0, "Recap"), (45.0, "Opening"), (135.0, "Episode"), (1260.0, "Ending"), (1350.0, "Preview")]
    private var namedChapters: [TransportChapter] { named.map { chapter($0.0, $0.1) } }
    private let namedDuration: Double = 23 * 60

    // MARK: - Conversion

    func testNamedFixtureYieldsRecapOpeningAndEnding() {
        let intervals = ChapterSkipFeed.intervals(chapters: namedChapters, durationMs: 1_380_000)
        XCTAssertEqual(summary(intervals), [
            "recap 0.0-45.0 chapters", "intro 45.0-135.0 chapters", "outro 1260.0-1350.0 chapters",
        ])
    }

    func testUntitledChaptersYieldNothing() {
        // The smoke fixture `test-long-chapters.mkv`: five unnamed chapters.
        let chapters = [0.0, 60, 120, 180, 240].map { chapter($0, "") }
        XCTAssertTrue(ChapterSkipFeed.intervals(chapters: chapters, durationMs: 300_000).isEmpty)
    }

    func testFewerThanTwoChaptersOrNoDurationYieldNothing() {
        XCTAssertTrue(ChapterSkipFeed.intervals(chapters: [chapter(0, "Opening")], durationMs: 600_000).isEmpty)
        XCTAssertTrue(ChapterSkipFeed.intervals(chapters: namedChapters, durationMs: 0).isEmpty)
    }

    func testFractionalChapterTimesRoundToTheMillisecond() {
        let intervals = ChapterSkipFeed.intervals(chapters: [chapter(10.0004, "OP"), chapter(100.0006, "Episode")],
                                                  durationMs: 600_000)
        XCTAssertEqual(intervals.first?.startTime, 10.0)
        XCTAssertEqual(intervals.first?.endTime, 100.001)
    }

    // MARK: - Feed (compute only when needed)

    func testFeedComputesOnceForTheSamePair() {
        var feed = ChapterSkipFeed()
        XCTAssertEqual(feed.update(chapters: namedChapters, durationSec: namedDuration, skipIntroEnabled: true)?.count, 3)
        XCTAssertNil(feed.update(chapters: namedChapters, durationSec: namedDuration, skipIntroEnabled: true))
        XCTAssertEqual(feed.intervals.count, 3)
    }

    func testFeedWaitsForAKnownDuration() {
        var feed = ChapterSkipFeed()
        XCTAssertNil(feed.update(chapters: namedChapters, durationSec: 0, skipIntroEnabled: true))
        XCTAssertNil(feed.update(chapters: namedChapters, durationSec: .nan, skipIntroEnabled: true))
        XCTAssertEqual(feed.update(chapters: namedChapters, durationSec: namedDuration, skipIntroEnabled: true)?.count, 3)
    }

    func testFeedIsSilentWithSkipIntroOff() {
        var feed = ChapterSkipFeed()
        XCTAssertNil(feed.update(chapters: namedChapters, durationSec: namedDuration, skipIntroEnabled: false))
        XCTAssertTrue(feed.intervals.isEmpty)
    }

    func testTurningSkipIntroOffClearsAndOnRecomputes() {
        var feed = ChapterSkipFeed()
        _ = feed.update(chapters: namedChapters, durationSec: namedDuration, skipIntroEnabled: true)
        XCTAssertEqual(feed.update(chapters: namedChapters, durationSec: namedDuration, skipIntroEnabled: false), [])
        XCTAssertNil(feed.update(chapters: namedChapters, durationSec: namedDuration, skipIntroEnabled: false))
        XCTAssertEqual(feed.update(chapters: namedChapters, durationSec: namedDuration, skipIntroEnabled: true)?.count, 3)
    }

    func testFeedRemembersTheSettingItLastSaw() {
        // Engines compare it with the live setting to recompute on a mid-playback toggle.
        var feed = ChapterSkipFeed()
        XCTAssertNil(feed.skipIntroEnabled)
        _ = feed.update(chapters: namedChapters, durationSec: 0, skipIntroEnabled: true)
        XCTAssertEqual(feed.skipIntroEnabled, true)
        _ = feed.update(chapters: namedChapters, durationSec: namedDuration, skipIntroEnabled: false)
        XCTAssertEqual(feed.skipIntroEnabled, false)
    }

    func testDurationChangeThatKeepsTheIntervalsDoesNotReport() {
        var feed = ChapterSkipFeed()
        _ = feed.update(chapters: namedChapters, durationSec: namedDuration, skipIntroEnabled: true)
        // The last chapter (Preview) is not a skip chapter: a longer duration changes nothing.
        XCTAssertNil(feed.update(chapters: namedChapters, durationSec: namedDuration + 30, skipIntroEnabled: true))
    }

    func testDurationChangeThatMovesTheLastIntervalReports() {
        var feed = ChapterSkipFeed()
        let chapters = [chapter(0, "Episode"), chapter(1260, "ED")]
        XCTAssertEqual(feed.update(chapters: chapters, durationSec: 1380, skipIntroEnabled: true)?.first?.endTime, 1380)
        XCTAssertEqual(feed.update(chapters: chapters, durationSec: 1400, skipIntroEnabled: true)?.first?.endTime, 1400)
        // Growing past the 240 s cap drops it.
        XCTAssertEqual(feed.update(chapters: chapters, durationSec: 1600, skipIntroEnabled: true), [])
    }

    func testNewChaptersReport() {
        var feed = ChapterSkipFeed()
        XCTAssertEqual(feed.update(chapters: [], durationSec: namedDuration, skipIntroEnabled: true), nil)
        XCTAssertEqual(feed.update(chapters: namedChapters, durationSec: namedDuration, skipIntroEnabled: true)?.count, 3)
    }

    // MARK: - Merge

    func testChaptersWinPerCategoryAndTheApiFillsTheRest() {
        var sources = SkipIntervalSources()
        sources.api = [interval(85, 175, "op", "aniskip"), interval(1300, 1390, "ed", "aniskip")]
        sources.chapters = ChapterSkipFeed.intervals(chapters: [chapter(0, "Episode"), chapter(90, "Opening"),
                                                                chapter(180, "Episode")], durationMs: 1_440_000)
        XCTAssertEqual(summary(sources.merged(isMovie: false)), [
            "intro 90.0-180.0 chapters", "ed 1300.0-1390.0 aniskip",
        ])
    }

    func testEitherSideAloneIsKeptAsIs() {
        var sources = SkipIntervalSources()
        sources.chapters = [interval(45, 135, "intro", "chapters")]
        XCTAssertEqual(summary(sources.merged(isMovie: false)), ["intro 45.0-135.0 chapters"])
        sources = SkipIntervalSources()
        sources.api = [interval(0, 90, "op")]
        XCTAssertEqual(summary(sources.merged(isMovie: false)), ["op 0.0-90.0 introdb"])
        XCTAssertTrue(SkipIntervalSources().merged(isMovie: false).isEmpty)
    }

    func testMovieWithIntroDbDataKeepsTheIntroDbList() {
        var sources = SkipIntervalSources()
        sources.api = [interval(6000, 6300, "movie-credits"), interval(6400, 6500, "post-credits")]
        sources.chapters = [interval(6000, 6200, "outro", "chapters")]
        XCTAssertEqual(summary(sources.merged(isMovie: true)), [
            "movie-credits 6000.0-6300.0 introdb", "post-credits 6400.0-6500.0 introdb",
        ])
        sources.api = []
        XCTAssertEqual(summary(sources.merged(isMovie: true)), ["outro 6000.0-6200.0 chapters"])
    }

    func testPostCreditsChapterIsKeptBesideTheApi() {
        var sources = SkipIntervalSources()
        sources.api = [interval(0, 90, "op")]
        sources.chapters = [interval(1300, 1400, "post-credits", "chapters")]
        XCTAssertEqual(summary(sources.merged(isMovie: false)), [
            "op 0.0-90.0 introdb", "post-credits 1300.0-1400.0 chapters",
        ])
    }

    func testIsMovieFollowsTheContentType() {
        XCTAssertTrue(SkipIntervalSources.isMovie(contentType: "movie"))
        XCTAssertTrue(SkipIntervalSources.isMovie(contentType: "Movie"))
        XCTAssertFalse(SkipIntervalSources.isMovie(contentType: "series"))
        XCTAssertFalse(SkipIntervalSources.isMovie(contentType: ""))
    }
}
