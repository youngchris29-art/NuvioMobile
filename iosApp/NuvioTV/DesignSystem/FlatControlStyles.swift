import SwiftUI

/// Platter-free replacement for `.card` on full-width text rows (settings rows, sidebar
/// categories, trailer/comment rows). Transparent at rest; while focused it draws a soft white
/// highlight plus the brand focus ring, so the row stays legible at 10 feet without the system
/// grey platter. The `Button` remains the focusable element, same as `PosterButtonStyle`.
struct SettingsRowButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        RowBody(configuration: configuration)
    }

    private struct RowBody: View {
        let configuration: Configuration
        @Environment(\.isFocused) private var isFocused

        var body: some View {
            configuration.label
                .background(
                    RoundedRectangle(cornerRadius: Theme.Radius.card)
                        .fill(Color.white.opacity(isFocused ? 0.1 : 0))
                )
                .overlay(
                    RoundedRectangle(cornerRadius: Theme.Radius.card)
                        .strokeBorder(Theme.Palette.accentFocus, lineWidth: isFocused ? 2 : 0)
                )
                .scaleEffect(isFocused ? 1.02 : 1)
                .scaleEffect(configuration.isPressed ? 0.97 : 1)
                .animation(.easeOut(duration: 0.15), value: isFocused)
                .animation(.easeOut(duration: 0.12), value: configuration.isPressed)
        }
    }
}

extension ButtonStyle where Self == SettingsRowButtonStyle {
    /// Platter-free style for full-width text rows.
    static var settingsRow: SettingsRowButtonStyle { .init() }
}

/// Platter-free replacement for `.bordered` chips. Unselected chips are outline-only; selected
/// chips fill with the theme accent. Focus reads as scale + the brand focus ring (white on
/// selected chips so it stands out against the accent fill).
struct ChipButtonStyle: ButtonStyle {
    var selected = false

    func makeBody(configuration: Configuration) -> some View {
        ChipBody(configuration: configuration, selected: selected)
    }

    private struct ChipBody: View {
        let configuration: Configuration
        let selected: Bool
        @Environment(\.isFocused) private var isFocused

        private var strokeColor: Color {
            // Focused+selected used a hardcoded white ring to stand out against the accent fill —
            // on the White theme that fill IS white, so the ring vanished exactly like the label
            // text did. `accentText` contrasts with the fill on every theme (dark ring on the
            // White theme's near-white fill, the previous light ring everywhere else).
            if isFocused { return selected ? Theme.Palette.accentText : Theme.Palette.accentFocus }
            return selected ? .clear : Theme.Palette.textSecondary.opacity(0.35)
        }

        var body: some View {
            configuration.label
                // Selected chips fill with the theme accent — on the White theme that fill is
                // near-white, so pin the text/icon color to the accent-aware `accentText` rather
                // than letting it fall through to the caller's (often unset, default-light) color.
                .foregroundStyle(selected ? Theme.Palette.accentText : Theme.Palette.textPrimary)
                .frame(minWidth: 40, minHeight: 40)
                .background(Capsule().fill(selected ? Theme.Palette.accent : .clear))
                .overlay(Capsule().strokeBorder(strokeColor, lineWidth: isFocused ? 3 : 1))
                .scaleEffect(isFocused ? 1.05 : 1)
                .scaleEffect(configuration.isPressed ? 0.97 : 1)
                .animation(.easeOut(duration: 0.15), value: isFocused)
                .animation(.easeOut(duration: 0.12), value: configuration.isPressed)
        }
    }
}

extension ButtonStyle where Self == ChipButtonStyle {
    /// Outline chip with no selection state.
    static var chip: ChipButtonStyle { .init() }
    /// Chip that fills with the theme accent when selected.
    static func chip(selected: Bool) -> ChipButtonStyle { .init(selected: selected) }
}

/// Label color for accent-tinted `.borderedProminent` buttons. tvOS swaps the prominent platter to
/// a near-white "lifted" fill on focus regardless of tint, so no fixed label color works: focused
/// needs dark text, unfocused needs the accent's contrast color (`Theme.Palette.accentText`). An
/// explicit `foregroundStyle` would disable the system's automatic label flip — this restores it.
struct ProminentAccentLabel: ViewModifier {
    @Environment(\.isFocused) private var isFocused

    func body(content: Content) -> some View {
        content.foregroundStyle(isFocused ? Color(hex: 0x0D0D0D) : Theme.Palette.accentText)
    }
}

extension View {
    /// Apply to the label of an accent-tinted `.borderedProminent` button.
    func prominentAccentLabel() -> some View { modifier(ProminentAccentLabel()) }
}
