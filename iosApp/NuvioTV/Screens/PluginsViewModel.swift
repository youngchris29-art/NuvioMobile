import Combine
import Foundation
import SharedCore

/// Drives the Settings "Plugins" section. Backed by the tvOS `PluginRepository` (tvosMain port
/// of mobile's JS plugin stack — QuickJS runtime). Plugin repositories arrive via cloud sync
/// from the mobile app (SyncManager → PluginSyncProvider); v1 is sync-only, so this exposes the
/// master switch and per-scraper toggles but no on-TV repo URL entry.
@MainActor
final class PluginsViewModel: ObservableObject {
    @Published private(set) var pluginsEnabled = true
    /// Streams list: one group per plugin repository instead of one per provider (shared setting,
    /// same as mobile's "Group plugin providers by repository").
    @Published private(set) var groupStreamsByRepository = false
    @Published private(set) var repositories: [PluginRepositoryItem] = []
    @Published private(set) var scrapers: [PluginScraper] = []

    private var watcher: FlowWatcher?

    func start() {
        guard watcher == nil else { return }
        watcher = FlowWatcherKt.watch(PluginRepository.shared.uiState) { [weak self] emitted in
            guard let self, let state = emitted as? PluginsUiState else { return }
            self.pluginsEnabled = state.pluginsEnabled
            self.groupStreamsByRepository = state.groupStreamsByRepository
            self.repositories = state.repositories
            self.scrapers = state.scrapers
        }
        PluginRepository.shared.initialize()
    }

    func stop() {
        watcher?.cancel()
        watcher = nil
    }

    func setPluginsEnabled(_ enabled: Bool) {
        PluginRepository.shared.setPluginsEnabled(enabled: enabled)
    }

    func setGroupStreamsByRepository(_ enabled: Bool) {
        PluginRepository.shared.setGroupStreamsByRepository(enabled: enabled)
    }

    /// Every provider of `repo` on or off at once (Settings › Plugins "All Providers").
    func setRepositoryEnabled(_ repo: PluginRepositoryItem, _ enabled: Bool) {
        PluginRepository.shared.setRepositoryScrapersEnabled(manifestUrl: repo.manifestUrl, enabled: enabled)
    }

    /// The "All Providers" switch reads on while any provider of the repository can run, so
    /// turning it off is always one press and turning it back on restores every provider.
    static func isRepositoryOn(_ scrapers: [PluginScraper]) -> Bool {
        scrapers.contains { $0.enabled }
    }

    func toggleScraper(_ scraper: PluginScraper, _ enabled: Bool) {
        PluginRepository.shared.toggleScraper(scraperId: scraper.id, enabled: enabled)
    }

    func refreshAll() {
        PluginRepository.shared.refreshAll()
    }

    @Published private(set) var isInstalling = false
    @Published private(set) var statusMessage: String?

    /// Installs a repository by manifest URL (the shared repo normalizes and appends
    /// /manifest.json). Also pushes to the account so other devices pick it up.
    func addRepository(_ rawUrl: String) {
        let url = rawUrl.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !url.isEmpty else { return }
        isInstalling = true
        statusMessage = nil
        PluginRepository.shared.addRepository(rawUrl: url) { [weak self] result, error in
            Task { @MainActor in
                guard let self else { return }
                self.isInstalling = false
                if let error {
                    self.statusMessage = String(localized: "Couldn't install: \(error.localizedDescription)")
                } else if let failure = result as? AddPluginRepositoryResultError {
                    self.statusMessage = String(localized: "Couldn't install: \(failure.message)")
                } else if let success = result as? AddPluginRepositoryResultSuccess {
                    self.statusMessage = String(localized: "Installed \(success.repository.name).")
                } else {
                    self.statusMessage = String(localized: "Couldn't install that URL.")
                }
            }
        }
    }

    func removeRepository(_ repo: PluginRepositoryItem) {
        PluginRepository.shared.removeRepository(manifestUrl: repo.manifestUrl)
        statusMessage = nil
    }

    /// Scrapers grouped under their repository, preserving repo order.
    func scrapers(in repo: PluginRepositoryItem) -> [PluginScraper] {
        scrapers.filter { $0.repositoryUrl == repo.manifestUrl }
    }

    /// Display order for providers: Finder-style (case-insensitive, natural numbers, so
    /// "Provider 2" lists before "Provider 10"); equal names keep their incoming order.
    nonisolated static func sortedScrapers(_ scrapers: [PluginScraper]) -> [PluginScraper] {
        sortedByName(scrapers, name: \.name)
    }

    /// Generic seam behind `sortedScrapers` so the ordering rule is testable without
    /// constructing Kotlin `PluginScraper` objects.
    nonisolated static func sortedByName<T>(_ items: [T], name: KeyPath<T, String>) -> [T] {
        items.enumerated().sorted { a, b in
            switch a.element[keyPath: name].localizedStandardCompare(b.element[keyPath: name]) {
            case .orderedAscending: return true
            case .orderedDescending: return false
            case .orderedSame: return a.offset < b.offset
            }
        }.map(\.element)
    }

    /// Whether a repository's provider list is open: the viewer's own choice when they made one,
    /// otherwise open only for a lone repository. Storing the choice (not a flip against the
    /// default) keeps it stable when the repository count crosses 1.
    nonisolated static func isRepositoryExpanded(stored: Bool?, repositoryCount: Int) -> Bool {
        stored ?? (repositoryCount == 1)
    }

    deinit {
        watcher?.cancel()
    }
}
