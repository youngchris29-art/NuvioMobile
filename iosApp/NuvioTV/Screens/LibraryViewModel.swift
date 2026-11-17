import Combine
import SharedCore

/// One card in the Library grid.
struct LibraryGridEntry: Identifiable, Equatable {
    /// `type:id`, normalized like the shared projection's de-duplication key, so ids are unique.
    let id: String
    let item: LibraryItem
    let state: LibraryGridPolicy.WatchState
    /// The projection's type key (`mediaCategory ?? type`), for the count line.
    let kind: String
}

/// A provider-list remove waiting for the viewer's OK (Simkl, see
/// `LibraryRepository.removalNeedsConfirmation`). Captures the list at hold time.
struct LibraryPendingRemoval {
    let item: LibraryItem
    let listKey: String
    let listTitle: String?
    let providerName: String?
}

/// Observes the shared `LibraryRepository` (the local Nuvio library, or the Trakt / Simkl /
/// MDBList library picked in Settings → Sources → Library Source). Profile-scoped (reloads on
/// profile switch via the Phase 4 lifecycle coordinator).
///
/// Library L1 (2026-10-04): the grid now goes through the shared `buildLibraryVerticalProjection`
/// (the provider's lists, a type filter, de-duplication and the shared sort, all as on mobile's
/// grid layout), adds watched / in-progress state per title for badges and the smart filters, and
/// publishes which screen state to show (`LibraryGridPolicy.Content`) instead of reading an
/// empty list as "empty" while a provider library is still loading or has failed.
@MainActor
final class LibraryViewModel: ObservableObject {
    @Published private(set) var entries: [LibraryGridEntry] = []
    @Published private(set) var content: LibraryGridPolicy.Content = .loading
    @Published private(set) var countLine = ""
    /// The shared `LibrarySourceMode` case name (`LOCAL` / `TRAKT` / `SIMKL` / `MDBLIST`).
    @Published private(set) var sourceModeName = "LOCAL"
    /// The provider's lists (Trakt watchlist and lists, Simkl statuses, MDBList lists). Always
    /// empty for the local library, which has no lists.
    @Published private(set) var sections: [LibrarySection] = []
    @Published private(set) var selectedSectionKey: String?
    /// The Type menu's rows: the chosen list's types in menu order, with counts under the Show
    /// choice, genre and year (`LibraryBarResolver`). Nil type = All.
    @Published private(set) var types: [LibraryGridPolicy.FacetOption] = []
    @Published private(set) var selectedType: String?
    @Published private(set) var allTypesCount = 0
    /// The smart filters the Show menu offers (`LibraryBarResolver`).
    @Published private(set) var visibleSmartFilters: [LibraryGridPolicy.SmartFilter] = []
    /// The Show choice applied (effective); the remembered one is `requestedSmartFilters`.
    @Published private(set) var activeSmartFilters: Set<LibraryGridPolicy.SmartFilter> = []
    /// The Genre menu's rows (under the Show choice, type and year), alphabetical, with counts.
    /// Empty when the source carries none (Simkl).
    @Published private(set) var genres: [LibraryGridPolicy.FacetOption] = []
    /// The genre applied (nil = All), spelled as its menu row.
    @Published private(set) var selectedGenre: String?
    /// The Year menu's rows (under the Show choice, type and genre), newest first, with counts.
    @Published private(set) var years: [LibraryGridPolicy.FacetOption] = []
    @Published private(set) var selectedYear: String?
    /// Which menus the bar draws (`LibraryBarResolver.shows`).
    @Published private(set) var showsType = false
    @Published private(set) var showsGenre = false
    @Published private(set) var showsYear = false
    @Published private(set) var showsShow = false

