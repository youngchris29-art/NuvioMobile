import SwiftUI
import SharedCore

/// "Player" category content (detail-settings-revamp W2-C): engine choice, intro/outro skipping,
/// video output, buffering and the next-episode preload. Split out of `PlaybackSettingsPane`;
/// bindings and view-model calls are unchanged. "Trailer Sound by Default" now lives in the Detail
/// Page pane (same `trailer_audio_default_on` key), so it is not repeated here. Returns ROWS ONLY;
/// the pane scaffold supplies the List.
struct PlayerSettingsPane: View {
    @ObservedObject var model: SettingsViewModel

    var body: some View {
        SettingsSection(String(localized: "Playback")) {
            // Hidden entirely unless an external player (Infuse) is installed.
            DefaultPlayerRow()
            SettingsToggleRow(
                title: String(localized: "Skip Intro"),
                subtitle: String(localized: "Show a Skip button during intros and outros"),
                isOn: Binding(get: { model.skipIntroEnabled }, set: { model.setSkipIntro($0) }),
                descriptionID: .playerSkipIntro
            )
            // Upstream 199c5882: per-segment-type auto-skip. Dependent on Skip Intro (no segments
            // are fetched without it), so hidden while it is off.
            if model.skipIntroEnabled {
                Group {
                    autoSkipRow(.intro, title: String(localized: "Auto-Skip Intros"),
                                subtitle: String(localized: "Skip intros and anime openings automatically."),
                                descriptionID: .playerAutoSkipIntro)
                    autoSkipRow(.recap, title: String(localized: "Auto-Skip Recaps"),
                                subtitle: String(localized: "Skip recap segments automatically."),
                                descriptionID: .playerAutoSkipRecap)
                    autoSkipRow(.outro, title: String(localized: "Auto-Skip Outros"),
                                subtitle: String(localized: "Skip outros and anime endings automatically."),
                                descriptionID: .playerAutoSkipOutro)
                    autoSkipRow(.movieCredits, title: String(localized: "Auto-Skip Movie Credits"),
                                subtitle: String(localized: "Skip movie credits, keeping post-credits scenes."),
                                descriptionID: .playerAutoSkipCredits)
                }
            }
            SettingsToggleRow(
                title: String(localized: "Episode Shuffle"),
                subtitle: String(localized: "Show a Shuffle button on series pages."),
                isOn: Binding(get: { model.episodeShuffleAvailable }, set: { model.setEpisodeShuffleAvailable($0) }),
                descriptionID: .playerEpisodeShuffle
            )
            // Upstream ecb69a88: gates the mpv player's "metadata card after a sustained pause"
            // overlay (MPVPlayerView.swift). The native AVPlayer engine doesn't have it.
            SettingsToggleRow(
                title: String(localized: "Pause Info Card"),
                subtitle: String(localized: "Show the title, source and time remaining after a short pause (mpv player)"),
                isOn: Binding(get: { model.pauseOverlayEnabled }, set: { model.setPauseOverlayEnabled($0) }),
                descriptionID: .playerPauseInfoCard
            )
            SettingsPickerRow(
                title: String(localized: "Hold Left/Right"),
                selection: Binding(get: { model.holdMode }, set: { model.setHoldMode($0) }),
                options: ["step", "scan"],
                descriptionID: .playerHoldMode,
                label: { $0 == "scan" ? String(localized: "Scan") : String(localized: "Step") }
            )
            SettingsToggleRow(
                title: String(localized: "Show Clock"),
                subtitle: String(localized: "Show the time of day while the controls are up (mpv player)"),
                isOn: Binding(get: { model.showClock }, set: { model.setShowClock($0) }),
                descriptionID: .playerShowClock
            )
        }

        SettingsSection(String(localized: "Video")) {
            SettingsToggleRow(
                title: String(localized: "Match Content Frame Rate"),
                subtitle: String(localized: "Switch the display mode to the video's native frame rate and dynamic range. Also enable Match Content in tvOS Settings \u{2192} Video and Audio."),
                isOn: Binding(get: { model.matchFrameRate }, set: { model.setMatchFrameRate($0) }),
                descriptionID: .playerMatchFrameRate
            )
            SettingsToggleRow(
                title: String(localized: "Enhanced Video Renderer"),
                subtitle: String(localized: "Use the gpu-next (libplacebo) renderer for better HDR tone-mapping. Experimental \u{2014} Apple TV hardware only (ignored on the Simulator). Applies to the next video."),
                isOn: Binding(get: { model.enhancedRenderer }, set: { model.setEnhancedRenderer($0) }),
                descriptionID: .playerEnhancedRenderer
            )
            SettingsToggleRow(
                title: String(localized: "Native player (Dolby Vision & HDR)"),
                subtitle: String(localized: "Play Dolby Vision, HDR10 and other compatible MKVs through the native AVPlayer engine for true DV output on Apple TV 4K; everything else stays on the mpv player. Profile 7 discs convert to 8.1 on the fly, and TrueHD/DTS-only audio plays as AAC 5.1."),
                isOn: Binding(get: { model.nativeDolbyVision }, set: { model.setNativeDolbyVision($0) }),
                descriptionID: .playerNativeDolbyVision
            )
            if model.nativeDolbyVision {
                SettingsToggleRow(
                    title: String(localized: "Keep Profile 7 FEL on mpv"),
                    subtitle: String(localized: "Profile 7 FEL releases carry enhancement data the 8.1 conversion must discard. Turn on to keep those files on the mpv player (plays as HDR10, nothing discarded) instead of native Dolby Vision. MEL releases convert losslessly and always play native."),
                    isOn: Binding(get: { model.dvP7FelMpv }, set: { model.setDvP7FelMpv($0) }),
                    descriptionID: .playerP7FelMpv
                )
            }
        }

        SettingsSection(String(localized: "Buffering")) {
            SettingsPickerRow(
                title: String(localized: "Streaming Buffer"),
                selection: Binding(get: { model.bufferMB }, set: { model.setBufferMB($0) }),
                options: [0, 64, 150, 512],
                descriptionID: .playerStreamingBuffer,
                label: Self.bufferLabel
            )
            SettingsPickerRow(
                title: String(localized: "Network Readahead"),
                selection: Binding(get: { model.readaheadSec }, set: { model.setReadaheadSec($0) }),
                options: [0, 30, 60, 120],
                descriptionID: .playerNetworkReadahead,
                label: Self.readaheadLabel
            )
            Text("Buffer changes apply to the next playback. Larger buffers smooth out flaky connections at the cost of memory.")
                .font(Theme.Font.caption)
                .foregroundStyle(Theme.Palette.textSecondary)
                .frame(maxWidth: 1100, alignment: .leading)
        }

        // FEAT-49 (upstream 22c9ab20): start the Up Next source search before the card shows.
        SettingsSection(
            String(localized: "Next Episode"),
            footer: String(localized: "Up Next looks for the next episode's sources about 30 seconds before the card appears, so the countdown can start the moment it shows.")
        ) {
            SettingsToggleRow(
                title: String(localized: "Preload Next Episode Sources"),
                subtitle: String(localized: "Start searching for sources in the background before the next episode card appears."),
                isOn: Binding(get: { model.preloadNextEpisodeSources }, set: { model.setPreloadNextEpisodeSources($0) }),
                descriptionID: .playerPreloadNextEpisode
            )
        }
    }

