import Foundation
import SharedCore

/// Search & Discover batch 2026-10-06 (A5): where Discover lives. Device-local `@AppStorage`
/// (`discover_placement`), mirroring `HomeLayout`. The synced "Hide Discover" flag still wins, so
/// a profile that hid Discover on another device keeps it off here (`effective`).
///
/// Launch argument (DEBUG only): `-discover_placement off|search|tab` lands in the argument
/// domain; `current()` (what the tab tree resolves) treats it as an override over both the stored
/// value and the synced flag. `settingValue()` (what the Settings picker shows) ignores it, so the
/// picker still follows picks under the override (review r1 P3-6).
nonisolated enum DiscoverPlacement: String, CaseIterable, Sendable {
    case off
    case underSearch = "search"
    case ownTab = "tab"

    /// The `UserDefaults` key (device-local, not synced).
    static let defaultsKey = "discover_placement"

    static let defaultValue: DiscoverPlacement = .ownTab

    /// Device-local Int bumped by every Settings pick (`SettingsViewModel.setDiscoverPlacement`).
    /// It joins `ContentView`'s remount key, so a pick that leaves the stored string unchanged
    /// (stored "tab" while the synced flag hid Discover, then Own Tab again) still rebuilds the tab
    /// tree. A synced flip does not bump it: it applies at the next remount or launch (review r1
    /// P2-1).
    static let revisionKey = "discover_placement_revision"

    /// nil, blank or unknown resolves to `defaultValue`. Trimmed and lower-cased.
    static func resolve(_ raw: String?) -> DiscoverPlacement {
        guard let raw else { return defaultValue }
        return DiscoverPlacement(rawValue: raw.trimmingCharacters(in: .whitespacesAndNewlines).lowercased())
            ?? defaultValue
    }

    /// The synced "Hide Discover" flag wins: `hideDiscover` → `.off`, else `resolve(stored)`. In
    /// DEBUG, a non-nil `argumentOverride` wins over both.
    static func effective(stored: String?, hideDiscover: Bool, argumentOverride: String? = nil) -> DiscoverPlacement {
        if let argumentOverride { return resolve(argumentOverride) }
        if hideDiscover { return .off }
        return resolve(stored)
    }

    /// What a Settings pick writes: the raw value for UserDefaults and the synced hideDiscover
    /// flag (true only for `.off`).
    static func writes(for choice: DiscoverPlacement) -> (placementRaw: String, hideDiscover: Bool) {
        (choice.rawValue, choice == .off)
    }

    /// The stored value and the synced flag, without the DEBUG override: what the Settings picker
    /// shows and compares a pick against.
    /// `defaults` and `hideDiscover` are test seams (nil reads the synced flag).
    static func settingValue(defaults: UserDefaults = .standard, hideDiscover: Bool? = nil) -> DiscoverPlacement {
        effective(stored: defaults.string(forKey: defaultsKey),
                  hideDiscover: hideDiscover ?? HomeCatalogSettingsRepository.shared.snapshot().hideDiscover)
    }

    /// Reads the stored value, the synced flag and (DEBUG) the launch-argument override. What the
    /// tab tree resolves, once per tree (`MainTabView.showsDiscoverTab`).
    static func current() -> DiscoverPlacement {
        let stored = UserDefaults.standard.string(forKey: defaultsKey)
        let hide = HomeCatalogSettingsRepository.shared.snapshot().hideDiscover
        var override: String?
        #if DEBUG
        override = UserDefaults.standard
            .volatileDomain(forName: UserDefaults.argumentDomain)[defaultsKey] as? String
        #endif
        return effective(stored: stored, hideDiscover: hide, argumentOverride: override)
    }

    var label: String {
        switch self {
        case .off: return String(localized: "Off")
        case .underSearch: return String(localized: "Under Search")
        case .ownTab: return String(localized: "Own Tab")
        }
    }
}
