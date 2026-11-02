import XCTest
import SharedCore
@testable import NuvioTV

/// Review r10: the Sync Line deadline must not wait for a loader that ignores cancellation.
final class SyncLineDeadlineTests: XCTestCase {
    /// Holds a loader's continuation so the test can release it after the assertions.
    private final class Parked<T>: @unchecked Sendable {
        private let lock = NSLock()
        private var continuation: CheckedContinuation<T?, Never>?
        func park(_ c: CheckedContinuation<T?, Never>) { lock.lock(); continuation = c; lock.unlock() }
        func release() {
            lock.lock(); let c = continuation; continuation = nil; lock.unlock()
            c?.resume(returning: nil)
        }
    }

    func testNeverResumingLoaderTimesOutAtTheDeadline() async {
        let parked = Parked<[SubtitleSyncCue]>()
        defer { parked.release() }
        let loader: () async -> [SubtitleSyncCue]? = {
            // Ignores cancellation: only `release()` ever resumes it.
            await withCheckedContinuation { parked.park($0) }
        }
        let start = Date()
        let loaded = await NativeSyncLineSheet.loadCues(loader, deadlineSeconds: 0.2)
        let elapsed = Date().timeIntervalSince(start)
        XCTAssertNil(loaded, "a hung loader ends in the sheet's failure state")
        XCTAssertGreaterThanOrEqual(elapsed, 0.18)
        XCTAssertLessThan(elapsed, 1.5, "the deadline must not join the hung loader")
    }

    func testLoaderThatFinishesFirstWins() async {
        let start = Date()
        let value = await SyncLineDeadline.value(within: 5) { () async -> Int? in
            try? await Task.sleep(nanoseconds: 20_000_000)
            return 7
        }
        XCTAssertEqual(value, 7)
        XCTAssertLessThan(Date().timeIntervalSince(start), 2)
    }

    func testCallerCancellationResumesWithNil() async {
        let parked = Parked<Int>()
        defer { parked.release() }
        let task = Task { () -> Int? in
            await SyncLineDeadline.value(within: 30) { () async -> Int? in
                await withCheckedContinuation { parked.park($0) }
            }
        }
        try? await Task.sleep(nanoseconds: 50_000_000)
        task.cancel()
        let start = Date()
        let value = await task.value
        XCTAssertNil(value)
        XCTAssertLessThan(Date().timeIntervalSince(start), 1.5)
    }

    func testMissingLoaderIsNil() async {
        let loaded = await NativeSyncLineSheet.loadCues(nil, deadlineSeconds: 5)
        XCTAssertNil(loaded)
    }
}