    /// Any filter that narrows the grid below the list and type: genre, year or a smart filter.
    var filtersActive: Bool { !activeSmartFilters.isEmpty || selectedGenre != nil || selectedYear != nil }
    @Published private(set) var sortOption: LibrarySortOption = .addedDesc
    /// What the grid is actually sorted by: the local library has no provider order, so a stored
    /// DEFAULT sorts (and is labelled) as Recently Added there, as on mobile.
    @Published private(set) var effectiveSortOption: LibrarySortOption = .addedDesc
    /// Sort options valid for the active source (DEFAULT = the provider's order, remote only).
    @Published private(set) var availableSortOptions: [LibrarySortOption] = []
    /// The shared state's `isLoading` (a provider pull in flight, incl. the Refresh pill's and
    /// Retry's user-initiated one), for the spinner beside the Refresh pill.
    @Published private(set) var isLoading = false
    /// Set while the remove confirmation is up.
    @Published private(set) var pendingRemoval: LibraryPendingRemoval?
    /// A failed remove's message, shown in an alert (the shared toast is a no-op on tvOS).
    @Published var actionError: String?

    var providerName: String? { LibraryGridPolicy.providerName(sourceModeName: sourceModeName) }
    /// Batch D review r2 P2: the Refresh pill shows for provider libraries only.
    var showsProviderControls: Bool { LibraryGridPolicy.showsProviderControls(sourceModeName: sourceModeName) }

    /// The chosen list's title ("Watchlist", "Plan to Watch", …), for the pill and the hold menu.
    var selectedSectionTitle: String? {
        guard let key = selectedSectionKey else { return nil }
        return sections.first { $0.type == key }?.displayTitle
    }

    /// Whether the hold menu offers "Remove from ‹list›" on the open list. Batch K: MDBList's
    /// external, dynamic and liked lists (upstream 3913a140b / 2cc2e6a61) are read-only, and the
    /// MDBList writer skips them, so a Remove there would do nothing. Read when the menu is built.
    var selectedSectionAllowsRemove: Bool {
        LibraryGridPolicy.offersRemove(listKey: selectedSectionKey) { key in
            LibraryRepository.shared.canRemoveFromList(listKey: key)
        }
    }

    private var libraryState: LibraryUiState?
    /// Newest drawable progress per content id (`WatchProgressEntry.parentMetaId`).
    private var progressByContentId: [String: Double] = [:]
    /// What the viewer picked. List and type come from the shared display settings (remembered per
    /// profile, upstream 2da28d707, and per source: review r1, a pick is applied only while the
    /// source it was made in is active); genre, year and Show live here for the session. A pick with
    /// no title in the current data is not applied (the bar shows All) but stays; only a viewer
    /// action drops a session pick (`LibraryBarResolver.picksToDrop`, review r3).
    private var requestedSectionKey: String?
    private var requestedType: String?
    /// The remembered list and type and the source they belong to: the display settings' values,
    /// mirrored at once when the viewer picks (in fixture mode the mirror is all there is).
    private var rememberedSectionKey: String?
    private var rememberedType: String?
    private var rememberedSource: String?
    private var requestedGenre: String?
    private var requestedYear: String?
    private var requestedSmartFilters: Set<LibraryGridPolicy.SmartFilter> = []
    /// The viewer action the next derive follows (review r3: only a viewer action drops a pick).
    private var pendingAction: LibraryBarResolver.ViewerAction?
    /// DEBUG fixture (mockups, UI leg, unit tests): a canned library, no repository reads or writes.
    let fixture: LibraryDebugFlags.Fixture
    /// Where a viewer's list and type picks are written: the shared display settings, or (fixture
    /// mode) nowhere. The only writer of remembered picks; tests pass a spy.
    private let pickStore: LibraryPickStore

    init(fixture: LibraryDebugFlags.Fixture = LibraryDebugFlags.fixture, pickStore: LibraryPickStore? = nil) {
        self.fixture = fixture
        self.pickStore = pickStore ?? (fixture == .off ? .sharedSettings : .discard)
    }
    private var lastSourceModeName: String?
    /// Watched flag per entry id. `WatchedRepository.isWatched` runs the tracker registry's
    /// `ensureLoaded` on every call, so it is asked once per title and again only after the watched
    /// flows emit, not on every library, progress or filter change.
    private var watchedByEntryID: [String: Bool] = [:]
    private var watchers: [FlowWatcher] = []
    private var republishScheduled = false

