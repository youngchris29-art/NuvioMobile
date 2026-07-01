import SwiftUI
import SharedCore

/// The Library tab: a focusable poster grid of the titles saved via "Add to Library". Tap opens the
/// detail screen; long-press removes. Empty until the user saves something.
struct LibraryView: View {
    @StateObject private var model = LibraryViewModel()

    private let columns = [
        GridItem(
            .adaptive(minimum: Theme.Size.posterWidth + Theme.Spacing.rowGap),
            spacing: Theme.Spacing.rowGap
        )
    ]

    var body: some View {
        NavigationStack {
            ZStack {
                Theme.Palette.background.ignoresSafeArea()

                ScrollView(.vertical) {
                    VStack(alignment: .leading, spacing: Theme.Spacing.lg) {
                        Text("Library")
                            .font(Theme.Font.screenTitle)
                            .foregroundStyle(Theme.Palette.textPrimary)

                        if model.items.isEmpty {
                            emptyState
                        } else {
                            LazyVGrid(columns: columns, spacing: Theme.Spacing.xl) {
                                ForEach(model.items, id: \.id) { item in
                                    NavigationLink(value: TitleRoute(preview: item.toMetaPreview())) {
                                        PosterCard(title: item.name, imageURL: item.poster)
                                    }
                                    .buttonStyle(.card)
                                    .contextMenu {
                                        Button(role: .destructive) {
                                            model.remove(item)
                                        } label: {
                                            Label("Remove from Library", systemImage: "trash")
                                        }
                                    }
                                }
                            }
                        }
                    }
                    .padding(Theme.Spacing.screen)
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
            .navigationDestination(for: TitleRoute.self) { route in
                DetailView(preview: route.preview)
            }
        }
        .onAppear { model.start() }
        .onDisappear { model.stop() }
    }

    private var emptyState: some View {
        VStack(spacing: Theme.Spacing.md) {
            Image(systemName: "books.vertical")
                .font(.system(size: 80))
                .foregroundStyle(Theme.Palette.textSecondary)
            Text("Your library is empty")
                .font(Theme.Font.sectionTitle)
                .foregroundStyle(Theme.Palette.textPrimary)
            Text("Add movies and shows with the + button on a title\u{2019}s page.")
                .font(Theme.Font.body)
                .foregroundStyle(Theme.Palette.textSecondary)
        }
        .frame(maxWidth: .infinity)
        .padding(.top, Theme.Spacing.sectionGap)
    }
}
