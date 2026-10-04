import Foundation

/// The context mpv's wakeup callback carries, in place of the player controller itself.
///
/// mpv calls the wakeup callback on its own threads, including one last time from
/// `mp_shutdown_clients` while `mpv_terminate_destroy` runs, and the controller runs that from its
/// `deinit`. The callback used to carry the controller unretained and call `readEvents()`, whose
/// `eventQueue.async { [weak self] in … }` then formed a weak reference to an object already being
/// deallocated: the Objective-C runtime aborts on that (device crash 2026-10-04, SIGABRT in
/// `objc_initWeak` under `MPVTVPlayerViewController.readEvents()`, after three failed loads in a
/// row on Try Next Source).
///
/// The relay holds the wake action, built at setup with `[weak self]` (the weak reference is formed
/// once, while the controller is alive). A wake only LOADS that reference, and a load of a
/// deallocating object yields nil, so a late wake is a no-op. The controller keeps the relay alive
/// and unsets the callback before `mpv_terminate_destroy` (`destroyPlayer`), so the relay outlives
/// every call into it.
final class MPVWakeupRelay {
    private let wake: () -> Void

    init(wake: @escaping () -> Void) {
        self.wake = wake
    }

    /// Pass to `mpv_set_wakeup_callback` with `context`.
    static let callback: @convention(c) (UnsafeMutableRawPointer?) -> Void = { ctx in
        guard let ctx else { return }
        Unmanaged<MPVWakeupRelay>.fromOpaque(ctx).takeUnretainedValue().wake()
    }

    /// Unretained: the owner holds the relay for as long as mpv can call back.
    var context: UnsafeMutableRawPointer {
        Unmanaged.passUnretained(self).toOpaque()
    }
}