    /// Which provider order `providerOrderWatcher` is collecting: one list of one source under
    /// one effective sort (review r1 P2). Nil for the local library, which has no provider order.
    private struct ProviderOrderKey: Equatable {
        let sourceModeName: String
        let listKey: String
        let sortOptionName: String
    }
    private var providerOrderWatcher: FlowWatcher?
    private var providerOrderKey: ProviderOrderKey?
    /// The latest `LibraryProviderOrderResult` for `providerOrderKey`: the provider's rank per
    /// item key (nil while unknown, or when the sort has no provider order), and whether the
    /// provider's sorter failed.
    private var providerOrderRanks: [String: Int]?
    /// The key `providerOrderRanks` were computed for, so a re-subscription for the same key (a
    /// Refresh / Retry) keeps the grid's order instead of blinking to the fallback while the
    /// provider's sorter re-emits.
    private var providerOrderRanksKey: ProviderOrderKey?
    private var providerOrderFailed = false

    func start() {
        if fixture != .off {
            // No flows: the fixture is the whole library. `libraryState` set once keeps this idempotent.
            guard libraryState == nil else { return }
            libraryState = LibraryFilterFixture.shared.uiState(provider: fixture == .provider)
            republish()
            return
        }
        guard watchers.isEmpty else { return }
        LibraryRepository.shared.ensureLoaded()
        LibraryDisplaySettingsRepository.shared.ensureLoaded()
        WatchedRepository.shared.ensureLoaded()
        WatchProgressRepository.shared.ensureLoaded()

        watchers.append(FlowWatcherKt.watch(LibraryRepository.shared.uiState) { [weak self] emitted in
            guard let self, let state = emitted as? LibraryUiState else { return }
            self.libraryState = state
            self.scheduleRepublish()
        })
        watchers.append(FlowWatcherKt.watch(LibraryDisplaySettingsRepository.shared.uiState) { [weak self] emitted in
            guard let self, let state = emitted as? LibraryDisplaySettingsUiState else { return }
            // The echo of the viewer's own pick (already mirrored) changes nothing: no second derive.
            let unchanged = self.sortOption == state.sortOption && self.rememberedSectionKey == state.selectedSectionKey
                && self.rememberedType == state.selectedType && self.rememberedSource == state.selectionSourceMode
            self.sortOption = state.sortOption
            self.rememberedSectionKey = state.selectedSectionKey
            self.rememberedType = state.selectedType
            self.rememberedSource = state.selectionSourceMode
            if !unchanged { self.scheduleRepublish() }
        })
        // Watched marks are read per title in `republish` through the repository's own
        // `isWatched` / `isFullyWatchedSeries` (the hold menu's test) and cached; these two only
        // drop the cache and trigger.
        watchers.append(FlowWatcherKt.watch(WatchedRepository.shared.uiState) { [weak self] _ in
            self?.watchedByEntryID.removeAll()
            self?.scheduleRepublish()
        })
        watchers.append(FlowWatcherKt.watch(WatchedRepository.shared.fullyWatchedSeriesKeys) { [weak self] _ in
            self?.watchedByEntryID.removeAll()
            self?.scheduleRepublish()
        })
        watchers.append(FlowWatcherKt.watch(WatchProgressRepository.shared.uiState) { [weak self] emitted in
            guard let self, let state = emitted as? WatchProgressUiState else { return }
            self.progressByContentId = Self.newestProgress(state)
            self.scheduleRepublish()
        })
    }

