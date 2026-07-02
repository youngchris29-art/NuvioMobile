import SwiftUI
import SharedCore

/// The Settings tab: Account (sign in / sign out), Playback (Skip Intro toggle) and Home Rows
/// (enable/disable + reorder the Home catalog rows).
struct SettingsView: View {
    @StateObject private var model = SettingsViewModel()
    @EnvironmentObject private var auth: AuthViewModel
    @State private var confirmingSignOut = false

    var body: some View {
        NavigationStack {
            ZStack {
                Theme.Palette.background.ignoresSafeArea()

                ScrollView(.vertical) {
                    VStack(alignment: .leading, spacing: Theme.Spacing.sectionGap) {
                        Text("Settings")
                            .font(Theme.Font.screenTitle)
                            .foregroundStyle(Theme.Palette.textPrimary)

                        section("Account") {
                            if auth.isAnonymous {
                                SettingsActionRow(
                                    title: "Sign In to Nuvio",
                                    subtitle: "Sync your library, watch progress, and profiles across devices. Local guest data on this Apple TV will be cleared.",
                                    systemImage: "person.crop.circle.badge.plus"
                                ) {
                                    confirmingSignOut = true
                                }
                            } else {
                                SettingsActionRow(
                                    title: "Sign Out",
                                    subtitle: "Signed in as \(auth.accountEmail ?? "your Nuvio account"). Local data on this Apple TV will be cleared.",
                                    systemImage: "rectangle.portrait.and.arrow.right"
                                ) {
                                    confirmingSignOut = true
                                }
                            }
                        }

                        section("Playback") {
                            SettingsToggleRow(
                                title: "Skip Intro",
                                subtitle: "Show a Skip button during intros and outros",
                                isOn: model.skipIntroEnabled
                            ) {
                                model.setSkipIntro(!model.skipIntroEnabled)
                            }
                        }

                        section("Subtitles") {
                            if let style = model.subtitleStyle {
                                SubtitleAppearanceControls(
                                    style: style,
                                    onTextColor: { model.setSubtitleTextColor($0) },
                                    onSize: { model.setSubtitleFontSize($0) },
                                    onBackground: { model.setSubtitleBackground($0) },
                                    onBold: { model.setSubtitleBold($0) },
                                    onOutline: { model.setSubtitleOutline($0) }
                                )
                            } else {
                                Text("Loading subtitle settings\u{2026}")
                                    .font(Theme.Font.body)
                                    .foregroundStyle(Theme.Palette.textSecondary)
                            }
                        }

                        section("Audio & Subtitle Language") {
                            Text("When playback starts, auto-select the audio and subtitle tracks in your preferred language (when a matching track exists).")
                                .font(Theme.Font.caption)
                                .foregroundStyle(Theme.Palette.textSecondary)
                                .frame(maxWidth: 1100, alignment: .leading)
                            LanguageSelectRow(
                                title: "Audio",
                                options: LanguageOptions.audio,
                                selected: model.preferredAudioLanguage
                            ) { model.setPreferredAudioLanguage($0) }
                            LanguageSelectRow(
                                title: "Subtitles",
                                options: LanguageOptions.subtitle,
                                selected: model.preferredSubtitleLanguage
                            ) { model.setPreferredSubtitleLanguage($0) }
                        }

                        section("Poster Style") {
                            PosterStyleControls(
                                widthDp: model.posterWidthDp,
                                cornerDp: model.posterCornerRadiusDp,
                                hideLabels: model.posterHideLabels,
                                landscapeRows: model.posterLandscapeRows,
                                onSize: { model.setPosterWidth($0) },
                                onCorner: { model.setPosterCorner($0) },
                                onHideLabels: { model.setPosterHideLabels($0) },
                                onLandscape: { model.setPosterLandscapeRows($0) },
                                onReset: { model.resetPosterStyle() }
                            )
                        }

                        section("Metadata (TMDB)") {
                            Text("Add a free TMDB API key to enrich titles with cast profiles, studios & networks, collections, and better artwork. Create one at themoviedb.org \u{2192} Settings \u{2192} API (v3 auth). Titles you open after enabling will be enriched.")
                                .font(Theme.Font.caption)
                                .foregroundStyle(Theme.Palette.textSecondary)
                                .frame(maxWidth: 1100, alignment: .leading)

                            if model.tmdbHasKey {
                                SettingsToggleRow(
                                    title: "TMDB Enrichment",
                                    subtitle: model.tmdbEnabled ? "On \u{00B7} API key saved" : "Off \u{00B7} API key saved",
                                    isOn: model.tmdbEnabled
                                ) {
                                    model.setTmdbEnabled(!model.tmdbEnabled)
                                }
                                SettingsActionRow(
                                    title: "Remove API Key",
                                    subtitle: "Clears the saved TMDB key and turns enrichment off.",
                                    systemImage: "trash"
                                ) {
                                    model.clearTmdbKey()
                                }
                            } else {
                                TmdbKeyEntryRow { model.saveTmdbKey($0) }
                            }
                        }

                        section("Home Rows") {
                            if model.catalogs.isEmpty {
                                Text("Install add-ons to customize your Home rows.")
                                    .font(Theme.Font.body)
                                    .foregroundStyle(Theme.Palette.textSecondary)
                            } else {
                                ForEach(model.catalogs, id: \.key) { item in
                                    CatalogSettingRow(
                                        item: item,
                                        onToggle: { model.toggleCatalog(item) },
                                        onUp: { model.moveUp(item) },
                                        onDown: { model.moveDown(item) }
                                    )
                                }
                            }
                        }
                    }
                    .padding(Theme.Spacing.screen)
                    .frame(maxWidth: 1500, alignment: .leading)
                }
            }
        }
        .onAppear { model.start() }
        .onDisappear { model.stop() }
        .alert(
            auth.isAnonymous ? "Switch to a Nuvio account?" : "Sign out?",
            isPresented: $confirmingSignOut
        ) {
            Button(auth.isAnonymous ? "Continue" : "Sign Out", role: .destructive) {
                // Clears the session AND wipes local data (AccountDataCleaner seam), then the root
                // gate drops to the Welcome screen where an account can be signed in.
                auth.signOut()
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text(
                auth.isAnonymous
                    ? "Guest data on this Apple TV (profiles, library, watch progress) will be cleared. You can then sign in on the welcome screen."
                    : "Local data on this Apple TV will be cleared. Your synced data stays in your Nuvio account."
            )
        }
    }

    @ViewBuilder
    private func section<Content: View>(_ title: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.md) {
            Text(title)
                .font(Theme.Font.sectionTitle)
                .foregroundStyle(Theme.Palette.textPrimary)
            content()
        }
    }
}

