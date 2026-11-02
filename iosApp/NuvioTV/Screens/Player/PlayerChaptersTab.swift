import SwiftUI

/// Chapters tab of the top panel (mpv player, files with chapters): one checkmark row per chapter,
/// "01 · Title · 0:00", the current one ticked. Select seeks to its start and closes the panel.
/// Focus entering the list lands on the current chapter, scrolled into view (review r1 P3 #13).
struct PlayerChaptersTab: View {
    @ObservedObject var model: PlayerTopPanelModel
    @FocusState private var focusedChapter: Int?
    /// The focus has entered the list since it appeared (only that first entry is redirected).
    @State private var focusEntered = false

    private var currentID: Int? { model.chapters.first(where: \.isCurrent)?.id }

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView(.vertical, showsIndicators: false) {
                VStack(alignment: .leading, spacing: Theme.Spacing.xxs) {
                    PlayerPanelSectionCaption(text: String(localized: "Chapters"))
                    ForEach(model.chapters) { chapter in
                        PlayerPanelOptionRow(option: PlayerPanelOption(
                            id: "\(chapter.id)",
                            title: String(format: "%02d · %@ · %@", chapter.id + 1, chapter.title,
                                          TransportTimeFormat.elapsed(chapter.sec)),
                            group: .chapter,
                            isSelected: chapter.isCurrent
                        ), identifierPrefix: "player.panel.chapter") {
                            model.onSelectChapter?(chapter)
                        }
                        .focused($focusedChapter, equals: chapter.id)
                        .id(chapter.id)
                    }
                }
                .frame(maxWidth: 1100, alignment: .leading)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .focusSection()
            .defaultFocus($focusedChapter, currentID, priority: .userInitiated)
            .onAppear {
                focusEntered = false
                if let id = currentID { proxy.scrollTo(id, anchor: .center) }
            }
            // Review r3 (B4): the mpv overlay now pulls the focus in as the shelf appears
            // (`UIFocusSystem.requestFocusUpdate`), and UIKit's pick from nothing is the first row,
            // not the list's default focus. The first entry is moved onto the current chapter;
            // every later move is the viewer's own.
            .onChange(of: focusedChapter) { _, new in
                guard let new, !focusEntered else { return }
                focusEntered = true
                if let target = PlayerChapterFocus.entryRedirect(entered: new, current: currentID) {
                    focusedChapter = target
                    proxy.scrollTo(target, anchor: .center)
                }
            }
        }
        .frame(maxHeight: 520, alignment: .top)
    }
}

/// Where the focus goes when it first enters the Chapters list: the current chapter, if it entered
/// anywhere else; nil = stay (already there, or nothing is current).
enum PlayerChapterFocus {
    static func entryRedirect(entered: Int, current: Int?) -> Int? {
        guard let current, current != entered else { return nil }
        return current
    }
}
