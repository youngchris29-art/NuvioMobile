import SwiftUI
import SharedCore
import Combine

/// Search screen, on tvOS's system search field (`.searchable`): results update under the keyboard
/// as you type (FEAT-37), with Siri dictation, typing from an iPhone and the viewer's own Linear or
/// Grid keyboard. Until S1 (2026-10-04) Search used a plain `TextField` because `.searchable` was
/// believed to leave its keyboard over pushed screens and other tabs; the 2026-10-04 spike and S1
/// Wave 0 found no such bleed on tvOS 26.5 or 27.2 with the structure below, and found the three
/// ways to get it wrong (`docs/search-s1-native-search-plan-2026-10-04.md` in the outer repo):
///
/// - `.searchable` sits on the results `ScrollView`, inside THIS tab's own `NavigationStack`. On
///   the `TabView` it makes tvOS wrap the whole tab shell in the search controller; inside a second,
///   nested `NavigationStack` the result links stop pushing.
/// - The typed text lives in `SearchQueryBox`, never in `@State`. With `@State`, every results
///   update re-applied a stale binding to the system field and typing from an iPhone flickered
///   between the old and new text (31 backward steps in 75 changes, on the Apple TV).
/// - `SearchFieldLayer`, which carries `.searchable`, observes only the query box, and
///   `SearchViewOwner` never publishes, so results updates re-run only `SearchContent`.
///
/// The inline keyboard has no Search/Done key, so a query joins Recent Searches when something is
/// opened from it (`SearchHistoryOnOpen`) or on the iPhone keyboard's return key.
///
/// While the query is empty the screen doubles as **Discover**: recent-search chips plus shared
/// `SearchRepository.discoverUiState`-driven browsing (type → catalog → genre → paginated grid).
struct SearchView: View {
    @StateObject private var owner = SearchViewOwner()
    @State private var path = NavigationPath()

