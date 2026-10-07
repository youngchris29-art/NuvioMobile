import SwiftUI

/// Chapters tab of the top panel (mpv player, files with chapters): one checkmark row per chapter,
/// "01 · Title · 0:00", the current one ticked. Select seeks to its start and closes the panel.
struct PlayerChaptersTab: View {
    @ObservedObject var model: PlayerTopPanelModel

    var body: some View {
        ScrollView(.vertical, showsIndicators: false) {
            VStack(alignment: .leading, spacing: Theme.Spacing.xxs) {
                PlayerPanelSectionCaption(text: String(localized: "Chapters"))
                ForEach(model.chapters) { chapter in
                    PlayerPanelOptionRow(option: PlayerPanelOption(
                        id: "\(chapter.id)",
                        title: String(format: "%02d · %@ · %@", chapter.id + 1, chapter.title,
                                      TransportTimeFormat.elapsed(chapter.sec)),
                        group: .audio,
                        isSelected: chapter.isCurrent
                    ), identifierPrefix: "player.panel.chapter") {
                        model.onSelectChapter?(chapter)
                    }
                }
            }
            .frame(maxWidth: 1100, alignment: .leading)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .frame(maxHeight: 520, alignment: .top)
    }
}
