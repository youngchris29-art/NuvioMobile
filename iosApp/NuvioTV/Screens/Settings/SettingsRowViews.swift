import SwiftUI
import SharedCore

/// Wraps one titled settings sub-section: a section title + its content, as its own nested focus
/// region so vertical swipes enter the nearest section without needing precise horizontal
/// alignment with the next control. Shared by every `*SettingsPane` in this folder — each pane's
/// body is just a stack of these.
@ViewBuilder
func settingsSection<Content: View>(
    _ title: String,
    @ViewBuilder content: () -> Content
) -> some View {
    VStack(alignment: .leading, spacing: Theme.Spacing.md) {
        Text(title)
            .font(Theme.Font.sectionTitle)
            .foregroundStyle(Theme.Palette.textPrimary)
        content()
    }
    .focusSection()
}

/// Focus-aware title/subtitle/value text color for content inside `.settingsRow`-styled buttons
/// (BUG-4/14/22/28/33 white-on-white class). An explicit `Theme.Palette.textPrimary`/
/// `textSecondary` on a Text bypasses `SettingsRowButtonStyle`'s dark-label treatment and
/// `colorScheme` flip on focus, leaving light text on the near-white focus platter — same fix
/// shape as `RowAccentTint` (FlatControlStyles.swift), applied to row text instead of icon tints.
private struct RowTextColor: ViewModifier {
    /// Secondary variant (subtitles/values/chevrons) dims slightly even on the focused platter,
    /// mirroring the textPrimary/textSecondary contrast used unfocused.
    var secondary = false
    @Environment(\.isFocused) private var isFocused

    func body(content: Content) -> some View {
        content.foregroundStyle(
            isFocused
                ? Theme.Palette.onFocusPlatter.opacity(secondary ? 0.7 : 1)
                : (secondary ? Theme.Palette.textSecondary : Theme.Palette.textPrimary)
        )
    }
}

private extension View {
    /// Focus-aware replacement for a bare `.foregroundStyle(Theme.Palette.textPrimary/textSecondary)`
    /// on title/subtitle/value/chevron text inside `.settingsRow`-styled buttons.
    func rowTextColor(secondary: Bool = false) -> some View {
        modifier(RowTextColor(secondary: secondary))
    }
}

/// A focusable settings row that performs an action on select (chevron affordance).
struct SettingsActionRow: View {
    let title: String
    let subtitle: String
    let systemImage: String
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: Theme.Spacing.lg) {
                Image(systemName: systemImage)
                    .font(Theme.Font.body)
                    .rowAccentTint()
                VStack(alignment: .leading, spacing: Theme.Spacing.xxs) {
                    Text(title)
                        .font(Theme.Font.body)
                        .rowTextColor()
                    Text(subtitle)
                        .font(Theme.Font.caption)
                        .rowTextColor(secondary: true)
                }
                Spacer()
                Image(systemName: "chevron.right")
                    .font(Theme.Font.body)
                    .rowTextColor(secondary: true)
            }
            .padding(Theme.Spacing.lg)
            .frame(maxWidth: .infinity)
        }
        .buttonStyle(.settingsRow)
    }
}

/// A focusable, read-only settings row that shows a title/value pair (e.g. About pane entries).
/// Focusable (not just a plain HStack) so it participates in the same D-pad flow as the other
/// rows in its section and picks up the platter/label treatment via `.settingsRow`.
struct SettingsInfoRow: View {
    let title: String
    let value: String
    var systemImage: String? = nil

    var body: some View {
        Button(action: {}) {
            HStack(spacing: Theme.Spacing.lg) {
                if let systemImage {
                    Image(systemName: systemImage)
                        .font(Theme.Font.body)
                        .rowAccentTint()
                }
                Text(title)
                    .font(Theme.Font.body)
                    .rowTextColor()
                Spacer()
                Text(value)
                    .font(Theme.Font.body)
                    .rowTextColor(secondary: true)
            }
            .padding(Theme.Spacing.lg)
            .frame(maxWidth: .infinity)
        }
        .buttonStyle(.settingsRow)
    }
}

