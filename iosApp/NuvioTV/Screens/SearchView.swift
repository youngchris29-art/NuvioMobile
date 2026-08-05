import SwiftUI
import SharedCore

/// Search screen. Uses a plain `TextField` rather than `.searchable` — on tvOS `.searchable` inside a
/// `TabView` leaves a persistent keyboard panel that bleeds over results and pushed screens. A
/// `TextField` instead opens tvOS's self-contained full-screen keyboard which dismisses on commit,
/// then shows results inline. Results push the detail screen via a normal NavigationLink.
///
/// While the query is empty the screen doubles as **Discover**: recent-search chips plus shared
/// `SearchRepository.discoverUiState`-driven browsing (type → catalog → genre → paginated grid).
struct SearchView: View {
    @StateObject private var model = SearchViewModel()
    @State private var query = ""
    @Environment(\.posterStyle) private var posterStyle

    private var gridColumns: [GridItem] {
        [GridItem(
            .adaptive(minimum: posterStyle.width + Theme.Spacing.rowGap),
            spacing: Theme.Spacing.rowGap
        )]
    }

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
                                .onSubmit { model.recordSearch(query) }
                        }
                        .padding(Theme.Spacing.lg)
                        .glassEffect(.regular, in: RoundedRectangle(cornerRadius: Theme.Radius.card))

                        if queryIsEmpty {
                            historyChips
                            discoverSection
                        } else {
                            searchResults
                        }
                    }
                    .padding(Theme.Spacing.screen)
                }
                .scrollClipDisabled()
                .reportsScrollToTabBar()
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
            .navigationDestination(for: EntityRoute.self) { route in
                EntityBrowseView(route: route)
            }
        }
        .onChange(of: query) { _, newValue in
            model.queryChanged(newValue)
        }
        .onAppear { model.start() }
        .onDisappear { model.stop() }
    }

    private var queryIsEmpty: Bool {
        query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    // MARK: - Search results (query non-empty)

    @ViewBuilder
    private var searchResults: some View {
        if model.isLoading {
            HStack(spacing: Theme.Spacing.md) {
                ProgressView()
                Text("Searching\u{2026}")
                    .font(Theme.Font.body)
                    .foregroundStyle(Theme.Palette.textSecondary)
            }
        } else if let message = model.emptyMessage {
            Text(message).font(Theme.Font.body).foregroundStyle(Theme.Palette.textSecondary)
        }

        ForEach(model.sections, id: \.key) { section in
            CatalogRowView(section: section)
        }
    }

    // MARK: - Recent searches

    @ViewBuilder
    private var historyChips: some View {
        if !model.history.isEmpty {
            VStack(alignment: .leading, spacing: Theme.Spacing.md) {
                Text("Recent Searches")
                    .font(Theme.Font.sectionTitle)
                    .foregroundStyle(Theme.Palette.textPrimary)
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: Theme.Spacing.md) {
                        ForEach(model.history, id: \.self) { item in
                            Button {
                                query = item
                            } label: {
                                HStack(spacing: Theme.Spacing.xs) {
                                    Image(systemName: "clock.arrow.circlepath")
                                    Text(item)
                                }
                                .font(Theme.Font.meta)
                                .padding(.horizontal, Theme.Spacing.md)
                                .padding(.vertical, Theme.Spacing.xs)
                            }
                            .buttonStyle(.chip)
                            .contextMenu {
                                Button(role: .destructive) {
                                    model.removeHistory(item)
                                } label: {
                                    Label("Remove from history", systemImage: "trash")
                                }
                            }
                        }
                    }
                    .padding(.vertical, Theme.Spacing.xs)
                }
            }
        }
    }

    // MARK: - Discover (query empty)

    @ViewBuilder
    private var discoverSection: some View {
        if let discover = model.discover {
            VStack(alignment: .leading, spacing: Theme.Spacing.lg) {
                Text("Discover")
                    .font(Theme.Font.sectionTitle)
                    .foregroundStyle(Theme.Palette.textPrimary)

                if !discover.typeOptions.isEmpty {
                    chipRow(
                        options: discover.typeOptions,
                        isSelected: { widen(discover.selectedType) == $0 },
                        label: { typeLabel($0) }
                    ) { model.selectDiscoverType($0) }
                }

                if discover.catalogOptions.count > 1 {
                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(spacing: Theme.Spacing.md) {
                            ForEach(discover.catalogOptions, id: \.key) { option in
                                discoverChip(
                                    title: option.catalogName,
                                    subtitle: option.addonName,
                                    isSelected: widen(discover.selectedCatalogKey) == option.key
                                ) {
                                    model.selectDiscoverCatalog(option.key)
                                }
                            }
                        }
                        .padding(.vertical, Theme.Spacing.xs)
                    }
                }

                if !discover.genreOptions.isEmpty {
                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(spacing: Theme.Spacing.md) {
                            if discover.selectedCatalog?.genreRequired != true {
                                discoverChip(title: String(localized: "All"), subtitle: nil, isSelected: widen(discover.selectedGenre) == nil) {
                                    model.selectDiscoverGenre(nil)
                                }
                            }
                            ForEach(discover.genreOptions, id: \.self) { genre in
                                discoverChip(title: genre, subtitle: nil, isSelected: widen(discover.selectedGenre) == genre) {
                                    model.selectDiscoverGenre(genre)
                                }
                            }
                        }
                        .padding(.vertical, Theme.Spacing.xs)
                    }
                }

                discoverGrid(discover)
            }
        }
    }

    @ViewBuilder
    private func discoverGrid(_ discover: DiscoverUiState) -> some View {
        if discover.items.isEmpty {
            if discover.isLoading {
                HStack(spacing: Theme.Spacing.md) {
                    ProgressView()
                    Text("Loading\u{2026}")
                        .font(Theme.Font.body)
                        .foregroundStyle(Theme.Palette.textSecondary)
                }
            } else if let reason = discover.emptyStateReason {
                Text(discoverEmptyMessage(reason))
                    .font(Theme.Font.body)
                    .foregroundStyle(Theme.Palette.textSecondary)
            }
        } else {
            LazyVGrid(columns: gridColumns, spacing: Theme.Spacing.xl) {
                ForEach(Array(discover.items.enumerated()), id: \.element.id) { index, item in
                    NavigationLink(value: TitleRoute(preview: item)) {
                        PosterCard(title: item.name, imageURL: item.poster)
                    }
                    .buttonStyle(.borderless)
                    .posterButtonShape()
                    .onAppear { model.discoverItemAppeared(at: index) }
                }
            }
            if discover.isLoading {
                HStack {
                    Spacer()
                    ProgressView()
                    Spacer()
                }
                .padding(.vertical, Theme.Spacing.md)
            }
        }
    }

    // MARK: - Chip helpers

    private func chipRow(
        options: [String],
        isSelected: @escaping (String) -> Bool,
        label: @escaping (String) -> String,
        onSelect: @escaping (String) -> Void
    ) -> some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: Theme.Spacing.md) {
                ForEach(options, id: \.self) { option in
                    discoverChip(title: label(option), subtitle: nil, isSelected: isSelected(option)) {
                        onSelect(option)
                    }
                }
            }
            .padding(.vertical, Theme.Spacing.xs)
        }
    }

    private func discoverChip(
        title: String,
        subtitle: String?,
        isSelected: Bool,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            HStack(spacing: Theme.Spacing.xs) {
                if isSelected {
                    Image(systemName: "checkmark.circle.fill")
                }
                VStack(alignment: .leading, spacing: 0) {
                    Text(title)
                    if let subtitle, !subtitle.isEmpty {
                        Text(subtitle)
                            .font(Theme.Font.caption)
                            // BUG-33 defect 3: a bare `textSecondary` here went to 1.52:1 on the
                            // focused platter (worse than the 2.23:1 it measured unfocused) —
                            // `.chipMetaText` (FlatControlStyles.swift) anchors to the same
                            // focus/selection-aware tokens the chip's own label already uses.
                            .chipMetaText(selected: isSelected)
                    }
                }
            }
            .font(Theme.Font.meta)
            .padding(.horizontal, Theme.Spacing.md)
            .padding(.vertical, Theme.Spacing.xs)
        }
        .buttonStyle(.chip(selected: isSelected))
    }

    /// Kotlin `String?` properties can surface non-optional; force an explicit optional for ==.
    private func widen(_ value: String?) -> String? { value }

    private func typeLabel(_ type: String) -> String {
        switch type.lowercased() {
        case "movie": return String(localized: "Movies")
        case "series": return String(localized: "Series")
        case "tv": return String(localized: "TV")
        case "anime": return String(localized: "Anime")
        default: return type.capitalized
        }
    }

    private func discoverEmptyMessage(_ reason: DiscoverEmptyStateReason) -> String {
        // KMP exports these enum entries all-lowercase (like CloudLibraryItemType.webdownload).
        if reason == DiscoverEmptyStateReason.noactiveaddons {
            return String(localized: "Install and enable an add-on to browse its catalogs.")
        }
        if reason == DiscoverEmptyStateReason.nodiscovercatalogs {
            return String(localized: "Your add-ons don't expose browsable catalogs.")
        }
        if reason == DiscoverEmptyStateReason.requestfailed {
            return String(localized: "Couldn't load this catalog. Try another genre or catalog.")
        }
        return String(localized: "Nothing here yet \u{2014} try another genre or catalog.")
    }
}
