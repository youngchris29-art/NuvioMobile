import Foundation
import SharedCore

/// Search & Discover batch 2026-10-06 (A5): where Discover lives. Device-local `@AppStorage`
/// (`discover_placement`), mirroring `HomeLayout`. The synced "Hide Discover" flag still wins, so
/// a profile that hid Discover on another device keeps it off here (`effective`).
///
/// Launch argument (DEBUG only): `-discover_placement off|search|tab` lands in the argument
/// domain; `current()` treats it as an override over both the stored value and the synced flag.
nonisolated enum DiscoverPlacement: String, CaseIterable, Sendable {
    case off
    case underSearch = "search"
    case ownTab = "tab"

    /// The `UserDefaults` key (device-local, not synced).
    static let defaultsKey = "discover_placement"

    static let defaultValue: DiscoverPlacement = .ownTab

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

    /// Reads the stored value, the synced flag and (DEBUG) the launch-argument override.
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