/// A focusable settings row that toggles a boolean on select.
struct SettingsToggleRow: View {
    let title: String
    let subtitle: String
    let isOn: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: Theme.Spacing.lg) {
                VStack(alignment: .leading, spacing: Theme.Spacing.xxs) {
                    Text(title)
                        .font(Theme.Font.body)
                        .rowTextColor()
                    Text(subtitle)
                        .font(Theme.Font.caption)
                        .rowTextColor(secondary: true)
                }
                Spacer()
                Image(systemName: isOn ? "checkmark.circle.fill" : "circle")
                    .font(Theme.Font.body)
                    .rowAccentTint(isOn)
            }
            .padding(Theme.Spacing.lg)
            .frame(maxWidth: .infinity)
        }
        .buttonStyle(.settingsRow)
    }
}

/// Manual API-key entry row (debrid fallback, MDBList, and similar key-gated services). Shared
/// between the Account & Services pane's per-provider debrid rows and the Content Sources pane's
/// MDBList row.
struct DebridKeyEntryRow: View {
    let providerName: String
    var placeholder: String?
    let onSave: (String) -> Void
    @State private var key = ""

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.md) {
            HStack(spacing: Theme.Spacing.md) {
                Image(systemName: "key")
                    .foregroundStyle(Theme.Palette.textSecondary)
                TextField(placeholder ?? String(localized: "Or paste your \(providerName) API key"), text: $key)
                    .textFieldStyle(.plain)
                    .font(Theme.Font.body)
                    .foregroundStyle(Theme.Palette.textPrimary)
            }
            .padding(Theme.Spacing.lg)
            .glassEffect(.regular, in: RoundedRectangle(cornerRadius: Theme.Radius.card))

            Button {
                if !key.isEmpty {
                    onSave(key)
                    key = ""
                }
            } label: {
                Label("Save Key", systemImage: "checkmark")
                    .font(Theme.Font.meta)
                    .prominentAccentLabel()
                    .padding(.horizontal, Theme.Spacing.lg)
                    .padding(.vertical, Theme.Spacing.xxs + 2)
            }
            .buttonStyle(.borderedProminent)
            .tint(Theme.Palette.accent)
            .disabled(key.isEmpty)
        }
    }
}

/// Language options for the audio/subtitle preference pickers. Special sentinels (`device`,
/// `original`, `none`) match the shared `AudioLanguageOption`/`SubtitleLanguageOption` constants;
/// labels are local since the shared label table lives in the mobile module. Shared between the
/// Playback pane (Audio & Subtitle Language) and the Content Sources pane (TMDB Metadata Language).
enum LanguageOptions {
    static let languages: [(name: String, code: String)] = [
        (String(localized: "English"), "en"), (String(localized: "Spanish"), "es"),
        (String(localized: "French"), "fr"), (String(localized: "German"), "de"),
        (String(localized: "Italian"), "it"), (String(localized: "Portuguese"), "pt"),
        (String(localized: "Japanese"), "ja"), (String(localized: "Korean"), "ko"),
        (String(localized: "Chinese"), "zh"), (String(localized: "Russian"), "ru"),
        (String(localized: "Hindi"), "hi"), (String(localized: "Arabic"), "ar")
    ]
    static var audio: [(name: String, code: String)] {
        [(String(localized: "Device"), "device"), (String(localized: "Original"), "original")] + languages
    }
    static var subtitle: [(name: String, code: String)] {
        [(String(localized: "Off"), "none"), (String(localized: "Device"), "device")] + languages
    }
    /// TMDB metadata language: Device = no stored language (the shared repo derives it from the
    /// Apple TV's language). TMDB accepts the same bare ISO 639-1 codes the track pickers use.
    static var tmdbMetadata: [(name: String, code: String)] {
        [(String(localized: "Device"), "device")] + languages
    }
}

/// A horizontally-scrolling row of language chips; the current selection is tinted.
struct LanguageSelectRow: View {
    let title: String
    let options: [(name: String, code: String)]
    let selected: String
    let onSelect: (String) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.sm) {
            Text(title)
                .font(Theme.Font.caption)
                .foregroundStyle(Theme.Palette.textSecondary)
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: Theme.Spacing.md) {
                    ForEach(options, id: \.code) { option in
                        Button { onSelect(option.code) } label: {
                            Text(option.name)
                                .font(Theme.Font.meta)
                                .padding(.horizontal, Theme.Spacing.md)
                                .padding(.vertical, Theme.Spacing.xxs + 2)
                        }
                        .buttonStyle(.chip(selected: selected == option.code))
                    }
                }
                .padding(.vertical, Theme.Spacing.xs)
            }
        }
    }
}
