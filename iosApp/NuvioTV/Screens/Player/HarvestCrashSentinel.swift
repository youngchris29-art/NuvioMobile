import Foundation

/// The key-value calls the sentinel needs; `UserDefaults` conforms as is, tests use a dictionary.
nonisolated protocol HarvestSentinelStore: AnyObject {
    func bool(forKey key: String) -> Bool
    func string(forKey key: String) -> String?
    func set(_ value: Bool, forKey key: String)
    func set(_ value: Any?, forKey key: String)
}

nonisolated extension UserDefaults: HarvestSentinelStore {}

/// Crash guard for the seek-preview harvest (review r1 P2 #3). Its one native call,
/// `screenshot-raw`, aborts the app on the simulator's Metal driver, and whether Apple TV
/// hardware survives the same readback is unproven. The flag is armed just before each real
/// capture and cleared when the call returns; a flag still armed when the next player opens means
/// the process died mid-capture, and the harvest turns itself off on this device until someone
/// picks a value in Settings › Developer › Thumbnail Harvest (A/B).
///
/// The flag holds the arming process's token (review r2 P3 #2): a player opening while another
/// controller of the same process is inside a capture (next-episode autoplay, Replay) finds this
/// process's own token and leaves it alone; only a token from an earlier process is a crash.
/// Only a file's first capture is synchronised to disk (`CFPreferencesAppSynchronize`), so a crash
/// on a later capture of the same file can lose the armed write; the first-capture case is the
/// deterministic one this guards.
///
/// Known limit (review r3 P3 #4): the key is one per process, so two controllers of the same
/// process capturing at once (the next-episode hand-off window) share it and the first `clear()`
/// removes the second capture's flag. A crash inside that overlap goes undetected on that launch
/// and is caught on the next capture that dies. Per-controller keys were not worth the extra
/// launch-time scan for a window this short.
nonisolated struct HarvestCrashSentinel {
    static let inFlightKey = "player.harvestInFlightOwner"
    static let disabledKey = "player.harvestDisabledByCrash"
    /// One per process, so a flag armed by this process is never read as a crash.
    static let processToken = UUID().uuidString

    let store: HarvestSentinelStore
    var token: String = Self.processToken

    /// `eventQueue`, immediately before `screenshot-raw`.
    func arm() { store.set(token, forKey: Self.inFlightKey) }

    /// `eventQueue`, as soon as `screenshot-raw` returns (success or failure).
    func clear() { store.set(nil, forKey: Self.inFlightKey) }

    /// The harvest is off on this device because a capture never returned.
    var isDisabled: Bool { store.bool(forKey: Self.disabledKey) }

    /// When a player opens: a flag left armed by an earlier process (one that died mid-capture)
    /// disables the harvest and is cleared; this process's own flag is a capture in progress.
    /// Returns true when this call disabled it (log it once).
    @discardableResult
    func checkAtLaunch() -> Bool {
        guard let owner = store.string(forKey: Self.inFlightKey), owner != token else { return false }
        store.set(nil, forKey: Self.inFlightKey)
        store.set(true, forKey: Self.disabledKey)
        return true
    }

    /// The Developer row: choosing any harvest value turns the guard's verdict off.
    func reenable() { store.set(false, forKey: Self.disabledKey) }
}
