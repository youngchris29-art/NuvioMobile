import SwiftUI

/// Focus treatment shared by the custom control styles below (HIG revamp, see
/// docs/design/hig-hybrid-contract.md): these mimic the SYSTEM tvOS focus language — the platter
/// turns near-white and the label flips dark, with a small lift — rather than the old brand
/// accent rings. Custom `ButtonStyle`s are kept only where a system style can't express the
/// shape (capsule chips with a selected fill; full-width transparent rows pending the Settings
/// List conversion). Everything else should use `.borderless` / `.card` / `.glass` /
/// `.bordered` directly.
private enum FocusLook {
    /// System focus platter color (near-white, as `.bordered`/`.card` render it).
    static let platter = Color.white
    /// Label color on the focused platter.
    static let onPlatter = Color.black.opacity(0.85)
    static let liftScale: CGFloat = 1.05
    static let pressScale: CGFloat = 0.97
    static let anim = Animation.easeOut(duration: 0.15)
    static let pressAnim = Animation.easeOut(duration: 0.12)
    /// Soft shadow under a lifted (focused) control — reads as elevation, not glow.
    static func liftShadow(_ isFocused: Bool) -> Color { .black.opacity(isFocused ? 0.45 : 0) }
}

/// Full-width text row style used by Settings (pending the native List conversion) and a few
/// content rows. Transparent at rest; focused it renders the system look: near-white platter,
/// dark label, slight lift.
struct SettingsRowButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        RowBody(configuration: configuration)
    }

    private struct RowBody: View {
        let configuration: Configuration
        @Environment(\.isFocused) private var isFocused

        var body: some View {
            configuration.label
                .foregroundStyle(isFocused ? FocusLook.onPlatter : Theme.Palette.textPrimary)
                // The label's own semantic colors (.primary/.secondary — e.g. subtitles, stream
                // metadata) don't inherit the foregroundStyle above; flipping the scheme makes
                // them resolve dark on the white focus platter (device feedback: light-on-white
                // text in the stream picker / settings rows was illegible).
                .environment(\.colorScheme, isFocused ? .light : .dark)
                .background(
                    RoundedRectangle(cornerRadius: Theme.Radius.card)
                        .fill(isFocused ? FocusLook.platter : .clear)
                )
                .shadow(color: FocusLook.liftShadow(isFocused), radius: 16, y: 8)
                .scaleEffect(isFocused ? 1.02 : 1)
                .scaleEffect(configuration.isPressed ? FocusLook.pressScale : 1)
                .animation(FocusLook.anim, value: isFocused)
                .animation(FocusLook.pressAnim, value: configuration.isPressed)
        }
    }
}

extension ButtonStyle where Self == SettingsRowButtonStyle {
    /// Platter-free-at-rest style for full-width text rows (system-look focus).
    static var settingsRow: SettingsRowButtonStyle { .init() }
}

/// Capsule chip. System focus language: grey platter at rest, near-white platter + dark label
/// while focused, small lift. Selection (the one place the brand accent is allowed) shows as an
/// accent fill at rest; focus always overrides it with the system white platter — exactly how
/// native tvOS pickers treat a focused selected item.
struct ChipButtonStyle: ButtonStyle {
    var selected = false

    func makeBody(configuration: Configuration) -> some View {
        ChipBody(configuration: configuration, selected: selected)
    }

    private struct ChipBody: View {
        let configuration: Configuration
        let selected: Bool
        @Environment(\.isFocused) private var isFocused

        private var fill: Color {
            if isFocused { return FocusLook.platter }
            if selected { return Theme.Palette.accent }
            return Color.white.opacity(0.1)
        }

        private var labelColor: Color {
            if isFocused { return FocusLook.onPlatter }
            if selected { return Theme.Palette.accentText }
            return Theme.Palette.textPrimary
        }

        var body: some View {
            configuration.label
                .foregroundStyle(labelColor)
                // Same semantic-color flip as SettingsRowButtonStyle — chip labels with their own
                // .secondary text stay legible on the white focus platter.
                .environment(\.colorScheme, isFocused ? .light : .dark)
                .frame(minWidth: 40, minHeight: 40)
                .background(Capsule().fill(fill))
                .shadow(color: FocusLook.liftShadow(isFocused), radius: 16, y: 8)
                .scaleEffect(isFocused ? FocusLook.liftScale : 1)
                .scaleEffect(configuration.isPressed ? FocusLook.pressScale : 1)
                .animation(FocusLook.anim, value: isFocused)
                .animation(FocusLook.pressAnim, value: configuration.isPressed)
        }
    }
}

extension ButtonStyle where Self == ChipButtonStyle {
    /// Capsule chip with no selection state.
    static var chip: ChipButtonStyle { .init() }
    /// Chip that fills with the theme accent when selected (at rest; focus overrides).
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

/// Accent tint for icons/labels that sit INSIDE a focusable row or chip (BUG-22). The row
/// styles above flip their platter to near-white on focus and rely on semantic colors flipping
/// with the forced light `colorScheme` — but an explicit `Theme.Palette.accent` bypasses that,
/// and the White theme's accent (~#F5F5F5) disappears on the white platter (state checkmarks,
/// row icons, the sidebar's selected category — the reporter's "white-on-white settings").
/// At rest the accent applies; on focus the content joins the platter's dark label color.
struct RowAccentTint: ViewModifier {
    /// When false the content shows [inactiveColor] instead of the accent (e.g. an unchecked
    /// state circle) — pass a SEMANTIC color so the row's colorScheme flip keeps it legible.
    var active = true
    var inactiveColor: Color = Theme.Palette.textSecondary
    @Environment(\.isFocused) private var isFocused

    func body(content: Content) -> some View {
        content.foregroundStyle(
            active ? (isFocused ? FocusLook.onPlatter : Theme.Palette.accent) : inactiveColor
        )
    }
}

extension View {
    /// Focus-aware accent for content inside `.settingsRow`/`.chip`-styled buttons — see
    /// [RowAccentTint]. Never use a bare `Theme.Palette.accent` inside those rows.
    func rowAccentTint(_ active: Bool = true, inactiveColor: Color = Theme.Palette.textSecondary) -> some View {
        modifier(RowAccentTint(active: active, inactiveColor: inactiveColor))
    }
}
