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

    /// Bumped by every scheduled announcement and by `invalidatePending()`: a scheduled one posts
    /// only if nothing came after it.
    @MainActor private(set) static var generation = 0

    /// How long a move announcement waits: the focus hand-off and VoiceOver's reading of the row
    /// come first, so the announcement neither cuts them off nor is cut off by them.
    static let settleDelay: TimeInterval = 0.5

    /// Review VO-r1…r6: posts `event` once the focus change has settled, and only if `isCurrent`
    /// still holds then (the same row still moving for `.started`; focus still on the moved row,
    /// nothing pushed, for the results) and no newer announcement or teardown came first. The
    /// condition is checked when it fires, so ANY change of focus or state in between (another
    /// row, the sidebar, the tab bar, a page, another move) drops it without listing the paths.
    @MainActor
    static func announceWhenSettled(_ event: MoveEvent, isCurrent: @escaping @MainActor () -> Bool) {
        generation += 1
        let scheduled = generation
        DispatchQueue.main.asyncAfter(deadline: .now() + settleDelay) {
            guard scheduled == generation, isCurrent() else { return }
            announce(event)
        }
    }

    /// Review VO-r7: the "still current" rule both panes use when a move announcement fires.
    /// Focus must still be on the moved row (`rowKey`), in the pane's own section, with no page
    /// pushed over it; for `.started` the row (`key`) must still be the lifted one, for the
    /// results nothing may be lifted any more.
    static func isMoveAnnouncementCurrent(
        _ event: MoveEvent, key: String, rowKey: String,
        focusedKey: String?, liftedKey: String?, pageOpen: Bool, inSection: Bool
    ) -> Bool {
        guard inSection, !pageOpen, focusedKey == rowKey else { return false }
        return event == .started ? liftedKey == key : liftedKey == nil
    }

    /// Drops an announcement still waiting (the pane that scheduled it went away).
    @MainActor
    static func invalidatePending() {
        generation += 1
    }

    /// Where an announcement goes: VoiceOver; tests swap it to capture what would be spoken.
    @MainActor static var post: (String) -> Void = { AccessibilityNotification.Announcement($0).post() }

    @MainActor
    static func announce(_ event: MoveEvent) {
        post(announcement(event))
    }
}
