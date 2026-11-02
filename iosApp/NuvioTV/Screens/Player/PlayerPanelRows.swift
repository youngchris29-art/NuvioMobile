import SwiftUI

// Rows shared by the player's popovers and pill content (both engines). They lived in
// PlayerTopPanel.swift until the swipe-down panel was removed (Insights, 2026-11-01).

/// One checkmark row of the Subtitles / Audio tab. DEFAULT tvOS button style on purpose: it draws
/// the white focus platter (the classic panel's focused-row look) and recolors the label itself.
/// `.borderless` would only brighten the label — invisible on an already-bright label (BUG-58
/// lesson) — and no explicit foreground color is set here so the platter's dark text wins.
struct PlayerPanelOptionRow: View {
    let option: PlayerPanelOption
    let identifierPrefix: String
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(alignment: .firstTextBaseline, spacing: Theme.Spacing.md) {
                Image(systemName: "checkmark")
                    .font(Theme.Font.body.weight(.semibold))
                    .opacity(option.isSelected ? 1 : 0)
                    .frame(width: 34)
                VStack(alignment: .leading, spacing: 2) {
                    Text(option.title)
                        .font(Theme.Font.body)
                        .lineLimit(1)
                    if let detail = option.detail {
                        Text(detail)
                            .font(Theme.Font.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                }
                Spacer(minLength: 0)
            }
            .contentShape(Rectangle())
        }
        // The selected row is where the focus lands when an mpv popover opens.
        .playerOverlayDefaultFocus(option.isSelected)
        .accessibilityIdentifier("\(identifierPrefix).\(option.id)")
        .accessibilityValue(Text(verbatim: option.isSelected ? "selected" : ""))
    }
}

/// Small uppercase column/section caption ("LANGUAGE", "SPEAKERS & HEADPHONES") — the classic
/// tvOS panel's column headers.
struct PlayerPanelSectionCaption: View {
    let text: String
    var body: some View {
        Text(text.uppercased())
            .font(Theme.Font.caption.weight(.semibold))
            .foregroundStyle(Theme.Palette.textSecondary)
            .padding(.bottom, Theme.Spacing.xxs)
    }
}

// MARK: - Overlay default focus (Insights device pass, 2026-11-01)

private struct PlayerOverlayFocusScopeKey: EnvironmentKey {
    static let defaultValue: Namespace.ID? = nil
}

extension EnvironmentValues {
    /// The focus scope of the mpv player's open popover or shelf (`MPVPlayerOverlay`); nil
    /// everywhere else (the native player's AVKit info panels place their own focus).
    var playerOverlayFocusScope: Namespace.ID? {
        get { self[PlayerOverlayFocusScopeKey.self] }
        set { self[PlayerOverlayFocusScopeKey.self] = newValue }
    }
}

/// Marks the view the focus should land on when an mpv popover or shelf opens (the selected row,
/// the first Cast card). Outside the mpv overlay's scope it does nothing.
private struct PlayerOverlayDefaultFocus: ViewModifier {
    @Environment(\.playerOverlayFocusScope) private var scope
    let preferred: Bool

    @ViewBuilder
    func body(content: Content) -> some View {
        if let scope {
            content.prefersDefaultFocus(preferred, in: scope)
        } else {
            content
        }
    }
}

extension View {
    func playerOverlayDefaultFocus(_ preferred: Bool) -> some View {
        modifier(PlayerOverlayDefaultFocus(preferred: preferred))
    }
}
