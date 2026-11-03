import XCTest
import SharedCore
@testable import NuvioTV

/// BUG-237: the mpv Subtitles tab's Sync Line list must stop waiting at its deadline even when
/// the cue loader ignores cancellation (the old task-group helper joined the hung loader).
final class PlayerSubtitlesTabSyncLineTests: XCTestCase {
    func testHungLoaderReturnsNilAtTheDeadline() async {
        let loader: () async -> [SubtitleSyncCue]? = {
            // Sleeps 5 s on a dispatch timer, so cancelling the task does not wake it.
            await withCheckedContinuation { (c: CheckedContinuation<[SubtitleSyncCue]?, Never>) in
                DispatchQueue.global().asyncAfter(deadline: .now() + 5) { c.resume(returning: []) }
            }
        }
        let start = Date()
        let loaded = await PlayerSubtitlesTab.loadSyncLineCues(loader, deadlineSeconds: 0.2)
        let elapsed = Date().timeIntervalSince(start)
        XCTAssertNil(loaded, "a hung loader ends in the tab's failure state")
        XCTAssertGreaterThanOrEqual(elapsed, 0.18)
        XCTAssertLessThan(elapsed, 1.0, "the deadline must not join the hung loader")
    }

    func testLoaderThatFinishesInTimeWins() async {
        let loaded = await PlayerSubtitlesTab.loadSyncLineCues({ [] }, deadlineSeconds: 5)
        XCTAssertEqual(loaded?.count, 0)
    }

    func testMissingLoaderIsNil() async {
        let loaded = await PlayerSubtitlesTab.loadSyncLineCues(nil, deadlineSeconds: 5)
        XCTAssertNil(loaded)
    }

    func testTabDeadlineIsTwelveSeconds() {
        XCTAssertEqual(PlayerSubtitlesTab.syncLineDeadlineSeconds, 12)
    }
}
