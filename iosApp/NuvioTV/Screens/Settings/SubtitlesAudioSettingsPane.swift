import SwiftUI
import SharedCore

/// "Subtitles & Audio" category content (detail-settings-revamp W2-C): subtitle appearance and
/// the audio/subtitle language preference, split out of `PlaybackSettingsPane` with logic and
/// wiring unchanged. Returns ROWS ONLY; the pane scaffold supplies the List.
struct SubtitlesAudioSettingsPane: View {
    @ObservedObject var model: SettingsViewModel

    var body: some View {
        SettingsSection(String(localized: "Subtitles")) {
            if let style = model.subtitleStyle {
                SubtitleAppearanceControls(
                    style: style,
                    onTextColor: { model.setSubtitleTextColor($0) },
                    onSize: { model.setSubtitleFontSize($0) },
                    onBackground: { model.setSubtitleBackground($0) },
                    onBold: { model.setSubtitleBold($0) },
                    onOutline: { model.setSubtitleOutline($0) },
                    onStripSdh: { model.setSubtitleStripSdh($0) }
                )
            } else {
                Text("Loading subtitle settings\u{2026}")
                    .font(Theme.Font.body)
                    .foregroundStyle(Theme.Palette.textSecondary)
            }
        }

        SettingsSection(String(localized: "Audio & Subtitle Language")) {
            Text("When playback starts, auto-select the audio and subtitle tracks in your preferred language (when a matching track exists).")
                .font(Theme.Font.caption)
                .foregroundStyle(Theme.Palette.textSecondary)
                .frame(maxWidth: 1100, alignment: .leading)
            SettingsPickerRow(
                title: String(localized: "Audio"),
                selection: Binding(get: { model.preferredAudioLanguage }, set: { model.setPreferredAudioLanguage($0) }),
                options: LanguageOptions.audio.map(\.code),
                descriptionID: .subtitlesAudioLanguage,
                label: { LanguageOptions.name(forCode: $0, in: LanguageOptions.audio) }
            )
            SettingsPickerRow(
                title: String(localized: "Subtitles"),
                selection: Binding(get: { model.preferredSubtitleLanguage }, set: { model.setPreferredSubtitleLanguage($0) }),
                options: LanguageOptions.subtitle.map(\.code),
                descriptionID: .subtitlesSubtitleLanguage,
                label: { LanguageOptions.name(forCode: $0, in: LanguageOptions.subtitle) }
            )
        }
    }
}

/// Subtitle appearance controls: a live preview plus text color, size, background, bold and outline.
/// Colors are `SubtitleColor` argb longs (0xAARRGGBB). The player reads these on the next file load.
/// Text Color stays a custom swatch row: the kit has no colour-swatch primitive.
private struct SubtitleAppearanceControls: View {
    let style: SubtitleStyleState
    let onTextColor: (Int64) -> Void
    let onSize: (Int32) -> Void
    let onBackground: (Int64) -> Void
    let onBold: (Bool) -> Void
    let onOutline: (Bool) -> Void
    let onStripSdh: (Bool) -> Void

    private let textColors: [(name: String, argb: Int64)] = [
        ("White", 0xFFFFFFFF), ("Yellow", 0xFFFFFF00), ("Cyan", 0xFF00FFFF), ("Green", 0xFF00FF00)
    ]
    private let sizes: [(name: String, sp: Int32)] = [
        (String(localized: "Small"), 14), (String(localized: "Medium"), 18),
        (String(localized: "Large"), 24), (String(localized: "X-Large"), 30)
    ]
    private let backgrounds: [(name: String, argb: Int64)] = [
        (String(localized: "Off"), 0x00000000), (String(localized: "Semi"), 0x80000000), (String(localized: "Solid"), 0xFF000000)
    ]

