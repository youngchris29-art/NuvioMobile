import Combine
import SharedCore

/// One card in the Library grid.
struct LibraryGridEntry: Identifiable {
    /// `type:id`, normalized like the shared projection's de-duplication key, so ids are unique.
    let id: String
    let item: LibraryItem
    let state: LibraryGridPolicy.WatchState
    /// The projection's type key (`mediaCategory ?? type`), for the count line.
    let kind: String
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
    /// Type keys present in the chosen list (`movie`, `series`, `anime`, …), sorted.
    @Published private(set) var types: [String] = []
    /// Nil = All.
    @Published private(set) var selectedType: String?
    @Published private(set) var visibleSmartFilters: [LibraryGridPolicy.SmartFilter] = []
    @Published private(set) var activeSmartFilters: Set<LibraryGridPolicy.SmartFilter> = []
    @Published private(set) var sortOption: LibrarySortOption = .addedDesc
    /// What the grid is actually sorted by: the local library has no provider order, so a stored
    /// DEFAULT sorts (and is labelled) as Recently Added there, as on mobile.
    @Published private(set) var effectiveSortOption: LibrarySortOption = .addedDesc
    /// Sort options valid for the active source (DEFAULT = the provider's order, remote only).
    @Published private(set) var availableSortOptions: [LibrarySortOption] = []

    var providerName: String? { LibraryGridPolicy.providerName(sourceModeName: sourceModeName) }

    /// The chosen list's title ("Watchlist", "Plan to Watch", …), for the pill and the hold menu.
    var selectedSectionTitle: String? {
        guard let key = selectedSectionKey else { return nil }
        return sections.first { $0.type == key }?.displayTitle
    }

    private var libraryState: LibraryUiState?
    /// Newest drawable progress per content id (`WatchProgressEntry.parentMetaId`).
    private var progressByContentId: [String: Double] = [:]
    /// What the viewer picked. The projection falls back (first list, All) when a pick no longer
    /// exists, and the published `selected…` values show what it actually used.
    private var requestedSectionKey: String?
    private var requestedType: String?
    private var lastSourceModeName: String?
    private var watchers: [FlowWatcher] = []
    private var republishScheduled = false

    func start() {
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
            self.sortOption = state.sortOption
            self.scheduleRepublish()
        })
        // Watched marks are re-read per title in `republish` through the repository's own
        // `isWatched` / `isFullyWatchedSeries` (the hold menu's test), so these two only trigger.
        watchers.append(FlowWatcherKt.watch(WatchedRepository.shared.uiState) { [weak self] _ in
            self?.scheduleRepublish()
        })
        watchers.append(FlowWatcherKt.watch(WatchedRepository.shared.fullyWatchedSeriesKeys) { [weak self] _ in
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
    }

    // MARK: - Viewer actions

    func selectSection(_ key: String) {
        requestedSectionKey = key
        republish()
    }

    /// Nil = All.
    func selectType(_ type: String?) {
        requestedType = type
        republish()
    }

    func toggleSmartFilter(_ filter: LibraryGridPolicy.SmartFilter) {
        activeSmartFilters = LibraryGridPolicy.toggling(filter, in: activeSmartFilters)
        republish()
    }

    func clearSmartFilters() {
        activeSmartFilters = []
        republish()
    }

    /// Persist a new sort (shared repo: profile-scoped NSUserDefaults). The watcher republishes.
    func setSort(_ option: LibrarySortOption) {
        LibraryDisplaySettingsRepository.shared.setSortOption(sortOption: option)
    }

    func sortLabel(_ option: LibrarySortOption) -> String {
        LibraryGridPolicy.sortLabel(optionName: option.name, sourceModeName: sourceModeName)
    }

    /// Retry after a failed load (the same pull mobile's Retry runs). Failure-contained in Kotlin.
    func retry() {
        LibraryRepository.shared.retryLoadAsync()
    }

    /// The hold menu's remove. With a provider list open it removes the title from THAT list.
    /// `toggleSaved` would flip the provider's default list instead (the watchlist), which on any
    /// other list would add the title to the watchlist rather than remove it. The local library has
    /// no lists, so it keeps `toggleSaved`, which removes a saved title.
    func remove(_ entry: LibraryGridEntry) {
        if let key = selectedSectionKey {
            LibraryRepository.shared.removeFromListAsync(item: entry.item, listKey: key)
        } else {
            LibraryRepository.shared.toggleSaved(item: entry.item)
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
            content = .loading
            return
        }
        let modeName = state.sourceMode.name
        if lastSourceModeName != modeName {
            // A different library (Settings → Library Source changed): its lists and types are
            // different, so forget the old picks.
            if lastSourceModeName != nil {
                requestedSectionKey = nil
                requestedType = nil
                activeSmartFilters = []
            }
            lastSourceModeName = modeName
        }
        sourceModeName = modeName
        availableSortOptions = LibraryDisplaySettingsKt.availableLibrarySortOptions(sourceMode: state.sourceMode)
        effectiveSortOption = LibraryDisplaySettingsKt.effectiveLibrarySortOption(
            selected: sortOption,
            sourceMode: state.sourceMode
        )

        // providerOrders stays empty, as on mobile's grid: the per-list added-order caches have no
        // public shared accessor. MDBList's DEFAULT order (newest added, then the chosen list's
        // rank) comes from `listKey`, which the projection sets to the chosen list.
        let projection = LibraryDisplaySettingsKt.buildLibraryVerticalProjection(
            sections: state.sections,
            sourceMode: state.sourceMode,
            selectedSectionKey: requestedSectionKey,
            selectedType: requestedType,
            sortOption: sortOption,
            providerOrders: [:]
        )
        sections = projection.availableSections
        selectedSectionKey = projection.selectedSectionKey
        types = projection.availableTypes
        selectedType = projection.selectedType

        let all = projection.entries.map { entry -> LibraryGridEntry in
            let item = entry.item
            return LibraryGridEntry(
                id: Self.entryID(item),
                item: item,
                state: watchState(item),
                kind: item.mediaCategory ?? item.type
            )
        }
        visibleSmartFilters = LibraryGridPolicy.visibleSmartFilters(
            states: all.map(\.state),
            active: activeSmartFilters
        )
        let shown = activeSmartFilters.isEmpty
            ? all
            : all.filter { LibraryGridPolicy.passes($0.state, filters: activeSmartFilters) }
        entries = shown
        countLine = LibraryGridPolicy.countLine(kinds: shown.map(\.kind))
        content = LibraryGridPolicy.content(
            isLoaded: state.isLoaded,
            isLoading: state.isLoading,
            errorMessage: state.errorMessage,
            hasAnySection: !state.sections.isEmpty,
            visibleCount: shown.count,
            smartFiltersActive: !activeSmartFilters.isEmpty
        )
    }

    private func watchState(_ item: LibraryItem) -> LibraryGridPolicy.WatchState {
        let isSeries = TitleHoldMenuPolicy.isSeries(type: item.type)
        let marked = WatchedRepository.shared.isWatched(id: item.id, type: item.type, season: nil, episode: nil)
        let fully = isSeries ? WatchedRepository.shared.isFullyWatchedSeries(id: item.id, type: item.type) : false
        return LibraryGridPolicy.WatchState(
            isWatched: TitleHoldMenuPolicy.effectiveWatched(titleMarked: marked, fullyWatchedSeries: fully, isSeries: isSeries),
            progress: progressByContentId[item.id]
        )
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
    }
}
