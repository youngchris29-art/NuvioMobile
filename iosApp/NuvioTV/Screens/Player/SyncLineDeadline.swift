import Foundation

/// Review r10: races an async operation against a deadline without waiting for the loser.
///
/// A structured task group joins every child before it returns, even after `cancelAll()`, so a
/// cue loader that ignores cancellation kept the Sync Line sheet spinning past its deadline. Here
/// the operation runs in an unstructured task and a checked continuation is resumed exactly once,
/// by whichever of the operation, the timer or the caller's cancellation comes first; the losers
/// are cancelled and left to finish on their own.
enum SyncLineDeadline {
    static func value<T>(within seconds: Double, _ operation: @escaping () async -> T?) async -> T? {
        let race = DeadlineRace<T>()
        return await withTaskCancellationHandler {
            await withCheckedContinuation { (continuation: CheckedContinuation<T?, Never>) in
                race.start(continuation, seconds: seconds, operation: operation)
            }
        } onCancel: {
            race.finish(nil)
        }
    }
}

/// The once-only resume guard behind `SyncLineDeadline`.
private final class DeadlineRace<T>: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<T?, Never>?
    private var finished = false
    private var work: Task<Void, Never>?
    private var timer: Task<Void, Never>?

    func start(_ continuation: CheckedContinuation<T?, Never>, seconds: Double,
               operation: @escaping () async -> T?) {
        lock.lock()
        if finished {
            // The caller was cancelled before the race began.
            lock.unlock()
            continuation.resume(returning: nil)
            return
        }
        self.continuation = continuation
        lock.unlock()

        let work = Task { [self] in finish(await operation()) }
        let timer = Task { [self] in
            try? await Task.sleep(nanoseconds: UInt64(max(0, seconds) * 1_000_000_000))
            finish(nil)
        }
        lock.lock()
        let alreadyFinished = finished
        if !alreadyFinished {
            self.work = work
            self.timer = timer
        }
        lock.unlock()
        if alreadyFinished {
            work.cancel()
            timer.cancel()
        }
    }

    func finish(_ value: T?) {
        lock.lock()
        guard !finished else { lock.unlock(); return }
        finished = true
        let continuation = continuation
        let work = work
        let timer = timer
        self.continuation = nil
        self.work = nil
        self.timer = nil
        lock.unlock()
        continuation?.resume(returning: value)
        work?.cancel()
        timer?.cancel()
    }
}