/// A focusable settings row that performs an action on select (chevron affordance).
private struct SettingsActionRow: View {
    let title: String
    let subtitle: String
    let systemImage: String
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: Theme.Spacing.lg) {
                Image(systemName: systemImage)
                    .font(.system(size: 34))
                    .foregroundStyle(Theme.Palette.accent)
                VStack(alignment: .leading, spacing: Theme.Spacing.xxs) {
                    Text(title)
                        .font(Theme.Font.body)
                        .foregroundStyle(Theme.Palette.textPrimary)
                    Text(subtitle)
                        .font(Theme.Font.caption)
                        .foregroundStyle(Theme.Palette.textSecondary)
                }
                Spacer()
                Image(systemName: "chevron.right")
                    .font(.system(size: 28))
                    .foregroundStyle(Theme.Palette.textSecondary)
            }
            .padding(Theme.Spacing.lg)
            .frame(maxWidth: .infinity)
        }
        .buttonStyle(.card)
    }
}

/// A focusable settings row that toggles a boolean on select.
private struct SettingsToggleRow: View {
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
                        .foregroundStyle(Theme.Palette.textPrimary)
                    Text(subtitle)
                        .font(Theme.Font.caption)
                        .foregroundStyle(Theme.Palette.textSecondary)
                }
                Spacer()
                Image(systemName: isOn ? "checkmark.circle.fill" : "circle")
                    .font(.system(size: 34))
                    .foregroundStyle(isOn ? Theme.Palette.accent : Theme.Palette.textSecondary)
            }
            .padding(Theme.Spacing.lg)
            .frame(maxWidth: .infinity)
        }
        .buttonStyle(.card)
    }
}

/// A Home-catalog row: title + add-on, with reorder (up/down) and an enable toggle.
private struct CatalogSettingRow: View {
    let item: HomeCatalogSettingsItem
    let onToggle: () -> Void
    let onUp: () -> Void
    let onDown: () -> Void

