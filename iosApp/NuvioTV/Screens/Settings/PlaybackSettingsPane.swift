import SwiftUI
import SharedCore

/// "Playback" category content: player engine toggles, buffer/readahead tuning, subtitle
/// appearance, and audio/subtitle language preference. Extracted from SettingsView.swift (Phase 2
/// HIG revamp file split) — logic and wiring preserved verbatim, only regrouped into a
/// per-category pane.
///
/// beta.15 §C (C3a): converted onto the native-List Settings kit (SettingsRowViews.swift, C1) —
/// the pane body returns its sections directly (no `VStack(spacing: sectionGap)` wrapper, which
/// used to collapse the whole pane into one giant List row), every toggle binds straight to the
/// view-model instead of the legacy value+action shim, and the Streaming Buffer / Network
/// Readahead / subtitle Size & Background chip rows are now `SettingsPickerRow` menus. Text Color
/// stays a custom swatch row — the kit has no colour-swatch primitive.
struct PlaybackSettingsPane: View {
    @ObservedObject var model: SettingsViewModel

    /// FEAT-11: whether a full-screen trailer should start with sound instead of muted. Mirrors
    /// DetailView's `trailer_audio_default_on` key (same @AppStorage key) — DetailView reads this
    /// to seed `HeroTrailerAudioState` at app launch and to restore it after a full-screen trailer
    /// dismisses; this pane also flips the shared state immediately so the change is felt without
    /// a relaunch.
    @AppStorage("trailer_audio_default_on") private var trailerAudioDefaultOn = false

