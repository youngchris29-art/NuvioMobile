import Combine
import Foundation
import SharedCore

/// Orchestrates the Home/Catalog screen end-to-end on top of SharedCore.
///
/// Pipeline (all shared Kotlin):
///   1. `AddonRepository.initialize()` loads any persisted addons (NSUserDefaults-backed on tvOS).
///   2. If none are installed yet, seed the default Cinemeta catalog addon so the screen has content.
///   3. Whenever the installed-addon set changes, push the enabled addons (those with a loaded
///      manifest) into `HomeRepository.refresh(...)`.
///   4. `HomeRepository.uiState` emits the assembled catalog sections, which we republish for SwiftUI.
///
/// Both flows are observed through the hand-written `FlowWatcher` bridge (no SKIE / kmp-nativecoroutines).
@MainActor
final class HomeViewModel: ObservableObject {
    @Published private(set) var heroItems: [MetaPreview] = []
    @Published private(set) var sections: [HomeCatalogSection] = []
    @Published private(set) var continueWatching: [WatchProgressEntry] = []
    @Published private(set) var isLoading: Bool = false
    @Published private(set) var errorMessage: String?

    /// Stremio's default community catalog addon — gives the tvOS build real content out of the box.
    private let cinemetaManifestUrl = "https://v3-cinemeta.strem.io/manifest.json"

    private var addonWatcher: FlowWatcher?
    private var homeWatcher: FlowWatcher?
    private var progressWatcher: FlowWatcher?
    private var didSeed = false
    /// Guards against redundant `refresh` calls — only re-refresh when the ready-addon set changes.
    private var lastRefreshSignature = ""
    private var started = false

    func start() {
        guard !started else { return }
        started = true

        // Home output → SwiftUI.
        homeWatcher = FlowWatcherKt.watch(HomeRepository.shared.uiState) { [weak self] emitted in
            guard let self, let state = emitted as? HomeUiState else { return }
            self.isLoading = state.isLoading
            self.heroItems = state.heroItems
            self.sections = state.sections
            self.errorMessage = state.errorMessage
        }

        // Installed addons → drive Home refresh.
        addonWatcher = FlowWatcherKt.watch(AddonRepository.shared.uiState) { [weak self] emitted in
            guard let self, let state = emitted as? AddonsUiState else { return }
            self.onAddonsChanged(state)
        }

        // Watch progress → Continue Watching row.
        progressWatcher = FlowWatcherKt.watch(WatchProgressRepository.shared.uiState) { [weak self] _ in
            guard let self else { return }
            self.continueWatching = WatchProgressRepository.shared.continueWatching()
        }

        AddonRepository.shared.initialize()
        WatchProgressRepository.shared.ensureLoaded()
    }

    func stop() {
        addonWatcher?.cancel()
        homeWatcher?.cancel()
        progressWatcher?.cancel()
        addonWatcher = nil
        homeWatcher = nil
        progressWatcher = nil
        started = false
    }

    private func onAddonsChanged(_ state: AddonsUiState) {
        // First run with an empty store → seed Cinemeta, then wait for the next emission.
        if state.addons.isEmpty {
            if !didSeed {
                didSeed = true
                AddonRepository.shared.addAddon(rawUrl: cinemetaManifestUrl) { _, _ in }
            }
            return
        }

        // Only addons whose manifest has actually loaded can contribute catalogs.
        let ready = AddonModelsKt.enabledAddons(state.addons).filter { $0.manifest != nil }
        guard !ready.isEmpty else { return }

        let signature = ready.map { $0.manifestUrl }.joined(separator: "|")
        guard signature != lastRefreshSignature else { return }
        lastRefreshSignature = signature

        HomeRepository.shared.refresh(addons: ready, force: true)
    }

    deinit {
        addonWatcher?.cancel()
        homeWatcher?.cancel()
    }
}
