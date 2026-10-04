import XCTest
@testable import NuvioTV

/// `MPVWakeupRelay` (device crash 2026-10-04): mpv's last wakeup arrives while the player
/// controller is in `deinit`. These tests drive the relay's C callback the way mpv does, including
/// from inside the owner's `deinit`; the old shape (callback → controller → `[weak self]`) aborts
/// the test process there.
final class MPVWakeupRelayTests: XCTestCase {

    /// Stands in for `MPVTVPlayerViewController`: builds its relay with `[weak self]` and, like the
    /// controller's `deinit` → `mpv_terminate_destroy`, gets one last wakeup while deallocating.
    /// An `NSObject` on purpose: the controller is an Objective-C object, so its weak references go
    /// through `objc_initWeak`, which is what aborts on a deallocating object (a pure Swift class
    /// takes the native weak path instead).
    private final class Owner: NSObject {
        private(set) var relay: MPVWakeupRelay?
        private let onWake: () -> Void
        var wakeDuringDeinit = false

        init(onWake: @escaping () -> Void) {
            self.onWake = onWake
            super.init()
            relay = MPVWakeupRelay { [weak self] in self?.handleWake() }
        }

        private func handleWake() {
            // What `readEvents()` does: hop to a queue holding a NEW weak reference to self.
            DispatchQueue.main.async { [weak self] in _ = self }
            onWake()
        }

        deinit {
            if wakeDuringDeinit, let relay {
                MPVWakeupRelay.callback(relay.context)
            }
        }
    }

    func testWakeReachesALiveOwner() {
        var wakes = 0
        let owner = Owner { wakes += 1 }
        let relay = try! XCTUnwrap(owner.relay)
        MPVWakeupRelay.callback(relay.context)
        MPVWakeupRelay.callback(relay.context)
        XCTAssertEqual(wakes, 2)
        withExtendedLifetime(owner) {}
    }

    /// The crash: a wakeup while the owner deallocates must be a no-op, not an abort.
    func testWakeDuringOwnerDeinitIsANoOp() {
        var wakes = 0
        var owner: Owner? = Owner { wakes += 1 }
        owner?.wakeDuringDeinit = true
        owner = nil
        XCTAssertEqual(wakes, 0)
    }

    /// A wakeup after the owner is gone (the relay outlived it) is also a no-op.
    func testWakeAfterOwnerIsGoneIsANoOp() {
        var wakes = 0
        var owner: Owner? = Owner { wakes += 1 }
        let relay = try! XCTUnwrap(owner?.relay)
        owner = nil
        MPVWakeupRelay.callback(relay.context)
        XCTAssertEqual(wakes, 0)
    }

    func testNilContextIsIgnored() {
        MPVWakeupRelay.callback(nil)
    }
}
