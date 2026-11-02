import SwiftUI

extension PillKind {
    /// Fixed order: subtitles, audio, speed, aspect, sources, episodes, more.
    static func visible(isSeries: Bool, canSwitchStreams: Bool, hasEpisodes: Bool) -> [PillKind] {
        var out: [PillKind] = [.subtitles, .audio, .speed, .aspect]
        if canSwitchStreams { out.append(.sources) }
        if canSwitchStreams && isSeries && hasEpisodes { out.append(.episodes) }
        out.append(.more)
        return out
    }

    var symbol: String {
        switch self {
        case .subtitles: return "captions.bubble"
        case .audio: return "speaker.wave.2"
        case .speed: return "gauge.with.dots.needle.67percent"
        case .aspect: return "aspectratio"
        case .sources: return "square.stack.3d.up"
        case .episodes: return "list.bullet.rectangle"
        case .more: return "ellipsis"
        }
    }

    var title: String {
        switch self {
        case .subtitles: return String(localized: "Subtitles")
        case .audio: return String(localized: "Audio")
        case .speed: return String(localized: "Speed")
        case .aspect: return String(localized: "Aspect")
        case .sources: return String(localized: "Sources")
        case .episodes: return String(localized: "Episodes")
        case .more: return String(localized: "More")
        }
    }

    /// One place on the row, clamped at the ends (no wrap). Not in `pills` → the first pill.
    static func move(from current: PillKind, by delta: Int, in pills: [PillKind]) -> PillKind? {
        guard !pills.isEmpty else { return nil }
        guard let i = pills.firstIndex(of: current) else { return pills.first }
        return pills[min(max(i + delta, 0), pills.count - 1)]
    }
}

/// The disc row. Nothing here is focusable: the mpv controller routes the remote and publishes
/// `focusedPill`; the discs just draw the focused look.
struct PlayerPillRow: View {
    @ObservedObject var model: TransportBarModel

    var body: some View {
        HStack(spacing: TransportBarLayout.pillSpacing) {
            ForEach(model.pills, id: \.self) { kind in
                // An open popover keeps its disc lit, so the popover reads as coming from it.
                let focused = model.focusedPill == kind || model.openPopover == kind
                PlayerPillDisc(symbol: kind.symbol, focused: focused)
                    .accessibilityElement()
                    .accessibilityLabel(kind.title)
                    .accessibilityAddTraits(.isButton)
                    .accessibilityValue(focused ? "focused" : "")
                    .accessibilityIdentifier("player.pill.\(kind.rawValue)")
            }
        }
    }
}
