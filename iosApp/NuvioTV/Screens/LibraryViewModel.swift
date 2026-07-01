import Combine
import SharedCore

/// Observes the shared `LibraryRepository` — the personal saved library that the detail screen's
/// "Add to Library" action writes to. Profile-scoped (reloads on profile switch via the Phase 4
/// lifecycle coordinator).
@MainActor
final class LibraryViewModel: ObservableObject {
    @Published private(set) var items: [LibraryItem] = []

    private var watcher: FlowWatcher?

    func start() {
        guard watcher == nil else { return }
        LibraryRepository.shared.ensureLoaded()
        watcher = FlowWatcherKt.watch(LibraryRepository.shared.uiState) { [weak self] emitted in
            guard let self, let state = emitted as? LibraryUiState else { return }
            self.items = state.items
        }
    }

    func stop() {
        watcher?.cancel()
        watcher = nil
    }

    /// Remove a title from the library. `toggleSaved` flips an already-saved item back off.
    func remove(_ item: LibraryItem) {
        LibraryRepository.shared.toggleSaved(item: item)
    }

    deinit { watcher?.cancel() }
}
