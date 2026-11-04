import XCTest
@testable import NuvioTV
import SharedCore

/// Unit tests for the resume decisions in `Screens/PlaybackProgressRecorder.swift` (the native
/// engine's resume path): the saved-position gate and the "Start Over" override the Continue
/// Watching hold menu relies on (orivio batch item 3). Both are pure static forms of the instance
/// methods, fed a hand-built `WatchProgressEntry` instead of the shared repository.
@MainActor
final class PlaybackProgressRecorderTests: XCTestCase {

    /// How many times a test's `entry` argument was evaluated (it is an autoclosure).
    private var reads = 0

    private func read(_ entry: WatchProgressEntry?) -> WatchProgressEntry? {
        reads += 1
        return entry
    }

    private func entry(positionMs: Int64, durationMs: Int64 = 3_600_000, completed: Bool = false,
                       percent: Float? = nil) -> WatchProgressEntry {
        WatchProgressEntry(
            contentType: "movie", parentMetaId: "tt1", parentMetaType: "movie", videoId: "tt1", title: "Movie",
            logo: nil, poster: nil, background: nil, seasonNumber: nil, episodeNumber: nil,
            episodeTitle: nil, episodeThumbnail: nil,
            lastPositionMs: positionMs, durationMs: durationMs, lastUpdatedEpochMs: 0,
            providerName: nil, providerAddonId: nil, lastStreamTitle: nil, lastStreamSubtitle: nil,
            pauseDescription: nil, lastSourceUrl: nil, isCompleted: completed,
            progressPercent: percent.map { KotlinFloat(float: $0) }, source: "local",
            trackingProviderId: nil, trackingProviderItemId: nil, trackingSourceUrl: nil,
            progressKey: nil, excludedNextUpSeasons: []
        )
    }

    // MARK: Progress session (batch D U2)

    private func context(sessionOnly: Bool) -> PlaybackContext {
        var context = PlaybackContext(
            url: URL(string: "https://rr3---sn-example.googlevideo.com/videoplayback?id=o-abc")!, title: "Movie",
            contentType: "movie", parentMetaId: "tt1", videoId: "tt1", season: nil, episode: nil,
            poster: nil, background: nil, providerName: "Add-on", providerAddonId: "addon:x",
            streamTitle: "Trailer 1080p", streamSubtitle: nil, externalSubtitles: []
        )
        context.sessionOnlySourceUrl = sessionOnly
        return context
    }

    func testSessionOnlyContextWritesNoLastSourceUrl() {
        // A link resolved from a ytId expires within hours: the progress entry (and so the
        // "reuse last link" readers) must never learn it, while every other field still lands.
        let session = PlaybackProgressRecorder.playbackSession(for: context(sessionOnly: true))
        let lastSourceUrl: String? = session.lastSourceUrl
        XCTAssertNil(lastSourceUrl)
        XCTAssertEqual(session.videoId, "tt1")
        XCTAssertEqual(session.providerAddonId, "addon:x")
        XCTAssertEqual(session.lastStreamTitle, "Trailer 1080p")

        let persisted = PlaybackProgressRecorder.playbackSession(for: context(sessionOnly: false))
        let persistedUrl: String? = persisted.lastSourceUrl
        XCTAssertEqual(persistedUrl, "https://rr3---sn-example.googlevideo.com/videoplayback?id=o-abc",
                       "an ordinary link is stored as the entry's last source")
    }

    // MARK: Resume position

    func testSavedPositionResumesWithoutStartOver() {
        let saved = entry(positionMs: 600_000)
        XCTAssertEqual(PlaybackProgressRecorder.resumePositionSec(
            startFromBeginning: false, actualDurationSec: 0, entry: saved), 600)
        XCTAssertEqual(PlaybackProgressRecorder.resumePositionSec(
            startFromBeginning: false, actualDurationSec: 3_600, entry: saved), 600)
    }

    func testStartOverIgnoresTheSavedPositionWithoutReadingIt() {
        let saved = entry(positionMs: 600_000)
        XCTAssertNil(PlaybackProgressRecorder.resumePositionSec(
            startFromBeginning: true, actualDurationSec: 3_600, entry: read(saved)))
        XCTAssertEqual(reads, 0, "Start Over must not even look up saved progress")
    }

    // MARK: External-player resume (issue #19)

    /// A Trakt /sync/playback row: a percentage, no position and no duration.
    private func traktEntry(percent: Float, completed: Bool = false) -> WatchProgressEntry {
        entry(positionMs: 0, durationMs: 0, completed: completed, percent: percent)
    }

