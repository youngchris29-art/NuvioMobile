import Foundation

/// The context mpv's wakeup callback carries, in place of the player controller itself.
///
/// mpv calls the wakeup callback on its own threads, holding the client's wakeup lock, including
/// one last time from `mp_shutdown_clients` while `mpv_terminate_destroy` runs, and the controller
/// runs that from its `deinit`. The callback used to carry the controller unretained and call
/// `readEvents()`, whose `eventQueue.async { [weak self] in … }` then formed a weak reference to an
/// object already being deallocated: the Objective-C runtime aborts on that (device crash
/// 2026-10-04, SIGABRT in `objc_initWeak` under `MPVTVPlayerViewController.readEvents()`, after
/// three failed loads in a row on Try Next Source).
///
/// The callback now touches only the relay: it hops to `queue` (the controller's `eventQueue`) and
/// runs `wake` there. So mpv's thread never loads, retains or releases the controller. Review r4
/// P2-2: a strong load on mpv's thread could have made it the controller's final releaser, running
/// `deinit` inside the callback and re-taking the wakeup lock it already held. `wake` captured the
/// controller `[weak self]` at setup, while it was alive, so a late wake only LOADS that reference,
/// and a load of a deallocating object yields nil. The controller keeps the relay alive and unsets
/// the callback before `mpv_terminate_destroy` (`destroyPlayer`); a wake already queued holds the
/// relay itself.
nonisolated final class MPVWakeupRelay: @unchecked Sendable {
    let queue: DispatchQueue
    private let wake: () -> Void

    init(queue: DispatchQueue, wake: @escaping () -> Void) {
        self.queue = queue
        self.wake = wake
    }

    /// Pass to `mpv_set_wakeup_callback` with `context`.
    static let callback: @convention(c) (UnsafeMutableRawPointer?) -> Void = { ctx in
        guard let ctx else { return }
        let relay = Unmanaged<MPVWakeupRelay>.fromOpaque(ctx).takeUnretainedValue()
        relay.queue.async { relay.wake() }
    }

    /// Unretained: the owner holds the relay for as long as mpv can call back.
    var context: UnsafeMutableRawPointer {
        Unmanaged.passUnretained(self).toOpaque()
    }
}
