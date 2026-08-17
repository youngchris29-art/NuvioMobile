import SwiftUI

// One look for every transient player affordance ("Skip Intro/Outro/Recap", "Play Next Episode",
// the up-next countdown) on BOTH engines. On the native AVPlayer screen the interactive chips are
// AVPlayerViewController.contextualActions (Apple's own affordance — focusable glass pill, system
// position); the mpv screen can't host focusable UI (libmpv owns the remote), so it draws
// `PlayerActionChip` in the same spot with the same label/symbol and triggers on D-pad Down. The
// countdown/status caption is app-drawn on both engines (`PlayerChipCaption`) because a UIAction
// title that changes every second re-animates the whole transport bar.
enum PlayerChipStyle {
    static let animation: Animation = .easeInOut(duration: 0.25)
    /// Bottom-trailing inset from the screen edge (overscan-safe), both engines.
    static let edgePadding: CGFloat = Theme.Spacing.screen
    /// SF Symbols mirrored on the native contextual actions.
    static let skipSymbol = "forward.frame.fill"
    static let nextSymbol = "forward.end.fill"
    /// Neutral Liquid Glass (docs/design/hig-hybrid-contract.md): a prompt is an action, not a
    /// selection, so it never wears the brand accent.
    static let glassTint = Color.black.opacity(0.45)
    /// Skip window ends this many seconds before the segment end so the affordance disappears
    /// cleanly (both engines' `updateSkipPrompt`).
    static let lastSecondExclusion: Double = 1
}

/// Non-focusable action chip drawn by the mpv screen (the native screen uses contextualActions).
struct PlayerActionChip: View {
    let label: String
    let symbol: String
    /// Trailing D-pad-down glyph — the mpv screen's trigger hint.
    var showsPressHint = false

    var body: some View {
        HStack(spacing: Theme.Spacing.sm) {
            Image(systemName: symbol)
            Text(label)
            if showsPressHint {
                Image(systemName: "chevron.down.circle.fill")
                    .foregroundStyle(Theme.Palette.textSecondary)
            }
        }
        .font(Theme.Font.sectionTitle)
        .foregroundStyle(Theme.Palette.textPrimary)
        .padding(.horizontal, Theme.Spacing.lg + Theme.Spacing.xs)
        .padding(.vertical, Theme.Spacing.md)
        .glassEffect(.regular.tint(PlayerChipStyle.glassTint), in: .capsule)
        .shadow(color: .black.opacity(0.4), radius: 10, y: 4)
        .accessibilityElement(children: .combine)
    }
}

/// Small status/countdown capsule shown above the action chip(s). Never focusable.
struct PlayerChipCaption: View {
    let text: String
    var symbol: String? = nil
    var showsProgress = false

    var body: some View {
        HStack(spacing: Theme.Spacing.xs) {
            if showsProgress { ProgressView().scaleEffect(0.6) }
            if let symbol { Image(systemName: symbol) }
            Text(text).monospacedDigit().lineLimit(1)
        }
        .font(Theme.Font.meta)
        .foregroundStyle(Theme.Palette.textSecondary)
        .padding(.horizontal, Theme.Spacing.md)
        .padding(.vertical, Theme.Spacing.xs)
        .glassEffect(.regular.tint(PlayerChipStyle.glassTint), in: .capsule)
        .frame(maxWidth: 620, alignment: .trailing)
    }
}

extension NextEpisodeEngine.Phase {
    /// Caption text for the up-next phase (nil = no caption). Shared by both engines.
    func chipCaption(nextTitle: String) -> (text: String, symbol: String?, progress: Bool)? {
        switch self {
        case .hidden: return nil
        case .searching: return (String(localized: "Finding next episode…"), nil, true)
        case .counting(let seconds):
            let title = nextTitle.count > 40 ? String(nextTitle.prefix(38)) + "…" : nextTitle
            return (String(localized: "Up next · \(title) · playing in \(seconds)s"), "forward.end", false)
        case .stillWatching: return (String(localized: "Still watching?"), "questionmark.circle", false)
        case .noStream: return (String(localized: "No stream found for the next episode."), "exclamationmark.circle", false)
        }
    }
}
