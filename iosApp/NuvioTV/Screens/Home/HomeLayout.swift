import Foundation

/// Home Stage & Strip (H1, plan 2026-10-03; P2 spec section 3.1): which Home the viewer gets.
///
///   - Stage   : the new Home. The focused title is drawn at the top of the screen (the stage)
///               with one row of posters below it, and Up / Down move one whole row at a time.
///               The default.
///   - Classic : the previous Home, the rotating banner or focus panel above scrolling rows.
///
/// The choice is the device-local `home_layout` string, never synced: like every other Home look
/// key (`hero_nuvio_style`, `inline_trailers_enabled`) it is a per-device display preference, not
/// account state. Every reader is LIVE (`@AppStorage`, no root `.id` remount: `hero_nuvio_style`
/// already flips layouts live at the same branch point in `HomeView`), and every reader passes
/// `HomeLayout.defaultValue.rawValue` as its `@AppStorage` default, so an unset key reads Stage
/// everywhere. Readers: `HomeView`, the folder page, and the Home Screen and Appearance Settings
/// panes. They all read this file, so there is exactly one copy of the key.
///
/// Stage is the default for new AND existing users, with no migration (P2-8): nothing is written
/// at launch, so a profile that never touched the setting simply gets the new Home.
///
/// Launch argument: `-home_layout classic|stage` lands in the argument domain, which is in
/// `UserDefaults.standard`'s search list, so both `current()` and `@AppStorage(HomeLayout.defaultsKey)`
/// see it (the same mechanism as `-detail_layout`). WARNING: the argument domain shadows the app
/// domain for the whole process. A picker write lands in the app domain, but every read keeps
/// returning the argument, so a UI test that flips the Home Layout picker must not pass
/// `-home_layout`.
nonisolated enum HomeLayout: String, CaseIterable, Sendable {
    case stage
    case classic

    /// The `UserDefaults` key (device-local `@AppStorage`, not synced).
    static let defaultsKey = "home_layout"

    /// Stage for everyone (P2-8).
    static let defaultValue: HomeLayout = .stage

    /// nil, blank or unknown resolves to `defaultValue`. Trimmed and lower-cased, so a hand-typed
    /// launch argument (`-home_layout Classic`) still resolves.
    static func resolve(_ raw: String?) -> HomeLayout {
        guard let raw else { return defaultValue }
        return HomeLayout(rawValue: raw.trimmingCharacters(in: .whitespacesAndNewlines).lowercased())
            ?? defaultValue
    }

    static func current(_ defaults: UserDefaults = .standard) -> HomeLayout {
        resolve(defaults.string(forKey: defaultsKey))
    }

    /// The Home Screen settings picker label ("Classic" already exists in the string catalog).
    var label: String {
        switch self {
        case .stage: return String(localized: "Stage")
        case .classic: return String(localized: "Classic")
        }
    }
}
