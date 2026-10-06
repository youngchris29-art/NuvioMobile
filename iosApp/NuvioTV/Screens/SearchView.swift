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
/// Search & Discover batch 2026-10-06 (O1 Dressed Search, plan B1/B3) dressed the page in the
/// stage's look: the ambient wash at layer 0 follows the focused result (`SearchWashDriver`); a typed
/// query shows the suggestion chips first, then the Top result card, the results grouped by type
/// ("Movies · 12", "Found in …" under the focused card) or one row per add-on (Settings > Sources >
/// Search Results), then People; a settled empty search names which of four empty states it is. While
/// the query is empty the page shows Recent Searches and, when Discover lives Under Search, a
/// Discover entry row that pushes the stage Discover page (`DiscoverRowsPage`). The inline
/// Discover browser (type / catalog / genre chips over a grid) left this page in that batch.
struct SearchView: View {
    @StateObject private var owner = SearchViewOwner()
    @State private var path = NavigationPath()

    var body: some View {
        NavigationStack(path: $path) {
            ZStack {
                Theme.Palette.background.ignoresSafeArea()
                // B3 a: layer 0, like the folder page's. Only the wash observes the driver's feed,
                // so a focus report never re-renders the page.
                AmbientWashLayer(feed: owner.wash.feed, probeID: "debug_wash_search")
                    .ignoresSafeArea()
                SearchFieldLayer(owner: owner, queryBox: owner.queryBox)
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
            // A4 / B3 h: the stage Discover page, pushed from the idle page's entry row (Under
            // Search placement). Its view model lives on the owner, so loaded rows survive a pop;
            // the pushed page starts and stops it itself.
            .navigationDestination(for: DiscoverRoute.self) { discoverRoute in
                DiscoverRowsPage(model: owner.discoverModel, host: .pushed, routeType: discoverRoute.type,
                                 onOpenGrid: { route in
                    path.append(route)
                })
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
    /// B3 a: the wash's feed and timing. Not published; only `AmbientWashLayer` observes its feed.
    let wash = SearchWashDriver()
    /// A4: the pushed stage Discover page's model (Under Search), created on first push and kept
    /// for the tab's life so its rows survive pop and push. Not published.
    lazy var discoverModel = DiscoverRowsViewModel()
}

/// Carries the system search field. Observes only the query box, so results updates never re-apply
/// `.searchable`'s text binding (the iPhone-keyboard flicker; see `SearchView`).
private struct SearchFieldLayer: View {
    /// A plain reference, never observed (it never publishes anyway).
    let owner: SearchViewOwner
    @ObservedObject var queryBox: SearchQueryBox

    var body: some View {
        SearchContent(model: owner.model, owner: owner, query: $queryBox.text)
            .searchable(text: $queryBox.text, prompt: Text("Search movies & shows"))
            // The iPhone keyboard's return key. The remote's inline keyboard has none.
            .onSubmit(of: .search) {
                owner.model.recordSearch(queryBox.text)
                owner.historyOnOpen.submitted(queryBox.text)
            }
            .onChange(of: queryBox.text) { _, newValue in
                owner.historyOnOpen.queryChanged(to: newValue)
                owner.model.queryChanged(newValue)
                // B3 a: the view model stays UI-free, so the view clears the wash on an empty field.
                if newValue.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    owner.wash.clear()
                } else {
                    owner.wash.queryTyped()
                }
            }
    }
}

/// The page under the search field: Recent Searches (and the Discover entry row, Under Search) while
/// the query is empty, the results otherwise. Observes the model.
private struct SearchContent: View {
    @ObservedObject var model: SearchViewModel
    /// A plain reference, never observed.
    let owner: SearchViewOwner
    @Binding var query: String
    /// Held for the keyboard flag only (Rail mode sets it; B4).
    @Environment(\.navigationChrome) private var navigationChrome

    var body: some View {
        ScrollView(.vertical) {
            VStack(alignment: .leading, spacing: Theme.Spacing.xl) {
                if queryIsEmpty {
                    idlePage
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
        // FEAT-30 / H9: in Rail mode Menu summons the navigation rail instead of
        // suspending the app; a second Menu (with focus now in the rail) falls through
        // to the system default and exits, so the exit convention survives one step
        // further in. Structurally absent in tabs mode — see `RailMenuRevealModifier`.
        .railMenuReveal()
        // B3 a: while focus is outside the results, the wash shows the Top result.
        .onChange(of: topResultIdentity) { _, _ in
            owner.wash.topResultChanged(model.topResult)
        }
        .onReceive(navigationChrome.$searchKeyboardFocused) { focused in
            if focused { owner.wash.keyboardFocused(topResult: model.topResult) }
        }
        #if DEBUG
        .overlay(alignment: .topLeading) { searchStateProbe }
        #endif
    }

    private var queryIsEmpty: Bool {
        trimmedQuery.isEmpty
    }

    private var trimmedQuery: String {
        query.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private var topResultIdentity: String? {
        model.topResult.map { "\($0.type):\($0.id)" }
    }

    // MARK: - Search results (query non-empty)

    @ViewBuilder
    private var searchResults: some View {
        // B3 d: first under the system band; hidden until the first rows (or a settle) arrive.
        if !model.suggestions.isEmpty, !(model.rows.isEmpty && model.isLoading) {
            SearchSuggestionRow(suggestions: model.suggestions, query: trimmedQuery) { index, text in
                if index == 0 {
                    // The quoted chip: the Search key the inline keyboard lacks.
                    model.recordSearch(trimmedQuery)
                    owner.historyOnOpen.submitted(trimmedQuery)
                } else {
                    query = text
                }
            }
        }

        if let emptyState = model.emptyState {
            SearchEmptyStateView(
                state: emptyState,
                onRetry: { model.retrySearch() },
                onOpenSettings: {
                    NotificationCenter.default.post(name: .nuvioOpenSettings,
                                                    object: nil,
                                                    userInfo: ["category": "sources"])
                }
            )
        } else {
            // While a search loads over the previous query's rows (`SearchRowsHold`), the rows stay
            // and "Searching…" doesn't show.
            if model.isLoading && model.rows.isEmpty && model.topResult == nil {
                HStack(spacing: Theme.Spacing.md) {
                    ProgressView()
                    Text("Searching\u{2026}")
                        .font(Theme.Font.body)
                        .foregroundStyle(Theme.Palette.textSecondary)
                }
            }

            if let top = model.topResult {
                SearchTopResultCard(item: top, foundIn: model.foundInCaption(for: top)) { item in
                    owner.wash.report(item)
                }
            }

            let footnote = cardFootnote
            ForEach(model.rows, id: \.key) { section in
                CatalogRowView(
                    section: section,
                    onItemFocusChange: { owner.wash.report($0) },
                    cardFootnote: footnote
                )
                .accessibilityElement(children: .contain)
                .accessibilityIdentifier(Self.groupID(section.key))
            }

            if !model.people.isEmpty {
                SearchPeopleRow(people: model.people) {
                    owner.wash.noteResultFocus()
                }
            }
        }
    }

    /// B3 f: "Found in …" under the focused card, grouped mode only (per add-on, the row heading
    /// already names the source).
    private var cardFootnote: ((MetaPreview) -> String?)? {
        guard model.rowsMode == .grouped else { return nil }
        let model = model
        return { model.foundInCaption(for: $0) }
    }

    /// `search.group.<key>`. Grouped rows' keys already read `search.group.type:<type>`; a
    /// per-add-on row's key gets the prefix.
    static func groupID(_ key: String) -> String {
        key.hasPrefix("search.group.") ? key : "search.group.\(key)"
    }

    // MARK: - Idle page (query empty)

    @ViewBuilder
    private var idlePage: some View {
        recentRow
        // A5 / B3 h: Own Tab puts Discover on the tab bar and rail, Off hides it; only Under
        // Search adds the entry row here.
        if model.discoverPlacement == .underSearch {
            DiscoverEntryRow()
        }
    }

    @ViewBuilder
    private var recentRow: some View {
        if !model.history.isEmpty {
            VStack(alignment: .leading, spacing: Theme.Spacing.md) {
                Text("Recent Searches")
                    .font(Theme.Font.sectionTitle)
                    .foregroundStyle(Theme.Palette.textPrimary)
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: Theme.Spacing.md) {
                        ForEach(model.history, id: \.self) { item in
                            FilterChip(title: item, systemImage: "clock.arrow.circlepath", isActive: false) {
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
                .scrollClipDisabled()
                .focusSection()
            }
            .accessibilityElement(children: .contain)
            .accessibilityIdentifier("search.recent")
        }
    }

    // MARK: - DEBUG probe

    #if DEBUG
    /// `search_state q=<query, spaces as +> rid=<active request id|-> mode=<grouped|per_addon>
    /// rows=<n> people=<n> hold=<idle|follow|hold|hold_other> empty=<token|->`. `rid` and `hold`
    /// are read off the view model (`debugActiveRequestId`, `debugHoldPhase`) when the leaf renders,
    /// which is on every published change (rows, people, empty state, loading).
    private var searchStateProbe: some View {
        Text(verbatim: Self.stateLine(query: trimmedQuery,
                                      mode: model.rowsMode,
                                      rows: model.rows.count,
                                      people: model.people.count,
                                      empty: model.emptyState,
                                      requestId: model.debugActiveRequestId,
                                      hold: model.debugHoldPhase))
            .font(.system(size: 8))
            .opacity(0.011)
            .allowsHitTesting(false)
            .accessibilityIdentifier("search_state")
    }

    static func stateLine(query: String, mode: SearchRowsMode, rows: Int, people: Int,
                          empty: SearchEmptyState?, requestId: Int64? = nil, hold: String = "-") -> String {
        let q = query.isEmpty ? "-" : query.replacingOccurrences(of: " ", with: "+")
        let rid = requestId.map { String($0) } ?? "-"
        return "search_state q=\(q) rid=\(rid) mode=\(mode.rawValue) rows=\(rows) people=\(people) hold=\(hold) empty=\(emptyToken(empty))"
    }

    static func emptyToken(_ state: SearchEmptyState?) -> String {
        switch state {
        case nil: return "-"
        case .manifestFailure: return "manifest_failure"
        case .noneCanSearch: return "none_can_search"
        case .allSourcesOff: return "all_sources_off"
        case .noResults: return "no_results"
        }
    }
    #endif
}
