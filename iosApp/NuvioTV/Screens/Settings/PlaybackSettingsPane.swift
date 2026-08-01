import SwiftUI
import SharedCore

/// "Playback" category content: player engine toggles, buffer/readahead tuning, subtitle
/// appearance, and audio/subtitle language preference. Extracted from SettingsView.swift (Phase 2
/// HIG revamp file split) — logic and wiring preserved verbatim, only regrouped into a
/// per-category pane.
struct PlaybackSettingsPane: View {
    @ObservedObject var model: SettingsViewModel

    /// FEAT-11: whether a full-screen trailer should start with sound instead of muted. Mirrors
    /// DetailView's `trailer_audio_default_on` key (same @AppStorage key) — DetailView reads this
    /// to seed `HeroTrailerAudioState` at app launch and to restore it after a full-screen trailer
    /// dismisses; this pane also flips the shared state immediately so the change is felt without
    /// a relaunch.
    @AppStorage("trailer_audio_default_on") private var trailerAudioDefaultOn = false

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.sectionGap) {
            settingsSection(String(localized: "Playback")) {
                // Hidden entirely unless an external player (Infuse) is installed —
                // see DefaultPlayerRow.
                DefaultPlayerRow()
                SettingsToggleRow(
                    title: String(localized: "Skip Intro"),
                    subtitle: String(localized: "Show a Skip button during intros and outros"),
                    isOn: model.skipIntroEnabled
                ) {
                    model.setSkipIntro(!model.skipIntroEnabled)
                }
                SettingsToggleRow(
                    title: String(localized: "Match Content Frame Rate"),
                    subtitle: String(localized: "Switch the display mode to the video's native frame rate and dynamic range. Also enable Match Content in tvOS Settings \u{2192} Video and Audio."),
                    isOn: model.matchFrameRate
                ) {
                    model.setMatchFrameRate(!model.matchFrameRate)
                }
                SettingsToggleRow(
                    title: String(localized: "Enhanced Video Renderer"),
                    subtitle: String(localized: "Use the gpu-next (libplacebo) renderer for better HDR tone-mapping. Experimental \u{2014} Apple TV hardware only (ignored on the Simulator). Applies to the next video."),
                    isOn: model.enhancedRenderer
                ) {
                    model.setEnhancedRenderer(!model.enhancedRenderer)
                }
                SettingsToggleRow(
                    title: String(localized: "Native player for Dolby Vision (beta)"),
                    subtitle: String(localized: "Play Dolby Vision, HDR10 and other compatible MKVs through the native AVPlayer engine for true DV output on Apple TV 4K; everything else stays on the mpv player. Profile 7 discs convert to 8.1 on the fly, and TrueHD/DTS-only audio plays as AAC 5.1."),
                    isOn: model.nativeDolbyVision
                ) {
                    model.setNativeDolbyVision(!model.nativeDolbyVision)
                }
                if model.nativeDolbyVision {
                    SettingsToggleRow(
                        title: String(localized: "Keep Profile 7 FEL on mpv"),
                        subtitle: String(localized: "Profile 7 FEL releases carry enhancement data the 8.1 conversion must discard. Turn on to keep those files on the mpv player (plays as HDR10, nothing discarded) instead of native Dolby Vision. MEL releases convert losslessly and always play native."),
                        isOn: model.dvP7FelMpv
                    ) {
                        model.setDvP7FelMpv(!model.dvP7FelMpv)
                    }
                }
                // FEAT-11
                SettingsToggleRow(
                    title: String(localized: "Trailer Sound by Default"),
                    subtitle: trailerAudioDefaultOn
                        ? String(localized: "On \u{00B7} Trailers start with sound; play/pause mutes")
                        : String(localized: "Off \u{00B7} Trailers start muted"),
                    isOn: trailerAudioDefaultOn
                ) {
                    trailerAudioDefaultOn.toggle()
                    // Applies immediately, without relaunch — DetailView otherwise only reads this
                    // default at app launch and after a full-screen trailer dismisses.
                    HeroTrailerAudioState.shared.setMuted(value: !trailerAudioDefaultOn)
                }
                tuningChipRow(
                    title: String(localized: "Streaming Buffer"),
                    options: [
                        (0, String(localized: "Default")),
                        (64, String(localized: "64 MB")),
                        (150, String(localized: "150 MB")),
                        (512, String(localized: "512 MB")),
                    ],
                    selected: model.bufferMB
                ) { model.setBufferMB($0) }
                tuningChipRow(
                    title: String(localized: "Network Readahead"),
                    options: [
                        (0, String(localized: "Default")),
                        (30, String(localized: "30 s")),
                        (60, String(localized: "60 s")),
                        (120, String(localized: "120 s")),
                    ],
                    selected: model.readaheadSec
                ) { model.setReadaheadSec($0) }
                Text("Buffer changes apply to the next playback. Larger buffers smooth out flaky connections at the cost of memory.")
                    .font(Theme.Font.caption)
                    .foregroundStyle(Theme.Palette.textSecondary)
                    .frame(maxWidth: 1100, alignment: .leading)
            }

            settingsSection(String(localized: "Subtitles")) {
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

            settingsSection(String(localized: "Audio & Subtitle Language")) {
                Text("When playback starts, auto-select the audio and subtitle tracks in your preferred language (when a matching track exists).")
                    .font(Theme.Font.caption)
                    .foregroundStyle(Theme.Palette.textSecondary)
                    .frame(maxWidth: 1100, alignment: .leading)
                LanguageSelectRow(
                    title: String(localized: "Audio"),
                    options: LanguageOptions.audio,
                    selected: model.preferredAudioLanguage
                ) { model.setPreferredAudioLanguage($0) }
                LanguageSelectRow(
                    title: String(localized: "Subtitles"),
                    options: LanguageOptions.subtitle,
                    selected: model.preferredSubtitleLanguage
                ) { model.setPreferredSubtitleLanguage($0) }
            }
        }
    }

    /// A labeled row of value chips for the device-local player tuning knobs.
    private func tuningChipRow(
        title: String,
        options: [(value: Int, label: String)],
        selected: Int,
        onSelect: @escaping (Int) -> Void
    ) -> some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.sm) {
            Text(title)
                .font(Theme.Font.caption)
                .foregroundStyle(Theme.Palette.textSecondary)
            HStack(spacing: Theme.Spacing.md) {
                ForEach(options, id: \.value) { option in
                    Button {
                        onSelect(option.value)
                    } label: {
                        HStack(spacing: Theme.Spacing.xs) {
                            if selected == option.value {
                                Image(systemName: "checkmark.circle.fill")
                            }
                            Text(option.label)
                        }
                        .font(Theme.Font.meta)
                        .padding(.horizontal, Theme.Spacing.md)
                        .padding(.vertical, Theme.Spacing.xs)
                    }
                    .buttonStyle(.chip(selected: selected == option.value))
                }
            }
        }
    }
}

