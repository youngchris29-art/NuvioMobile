import Foundation

/// Search & Discover batch 2026-10-06 (B6): how Search results are laid out. Device-local
/// (`UserDefaults`, key `search_rows_mode`), set from Settings > Sources > Search Results.
/// `grouped` merges the add-ons' results into Top result / Movies / Series / People; `perAddon`
/// keeps one row per add-on catalog (what Search showed before the batch).
nonisolated enum SearchRowsMode: String, CaseIterable, Sendable {
    case grouped
    case perAddon = "per_addon"

    static let defaultsKey = "search_rows_mode"
    static let defaultValue: SearchRowsMode = .grouped

    /// nil, blank or unknown resolves to `defaultValue`. Trimmed and lower-cased.
    static func resolve(_ raw: String?) -> SearchRowsMode {
        guard let raw else { return defaultValue }
        return SearchRowsMode(rawValue: raw.trimmingCharacters(in: .whitespacesAndNewlines).lowercased())
            ?? defaultValue
    }

    static func current() -> SearchRowsMode {
        resolve(UserDefaults.standard.string(forKey: defaultsKey))
    }

    static func set(_ mode: SearchRowsMode) {
        UserDefaults.standard.set(mode.rawValue, forKey: defaultsKey)
    }

    var label: String {
        switch self {
        case .grouped: return String(localized: "Grouped by type")
        case .perAddon: return String(localized: "One row per add-on")
        }
    }
}