    /// One auto-skip segment-type toggle (upstream 199c5882's selection dialog, as plain rows).
    private func autoSkipRow(
        _ type: AutoSkipSegmentType,
        title: String,
        subtitle: String,
        descriptionID: SettingsDescriptionID
    ) -> some View {
        SettingsToggleRow(
            title: title,
            subtitle: subtitle,
            isOn: Binding(get: { model.isAutoSkipEnabled(type) }, set: { model.setAutoSkip(type, enabled: $0) }),
            descriptionID: descriptionID
        )
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
/// Self-contained on purpose: owns its own `availablePlayers()` probe and @AppStorage binding.
/// Renders NOTHING when no external player is installed — a "Default Player" row whose only
/// option is the built-in player is dead UI. The stored id is deliberately device-local
/// (@AppStorage, not synced): which apps are installed differs per Apple TV.
private struct DefaultPlayerRow: View {
    @AppStorage("default_external_player_id") private var defaultExternalPlayerId = ""
    /// Probed at init, NOT in `.onAppear`: with no players this row renders nothing, and
    /// SwiftUI never fires `onAppear` for a view that renders empty (found on a real Apple TV
    /// with Infuse installed). Init runs on the main thread (canOpenURL requirement).
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
                descriptionID: .playerDefaultPlayer,
                label: { id in
                    id.isEmpty ? String(localized: "NuvioTV (Built-in)") : (externalPlayers.first { $0.id == id }?.name ?? id)
                }
            )
            .onAppear {
                // A stored default whose app was uninstalled silently reverts to built-in.
                if !defaultExternalPlayerId.isEmpty,
                   !externalPlayers.contains(where: { $0.id == defaultExternalPlayerId }) {
                    defaultExternalPlayerId = ""
                }
            }
        }
    }
}
