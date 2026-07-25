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
    @Published private(set) var sections: [HomeCatalogSection] = []
    @Published private(set) var isLoading: Bool = false
    @Published private(set) var emptyMessage: String?
    /// Recent searches for this profile (most recent first).
    @Published private(set) var history: [String] = []
    /// Shared Discover state: type/catalog/genre options + a paginated item grid.
    @Published private(set) var discover: DiscoverUiState?

    private var addonWatcher: FlowWatcher?
    private var searchWatcher: FlowWatcher?
    private var discoverWatcher: FlowWatcher?
    private var historyWatcher: FlowWatcher?
    private var enabledAddons: [ManagedAddon] = []
    private var lastDiscoverAddonSignature: String?
    private var debounce: Task<Void, Never>?
    private var started = false

    func start() {
        guard !started else { return }
        started = true

        searchWatcher = FlowWatcherKt.watch(SearchRepository.shared.uiState) { [weak self] emitted in
            guard let self, let state = emitted as? SearchUiState else { return }
            self.isLoading = state.isLoading
            self.sections = state.sections
            self.emptyMessage = state.sections.isEmpty && !state.isLoading && state.emptyStateReason != nil
                ? String(localized: "No results.")
                : nil
        }

        discoverWatcher = FlowWatcherKt.watch(SearchRepository.shared.discoverUiState) { [weak self] emitted in
            guard let self, let state = emitted as? DiscoverUiState else { return }
            self.discover = state
        }

        historyWatcher = FlowWatcherKt.watch(SearchHistoryRepository.shared.uiState) { [weak self] emitted in
            guard let self, let items = emitted as? [String] else { return }
            self.history = items
        }
        SearchHistoryRepository.shared.ensureLoaded()

        addonWatcher = FlowWatcherKt.watch(AddonRepository.shared.uiState) { [weak self] emitted in
            guard let self, let state = emitted as? AddonsUiState else { return }
            self.enabledAddons = AddonModelsKt.enabledAddons(state.addons)
            self.refreshDiscoverIfNeeded()
        }

        AddonRepository.shared.initialize()
    }

    func stop() {
        debounce?.cancel()
        addonWatcher?.cancel()
        searchWatcher?.cancel()
        discoverWatcher?.cancel()
        historyWatcher?.cancel()
        addonWatcher = nil
        searchWatcher = nil
        discoverWatcher = nil
        historyWatcher = nil
        started = false
    }

    /// Called as the search text changes; debounces, then queries (or resets on empty).
    func queryChanged(_ text: String) {
        debounce?.cancel()
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)

        guard !trimmed.isEmpty else {
            SearchRepository.shared.reset()
            sections = []
            emptyMessage = nil
            return
        }

        debounce = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 350_000_000)
            guard !Task.isCancelled, let self else { return }
            SearchRepository.shared.search(query: trimmed, addons: self.enabledAddons)
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
        let signature = enabledAddons.map { $0.manifestUrl }.sorted().joined(separator: "|")
        guard signature != lastDiscoverAddonSignature else { return }
        lastDiscoverAddonSignature = signature
        SearchRepository.shared.refreshDiscover(addons: enabledAddons)
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
    }
}
