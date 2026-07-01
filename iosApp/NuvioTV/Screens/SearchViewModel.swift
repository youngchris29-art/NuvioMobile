import Combine
import Foundation
import SharedCore

/// Drives the Search screen. Observes the installed addons (to pass into `SearchRepository.search`)
/// and the shared `SearchRepository.uiState` (results, as `[HomeCatalogSection]`).
///
/// Queries are debounced so we don't fire a request on every keystroke.
@MainActor
final class SearchViewModel: ObservableObject {
    @Published private(set) var sections: [HomeCatalogSection] = []
    @Published private(set) var isLoading: Bool = false
    @Published private(set) var emptyMessage: String?

    private var addonWatcher: FlowWatcher?
    private var searchWatcher: FlowWatcher?
    private var enabledAddons: [ManagedAddon] = []
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
                ? "No results."
                : nil
        }

        addonWatcher = FlowWatcherKt.watch(AddonRepository.shared.uiState) { [weak self] emitted in
            guard let self, let state = emitted as? AddonsUiState else { return }
            self.enabledAddons = AddonModelsKt.enabledAddons(state.addons)
        }

        AddonRepository.shared.initialize()
    }

    func stop() {
        debounce?.cancel()
        addonWatcher?.cancel()
        searchWatcher?.cancel()
        addonWatcher = nil
        searchWatcher = nil
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

    deinit {
        debounce?.cancel()
        addonWatcher?.cancel()
        searchWatcher?.cancel()
    }
}