    func stop() {
        watchers.forEach { $0.cancel() }
        watchers.removeAll()
        providerOrderWatcher?.cancel()
        providerOrderWatcher = nil
        providerOrderKey = nil
        providerOrderRanks = nil
        providerOrderRanksKey = nil
        providerOrderFailed = false
    }

    // MARK: - Viewer actions

    func selectSection(_ key: String) {
        // Persisted per profile and source, and mirrored here at once so this derive (the action's)
        // sees the new list. A new list starts on All types.
        guard let source = libraryState?.sourceMode else { return }
        pickStore.writeSection(key, source)
        #if DEBUG
        debugPickWrites += 1
        #endif
        rememberedSectionKey = key
        rememberedType = nil
        rememberedSource = source.name
        act(.list)
    }

    /// Nil = All.
    func selectType(_ type: String?) {
        guard let source = libraryState?.sourceMode else { return }
        pickStore.writeType(type, source)
        #if DEBUG
        debugPickWrites += 1
        #endif
        if rememberedSource != source.name { rememberedSectionKey = nil }
        rememberedType = type
        rememberedSource = source.name
        act(.type)
    }

    /// Nil = All.
    func selectGenre(_ genre: String?) {
        requestedGenre = genre
        act(.genre)
    }

    /// Nil = All.
    func selectYear(_ year: String?) {
        requestedYear = year
        act(.year)
    }

    func toggleSmartFilter(_ filter: LibraryGridPolicy.SmartFilter) {
        requestedSmartFilters = LibraryGridPolicy.toggling(filter, in: requestedSmartFilters)
        act(.show)
    }

    /// The Show menu: one choice, mapped onto the same smart-filter set.
    func selectWatchChoice(_ choice: LibraryGridPolicy.WatchChoice) {
        requestedSmartFilters = LibraryGridPolicy.smartFilters(for: choice)
        act(.show)
    }

    /// Derives right away for a viewer action, so `LibraryBarResolver.picksToDrop` judges the picks
    /// against the titles on screen under the new selection.
    private func act(_ action: LibraryBarResolver.ViewerAction) {
        pendingAction = action
        republish()
        // Never carried into a later derive (a snapshot), whichever path `republish` took.
        pendingAction = nil
    }

    #if DEBUG
    /// The probe's count of list and type picks written (the UI leg's check that re-picking the row
    /// a menu already shows reaches the setter).
    @Published private(set) var debugPickWrites = 0

    /// Tests only (fixture mode): replace the canned library with `state`, e.g. a partial provider
    /// snapshot, and derive as a library emission would.
    func replaceFixtureLibrary(_ state: LibraryUiState) {
        guard fixture != .off else { return }
        libraryState = state
        republish()
    }
    #endif

    /// Clear Filters (the bar's pill and the no-matches state): genre, year and smart filters.
    /// List, type and sort stay.
    func clearFilters() {
        requestedSmartFilters = []
        requestedGenre = nil
        requestedYear = nil
        act(.clearFilters)
    }

    /// Persist a new sort (shared repo: profile-scoped NSUserDefaults). The watcher republishes.
    func setSort(_ option: LibrarySortOption) {
        guard fixture == .off else {
            sortOption = option
            republish()
            return
        }
        LibraryDisplaySettingsRepository.shared.setSortOption(sortOption: option)
    }

    func sortLabel(_ option: LibrarySortOption) -> String {
        LibraryGridPolicy.sortLabel(optionName: option.name, sourceModeName: sourceModeName)
    }

    /// Retry after a failed load (the same pull mobile's Retry runs). Failure-contained in Kotlin.
    func retry() {
        guard fixture == .off else { return }
        resetProviderOrderSubscription()
        LibraryRepository.shared.retryLoadAsync()
    }

    /// The Refresh pill (batch D review r2 P2): the one user-initiated pull a provider library
    /// has outside the failed state. `retryLoadAsync` runs the USER_INITIATED pull, which for
    /// MDBList re-downloads the lists (a list re-sorted on mdblist.com keeps its `updatedAt`, so
    /// nothing else would notice). Ignored while a pull is already in flight.
    func refresh() {
        guard fixture == .off else { return }
        guard !isLoading else { return }
        retry()
    }

