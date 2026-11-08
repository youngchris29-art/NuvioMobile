import SwiftUI

/// Add-ons hub v2: VoiceOver wording, from Christian's check on the Apple TV (2026-11-08).
///
/// On the box VoiceOver read the sidebar rows as just "Installed, button": the row's
/// `accessibilityValue` (the count) and its `.isSelected` trait were not spoken, so the sidebar
/// label carries both itself. Move mode's start was never spoken either (the badge appears on the
/// row without a focus change), so starting, dropping and cancelling a move post an announcement,
/// and the lifted row's value starts with "Moving".
nonisolated enum HubAccessibility {
    /// The sidebar row's spoken label: the section, its trailing value when it has one, and
    /// "current section" for the section the right column shows.
    static func sidebarLabel(title: String, value: String, isSelected: Bool) -> String {
        var parts = [title]
        let trimmed = value.trimmingCharacters(in: .whitespaces)
        if !trimmed.isEmpty { parts.append(trimmed) }
        if isSelected { parts.append(String(localized: "current section")) }
        return parts.joined(separator: ", ")
    }

    /// A row's spoken value, led by "Moving" while the row is lifted.
    static func rowValue(_ base: String, isMoving: Bool) -> String {
        isMoving ? String(localized: "Moving") + ", " + base : base
    }

    enum MoveEvent: Equatable {
        case started, committed, cancelled
    }

    /// What VoiceOver says when a move starts, drops or is cancelled.
    static func announcement(_ event: MoveEvent) -> String {
        switch event {
        case .started: return String(localized: "Moving. Press Up or Down, then Select to drop it, or Menu to cancel.")
        case .committed: return String(localized: "Moved.")
        case .cancelled: return String(localized: "Move cancelled.")
        }
    }

    @MainActor
    static func announce(_ event: MoveEvent) {
        AccessibilityNotification.Announcement(announcement(event)).post()
    }
}