    var body: some View {
        NavigationStack(path: $path) {
            ZStack {
                Theme.Palette.background.ignoresSafeArea()
                SearchFieldLayer(model: owner.model, queryBox: owner.queryBox)
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
        // Recent Searches on intent: anything opened from a query saves it (see `SearchHistoryOnOpen`).
        .onChange(of: path.count) { oldCount, newCount in
            if let query = owner.historyOnOpen.pathChanged(from: oldCount, to: newCount, query: owner.queryBox.text) {
                owner.model.recordSearch(query)
            }
        }
        .onAppear { owner.model.start() }
        .onDisappear { owner.model.stop() }
    }
}

/// The typed text, observed only by `SearchFieldLayer` (and read by `SearchContent` through a
/// binding). Never `@State`: see `SearchView`.
final class SearchQueryBox: ObservableObject {
    @Published var text = ""
}

/// Owns Search's state for the life of the tab. Deliberately publishes nothing, so `SearchView`'s
/// body never re-runs on a results update.
final class SearchViewOwner: ObservableObject {
    let model = SearchViewModel()
    let queryBox = SearchQueryBox()
    var historyOnOpen = SearchHistoryOnOpen()
}

/// Carries the system search field. Observes only the query box, so results updates never re-apply
/// `.searchable`'s text binding (the iPhone-keyboard flicker; see `SearchView`).
private struct SearchFieldLayer: View {
    let model: SearchViewModel
    @ObservedObject var queryBox: SearchQueryBox

    var body: some View {
        SearchContent(model: model, query: $queryBox.text)
            .searchable(text: $queryBox.text, prompt: Text("Search movies & shows"))
            // The iPhone keyboard's return key. The remote's inline keyboard has none.
            .onSubmit(of: .search) { model.recordSearch(queryBox.text) }
            .onChange(of: queryBox.text) { _, newValue in
                model.queryChanged(newValue)
            }
    }
}

/// The page under the search field: Recent Searches and Discover while the query is empty, the
/// results otherwise. Observes the model.
private struct SearchContent: View {
    @ObservedObject var model: SearchViewModel
    @Binding var query: String
    @Environment(\.posterStyle) private var posterStyle

    private var gridColumns: [GridItem] {
        [GridItem(
            .adaptive(minimum: posterStyle.width + Theme.Spacing.rowGap),
            spacing: Theme.Spacing.rowGap
        )]
    }

    var body: some View {
        ScrollView(.vertical) {
            VStack(alignment: .leading, spacing: Theme.Spacing.xl) {
                if queryIsEmpty {
                    historyChips
                    // UX-8: the user can hide the whole Discover section (synced per
                    // profile) — the page is then the search field + recent searches.
                    if !model.hideDiscover {
                        discoverSection
                    }
                } else {
                    searchResults
                }
            }
            .padding(Theme.Spacing.screen)
        }
        .scrollClipDisabled()
        // beta.19-rc1 verdict (M3, BUG-133): Search has no settle corrector, so its rows'
        // inline trailers gate on `RowsMotionClock` (`RowRestSource.motionClock`, the
        // default); this stamps it while the results scroll vertically.
        .rowsMotionStamp(.vertical)
        .reportsScrollToTabBar(tab: "Search")
        // FEAT-30: in sidebar mode Menu summons the floating sidebar instead of
        // suspending the app; a second Menu (with focus now in the sidebar) falls through
        // to the system default and exits, so the exit convention survives one step
        // further in. Structurally absent in tabs mode — see `SidebarMenuRevealModifier`.
        .sidebarMenuReveal()
    }

    private var queryIsEmpty: Bool {
        query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    // MARK: - Search results (query non-empty)

    @ViewBuilder
    private var searchResults: some View {
        // While a search loads over the previous query's rows (`SearchRowsHold`), the rows stay
        // and "Searching…" doesn't show.
        if model.isLoading && model.sections.isEmpty {
            HStack(spacing: Theme.Spacing.md) {
                ProgressView()
                Text("Searching\u{2026}")
                    .font(Theme.Font.body)
                    .foregroundStyle(Theme.Palette.textSecondary)
            }
        } else if let error = model.searchError {
            // Codex r1 on upstream 085e8dc6: a failed fan-out is not "No results." — name it and
            // offer the recovery (manifest re-fetch or a forced re-query, see retrySearch()).
            VStack(alignment: .leading, spacing: Theme.Spacing.md) {
                Text(error).font(Theme.Font.body).foregroundStyle(Theme.Palette.textSecondary)
                Button {
                    model.retrySearch()
                } label: {
                    Label("Retry", systemImage: "arrow.clockwise")
                        .font(Theme.Font.meta)
                        .padding(.horizontal, Theme.Spacing.md)
                        .padding(.vertical, Theme.Spacing.xs)
                }
                .buttonStyle(.chip)
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
                            RecentSearchChip(item: item) {
                                query = item
                            }
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
                                DiscoverChip(
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
                                DiscoverChip(title: String(localized: "All"), subtitle: nil, isSelected: widen(discover.selectedGenre) == nil) {
                                    model.selectDiscoverGenre(nil)
                                }
                            }
                            ForEach(discover.genreOptions, id: \.self) { genre in
                                DiscoverChip(title: genre, subtitle: nil, isSelected: widen(discover.selectedGenre) == genre) {
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
                // Upstream 085e8dc6: RequestFailed with NO catalog options means an add-on MANIFEST
                // failed (SearchRepository.refreshDiscover's early return), not a catalog page —
                // say so and offer the honest recovery (re-fetch the manifests) instead of
                // "try another genre".
                if reason == DiscoverEmptyStateReason.requestfailed, discover.catalogOptions.isEmpty {
                    VStack(alignment: .leading, spacing: Theme.Spacing.md) {
                        Text(widen(discover.errorMessage) ?? String(localized: "Couldn't load your add-ons."))
                            .font(Theme.Font.body)
                            .foregroundStyle(Theme.Palette.textSecondary)
                        Button {
                            AddonRepository.shared.refreshAll()
                        } label: {
                            Label("Retry", systemImage: "arrow.clockwise")
                                .font(Theme.Font.meta)
                                .padding(.horizontal, Theme.Spacing.md)
                                .padding(.vertical, Theme.Spacing.xs)
                        }
                        .buttonStyle(.chip)
                    }
                } else {
                    Text(discoverEmptyMessage(reason))
                        .font(Theme.Font.body)
                        .foregroundStyle(Theme.Palette.textSecondary)
                }
            }
        } else {
            LazyVGrid(columns: gridColumns, spacing: Theme.Spacing.xl) {
                ForEach(Array(discover.items.enumerated()), id: \.element.id) { index, item in
                    NavigationLink(value: TitleRoute(preview: item)) {
                        PosterCard(title: item.name, imageURL: item.poster, fallbackImageURL: item.rawPosterUrl)
                    }
                    .cardFocusButtonStyle()
                    .posterButtonShape()
                    .titleHoldMenu(preview: item)
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
                    DiscoverChip(title: label(option), subtitle: nil, isSelected: isSelected(option)) {
                        onSelect(option)
                    }
                }
            }
            .padding(.vertical, Theme.Spacing.xs)
        }
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

private struct RecentSearchChip: View {
    let item: String
    let action: () -> Void
    @FocusState private var focused: Bool

    var body: some View {
        Button(action: action) {
            HStack(spacing: Theme.Spacing.xs) {
                Image(systemName: "clock.arrow.circlepath")
                Text(item)
            }
            .font(Theme.Font.meta)
            .padding(.horizontal, Theme.Spacing.md)
            .padding(.vertical, Theme.Spacing.xs)
            .foregroundStyle(focused ? Theme.Palette.onFocusPlatter : Theme.Palette.textPrimary)
        }
        .buttonStyle(.chip)
        .focused($focused)
        .environment(\.settingsRowIsFocused, focused)
    }
}

private struct DiscoverChip: View {
    let title: String
    let subtitle: String?
    let isSelected: Bool
    let action: () -> Void
    @FocusState private var focused: Bool

    var body: some View {
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
                            .chipMetaText(selected: isSelected)
                    }
                }
            }
            .font(Theme.Font.meta)
            .padding(.horizontal, Theme.Spacing.md)
            .padding(.vertical, Theme.Spacing.xs)
        }
        .buttonStyle(.chip(selected: isSelected))
        .focused($focused)
        .environment(\.settingsRowIsFocused, focused)
    }
}