    /// Review r2 P3-4: a provider-order watcher that failed (or went stale) would stay failed for
    /// as long as its (source, list, sort) key stood, because `observeProviderOrder` only
    /// re-subscribes on a key change. Forgetting the key makes the next republish (the pull's own
    /// state emission) subscribe again; the ranks stay for the grid until the sorter re-emits.
    private func resetProviderOrderSubscription() {
        providerOrderWatcher?.cancel()
        providerOrderWatcher = nil
        providerOrderKey = nil
        providerOrderFailed = false
    }

    /// The hold menu's remove. With a provider list open it removes the title from THAT list
    /// (`removeFromListAsync` touches only the provider that owns it). `toggleSaved` would flip the
    /// provider's default list instead (the watchlist), which on any other list would add the title
    /// to the watchlist rather than remove it. Simkl asks first: leaving a status there also clears
    /// the title's watched history and rating.
    ///
    /// The local library has no lists (`selectedSectionKey` is always nil there), so it keeps
    /// `toggleSaved`, guarded like the catalog hold menu (`labelStillMatchesLiveState`): a menu
    /// built before the title was removed elsewhere must not re-add it.
    ///
    /// `listKey` / `listTitle` are what the menu showed, read when it was built, so a sync that
    /// changes the open list while the menu is up can't make the action disagree with its label.
    func requestRemove(_ entry: LibraryGridEntry, listKey: String?, listTitle: String?) {
        guard fixture == .off else { return }
        guard let key = listKey else {
            if LibraryRepository.shared.isSaved(id: entry.item.id, type: entry.item.type) {
                LibraryRepository.shared.toggleSaved(item: entry.item)
            }
            return
        }
        let removal = LibraryPendingRemoval(
            item: entry.item,
            listKey: key,
            listTitle: listTitle,
            providerName: providerName
        )
        if LibraryRepository.shared.removalNeedsConfirmation(item: entry.item, listKey: key) {
            pendingRemoval = removal
        } else {
            performRemoval(removal, confirmed: false)
        }
    }

    func confirmRemoval(_ removal: LibraryPendingRemoval) {
        pendingRemoval = nil
        performRemoval(removal, confirmed: true)
    }

    func cancelRemoval() {
        pendingRemoval = nil
    }

    private func performRemoval(_ removal: LibraryPendingRemoval, confirmed: Bool) {
        LibraryRepository.shared.removeFromListAsync(
            item: removal.item,
            listKey: removal.listKey,
            destructiveRemovalConfirmed: confirmed
        ) { [weak self] message in
            // Called off the main thread; nil = removed.
            guard let message else { return }
            Task { @MainActor in self?.actionError = LibraryGridPolicy.removeFailedMessage(message) }
        }
    }

    // MARK: - Derivation

    /// Several flows emit together on start and after a sync; derive once per main-actor turn.
    private func scheduleRepublish() {
        guard !republishScheduled else { return }
        republishScheduled = true
        Task { @MainActor [weak self] in
            guard let self else { return }
            self.republishScheduled = false
            self.republish()
        }
    }

