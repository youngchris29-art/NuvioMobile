import Combine
import Foundation
import SharedCore

/// Drives the Search screen. Observes the installed addons (to pass into `SearchRepository.search`
/// and `refreshDiscover`), the shared `SearchRepository.uiState` (results, as `[HomeCatalogSection]`),
/// the Discover state (`discoverUiState` — genre/catalog browsing shown while the query is empty),
/// and the per-profile search history (`SearchHistoryRepository`).
///
/// Queries are debounced so we don't fire a request on every keystroke.
@MainActor
final class SearchViewModel: ObservableObject {
    /// FEAT-10: which search-capable catalogs the user has switched OFF in Settings →
    /// Content Sources → Search Sources. Stored as their stable `manifestId:type:catalogId`
    /// keys. Local to this Apple TV (not synced), like the appearance toggles — keys for
    /// since-uninstalled addons linger harmlessly (they never match) and re-arm if the
    /// addon comes back.
    enum SearchSourceSettings {
        private static let defaultsKey = "search_disabled_catalog_keys"

        static var disabledKeys: Set<String> {
            Set(UserDefaults.standard.stringArray(forKey: defaultsKey) ?? [])
        }

        static func setDisabled(_ disabled: Bool, forKey key: String) {
            var keys = disabledKeys
            if disabled { keys.insert(key) } else { keys.remove(key) }
            UserDefaults.standard.set(Array(keys).sorted(), forKey: defaultsKey)
        }

        /// Persists an entire resolved disabled-keys set in one write. Callers that compute a
        /// whole new set (e.g. the collision-group resolver in `SettingsViewModel.setSearchSource`)
        /// should use this instead of a remove/add diff loop: a single `UserDefaults.set` call is
        /// atomic for this purpose, so app termination mid-update can't land on a torn state where
        /// some sibling keys were persisted and others weren't.
        static func setAll(_ keys: Set<String>) {
            UserDefaults.standard.set(Array(keys).sorted(), forKey: defaultsKey)
        }
    }
    @Published private(set) var sections: [HomeCatalogSection] = []
    @Published private(set) var isLoading: Bool = false
    @Published private(set) var emptyMessage: String?
    /// BUG-33 defect 1 instrumentation: passthrough of `SearchUiState.lastFanOut` — a
    /// human-readable "searched N of M catalogs" line set by the shared repo right after the
    /// last `search()` call. Settings → Content Sources → Search Sources renders the same value
    /// via its own watcher on `SearchRepository.shared.uiState` (this tab and the Settings tab
    /// hold independent view-model instances, so each watches the shared state directly rather
    /// than one passing a value to the other).
    @Published private(set) var lastFanOut: String?
    /// Recent searches for this profile (most recent first).
    @Published private(set) var history: [String] = []
    /// Shared Discover state: type/catalog/genre options + a paginated item grid.
    @Published private(set) var discover: DiscoverUiState?
    /// UX-8: the user hid the whole Discover section (synced home-catalog setting). Seeded from
    /// the repository snapshot so the very first frame is right, then live via the watcher.
    @Published private(set) var hideDiscover = HomeCatalogSettingsRepository.shared.snapshot().hideDiscover
    private var catalogSettingsWatcher: FlowWatcher?

    private var addonWatcher: FlowWatcher?
    private var searchWatcher: FlowWatcher?
    private var discoverWatcher: FlowWatcher?
    private var historyWatcher: FlowWatcher?
    private var enabledAddons: [ManagedAddon] = []
    private var lastDiscoverAddonSignature: String?
    private var debounce: Task<Void, Never>?
    private var started = false

    /// H2 hardening (BUG-47), mirrors `CatalogGridViewModel.stopped`: `FlowWatcher.cancel()`'s
    /// cancellation is cooperative, so a resume already queued on the main run loop can deliver one
    /// more value to a callback AFTER `stop()` returns, driving `@Published` mutations into a view
    /// mid-pop. One flag for all four watchers — they're always started and stopped together.
    private var stopped = false

