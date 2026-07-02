import SwiftUI
import SharedCore

/// Search screen. Uses a plain `TextField` rather than `.searchable` — on tvOS `.searchable` inside a
/// `TabView` leaves a persistent keyboard panel that bleeds over results and pushed screens. A
/// `TextField` instead opens tvOS's self-contained full-screen keyboard which dismisses on commit,
/// then shows results inline. Results push the detail screen via a normal NavigationLink.
struct SearchView: View {
    @StateObject private var model = SearchViewModel()
    @State private var query = ""

    var body: some View {
        NavigationStack {
            ZStack {
                Theme.Palette.background.ignoresSafeArea()

                ScrollView(.vertical) {
                    VStack(alignment: .leading, spacing: Theme.Spacing.xl) {
                        HStack(spacing: Theme.Spacing.md) {
                            Image(systemName: "magnifyingglass")
                                .foregroundStyle(Theme.Palette.textSecondary)
                            TextField("Search movies & shows", text: $query)
                                .textFieldStyle(.plain)
                                .font(Theme.Font.body)
                                .foregroundStyle(Theme.Palette.textPrimary)
                        }
                        .padding(Theme.Spacing.lg)
                        .glassEffect(.regular, in: RoundedRectangle(cornerRadius: Theme.Radius.card))

                        if model.isLoading {
                            HStack(spacing: Theme.Spacing.md) {
                                ProgressView()
                                Text("Searching\u{2026}").foregroundStyle(Theme.Palette.textSecondary)
                            }
                        } else if let message = model.emptyMessage {
                            Text(message).font(Theme.Font.body).foregroundStyle(Theme.Palette.textSecondary)
                        } else if model.sections.isEmpty {
                            Text("Search for movies and shows.")
                                .font(Theme.Font.body).foregroundStyle(Theme.Palette.textSecondary)
                        }

                        ForEach(model.sections, id: \.key) { section in
                            CatalogRowView(section: section)
                        }
                    }
                    .padding(Theme.Spacing.screen)
                }
            }
            .navigationDestination(for: TitleRoute.self) { route in
                DetailView(preview: route.preview)
            }
            .navigationDestination(for: CatalogRoute.self) { route in
                CatalogGridView(route: route)
            }
            .navigationDestination(for: PersonRoute.self) { route in
                PersonDetailView(personId: route.id, personName: route.name)
            }
        }
        .onChange(of: query) { _, newValue in
            model.queryChanged(newValue)
        }
        .onAppear { model.start() }
        .onDisappear { model.stop() }
    }
}