    private func republish() {
        guard let state = libraryState else {
            update(\.content, .loading)
            return
        }
        let modeName = state.sourceMode.name
        if lastSourceModeName != modeName {
            // A different library (Settings → Library Source changed): its genres, years and watch
            // states are different, so the session filters go. The remembered list and type stay in
            // the shared settings tagged with their source: another source opens on its first list
            // and All types, and the old source gets them back until a pick is made elsewhere.
            if lastSourceModeName != nil {
                requestedGenre = nil
                requestedYear = nil
                requestedSmartFilters = []
            }
            lastSourceModeName = modeName
        }
        update(\.sourceModeName, modeName)
        update(\.availableSortOptions, LibraryDisplaySettingsKt.availableLibrarySortOptions(sourceMode: state.sourceMode))
        let effective = LibraryDisplaySettingsKt.effectiveLibrarySortOption(
            selected: sortOption,
            sourceMode: state.sourceMode
        )
        update(\.effectiveSortOption, effective)

        // The remembered list and type apply only in the source they were picked in (review r1).
        let picks = LibraryGridPolicy.rememberedPicks(
            sectionKey: rememberedSectionKey,
            type: rememberedType,
            pickedIn: rememberedSource,
            activeSource: modeName
        )
        requestedSectionKey = picks.sectionKey
        requestedType = picks.type

        // Provider orders (batch D review r1 P2, mobile's `rememberLibraryProviderOrders`): for a
        // provider library, the chosen list's order under the effective sort comes from the
        // provider's own sorter — MDBList's added / release orders are its server's, not derivable
        // from `savedAtEpochMs` (U1). The shared `observeProviderOrder` emits (nil, false) once for
        // a sort with no provider order (DEFAULT, whose "List Order" is the list rank the
        // projection reads off `listKey`; TITLE_*), so those cost nothing. One watcher at a time,
        // re-created when the (source, list, effective sort) triple changes. On a failed sorter
        // the projection falls back to DEFAULT, as mobile's grid does; the pill keeps showing the
        // selected sort (`effectiveSortOption` is untouched). The DEBUG fixture has no provider.
        let orderListKey: String? = (fixture != .off || LibraryGridPolicy.providerName(sourceModeName: modeName) == nil)
            ? nil
            : (state.sections.first { $0.type == requestedSectionKey } ?? state.sections.first)?.type
        observeProviderOrder(
            key: orderListKey.map { ProviderOrderKey(sourceModeName: modeName, listKey: $0, sortOptionName: effective.name) },
            sortOption: effective
        )
        let providerOrders: [String: [String: KotlinInt]]
        if let orderListKey, let ranks = providerOrderRanks {
            providerOrders = [orderListKey: ranks.mapValues { KotlinInt(int: Int32($0)) }]
        } else {
            providerOrders = [:]
        }
        // The shared projection picks the list, de-duplicates and sorts; type, genre, year and the
        // Show choice are the bar's (`LibraryBarResolver`), so every count honours the Show choice
        // without a Kotlin-to-Swift callback per title.
        let projection = LibraryDisplaySettingsKt.buildLibraryVerticalProjection(
            sections: state.sections,
            sourceMode: state.sourceMode,
            selectedSectionKey: requestedSectionKey,
            selectedType: nil,
            sortOption: providerOrderFailed ? LibrarySortOption.default_ : sortOption,
            providerOrders: providerOrders,
            selectedGenre: nil,
            selectedYear: nil
        )
        update(\.sections, projection.availableSections)
        update(\.selectedSectionKey, projection.selectedSectionKey)

        let all = projection.entries.map { entry -> LibraryGridEntry in
            let item = entry.item
            let id = Self.entryID(item)
            return LibraryGridEntry(
                id: id,
                item: item,
                state: watchState(item, entryID: id),
                kind: item.mediaCategory ?? item.type
            )
        }
        let titles = all.map { entry in
            LibraryBarResolver.Title(
                typeKey: entry.kind,
                genres: entry.item.genres,
                year: LibraryBarResolver.releaseYear(entry.item.releaseInfo),
                state: entry.state
            )
        }
        let bar = LibraryBarResolver.resolve(
            titles: titles,
            request: .init(type: requestedType, genre: requestedGenre, year: requestedYear, smartFilters: requestedSmartFilters),
            typeOrder: projection.availableTypes
        )
        // Data never forgets a pick; only the viewer does (review r3). After a viewer action the
        // session picks with no title under the new selection go for good; after a snapshot nothing
        // goes (an unavailable pick just shows as All until its titles return). Nothing here writes
        // the remembered list or type.
        let drop = LibraryBarResolver.picksToDrop(after: pendingAction, unavailable: bar.unavailable)
        pendingAction = nil
        if drop.contains(.genre) { requestedGenre = nil }
        if drop.contains(.year) { requestedYear = nil }
        if drop.contains(.show) { requestedSmartFilters = [] }
        update(\.types, bar.types)
        update(\.selectedType, bar.selectedType)
        update(\.allTypesCount, bar.allTypesCount)
        update(\.genres, bar.genres)
        update(\.selectedGenre, bar.selectedGenre)
        update(\.years, bar.years)
        update(\.selectedYear, bar.selectedYear)
        update(\.visibleSmartFilters, bar.visibleSmartFilters)
        update(\.activeSmartFilters, bar.smartFilters)
        update(\.showsType, bar.showsType)
        update(\.showsGenre, bar.showsGenre)
        update(\.showsYear, bar.showsYear)
        update(\.showsShow, bar.showsShow)

        let shown = bar.shown.map { all[$0] }
        update(\.entries, shown)
        update(\.countLine, LibraryGridPolicy.countLine(kinds: shown.map(\.kind)))
        update(\.isLoading, state.isLoading)
        update(\.content, LibraryGridPolicy.content(
            isLoaded: state.isLoaded,
            isLoading: state.isLoading,
            errorMessage: state.errorMessage,
            hasAnySection: !state.sections.isEmpty,
            visibleCount: shown.count,
            filtersActive: filtersActive
        ))
    }