    var body: some View {
        HStack(spacing: Theme.Spacing.md) {
            VStack(alignment: .leading, spacing: Theme.Spacing.xxs) {
                Text(item.displayTitle)
                    .font(Theme.Font.body)
                    .foregroundStyle(item.enabled ? Theme.Palette.textPrimary : Theme.Palette.textSecondary)
                    .lineLimit(1)
                Text(item.addonName)
                    .font(Theme.Font.caption)
                    .foregroundStyle(Theme.Palette.textSecondary)
                    .lineLimit(1)
            }
            Spacer(minLength: Theme.Spacing.lg)

            Button(action: onUp) {
                Image(systemName: "chevron.up")
            }
            .buttonStyle(.bordered)

            Button(action: onDown) {
                Image(systemName: "chevron.down")
            }
            .buttonStyle(.bordered)

            Button(action: onToggle) {
                Image(systemName: item.enabled ? "checkmark.circle.fill" : "circle")
                    .foregroundStyle(item.enabled ? Theme.Palette.accent : Theme.Palette.textSecondary)
            }
            .buttonStyle(.bordered)
        }
        .padding(.vertical, Theme.Spacing.xs)
        .frame(maxWidth: .infinity)
    }
}

/// TMDB API key entry: a tvOS `TextField` (opens the full-screen keyboard, dismisses on commit) plus
/// a Save button. The shared repo trims the key and enables enrichment; we only guard against empty.
private struct TmdbKeyEntryRow: View {
    let onSave: (String) -> Void
    @State private var key = ""

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.md) {
            HStack(spacing: Theme.Spacing.md) {
                Image(systemName: "key")
                    .foregroundStyle(Theme.Palette.textSecondary)
                TextField("TMDB API Key (v3 auth)", text: $key)
                    .textFieldStyle(.plain)
                    .font(Theme.Font.body)
                    .foregroundStyle(Theme.Palette.textPrimary)
            }
            .padding(Theme.Spacing.lg)
            .background(.thinMaterial, in: RoundedRectangle(cornerRadius: Theme.Radius.card))

            Button {
                if !key.isEmpty { onSave(key) }
            } label: {
                Label("Save & Enable", systemImage: "checkmark")
                    .font(Theme.Font.meta)
                    .padding(.horizontal, Theme.Spacing.lg)
                    .padding(.vertical, Theme.Spacing.xxs + 2)
            }
            .buttonStyle(.borderedProminent)
            .tint(Theme.Palette.accent)
            .disabled(key.isEmpty)
        }
    }
}

/// Subtitle appearance controls: a live preview plus text color, size, background, bold and outline.
/// Colors are `SubtitleColor` argb longs (0xAARRGGBB). The player reads these on the next file load.
private struct SubtitleAppearanceControls: View {
    let style: SubtitleStyleState
    let onTextColor: (Int64) -> Void
    let onSize: (Int32) -> Void
    let onBackground: (Int64) -> Void
    let onBold: (Bool) -> Void
    let onOutline: (Bool) -> Void

