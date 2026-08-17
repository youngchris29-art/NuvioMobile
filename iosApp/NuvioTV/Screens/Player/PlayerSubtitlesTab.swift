import SwiftUI

/// Subtitles tab: Off, then the file's embedded text tracks, then addon-fetched subtitles — one
/// checkmark row each. Sections are labelled only when both embedded and addon rows exist.
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
}
