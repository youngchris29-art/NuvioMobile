import XCTest
@testable import NuvioTV

/// `MPVWakeupRelay` (device crash 2026-10-04): mpv's last wakeup arrives while the player
/// controller is in `deinit`. These tests drive the relay's C callback the way mpv does, from a
/// background thread and from inside the owner's `deinit`; the old shape (callback → controller →
/// `[weak self]`) aborts the test process there.
final class MPVWakeupRelayTests: XCTestCase {

    /// Stands in for `MPVTVPlayerViewController`: builds its relay with `[weak self]` on its own
    /// serial queue and, like the controller's `deinit` → `mpv_terminate_destroy`, can get one last
    /// wakeup while deallocating. An `NSObject` on purpose: the controller is an Objective-C object,
    /// so its weak references go through `objc_initWeak`, which is what aborts on a deallocating
    /// object (a pure Swift class takes the native weak path instead).
    private final class Owner: NSObject {
        let queue = DispatchQueue(label: "MPVWakeupRelayTests.events")
        private(set) var relay: MPVWakeupRelay?
        private let onWake: (_ onQueue: Bool) -> Void
        var wakeDuringDeinit = false
        private let queueKey = DispatchSpecificKey<Bool>()

        init(onWake: @escaping (_ onQueue: Bool) -> Void) {
            self.onWake = onWake
            super.init()
            queue.setSpecific(key: queueKey, value: true)
            relay = MPVWakeupRelay(queue: queue) { [weak self] in self?.drain() }
        }

        private func drain() {
            // What `drainEvents()` hands to the main thread: a NEW weak reference to self.
            DispatchQueue.main.async { [weak self] in _ = self }
            onWake(DispatchQueue.getSpecific(key: queueKey) == true)
        }

        deinit {
            if wakeDuringDeinit, let relay {
                MPVWakeupRelay.callback(relay.context)
            }
        }
    }

    /// Waits until every block already on `queue` has run.
    private func flush(_ queue: DispatchQueue) {
        queue.sync {}
    }

    func testWakeFromAnotherThreadRunsOnTheOwnersQueue() {
        var wakes: [Bool] = []
        let owner = Owner { wakes.append($0) }
        let relay = try! XCTUnwrap(owner.relay)
        let fired = expectation(description: "callback fired off the main thread")
        DispatchQueue.global().async {
            MPVWakeupRelay.callback(relay.context)
            MPVWakeupRelay.callback(relay.context)
            fired.fulfill()
        }
        wait(for: [fired], timeout: 2)
        flush(owner.queue)
        XCTAssertEqual(wakes, [true, true], "each wake runs on the owner's queue")
        withExtendedLifetime(owner) {}
    }

    /// The crash: a wakeup while the owner deallocates must be a no-op, not an abort.
    func testWakeDuringOwnerDeinitIsANoOp() {
        var wakes = 0
        var owner: Owner? = Owner { _ in wakes += 1 }
        let queue = try! XCTUnwrap(owner?.queue)
        owner?.wakeDuringDeinit = true
        owner = nil
        flush(queue)
        XCTAssertEqual(wakes, 0)
    }

    /// A wake queued while the owner was alive that runs after the owner is gone is a no-op, and
    /// the queued block keeps the relay alive until then.
    func testWakeQueuedBeforeTheOwnerGoesIsANoOp() {
        var wakes = 0
        var owner: Owner? = Owner { _ in wakes += 1 }
        let queue = try! XCTUnwrap(owner?.queue)
        let context = try! XCTUnwrap(owner?.relay?.context)
        let gate = DispatchSemaphore(value: 0)
        queue.async { gate.wait() } // holds the queue so the wake stays queued
        MPVWakeupRelay.callback(context)
        owner = nil
        gate.signal()
        flush(queue)
        XCTAssertEqual(wakes, 0)
    }

    func testNilContextIsIgnored() {
        MPVWakeupRelay.callback(nil)
    }
}
