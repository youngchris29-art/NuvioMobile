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
            ScrollView(.vertical) {
                VStack(alignment: .leading, spacing: 40) {
                    HStack(spacing: 16) {
                        Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                        TextField("Search movies & shows", text: $query)
                            .textFieldStyle(.plain)
                            .font(.title3)
                    }
                    .padding(20)
                    .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 12))

                    if model.isLoading {
                        HStack(spacing: 16) {
                            ProgressView()
                            Text("Searching\u{2026}").foregroundStyle(.secondary)
                        }
                    } else if let message = model.emptyMessage {
                        Text(message).font(.title3).foregroundStyle(.secondary)
                    } else if model.sections.isEmpty {
                        Text("Search for movies and shows.")
                            .font(.title3).foregroundStyle(.secondary)
                    }

                    ForEach(model.sections, id: \.key) { section in
                        CatalogRowView(section: section)
                    }
                }
                .padding(60)
            }
            .navigationTitle("Search")
            .navigationDestination(for: TitleRoute.self) { route in
                DetailView(preview: route.preview)
            }
        }
        .onChange(of: query) { _, newValue in
            model.queryChanged(newValue)
        }
        .onAppear { model.start() }
        .onDisappear { model.stop() }
    }
}