    var body: some View {
        SettingsSection(String(localized: "Playback")) {
            // Hidden entirely unless an external player (Infuse) is installed —
            // see DefaultPlayerRow.
            DefaultPlayerRow()
            SettingsToggleRow(
                title: String(localized: "Skip Intro"),
                subtitle: String(localized: "Show a Skip button during intros and outros"),
                isOn: Binding(get: { model.skipIntroEnabled }, set: { model.setSkipIntro($0) })
            )
            SettingsToggleRow(
                title: String(localized: "Match Content Frame Rate"),
                subtitle: String(localized: "Switch the display mode to the video's native frame rate and dynamic range. Also enable Match Content in tvOS Settings \u{2192} Video and Audio."),
                isOn: Binding(get: { model.matchFrameRate }, set: { model.setMatchFrameRate($0) })
            )
            SettingsToggleRow(
                title: String(localized: "Enhanced Video Renderer"),
                subtitle: String(localized: "Use the gpu-next (libplacebo) renderer for better HDR tone-mapping. Experimental \u{2014} Apple TV hardware only (ignored on the Simulator). Applies to the next video."),
                isOn: Binding(get: { model.enhancedRenderer }, set: { model.setEnhancedRenderer($0) })
            )
            SettingsToggleRow(
                title: String(localized: "Native player (Dolby Vision & HDR)"),
                subtitle: String(localized: "Play Dolby Vision, HDR10 and other compatible MKVs through the native AVPlayer engine for true DV output on Apple TV 4K; everything else stays on the mpv player. Profile 7 discs convert to 8.1 on the fly, and TrueHD/DTS-only audio plays as AAC 5.1."),
                isOn: Binding(get: { model.nativeDolbyVision }, set: { model.setNativeDolbyVision($0) })
            )
            if model.nativeDolbyVision {
                SettingsToggleRow(
                    title: String(localized: "Keep Profile 7 FEL on mpv"),
                    subtitle: String(localized: "Profile 7 FEL releases carry enhancement data the 8.1 conversion must discard. Turn on to keep those files on the mpv player (plays as HDR10, nothing discarded) instead of native Dolby Vision. MEL releases convert losslessly and always play native."),
                    isOn: Binding(get: { model.dvP7FelMpv }, set: { model.setDvP7FelMpv($0) })
                )
            }
            // FEAT-11
            SettingsToggleRow(
                title: String(localized: "Trailer Sound by Default"),
                subtitle: String(localized: "Trailers start with sound; play/pause mutes"),
                isOn: Binding(
                    get: { trailerAudioDefaultOn },
                    set: { newValue in
                        trailerAudioDefaultOn = newValue
                        // Applies immediately, without relaunch — DetailView otherwise only reads
                        // this default at app launch and after a full-screen trailer dismisses.
                        HeroTrailerAudioState.shared.setMuted(value: !newValue)
                    }
                )
            )
            SettingsPickerRow(
                title: String(localized: "Streaming Buffer"),
                selection: Binding(get: { model.bufferMB }, set: { model.setBufferMB($0) }),
                options: [0, 64, 150, 512],
                label: Self.bufferLabel
            )
            SettingsPickerRow(
                title: String(localized: "Network Readahead"),
                selection: Binding(get: { model.readaheadSec }, set: { model.setReadaheadSec($0) }),
                options: [0, 30, 60, 120],
                label: Self.readaheadLabel
            )
            Text("Buffer changes apply to the next playback. Larger buffers smooth out flaky connections at the cost of memory.")
                .font(Theme.Font.caption)
                .foregroundStyle(Theme.Palette.textSecondary)
                .frame(maxWidth: 1100, alignment: .leading)
        }

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
                label: { LanguageOptions.name(forCode: $0, in: LanguageOptions.audio) }
            )
            SettingsPickerRow(
                title: String(localized: "Subtitles"),
                selection: Binding(get: { model.preferredSubtitleLanguage }, set: { model.setPreferredSubtitleLanguage($0) }),
                options: LanguageOptions.subtitle.map(\.code),
                label: { LanguageOptions.name(forCode: $0, in: LanguageOptions.subtitle) }
            )
        }
    }

    private static func bufferLabel(_ value: Int) -> String {
        switch value {
        case 0: return String(localized: "Default")
        case 64: return String(localized: "64 MB")
        case 150: return String(localized: "150 MB")
        case 512: return String(localized: "512 MB")
        default: return "\(value) MB"
        }
    }

    private static func readaheadLabel(_ value: Int) -> String {
        switch value {
        case 0: return String(localized: "Default")
        case 30: return String(localized: "30 s")
        case 60: return String(localized: "60 s")
        case 120: return String(localized: "120 s")
        default: return "\(value) s"
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
///
/// C3a: was a hand-rolled `Menu` + manual `HStack` with the legacy focus-aware text-colour
/// modifier and full-width row button style; now `SettingsPickerRow` gives the same Menu{Picker}
/// pill for free with system-inverted label colour, so the custom row chrome is gone.
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
            SettingsPickerRow(
                title: String(localized: "Default Player"),
                subtitle: defaultExternalPlayerId.isEmpty
                    ? String(localized: "Streams play in the built-in player. Hold a stream to open it in an external player instead.")
                    : String(localized: "Streams open in \(selectedName). Hold a stream to play it in NuvioTV instead; if \(selectedName) can\u{2019}t open, playback falls back to the built-in player."),
                selection: $defaultExternalPlayerId,
                options: [""] + externalPlayers.map(\.id),
                label: { id in
                    id.isEmpty ? String(localized: "NuvioTV (Built-in)") : (externalPlayers.first { $0.id == id }?.name ?? id)
                }
            )
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
///
/// C3a: Size and Background were text-label chip rows (the anti-pattern per the kit's field notes)
/// — both are now `SettingsPickerRow` menus. Text Color stays a custom swatch row: the kit has no
/// colour-swatch primitive, and a `Menu{Picker}` pill can't show a live colour preview.
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
            label: { sp in sizes.first { $0.sp == sp }?.name ?? "\(sp)" }
        )

        SettingsPickerRow(
            title: String(localized: "Background"),
            selection: Binding(get: { style.backgroundColor }, set: { onBackground($0) }),
            options: backgrounds.map(\.argb),
            label: { argb in backgrounds.first { $0.argb == argb }?.name ?? "\(argb)" }
        )

        SettingsToggleRow(
            title: String(localized: "Bold"),
            subtitle: String(localized: "Use a heavier subtitle font"),
            isOn: Binding(get: { style.bold }, set: { onBold($0) })
        )
        SettingsToggleRow(
            title: String(localized: "Outline"),
            subtitle: String(localized: "Draw an outline around text for readability"),
            isOn: Binding(get: { style.outlineEnabled }, set: { onOutline($0) })
        )
        SettingsToggleRow(
            title: String(localized: "Strip SDH Subtitles"),
            subtitle: String(localized: "Hide sound descriptions and speaker labels from text subtitles."),
            isOn: Binding(get: { style.stripSdh }, set: { onStripSdh($0) })
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
