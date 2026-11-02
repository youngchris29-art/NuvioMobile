import SwiftUI

// Insights (2026-11-01): the mpv route's text pill row under the times row (Info · Cast ·
// Chapters · Up Next). Same pattern as the disc row (`PlayerPills.swift`): nothing focusable, the
// controller routes the remote and publishes `TransportBarModel.focusedInfoPill`.

extension PlayerInfoPill {
    /// One place on the row, clamped at the ends (no wrap). Not in `pills` → the first pill.
    static func move(from current: PlayerInfoPill, by delta: Int, in pills: [PlayerInfoPill]) -> PlayerInfoPill? {
        guard !pills.isEmpty else { return nil }
        guard let i = pills.firstIndex(of: current) else { return pills.first }
        return pills[min(max(i + delta, 0), pills.count - 1)]
    }

    /// The row changed under the focus (Cast loaded, the next episode went away): a focused pill
    /// that left the row moves to the nearest one still on it, at its old place clamped; an open
    /// shelf whose pill left closes.
    static func reconcile(focused: PlayerInfoPill?, open: PlayerInfoPill?, old: [PlayerInfoPill],
                          new: [PlayerInfoPill]) -> (focused: PlayerInfoPill?, open: PlayerInfoPill?) {
        var f = focused
        if let current = focused, !new.contains(current) {
            let index = old.firstIndex(of: current) ?? 0
            f = new.isEmpty ? nil : new[min(index, new.count - 1)]
        }
        let o = open.flatMap { new.contains($0) ? $0 : nil }
        return (f, o)
    }
}

/// The text pill row. The focused pill and the pill whose shelf is open draw the focused look.
struct PlayerInfoPillRow: View {
    @ObservedObject var model: TransportBarModel

    var body: some View {
        HStack(spacing: TransportBarLayout.infoPillSpacing) {
            ForEach(model.infoPills) { pill in
                let focused = model.focusedInfoPill == pill || model.openInfoPill == pill
                PlayerInfoPillCapsule(title: pill.title, focused: focused)
                    .accessibilityElement()
                    .accessibilityLabel(pill.title)
                    .accessibilityAddTraits(.isButton)
                    .accessibilityValue(focused ? "focused" : "")
                    .accessibilityIdentifier("player.infoPill.\(pill.rawValue)")
            }
        }
    }
}