    var body: some View {
        preview

        controlRow(String(localized: "Text Color")) {
            ForEach(textColors, id: \.argb) { entry in
                Button { onTextColor(entry.argb) } label: {
                    SubtitleColorSwatch(
                        fill: color(entry.argb),
                        colorHex: UInt32(entry.argb & 0xFFFFFF),
                        isSelected: style.textColor == entry.argb
                    )
                }
                .buttonStyle(.borderless)
            }
        }

        SettingsPickerRow(
            title: String(localized: "Size"),
            selection: Binding(get: { style.fontSizeSp }, set: { onSize($0) }),
            options: sizes.map(\.sp),
            descriptionID: .subtitlesSize,
            label: { sp in sizes.first { $0.sp == sp }?.name ?? "\(sp)" }
        )

        SettingsPickerRow(
            title: String(localized: "Background"),
            selection: Binding(get: { style.backgroundColor }, set: { onBackground($0) }),
            options: backgrounds.map(\.argb),
            descriptionID: .subtitlesBackground,
            label: { argb in backgrounds.first { $0.argb == argb }?.name ?? "\(argb)" }
        )

        SettingsToggleRow(
            title: String(localized: "Bold"),
            subtitle: String(localized: "Use a heavier subtitle font"),
            isOn: Binding(get: { style.bold }, set: { onBold($0) }),
            descriptionID: .subtitlesBold
        )
        SettingsToggleRow(
            title: String(localized: "Outline"),
            subtitle: String(localized: "Draw an outline around text for readability"),
            isOn: Binding(get: { style.outlineEnabled }, set: { onOutline($0) }),
            descriptionID: .subtitlesOutline
        )
        SettingsToggleRow(
            title: String(localized: "Strip SDH Subtitles"),
            subtitle: String(localized: "Hide sound descriptions and speaker labels from text subtitles."),
            isOn: Binding(get: { style.stripSdh }, set: { onStripSdh($0) }),
            descriptionID: .subtitlesStripSdh
        )
    }

    private var preview: some View {
        ZStack {
            RoundedRectangle(cornerRadius: Theme.Radius.card).fill(Color.black)
            Text("The quick brown fox")
                .font(style.bold ? Theme.Font.sectionTitle : Theme.Font.body)
                .foregroundStyle(color(style.textColor))
                .padding(.horizontal, Theme.Spacing.md)
                .padding(.vertical, Theme.Spacing.xs)
                .background(color(style.backgroundColor))
        }
        .frame(height: 130)
        .frame(maxWidth: 700)
    }

    @ViewBuilder
    private func controlRow<Content: View>(_ title: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.sm) {
            Text(title)
                .font(Theme.Font.caption)
                .foregroundStyle(Theme.Palette.textSecondary)
            HStack(spacing: Theme.Spacing.md) { content() }
        }
    }

    private func color(_ argb: Int64) -> Color {
        Color(
            .sRGB,
            red: Double((argb >> 16) & 0xFF) / 255.0,
            green: Double((argb >> 8) & 0xFF) / 255.0,
            blue: Double(argb & 0xFF) / 255.0,
            opacity: Double((argb >> 24) & 0xFF) / 255.0
        )
    }
}

/// A subtitle text-color swatch: selection wears a ring that contrasts with the swatch's own
/// fill; focus scales + shadows the circle (platter-free, same focus language as the theme
/// swatches). Reports "Text Color" to the Settings explainer while focused.
private struct SubtitleColorSwatch: View {
    let fill: Color
    /// Raw RGB backing `fill`, so the selection ring can pick a shade that stays visible against it.
    let colorHex: UInt32
    let isSelected: Bool

    @Environment(\.isFocused) private var isFocused

    var body: some View {
        Circle()
            .fill(fill)
            .frame(width: 46, height: 46)
            .overlay(
                Circle().stroke(
                    isSelected ? Theme.Palette.onColor(forFillHex: colorHex) : Theme.Palette.textSecondary.opacity(0.4),
                    lineWidth: isSelected ? 4 : 1
                )
            )
            .padding(Theme.Spacing.xs)
            .settingsDescription(.subtitlesTextColor, title: String(localized: "Text Color"), systemImage: "textformat")
    }
}