    func testExternalResumeScalesATraktPercentageByTheRuntime() {
        let resume = ExternalResumePolicy.resume(startsOver: false, entry: traktEntry(percent: 40),
                                                 fallbackDurationMs: 6_000_000)
        XCTAssertEqual(resume.source, .percent)
        XCTAssertEqual(resume.positionMs, 2_400_000, "40 % of a 100-minute runtime")
    }

    func testExternalResumePercentageWithoutARuntimeSendsZero() {
        XCTAssertEqual(ExternalResumePolicy.resume(startsOver: false, entry: traktEntry(percent: 40),
                                                   fallbackDurationMs: nil), ExternalResumePolicy.noResume)
        XCTAssertEqual(ExternalResumePolicy.resume(startsOver: false, entry: traktEntry(percent: 40),
                                                   fallbackDurationMs: 0), ExternalResumePolicy.noResume)
    }

    func testExternalResumeCompletedSendsZero() {
        XCTAssertEqual(ExternalResumePolicy.resume(startsOver: false, entry: traktEntry(percent: 40, completed: true),
                                                   fallbackDurationMs: 6_000_000), ExternalResumePolicy.noResume)
        XCTAssertEqual(ExternalResumePolicy.resume(startsOver: false,
                                                   entry: entry(positionMs: 600_000, completed: true),
                                                   fallbackDurationMs: 6_000_000), ExternalResumePolicy.noResume)
    }

    func testExternalResumeSavedPositionUnderTenSecondsSendsZero() {
        XCTAssertEqual(ExternalResumePolicy.resume(startsOver: false, entry: entry(positionMs: 10_000),
                                                   fallbackDurationMs: 6_000_000), ExternalResumePolicy.noResume)
        let saved = ExternalResumePolicy.resume(startsOver: false, entry: entry(positionMs: 600_000),
                                                fallbackDurationMs: 6_000_000)
        XCTAssertEqual(saved, ExternalResumePolicy.Resume(positionMs: 600_000, source: .position),
                       "a real position wins over the runtime")
    }

    func testExternalResumeMovieWithoutMetaFetchesTheRuntime() {
        // Home / Library continue-watching pass no meta; a Trakt movie row has no position.
        XCTAssertTrue(ExternalResumePolicy.needsCatalogRuntime(isSeries: false, hasMeta: false, hasEpisodes: false,
                                                               resumePositionMs: nil))
        XCTAssertFalse(ExternalResumePolicy.needsCatalogRuntime(isSeries: false, hasMeta: true, hasEpisodes: false,
                                                                resumePositionMs: nil),
                       "Detail passes the catalog record")
        XCTAssertFalse(ExternalResumePolicy.needsCatalogRuntime(isSeries: false, hasMeta: false, hasEpisodes: false,
                                                                resumePositionMs: 600_000),
                       "a saved position needs no runtime")
    }

    func testExternalResumeSeriesWithoutEpisodesWaitsForTheFetch() {
        // Review r3: a series from Continue Watching takes its episode runtime from the same fetch.
        XCTAssertTrue(ExternalResumePolicy.needsCatalogRuntime(isSeries: true, hasMeta: false, hasEpisodes: false,
                                                               resumePositionMs: nil))
        XCTAssertTrue(ExternalResumePolicy.needsCatalogRuntime(isSeries: true, hasMeta: true, hasEpisodes: false,
                                                               resumePositionMs: nil),
                      "the title's runtime is not the episode's")
        XCTAssertFalse(ExternalResumePolicy.needsCatalogRuntime(isSeries: true, hasMeta: false, hasEpisodes: true,
                                                                resumePositionMs: nil),
                       "EpisodesSection passes the episode list")
        XCTAssertFalse(ExternalResumePolicy.needsCatalogRuntime(isSeries: true, hasMeta: false, hasEpisodes: false,
                                                                resumePositionMs: 600_000))
    }

    @MainActor
    func testExternalHandOffWaitsForARuntimeFetchThatLandsInTime() async {
        // Review r2: the hand-off starts before the runtime resolves; the fetch lands 100 ms later.
        var pending = true
        Task { @MainActor in
            try? await Task.sleep(nanoseconds: 100_000_000)
            pending = false
        }
        let arrived = await ExternalResumePolicy.awaitRuntime(isPending: { pending }, waitSeconds: 1.0)
        XCTAssertTrue(arrived)
        XCTAssertFalse(pending)
    }