    private let textColors: [(name: String, argb: Int64)] = [
        ("White", 0xFFFFFFFF), ("Yellow", 0xFFFFFF00), ("Cyan", 0xFF00FFFF), ("Green", 0xFF00FF00)
    ]
    private let sizes: [(name: String, sp: Int32)] = [
        ("Small", 14), ("Medium", 18), ("Large", 24), ("X-Large", 30)
    ]
    private let backgrounds: [(name: String, argb: Int64)] = [
        ("Off", 0x00000000), ("Semi", 0x80000000), ("Solid", 0xFF000000)
    ]

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.lg) {
            preview

            controlRow("Text Color") {
                ForEach(textColors, id: \.argb) { entry in
                    Button { onTextColor(entry.argb) } label: {
                        Circle()
                            .fill(color(entry.argb))
                            .frame(width: 46, height: 46)
                            .overlay(
                                Circle().stroke(
                                    style.textColor == entry.argb ? Theme.Palette.accent : Theme.Palette.textSecondary.opacity(0.4),
                                    lineWidth: style.textColor == entry.argb ? 4 : 1
                                )
                            )
                    }
                    .buttonStyle(.card)
                }
            }

            controlRow("Size") {
                ForEach(sizes, id: \.sp) { entry in
                    chip(entry.name, selected: style.fontSizeSp == entry.sp) { onSize(entry.sp) }
                }
            }

            controlRow("Background") {
                ForEach(backgrounds, id: \.argb) { entry in
                    chip(entry.name, selected: style.backgroundColor == entry.argb) { onBackground(entry.argb) }
                }
            }

            SettingsToggleRow(title: "Bold", subtitle: "Use a heavier subtitle font", isOn: style.bold) {
                onBold(!style.bold)
            }
            SettingsToggleRow(title: "Outline", subtitle: "Draw an outline around text for readability", isOn: style.outlineEnabled) {
                onOutline(!style.outlineEnabled)
            }
        }
    }

    private var preview: some View {
        ZStack {
            RoundedRectangle(cornerRadius: Theme.Radius.card).fill(Color.black)
            Text("The quick brown fox")
                .font(.system(size: 34, weight: style.bold ? .bold : .regular))
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

    private func chip(_ label: String, selected: Bool, _ action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(label)
                .font(Theme.Font.meta)
                .padding(.horizontal, Theme.Spacing.md)
                .padding(.vertical, Theme.Spacing.xxs + 2)
        }
        .buttonStyle(.bordered)
        .tint(selected ? Theme.Palette.accent : nil)
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

/// Language options for the audio/subtitle preference pickers. Special sentinels (`device`,
/// `original`, `none`) match the shared `AudioLanguageOption`/`SubtitleLanguageOption` constants;
/// labels are local since the shared label table lives in the mobile module.
private enum LanguageOptions {
    static let languages: [(name: String, code: String)] = [
        ("English", "en"), ("Spanish", "es"), ("French", "fr"), ("German", "de"),
        ("Italian", "it"), ("Portuguese", "pt"), ("Japanese", "ja"), ("Korean", "ko"),
        ("Chinese", "zh"), ("Russian", "ru"), ("Hindi", "hi"), ("Arabic", "ar")
    ]
    static var audio: [(name: String, code: String)] {
        [("Device", "device"), ("Original", "original")] + languages
    }
    static var subtitle: [(name: String, code: String)] {
        [("Off", "none"), ("Device", "device")] + languages
    }
}

/// A horizontally-scrolling row of language chips; the current selection is tinted.
private struct LanguageSelectRow: View {
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
                        .buttonStyle(.bordered)
                        .tint(selected == option.code ? Theme.Palette.accent : nil)
                    }
                }
                .padding(.vertical, Theme.Spacing.xs)
            }
        }
    }
}

/// Poster card style controls: size, corner radius, hide-titles and landscape-rows toggles, and a
/// reset. Values are the shared dp presets (scaled to tvOS points by `PosterStyle`).
private struct PosterStyleControls: View {
    let widthDp: Int32
    let cornerDp: Int32
    let hideLabels: Bool
    let landscapeRows: Bool
    let onSize: (Int32) -> Void
    let onCorner: (Int32) -> Void
    let onHideLabels: (Bool) -> Void
    let onLandscape: (Bool) -> Void
    let onReset: () -> Void

    private let sizes: [(name: String, dp: Int32)] = [("Small", 105), ("Medium", 126), ("Large", 154)]
    private let corners: [(name: String, dp: Int32)] = [("Square", 0), ("Rounded", 12), ("Round", 28)]

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.lg) {
            controlRow("Size") {
                ForEach(sizes, id: \.dp) { size in
                    chip(size.name, selected: widthDp == size.dp) { onSize(size.dp) }
                }
            }
            controlRow("Corners") {
                ForEach(corners, id: \.dp) { corner in
                    chip(corner.name, selected: cornerDp == corner.dp) { onCorner(corner.dp) }
                }
            }

            SettingsToggleRow(title: "Hide Titles", subtitle: "Show posters without a title label", isOn: hideLabels) {
                onHideLabels(!hideLabels)
            }
            SettingsToggleRow(title: "Landscape Rows", subtitle: "Show Home & Search catalog rows as wide 16:9 cards", isOn: landscapeRows) {
                onLandscape(!landscapeRows)
            }

            Button(role: .destructive, action: onReset) {
                Label("Reset to Defaults", systemImage: "arrow.counterclockwise")
                    .font(Theme.Font.meta)
                    .padding(.horizontal, Theme.Spacing.md)
                    .padding(.vertical, Theme.Spacing.xxs + 2)
            }
            .buttonStyle(.bordered)
        }
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

    private func chip(_ label: String, selected: Bool, _ action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(label)
                .font(Theme.Font.meta)
                .padding(.horizontal, Theme.Spacing.md)
                .padding(.vertical, Theme.Spacing.xxs + 2)
        }
        .buttonStyle(.bordered)
        .tint(selected ? Theme.Palette.accent : nil)
    }
}
