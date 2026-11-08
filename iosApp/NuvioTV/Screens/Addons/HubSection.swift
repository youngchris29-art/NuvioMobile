import Foundation

/// Add-ons hub v2 (A1): the sidebar sections of the two-column Add-ons page, in display order.
nonisolated enum HubSection: String, CaseIterable, Hashable, Sendable {
    case installed, catalogs, debrid, plugins, install, refresh, phone

    /// The sidebar row's label.
    var title: String {
        switch self {
        case .installed: return String(localized: "Installed")
        case .catalogs: return String(localized: "Catalogs")
        case .debrid: return String(localized: "Debrid")
        case .plugins: return String(localized: "Plugins")
        case .install: return String(localized: "Install add-on")
        case .refresh: return String(localized: "Refresh all")
        case .phone: return String(localized: "Manage from phone")
        }
    }

    /// The SF Symbol drawn beside the label.
    var systemImage: String {
        switch self {
        case .installed: return "puzzlepiece.extension"
        case .catalogs: return "square.grid.2x2"
        case .debrid: return "bolt.horizontal"
        case .plugins: return "powerplug"
        case .install: return "plus.circle"
        case .refresh: return "arrow.clockwise"
        case .phone: return "iphone"
        }
    }

    /// True only for Refresh all: an action row runs on Select and never becomes the content section.
    var isAction: Bool { self == .refresh }

    /// Whether the row shows: Manage from phone only when `phoneEnabled`, everything else always.
    /// Plugins stays visible while plugins are off (review r4): its pane holds the switch that
    /// turns them back on, so hiding the row stranded the user.
    func isVisible(summary: AddonsViewModel.HubSummary, phoneEnabled: Bool) -> Bool {
        switch self {
        case .phone: return phoneEnabled
        default: return true
        }
    }

    /// The visible sections in display order.
    static func visible(summary: AddonsViewModel.HubSummary, phoneEnabled: Bool) -> [HubSection] {
        allCases.filter { $0.isVisible(summary: summary, phoneEnabled: phoneEnabled) }
    }

    /// The short value drawn at the row's trailing edge, or nil when the row has none (the view
    /// draws the refresh stamp itself).
    func trailingValue(summary: AddonsViewModel.HubSummary) -> String? {
        switch self {
        case .installed:
            return "\(summary.addonsInstalled)"
        case .catalogs:
            return String(localized: "\(summary.catalogsOn) of \(summary.catalogsTotal)")
        case .debrid:
            return summary.debridConnected.isEmpty
                ? String(localized: "Not connected")
                : summary.debridConnected.joined(separator: ", ")
        case .plugins:
            return summary.plugins.map { "\($0.providers)" } ?? String(localized: "Off")
        case .install, .refresh, .phone:
            return nil
        }
    }

    /// The stored section to restore: `raw` when it names a visible, non-action section, else Installed.
    static func resolved(raw: String?, visible: [HubSection]) -> HubSection {
        guard let raw, let section = HubSection(rawValue: raw),
              visible.contains(section), !section.isAction else { return .installed }
        return section
    }
}

/// Add-ons hub v2 C2: another screen (Settings › Account & Profiles) asks for a hub section. The
/// shell switches to the Add-ons tab on the notification; the hub selects the section at once
/// when it is mounted, or on its next appearance from `pending`.
@MainActor
enum AddonsHubRequests {
    static let notification = Notification.Name("com.nuvio.tv.openAddonsSection")
    /// The section asked for and not yet shown.
    static var pending: HubSection?

    static func open(_ section: HubSection) {
        pending = section
        NotificationCenter.default.post(name: notification, object: nil, userInfo: ["section": section.rawValue])
    }

    /// The pending section, once (the hub calls this when it shows it).
    static func take() -> HubSection? {
        defer { pending = nil }
        return pending
    }
}
