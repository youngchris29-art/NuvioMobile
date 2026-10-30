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

    func testRestorationWritesTheEntryBackAsItWas() throws {
        // What the mpv player writes back when a stream it saved turned live: the entry's own
        // fields and position, not the live session's.
        let prior = entry(positionMs: 600_000, durationMs: 3_600_000)
        let restore = try XCTUnwrap(PlaybackProgressRecorder.restoration(of: prior, profileId: 3))
        XCTAssertEqual(restore.session.profileId, 3)
        XCTAssertEqual(restore.session.videoId, "tt1")
        XCTAssertEqual(restore.session.parentMetaId, "tt1")
        XCTAssertEqual(restore.session.title, "Movie")
        XCTAssertEqual(restore.snapshot.positionMs, 600_000)
        XCTAssertEqual(restore.snapshot.durationMs, 3_600_000)
        XCTAssertFalse(restore.snapshot.isPlaying)
        XCTAssertNil(PlaybackProgressRecorder.restoration(of: entry(positionMs: 0, durationMs: 0, percent: 40), profileId: 3),
                     "a percentage-only entry cannot be written back")
    }
}