    func start() {
        guard !started else { return }
        started = true
        stopped = false

        searchWatcher = FlowWatcherKt.watch(SearchRepository.shared.uiState) { [weak self] emitted in
            guard let self, !self.stopped else { return }
            guard let state = emitted as? SearchUiState else { return }
            self.isLoading = state.isLoading
            self.sections = state.sections
            self.emptyMessage = state.sections.isEmpty && !state.isLoading && state.emptyStateReason != nil
                ? String(localized: "No results.")
                : nil
            self.lastFanOut = state.lastFanOut
        }

        discoverWatcher = FlowWatcherKt.watch(SearchRepository.shared.discoverUiState) { [weak self] emitted in
            guard let self, !self.stopped else { return }
            guard let state = emitted as? DiscoverUiState else { return }
            self.discover = state
        }

        historyWatcher = FlowWatcherKt.watch(SearchHistoryRepository.shared.uiState) { [weak self] emitted in
            guard let self, !self.stopped else { return }
            guard let items = emitted as? [String] else { return }
            self.history = items
        }
        SearchHistoryRepository.shared.ensureLoaded()

        // UX-8: follow the synced Hide Discover flag. When it flips back OFF while the screen is
        // up, re-arm so the section rebuilds (refreshDiscoverIfNeeded early-returns on a matching
        // addon signature and would otherwise leave `discover` stale/nil).
        catalogSettingsWatcher = FlowWatcherKt.watch(HomeCatalogSettingsRepository.shared.uiState) { [weak self] emitted in
            guard let self, !self.stopped else { return }
            guard let state = emitted as? HomeCatalogSettingsUiState else { return }
            let wasHidden = self.hideDiscover
            self.hideDiscover = state.hideDiscover
            if wasHidden && !state.hideDiscover {
                self.lastDiscoverAddonSignature = nil
                self.refreshDiscoverIfNeeded()
            }
        }

        addonWatcher = FlowWatcherKt.watch(AddonRepository.shared.uiState) { [weak self] emitted in
            guard let self, !self.stopped else { return }
            guard let state = emitted as? AddonsUiState else { return }
            self.enabledAddons = AddonModelsKt.enabledAddons(state.addons)
            self.refreshDiscoverIfNeeded()
        }

        AddonRepository.shared.initialize()
    }

    func stop() {
        // H2: flip first, before tearing down the watchers — see the `stopped` doc comment.
        stopped = true
        debounce?.cancel()
        addonWatcher?.cancel()
        searchWatcher?.cancel()
        discoverWatcher?.cancel()
        historyWatcher?.cancel()
        catalogSettingsWatcher?.cancel()
        addonWatcher = nil
        searchWatcher = nil
        discoverWatcher = nil
        historyWatcher = nil
        catalogSettingsWatcher = nil
        started = false
        // Re-arm Discover for the next start(): refreshDiscoverIfNeeded() early-returns when
        // the signature already matches, so without this the section would never rebuild.
        // canReuseDiscoverState in the repository still avoids redundant network work.
        lastDiscoverAddonSignature = nil
    }

    /// Called as the search text changes; debounces, then queries (or resets on empty).
    func queryChanged(_ text: String) {
        debounce?.cancel()
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)

        guard !trimmed.isEmpty else {
            // `.reset()` is the nuclear account/profile-teardown variant — it also wipes
            // discoverSources, which permanently kills the Discover section here since
            // nothing ever re-arms it. Use `.clear()`, which only resets search state. (BUG-33(2))
            SearchRepository.shared.clear()
            sections = []
            emptyMessage = nil
            return
        }

        debounce = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 350_000_000)
            guard !Task.isCancelled, let self else { return }
            SearchRepository.shared.search(
                query: trimmed,
                addons: self.enabledAddons,
                // FEAT-10: sources switched off in Settings → Content Sources → Search
                // Sources. Read fresh per query so a settings change applies immediately.
                disabledCatalogKeys: Self.SearchSourceSettings.disabledKeys,
                forceRefresh: false
            )
        }
    }

    // MARK: - Search history

    /// Record a committed query (keyboard submit), so partial typing doesn't pollute history.
    func recordSearch(_ query: String) {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        SearchHistoryRepository.shared.recordSearch(query: trimmed)
    }

    func removeHistory(_ query: String) {
        SearchHistoryRepository.shared.removeSearch(query: query)
    }

    // MARK: - Discover

    /// (Re)build the Discover catalog options when the enabled-addon set changes.
    private func refreshDiscoverIfNeeded() {
        // UX-8: nothing to build while the section is hidden — skips the addon fan-out too. The
        // catalog-settings watcher re-arms `lastDiscoverAddonSignature` when the flag clears.
        guard !hideDiscover else { return }
        let signature = enabledAddons.map { $0.manifestUrl }.sorted().joined(separator: "|")
        guard signature != lastDiscoverAddonSignature else { return }
        lastDiscoverAddonSignature = signature
        SearchRepository.shared.refreshDiscover(addons: enabledAddons, forceRefresh: false)
    }

    func selectDiscoverType(_ type: String) {
        SearchRepository.shared.selectDiscoverType(type: type)
    }

    func selectDiscoverCatalog(_ key: String) {
        SearchRepository.shared.selectDiscoverCatalog(catalogKey: key)
    }

    func selectDiscoverGenre(_ genre: String?) {
        SearchRepository.shared.selectDiscoverGenre(genre: genre)
    }

    /// Load-more sentinel: fire pagination as the grid approaches its end.
    func discoverItemAppeared(at index: Int) {
        guard let discover, discover.canLoadMore, !discover.isLoading else { return }
        if index >= discover.items.count - 8 {
            SearchRepository.shared.loadMoreDiscover()
        }
    }

    deinit {
        debounce?.cancel()
        addonWatcher?.cancel()
        searchWatcher?.cancel()
        discoverWatcher?.cancel()
        historyWatcher?.cancel()
        catalogSettingsWatcher?.cancel()
    }
}
