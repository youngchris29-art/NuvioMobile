import AVKit
import SwiftUI

/// Audio tab, laid out like the classic tvOS panel: a LANGUAGE column (one checkmark row per audio
/// track) and a SPEAKERS & HEADPHONES column (current output route + the system route picker).
/// Enhance Dialogue / Reduce Loud Sounds have no public API — they stay in the native transport-bar
/// Audio popover, and the column says so.
struct PlayerAudioTab: View {
    @ObservedObject var model: PlayerTopPanelModel

    var body: some View {
        HStack(alignment: .top, spacing: Theme.Spacing.screen) {
            ScrollView(.vertical, showsIndicators: false) {
                VStack(alignment: .leading, spacing: Theme.Spacing.xxs) {
                    PlayerPanelSectionCaption(text: String(localized: "Language"))
                    ForEach(model.audio) { option in
                        PlayerPanelOptionRow(option: option, identifierPrefix: "player.panel.audio") {
                            model.onSelectAudio?(option)
                        }
                    }
                    if model.audio.isEmpty {
                        Text("No stream details yet.")
                            .font(Theme.Font.body)
                            .foregroundStyle(Theme.Palette.textSecondary)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            // Full-width rows: Down from the (centred) tab row must land on the first language row,
            // not on the route picker in the trailing column — the focus engine prefers overlap.
            .frame(maxWidth: .infinity, alignment: .leading)
            .focusSection()

            VStack(alignment: .leading, spacing: Theme.Spacing.xs) {
                PlayerPanelSectionCaption(text: String(localized: "Speakers & Headphones"))
                HStack(spacing: Theme.Spacing.sm) {
                    Image(systemName: "checkmark").font(Theme.Font.body.weight(.semibold)).frame(width: 34)
                    Image(systemName: "hifispeaker.and.appletv")
                    Text(model.outputRouteName.isEmpty ? "Apple TV" : model.outputRouteName)
                        .font(Theme.Font.body)
                        .foregroundStyle(Theme.Palette.textPrimary)
                        .lineLimit(1)
                }
                if model.canPickRoute {
                    AudioRoutePickerButton()
                        .frame(height: 70)
                        .padding(.top, Theme.Spacing.xs)
                        .accessibilityIdentifier("player.panel.audio.route")
                }
                if let fx = model.audioEffects {
                    effectsRows(fx)
                } else {
                    Text("Enhance Dialogue and sound options are in the player's Audio button.")
                        .font(Theme.Font.caption)
                        .foregroundStyle(Theme.Palette.textSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                        .padding(.top, Theme.Spacing.sm)
                }
            }
            .frame(width: 520, alignment: .leading)
            .focusSection()
        }
        .frame(maxWidth: .infinity, maxHeight: 520, alignment: .topLeading)
    }
}

extension PlayerAudioTab {
    /// mpv-only Boost + Audio Mode rows (P5 B20). Ids use `player.panel.audioFx.` — never the
    /// `player.panel.audio.` prefix, which the probe legs count as audio tracks.
    @ViewBuilder
    fileprivate func effectsRows(_ fx: PlayerAudioEffectsState) -> some View {
        PlayerPanelSectionCaption(text: String(localized: "Sound")).padding(.top, Theme.Spacing.sm)
        HStack(spacing: Theme.Spacing.xs) {
            Text(String(localized: "Boost"))
                .font(Theme.Font.body)
                .foregroundStyle(Theme.Palette.textPrimary)
                .frame(width: 110, alignment: .leading)
            Button { model.onAudioBoostChange?(PlayerAudioEffects.clampBoost(fx.boostDb - 2)) } label: {
                Image(systemName: "minus")
            }
            .accessibilityIdentifier("player.panel.audioFx.boost.minus")
            Text(fx.boostDb == 0 ? String(localized: "Off") : String(localized: "+\(fx.boostDb) dB"))
                .font(Theme.Font.body.monospacedDigit())
                .foregroundStyle(Theme.Palette.textPrimary)
                .lineLimit(1)
                .minimumScaleFactor(0.8)
                .frame(width: 90)
                .accessibilityIdentifier("player.panel.audioFx.boost.value")
            Button { model.onAudioBoostChange?(PlayerAudioEffects.clampBoost(fx.boostDb + 2)) } label: {
                Image(systemName: "plus")
            }
            .accessibilityIdentifier("player.panel.audioFx.boost.plus")
            // Always mounted (see PlayerSubtitlesTab): a Reset that vanished on press dropped focus.
            Button(String(localized: "Reset")) { if fx.boostDb != 0 { model.onAudioBoostChange?(0) } }
                .font(Theme.Font.meta)
                .lineLimit(1)
                .minimumScaleFactor(0.7)
                .accessibilityIdentifier("player.panel.audioFx.boost.reset")
        }
        PlayerPanelSectionCaption(text: String(localized: "Audio Mode")).padding(.top, Theme.Spacing.xs)
        ForEach(PlayerAudioMode.allCases, id: \.self) { mode in
            PlayerPanelOptionRow(
                option: PlayerPanelOption(
                    id: mode.rawValue,
                    title: mode == .off ? String(localized: "Off") : String(localized: "Dialogue"),
                    group: .audio,
                    isSelected: fx.mode == mode
                ),
                identifierPrefix: "player.panel.audioFx.mode"
            ) { model.onAudioModeChange?(mode) }
        }
        Text("Dialogue raises voices. Boost can distort loud scenes.")
            .font(Theme.Font.caption)
            .foregroundStyle(Theme.Palette.textSecondary)
            .fixedSize(horizontal: false, vertical: true)
            .padding(.top, Theme.Spacing.xs)
        // Aether: active shaping needs PCM, so Dolby Atmos passthrough is off while either is on.
        if PlayerAudioAtmosNote.isShown(endsAtmos: model.audioShapingEndsAtmos, effects: fx) {
            Text("Dolby Atmos passthrough is off while this is on")
                .font(Theme.Font.caption)
                .foregroundStyle(Theme.Palette.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.top, Theme.Spacing.xxs)
                .accessibilityIdentifier("player.panel.audioFx.atmosNote")
        }
    }
}

/// When the Audio tab warns that Dolby Atmos passthrough is off (Aether only: Boost and Dialogue are
/// applied to decoded PCM there). Pure so it is unit-testable.
nonisolated enum PlayerAudioAtmosNote {
    static func isShown(endsAtmos: Bool, effects: PlayerAudioEffectsState) -> Bool {
        endsAtmos && (effects.boostDb > 0 || effects.mode == .dialogue)
    }
}

/// System AirPlay / Bluetooth output picker (opens the tvOS route sheet). Wrapped so it takes part
/// in the SwiftUI focus layout like any other control.
struct AudioRoutePickerButton: UIViewRepresentable {
    func makeUIView(context: Context) -> AVRoutePickerView {
        let view = AVRoutePickerView()
        view.prioritizesVideoDevices = false
        view.routePickerButtonStyle = .system
        return view
    }

    func updateUIView(_ uiView: AVRoutePickerView, context: Context) {}
}