    /// A title's watch state: the repositories', or the fixture's id convention.
    private func watchState(_ item: LibraryItem, entryID: String) -> LibraryGridPolicy.WatchState {
        if fixture != .off {
            return LibraryDebugFlags.fixtureWatchState(id: item.id)
        }
        return LibraryGridPolicy.WatchState(
            isWatched: isWatched(item, entryID: entryID),
            progress: progressByContentId[item.id]
        )
    }

    /// Keeps exactly one provider-order watcher, for `key`; a nil key (local library) stops any.
    /// The watcher's emissions only store the result and schedule a republish, which reads it.
    private func observeProviderOrder(key: ProviderOrderKey?, sortOption: LibrarySortOption) {
        guard key != providerOrderKey else { return }
        providerOrderWatcher?.cancel()
        providerOrderWatcher = nil
        providerOrderKey = key
        if key != providerOrderRanksKey {
            providerOrderRanks = nil
            providerOrderRanksKey = nil
        }
        providerOrderFailed = false
        guard let key else { return }
        let flow = LibraryRepository.shared.observeProviderOrder(listKey: key.listKey, sortOption: sortOption)
        providerOrderWatcher = FlowWatcherKt.watchFlow(flow) { [weak self] emitted in
            guard let self, self.providerOrderKey == key,
                  let result = emitted as? LibraryProviderOrderResult else { return }
            let ranks: [String: KotlinInt]? = result.ranks
            self.providerOrderRanks = ranks?.mapValues { $0.intValue }
            self.providerOrderRanksKey = key
            self.providerOrderFailed = result.failed
            self.scheduleRepublish()
        }
    }

    /// Writes a published value only when it changed, so a sync or progress tick that changes
    /// nothing on screen doesn't invalidate the whole grid.
    private func update<Value: Equatable>(_ keyPath: ReferenceWritableKeyPath<LibraryViewModel, Value>, _ value: Value) {
        if self[keyPath: keyPath] != value {
            self[keyPath: keyPath] = value
        }
    }

    /// The hold menu's own test (a movie's marker, or a fully watched / title-marked series), cached
    /// per entry until the watched flows emit.
    private func isWatched(_ item: LibraryItem, entryID: String) -> Bool {
        if let cached = watchedByEntryID[entryID] { return cached }
        let isSeries = TitleHoldMenuPolicy.isSeries(type: item.type)
        let marked = WatchedRepository.shared.isWatched(id: item.id, type: item.type, season: nil, episode: nil)
        let fully = isSeries ? WatchedRepository.shared.isFullyWatchedSeries(id: item.id, type: item.type) : false
        let watched = TitleHoldMenuPolicy.effectiveWatched(titleMarked: marked, fullyWatchedSeries: fully, isSeries: isSeries)
        watchedByEntryID[entryID] = watched
        return watched
    }

