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
            if isFocused { return selected ? .white : Theme.Palette.accentFocus }
            return selected ? .clear : Theme.Palette.textSecondary.opacity(0.35)
        }

        var body: some View {
            configuration.label
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
