import Foundation

/// The key-value calls the sentinel needs; `UserDefaults` conforms as is, tests use a dictionary.
nonisolated protocol HarvestSentinelStore: AnyObject {
    func bool(forKey key: String) -> Bool
    func set(_ value: Bool, forKey key: String)
}

nonisolated extension UserDefaults: HarvestSentinelStore {}

/// Crash guard for the seek-preview harvest (review r1 P2 #3). Its one native call,
/// `screenshot-raw`, aborts the app on the simulator's Metal driver, and whether Apple TV
/// hardware survives the same readback is unproven. The flag is armed just before each real
/// capture and cleared when the call returns; a flag still armed when the next player opens means
/// the process died mid-capture, and the harvest turns itself off on this device until someone
/// picks a value in Settings › Developer › Thumbnail Harvest (A/B).
nonisolated struct HarvestCrashSentinel {
    static let inFlightKey = "player.harvestInFlight"
    static let disabledKey = "player.harvestDisabledByCrash"

    let store: HarvestSentinelStore

    /// `eventQueue`, immediately before `screenshot-raw`.
    func arm() { store.set(true, forKey: Self.inFlightKey) }

    /// `eventQueue`, as soon as `screenshot-raw` returns (success or failure).
    func clear() { store.set(false, forKey: Self.inFlightKey) }

    /// The harvest is off on this device because a capture never returned.
    var isDisabled: Bool { store.bool(forKey: Self.disabledKey) }

    /// When a player opens: a flag left armed by a process that died mid-capture disables the
    /// harvest and is cleared. Returns true when this call disabled it (log it once).
    @discardableResult
    func checkAtLaunch() -> Bool {
        guard store.bool(forKey: Self.inFlightKey) else { return false }
        store.set(false, forKey: Self.inFlightKey)
        store.set(true, forKey: Self.disabledKey)
        return true
    }

    /// The Developer row: choosing any harvest value turns the guard's verdict off.
    func reenable() { store.set(false, forKey: Self.disabledKey) }
}
