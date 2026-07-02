import Combine
import SharedCore

/// Backs the full-grid "See All" screen. Observes the shared `CatalogRepository` (a paginated,
/// reactive catalog loader already in `SharedCore`): loads the target's first page on `start`,
/// paginates via `loadMore()` as the grid nears its end, and clears on `stop`.
///
/// `CatalogRepository` is a singleton and holds one active request at a time; only one grid is on
/// screen at once (pushed onto the Home/Search `NavigationStack`), so a single instance is fine.
@MainActor
final class CatalogGridViewModel: ObservableObject {
    @Published private(set) var items: [MetaPreview] = []
    @Published private(set) var isLoading = false
    @Published private(set) var canLoadMore = false
    @Published private(set) var errorMessage: String?

    private var watcher: FlowWatcher?
    private let target: any CatalogTarget

    init(target: any CatalogTarget) {
        self.target = target
    }

    func start() {
        guard watcher == nil else { return }
        watcher = FlowWatcherKt.watch(CatalogRepository.shared.uiState) { [weak self] emitted in
            guard let self, let state = emitted as? CatalogUiState else { return }
            self.items = state.items
            self.isLoading = state.isLoading
            self.canLoadMore = state.canLoadMore
            // Nullable Kotlin String may bridge as non-optional in this framework — normalize empty to nil.
            let message: String? = state.errorMessage
            self.errorMessage = (message?.isEmpty == false) ? message : nil
        }
        CatalogRepository.shared.load(target: target, force: false)
    }

    /// Infinite-scroll trigger: called from each grid cell's `onAppear`. Fires `loadMore()` once the
    /// user nears the end of the loaded items, and no-ops if already loading or fully paged.
    func itemAppeared(at index: Int) {
        guard canLoadMore, !isLoading else { return }
        if index >= items.count - 8 {
            CatalogRepository.shared.loadMore()
        }
    }

    func stop() {
        watcher?.cancel()
        watcher = nil
        CatalogRepository.shared.clear()
    }

    deinit { watcher?.cancel() }
}
