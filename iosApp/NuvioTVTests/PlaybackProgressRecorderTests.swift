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
}