/// "Default Player" chooser (FEAT-5 follow-up): built-in vs. any installed external player
/// (Infuse / VLC / Outplayer — whichever the Info.plist allowlist probe finds). When an
/// external player is the default, plain Select on a stream row hands off to it instead of the
/// in-app player, and the row's long-press menu gains a "Play in NuvioTV Player" escape hatch
/// (StreamPickerView reads the same key).
///
/// Self-contained on purpose: owns its own `availablePlayers()` probe and @AppStorage binding so
/// SettingsView doesn't grow more state. Renders NOTHING when no external player is installed —
/// a "Default Player" row whose only option is the built-in player is dead UI, and hiding it
/// matches the picker's own behavior (no Infuse ⇒ no handoff affordances anywhere).
///
/// The stored id is deliberately device-local (@AppStorage, not synced): which apps are
/// installed differs per Apple TV, so a synced default would dangle on every other device.
private struct DefaultPlayerRow: View {
    @AppStorage("default_external_player_id") private var defaultExternalPlayerId = ""
    /// Probed at init, NOT in `.onAppear`: with no players this row renders nothing, and
    /// SwiftUI never fires `onAppear` for a view that renders empty — an onAppear probe
    /// therefore deadlocks the row into permanent invisibility (found on a real Apple TV with
    /// Infuse installed: the probe returned Infuse fine, but never got the chance to run).
    /// Init runs on the main thread (canOpenURL requirement) every time SettingsView rebuilds,
    /// so install/remove of a player is picked up at least as often as the old per-appearance
    /// probe — and the calls are a few cheap registry lookups.
    private let externalPlayers: [ExternalPlayerApp] = ExternalPlayerPlatform.shared.availablePlayers()

    /// Display name for the current selection (row trailing value).
    private var selectedName: String {
        externalPlayers.first { $0.id == defaultExternalPlayerId }?.name ?? String(localized: "NuvioTV (Built-in)")
    }

