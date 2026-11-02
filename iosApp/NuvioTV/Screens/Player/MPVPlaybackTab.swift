import Combine
import SharedCore
import SwiftUI

/// The mpv player's fourth panel tab ("Playback"): what its old swipe-up settings menu carried
/// beyond tracks — playback speed, subtitle/audio delay, the diagnostics overlay toggle, an
/// episode jump list and alternate sources — laid out as three columns inside the top panel.
/// The speed row and the Episodes / Sources columns live in `PlayerPlaybackColumns.swift`,
/// shared with the native engine's `NativePlaybackTab` (P4 A8).
/// Same rules as the other tabs: default tvOS button focus, Theme tokens, no accent.
struct MPVPlaybackTab: View {
    /// BUG-180 (Steven rc7): the three values this tab draws, not the whole `MPVPlaybackState`
    /// (which publishes the position twice a second and re-rendered the open tab on every tick).
    @StateObject private var values: MPVPlaybackTabValues
    @ObservedObject var engine: NextEpisodeEngine
    /// True when the presenter can swap playback contexts (episode jump / source switching).
    let canSwitchStreams: Bool
    /// Closes the panel after an action that replaces playback (episode jump, source switch).
    let onClose: () -> Void
    /// Insights (2026-11-01): the Speed popover draws the settings column alone; Episodes and
    /// Sources have popovers of their own.
    var settingsOnly = false
    private let state: MPVPlaybackState

    init(state: MPVPlaybackState, engine: NextEpisodeEngine, canSwitchStreams: Bool, settingsOnly: Bool = false,
         onClose: @escaping () -> Void) {
        self.state = state
        self.settingsOnly = settingsOnly
        _values = StateObject(wrappedValue: MPVPlaybackTabValues(state: state))
        _engine = ObservedObject(wrappedValue: engine)
        self.canSwitchStreams = canSwitchStreams
        self.onClose = onClose
    }

    var body: some View {
        if settingsOnly {
            settingsColumn
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        } else {
            columns
        }
    }

    private var columns: some View {
        HStack(alignment: .top, spacing: Theme.Spacing.xl) {
            settingsColumn
                .frame(maxWidth: .infinity, alignment: .leading)
                .focusSection()
            if canSwitchStreams, !PlayerEpisodesColumn.sortedEpisodes(engine).isEmpty {
                PlayerEpisodesColumn(engine: engine, onClose: onClose)
                    .frame(width: 440)
                    .focusSection()
            }
            if canSwitchStreams {
                PlayerSourcesColumn(engine: engine, onClose: onClose)
                    .frame(width: 560)
                    .focusSection()
            }
        }
        .frame(maxWidth: .infinity, maxHeight: 520, alignment: .topLeading)
    }

    // MARK: - Speed · timing · diagnostics

    private var settingsColumn: some View {
        ScrollView(.vertical, showsIndicators: false) {
            VStack(alignment: .leading, spacing: Theme.Spacing.md) {
                PlayerPanelSectionCaption(text: String(localized: "Playback Speed"))
                PlayerSpeedRow(current: values.playbackSpeed) { state.setSpeed?($0) }
                if values.rememberSpeedAvailable {
                    PlayerRememberSpeedRow(isOn: values.rememberSpeed) { state.setRememberSpeed?(!values.rememberSpeed) }
                }

                // Subtitle delay moved to the Subtitles tab's "Timing" row (beta.15 §B1) — that's
                // where a viewer actually looks when subs are out of sync, and it now persists
                // per title/profile. Audio delay stays here and persists per title/profile, like the subtitle delay.
                PlayerPanelSectionCaption(text: String(localized: "Timing")).padding(.top, Theme.Spacing.sm)
                delayRow(title: String(localized: "Audio Delay"), value: values.audioDelaySec, step: 0.25, limit: values.audioDelayLimitSec,
                         apply: { state.setAudioDelay?($0) }, reset: { state.resetAudioDelay?() })
                Text("Positive values delay the track; negative values play it earlier.")
                    .font(Theme.Font.caption)
                    .foregroundStyle(Theme.Palette.textSecondary)

                PlayerPanelSectionCaption(text: String(localized: "Diagnostics")).padding(.top, Theme.Spacing.sm)
                Button { state.showStreamInfo.toggle() } label: {
                    HStack(spacing: Theme.Spacing.sm) {
                        Image(systemName: values.showStreamInfo ? "checkmark.circle.fill" : "info.circle")
                        Text(values.showStreamInfo ? String(localized: "Hide Stream Info") : String(localized: "Show Stream Info"))
                    }
                    .font(Theme.Font.body)
                }
                .accessibilityIdentifier("player.panel.diagnostics")
            }
        }
    }

    private func delayRow(title: String, value: Double, step: Double, limit: Double,
                          apply: @escaping (Double) -> Void, reset: @escaping () -> Void) -> some View {
        HStack(spacing: Theme.Spacing.sm) {
            Text(title)
                .font(Theme.Font.body)
                .foregroundStyle(Theme.Palette.textPrimary)
                .frame(width: 260, alignment: .leading)
            Button { apply(max(-limit, value - step)) } label: { Image(systemName: "minus") }
            Text(value == 0 ? "0.00 s" : String(format: "%+.2f s", value))
                .font(Theme.Font.body.monospacedDigit())
                .foregroundStyle(Theme.Palette.textPrimary)
                .frame(width: 150)
            Button { apply(min(limit, value + step)) } label: { Image(systemName: "plus") }
            // Always mounted (see PlayerSubtitlesTab): a Reset that vanished on press dropped focus.
            Button(String(localized: "Reset")) { reset() }.font(Theme.Font.meta)
        }
    }
}

/// BUG-180: mirrors only the `MPVPlaybackState` values the Playback tab draws, each de-duplicated,
/// so the tab re-renders when one of them changes and not on every position tick.
@MainActor
final class MPVPlaybackTabValues: ObservableObject {
    @Published private(set) var playbackSpeed: Double
    @Published private(set) var audioDelaySec: Double
    @Published private(set) var showStreamInfo: Bool
    @Published private(set) var rememberSpeed: Bool
    @Published private(set) var audioDelayLimitSec: Double
    /// Mirrored: the panel can open before FILE_LOADED, and the row appears when it lands.
    @Published private(set) var rememberSpeedAvailable: Bool

    init(state: MPVPlaybackState) {
        playbackSpeed = state.playbackSpeed
        audioDelaySec = state.audioDelaySec
        showStreamInfo = state.showStreamInfo
        rememberSpeed = state.rememberSpeed
        audioDelayLimitSec = state.audioDelayLimitSec
        rememberSpeedAvailable = state.rememberSpeedAvailable
        state.$rememberSpeedAvailable.removeDuplicates().assign(to: &$rememberSpeedAvailable)
        state.$rememberSpeed.removeDuplicates().assign(to: &$rememberSpeed)
        state.$audioDelayLimitSec.removeDuplicates().assign(to: &$audioDelayLimitSec)
        state.$playbackSpeed.removeDuplicates().assign(to: &$playbackSpeed)
        state.$audioDelaySec.removeDuplicates().assign(to: &$audioDelaySec)
        state.$showStreamInfo.removeDuplicates().assign(to: &$showStreamInfo)
    }
}