    private static func entryID(_ item: LibraryItem) -> String {
        let type = item.type.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return "\(type):\(item.id.trimmingCharacters(in: .whitespacesAndNewlines))"
    }

    /// The newest progress entry per title decides its bar: a series whose latest episode is
    /// finished shows none, even if an older episode was left half-way.
    private static func newestProgress(_ state: WatchProgressUiState) -> [String: Double] {
        var newest: [String: WatchProgressEntry] = [:]
        for entry in state.entries {
            if let current = newest[entry.parentMetaId], current.lastUpdatedEpochMs >= entry.lastUpdatedEpochMs {
                continue
            }
            newest[entry.parentMetaId] = entry
        }
        return newest.compactMapValues { entry in
            LibraryGridPolicy.visibleProgress(
                fraction: Double(entry.progressFraction),
                isCompleted: entry.isEffectivelyCompleted
            )
        }
    }

    deinit {
        watchers.forEach { $0.cancel() }
        providerOrderWatcher?.cancel()
    }
}

/// W5: DEBUG-only launch arguments for the Library bar mockups, its UI leg and the VM tests.
/// Release builds always read `.off` / false.
nonisolated enum LibraryDebugFlags {
    enum Fixture: String, Sendable { case off, local, provider }

    /// `-debug.libraryFixture local|provider`.
    static var fixture: Fixture {
        #if DEBUG
        Fixture(rawValue: UserDefaults.standard.string(forKey: "debug.libraryFixture") ?? "") ?? .off
        #else
        .off
        #endif
    }

    /// `-debug.libraryCountLine "<text>"`: the header's count line replaced by `<text>` (the UI
    /// leg's long-string check of the header with Refresh). Nil = the real count line.
    static var countLineOverride: String? {
        #if DEBUG
        UserDefaults.standard.string(forKey: "debug.libraryCountLine").flatMap { $0.isEmpty ? nil : $0 }
        #else
        nil
        #endif
    }

    /// `-debug.libraryBarGeometry YES`: the `debug_library_bar` probe.
    static var geometryProbe: Bool {
        #if DEBUG
        UserDefaults.standard.bool(forKey: "debug.libraryBarGeometry")
        #else
        false
        #endif
    }

    /// `LibraryFilterFixture` ids: `fx-w-` watched, `fx-p-` 40 % in.
    static func fixtureWatchState(id: String) -> LibraryGridPolicy.WatchState {
        LibraryGridPolicy.WatchState(
            isWatched: id.hasPrefix("fx-w-"),
            progress: id.hasPrefix("fx-p-") ? 0.4 : nil
        )
    }
}

/// W5: the one writer of the Library's remembered list and type picks (per profile and source).
/// Called only from the viewer's own list and type picks; no derive writes (review r3).
struct LibraryPickStore {
    let writeSection: (_ sectionKey: String, _ source: LibrarySourceMode) -> Void
    let writeType: (_ type: String?, _ source: LibrarySourceMode) -> Void

    /// The shared display settings (profile-scoped, tagged with the source).
    static let sharedSettings = LibraryPickStore(
        writeSection: { LibraryDisplaySettingsRepository.shared.setSelectedSection(sectionKey: $0, sourceMode: $1) },
        writeType: { LibraryDisplaySettingsRepository.shared.setSelectedType(type: $0, sourceMode: $1) }
    )

    /// Fixture mode: the view model's own mirror is the whole memory; nothing is written.
    static let discard = LibraryPickStore(writeSection: { _, _ in }, writeType: { _, _ in })
}