    var body: some View {
        if !externalPlayers.isEmpty {
            // Dropdown rather than inline chips: renders as a normal settings row showing the
            // current choice; Select pops the native tvOS menu. The embedded Picker gets
            // radio-style checkmarks in the menu for free, bound straight to the stored id.
            Menu {
                Picker("Default Player", selection: $defaultExternalPlayerId) {
                    Text("NuvioTV (Built-in)").tag("")
                    ForEach(externalPlayers, id: \.id) { player in
                        Text(player.name).tag(player.id)
                    }
                }
            } label: {
                HStack(spacing: Theme.Spacing.lg) {
                    Image(systemName: "play.rectangle.on.rectangle")
                        .font(Theme.Font.body)
                        .rowAccentTint()
                    VStack(alignment: .leading, spacing: Theme.Spacing.xxs) {
                        Text("Default Player")
                            .font(Theme.Font.body)
                            .foregroundStyle(Theme.Palette.textPrimary)
                        Text(defaultExternalPlayerId.isEmpty
                            ? "Streams play in the built-in player. Hold a stream to open it in an external player instead."
                            : "Streams open in \(selectedName). Hold a stream to play it in NuvioTV instead; if \(selectedName) can\u{2019}t open, playback falls back to the built-in player.")
                            .font(Theme.Font.caption)
                            .foregroundStyle(Theme.Palette.textSecondary)
                    }
                    Spacer()
                    Text(selectedName)
                        .font(Theme.Font.body)
                        .foregroundStyle(Theme.Palette.textSecondary)
                    Image(systemName: "chevron.up.chevron.down")
                        .font(Theme.Font.body)
                        .foregroundStyle(Theme.Palette.textSecondary)
                }
                .padding(Theme.Spacing.lg)
                .frame(maxWidth: .infinity)
            }
            .menuStyle(.button)
            .buttonStyle(.settingsRow)
            .onAppear {
                // Safe here: this onAppear is on the VISIBLE content, so it actually fires.
                // A stored default whose app was uninstalled silently reverts to built-in —
                // the picker independently guards against this too, but clearing here keeps
                // the row's displayed value honest. When NO player is installed the row is
                // hidden and a stale id survives harmlessly; the stream picker's membership
                // check already ignores it.
                if !defaultExternalPlayerId.isEmpty,
                   !externalPlayers.contains(where: { $0.id == defaultExternalPlayerId }) {
                    defaultExternalPlayerId = ""
                }
            }
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
        (String(localized: "Small"), 14), (String(localized: "Medium"), 18),
        (String(localized: "Large"), 24), (String(localized: "X-Large"), 30)
    ]
    private let backgrounds: [(name: String, argb: Int64)] = [
        (String(localized: "Off"), 0x00000000), (String(localized: "Semi"), 0x80000000), (String(localized: "Solid"), 0xFF000000)
    ]

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.lg) {
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

            controlRow(String(localized: "Size")) {
                ForEach(sizes, id: \.sp) { entry in
                    chip(entry.name, selected: style.fontSizeSp == entry.sp) { onSize(entry.sp) }
                }
            }

            controlRow(String(localized: "Background")) {
                ForEach(backgrounds, id: \.argb) { entry in
                    chip(entry.name, selected: style.backgroundColor == entry.argb) { onBackground(entry.argb) }
                }
            }

            SettingsToggleRow(title: String(localized: "Bold"), subtitle: String(localized: "Use a heavier subtitle font"), isOn: style.bold) {
                onBold(!style.bold)
            }
            SettingsToggleRow(title: String(localized: "Outline"), subtitle: String(localized: "Draw an outline around text for readability"), isOn: style.outlineEnabled) {
                onOutline(!style.outlineEnabled)
            }
        }
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

    private func chip(_ label: String, selected: Bool, _ action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(label)
                .font(Theme.Font.meta)
                .padding(.horizontal, Theme.Spacing.md)
                .padding(.vertical, Theme.Spacing.xxs + 2)
        }
        .buttonStyle(.chip(selected: selected))
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
/// swatches).
private struct SubtitleColorSwatch: View {
    let fill: Color
    /// Raw RGB backing `fill`, so the selection ring can pick a shade that stays visible against
    /// it — a static accent ring nearly disappeared on the White swatch when the app theme was
    /// also White (same problem `SwatchLabel` fixes for the theme picker).
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
    }
}
