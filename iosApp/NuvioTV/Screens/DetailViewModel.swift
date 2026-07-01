import Combine
import Foundation
import SharedCore

/// Loads and observes the full metadata for a single title via the shared `MetaDetailsRepository`.
///
/// `MetaDetailsRepository.load(type:id:)` kicks off the fetch (cache-first, then addon/TMDB enrich);
/// `uiState` (a `StateFlow<MetaDetailsUiState>`) emits `{isLoading, meta, errorMessage}` as it resolves.
@MainActor
final class DetailViewModel: ObservableObject {
    @Published private(set) var meta: MetaDetails?
    @Published private(set) var isLoading: Bool = false
    @Published private(set) var errorMessage: String?

    private var watcher: FlowWatcher?
    private let type: String
    private let id: String

    init(type: String, id: String) {
        self.type = type
        self.id = id
    }

    func start() {
        guard watcher == nil else { return }
        watcher = FlowWatcherKt.watch(MetaDetailsRepository.shared.uiState) { [weak self] emitted in
            guard let self, let state = emitted as? MetaDetailsUiState else { return }
            // The shared repo holds one in-flight detail at a time — only adopt emissions for ours.
            if let m = state.meta, m.type != self.type || m.id != self.id { return }
            self.isLoading = state.isLoading
            self.meta = state.meta
            self.errorMessage = state.errorMessage
        }
        MetaDetailsRepository.shared.load(type: type, id: id)
    }

    func stop() {
        watcher?.cancel()
        watcher = nil
        MetaDetailsRepository.shared.clear()
    }

    deinit {
        watcher?.cancel()
    }
}