    @MainActor
    func testExternalHandOffGivesUpOnARuntimeFetchThatNeverLands() async {
        let started = Date()
        let arrived = await ExternalResumePolicy.awaitRuntime(isPending: { true }, waitSeconds: 0.2)
        XCTAssertFalse(arrived)
        XCTAssertGreaterThanOrEqual(Date().timeIntervalSince(started), 0.2)
        let nothingPending = await ExternalResumePolicy.awaitRuntime(isPending: { false }, waitSeconds: 0.2)
        XCTAssertTrue(nothingPending, "nothing pending returns at once")
    }

    func testExternalResumeStartOverSendsZero() {
        XCTAssertEqual(ExternalResumePolicy.resume(startsOver: true, entry: traktEntry(percent: 40),
                                                   fallbackDurationMs: 6_000_000), ExternalResumePolicy.noResume)
        XCTAssertEqual(ExternalResumePolicy.resume(startsOver: true, entry: entry(positionMs: 600_000),
                                                   fallbackDurationMs: 6_000_000), ExternalResumePolicy.noResume)
    }

    func testExternalResumePercentageOutsideTwoToNinetyFiveSendsZero() {
        XCTAssertEqual(ExternalResumePolicy.resume(startsOver: false, entry: traktEntry(percent: 1),
                                                   fallbackDurationMs: 6_000_000), ExternalResumePolicy.noResume)
        XCTAssertEqual(ExternalResumePolicy.resume(startsOver: false, entry: traktEntry(percent: 96),
                                                   fallbackDurationMs: 6_000_000), ExternalResumePolicy.noResume)
        // Both bounds are inclusive.
        XCTAssertEqual(ExternalResumePolicy.resume(startsOver: false, entry: traktEntry(percent: 2),
                                                   fallbackDurationMs: 6_000_000).positionMs, 120_000)
        XCTAssertEqual(ExternalResumePolicy.resume(startsOver: false, entry: traktEntry(percent: 95),
                                                   fallbackDurationMs: 6_000_000).positionMs, 5_700_000)
    }

    func testExternalResumeWithNoEntrySendsZero() {
        XCTAssertEqual(ExternalResumePolicy.resume(startsOver: false, entry: nil, fallbackDurationMs: 6_000_000),
                       ExternalResumePolicy.noResume)
    }

    func testCompletedOrShortProgressDoesNotResume() {
        XCTAssertNil(PlaybackProgressRecorder.resumePositionSec(
            startFromBeginning: false, actualDurationSec: 0, entry: entry(positionMs: 600_000, completed: true)))
        XCTAssertNil(PlaybackProgressRecorder.resumePositionSec(
            startFromBeginning: false, actualDurationSec: 0, entry: entry(positionMs: 10_000)),
                     "ten seconds in is not worth resuming")
        XCTAssertNil(PlaybackProgressRecorder.resumePositionSec(
            startFromBeginning: false, actualDurationSec: 0, entry: nil))
    }

    // MARK: Percentage-only resume (Trakt / Simkl rows)

    func testPercentageOnlyEntryResumesByPercentWithoutStartOver() {
        let saved = entry(positionMs: 0, durationMs: 0, percent: 40)
        let percent = PlaybackProgressRecorder.pendingResumePercent(startFromBeginning: false, entry: saved)
        XCTAssertEqual(percent ?? -1, 40, accuracy: 0.001)
    }

    func testStartOverIgnoresTheSavedPercentWithoutReadingIt() {
        let saved = entry(positionMs: 0, durationMs: 0, percent: 40)
        XCTAssertNil(PlaybackProgressRecorder.pendingResumePercent(startFromBeginning: true, entry: read(saved)))
        XCTAssertEqual(reads, 0, "Start Over must not even look up saved progress")
    }

    func testEntryWithAPositionHasNoPendingPercent() {
        XCTAssertNil(PlaybackProgressRecorder.pendingResumePercent(
            startFromBeginning: false, entry: entry(positionMs: 600_000)),
                     "a stored position resumes by position, not by percent")
    }

    // MARK: Live streams (NuvioTV b4e47d6d6)

    func testRecordSkipsTheSaveForALiveStream() {
        XCTAssertNil(PlaybackProgressRecorder.progressSnapshot(positionSec: 600, durationSec: 3_600, isPaused: false,
                                                               speed: 1, isLive: true),
                     "a live stream writes no resume position")
        let vod = PlaybackProgressRecorder.progressSnapshot(positionSec: 600, durationSec: 3_600, isPaused: true,
                                                            speed: 1, isLive: false)
        XCTAssertEqual(vod?.positionMs, 600_000)
        XCTAssertEqual(vod?.durationMs, 3_600_000)
        XCTAssertEqual(vod?.isPlaying, false)
    }
}
