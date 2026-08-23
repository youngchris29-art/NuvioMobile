import SharedCore
import SwiftUI

/// Subtitles tab: Off, then the file's embedded text tracks, then addon-fetched subtitles — one
/// checkmark row each, plus (when the engine supports it) a "Timing" row to nudge subtitle sync.
/// Sections are labelled only when both embedded and addon rows exist.
struct PlayerSubtitlesTab: View {
    @ObservedObject var model: PlayerTopPanelModel

    var body: some View {
        let options = model.subtitles
        let embedded = options.filter { $0.group == .embedded }
        let addon = options.filter { $0.group == .addon }
        let off = options.first { $0.group == .off }
        let labelled = !embedded.isEmpty && !addon.isEmpty

        // Scrolls with focus (addon lists can run to a dozen+ rows); we own the container now, so
        // lazy/scrolling content no longer breaks the panel's height measurement.
        ScrollView(.vertical, showsIndicators: false) {
            VStack(alignment: .leading, spacing: Theme.Spacing.xxs) {
                PlayerPanelSectionCaption(text: String(localized: "Subtitles"))
                if let off { row(off) }
                if labelled { PlayerPanelSectionCaption(text: String(localized: "Embedded")).padding(.top, Theme.Spacing.sm) }
                ForEach(embedded) { row($0) }
                if labelled { PlayerPanelSectionCaption(text: String(localized: "From addons")).padding(.top, Theme.Spacing.sm) }
                ForEach(addon) { row($0) }
                if embedded.isEmpty && addon.isEmpty {
                    HStack(spacing: Theme.Spacing.xs) {
                        if model.subtitlesSearching { ProgressView().scaleEffect(0.6) }
                        Text(model.subtitlesSearching
                             ? String(localized: "Searching addon subtitles…")
                             : String(localized: "No subtitles for this title"))
                            .font(Theme.Font.body)
                            .foregroundStyle(Theme.Palette.textSecondary)
                    }
                    .padding(.top, Theme.Spacing.xs)
                }
                if model.supportsSubtitleDelay {
                    PlayerPanelSectionCaption(text: String(localized: "Timing")).padding(.top, Theme.Spacing.sm)
                    subtitleDelayRow
                }
            }
            .frame(maxWidth: 1100, alignment: .leading)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .frame(maxHeight: 520, alignment: .top)
    }

    private func row(_ option: PlayerPanelOption) -> some View {
        PlayerPanelOptionRow(option: option, identifierPrefix: "player.panel.subtitle") {
            model.onSelectSubtitle?(option.group == .off ? nil : option)
        }
    }

    // MARK: - Timing (subtitle delay)

    /// One row: coarse ±1s chips flank fine ±0.1s chips around a monospaced value label, mirroring
    /// mobile's step (`SUBTITLE_DELAY_STEP_MS` = 100ms) with tvOS-friendly ±1s jumps for the remote.
    /// D-pad friendly: five focusable buttons (default tvOS button style, matching every other
    /// panel row — `PlayerPanelOptionRow`'s doc comment explains why a custom style would be
    /// invisible here) plus a conditional Reset.
    private var subtitleDelayRow: some View {
        let delayMs = model.subtitleDelayMs
        let delaySec = Double(delayMs) / 1000.0
        return HStack(spacing: Theme.Spacing.sm) {
            Text(String(localized: "Subtitle Delay"))
                .font(Theme.Font.body)
                .foregroundStyle(Theme.Palette.textPrimary)
                .frame(width: 260, alignment: .leading)
            delayButton(String(localized: "−1 s")) { applyDelay(delayMs - 1000) }
                .accessibilityIdentifier("player.panel.subtitleDelay.minus1")
            delayButton(String(localized: "−0.1 s")) { applyDelay(delayMs - 100) }
                .accessibilityIdentifier("player.panel.subtitleDelay.minus")
            Text(String(format: "%+.2f s", delaySec))
                .font(Theme.Font.body.monospacedDigit())
                .foregroundStyle(Theme.Palette.textPrimary)
                .frame(width: 120)
                .accessibilityIdentifier("player.panel.subtitleDelay.value")
            delayButton(String(localized: "+0.1 s")) { applyDelay(delayMs + 100) }
                .accessibilityIdentifier("player.panel.subtitleDelay.plus")
            delayButton(String(localized: "+1 s")) { applyDelay(delayMs + 1000) }
                .accessibilityIdentifier("player.panel.subtitleDelay.plus1")
            if delayMs != 0 {
                Button(String(localized: "Reset")) { applyDelay(0) }
                    .font(Theme.Font.meta)
                    .accessibilityIdentifier("player.panel.subtitleDelay.reset")
            }
        }
    }

    private func delayButton(_ label: String, action: @escaping () -> Void) -> some View {
        Button(action: action) { Text(label).font(Theme.Font.meta) }
    }

    private func applyDelay(_ ms: Int) {
        let clamped = min(Int(SubtitleAudioModelsKt.SUBTITLE_DELAY_MAX_MS),
                          max(Int(SubtitleAudioModelsKt.SUBTITLE_DELAY_MIN_MS), ms))
        model.onSubtitleDelayChange?(clamped)
    }
}
