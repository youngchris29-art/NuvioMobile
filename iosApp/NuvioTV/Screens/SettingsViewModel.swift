import Combine
import SharedCore

/// Backs the Settings screen. All settings persist locally (profile-scoped) via the shared
/// repositories — no config/sign-in needed.
///
/// - Playback: `PlayerSettingsRepository.skipIntroEnabled` (gates the in-player Skip pill).
/// - Home Rows: `HomeCatalogSettingsRepository` (enable/disable + reorder). `HomeRepository` already
///   reads these preferences, so changes take effect on Home after a refresh (which we trigger).
@MainActor
final class SettingsViewModel: ObservableObject {
    @Published private(set) var skipIntroEnabled = true
    @Published private(set) var catalogs: [HomeCatalogSettingsItem] = []

    private var playerWatcher: FlowWatcher?
    private var catalogWatcher: FlowWatcher?
    private var addonWatcher: FlowWatcher?
    private var enabledAddons: [ManagedAddon] = []

    func start() {
        guard playerWatcher == nil else { return }

        PlayerSettingsRepository.shared.ensureLoaded()
        playerWatcher = FlowWatcherKt.watch(PlayerSettingsRepository.shared.uiState) { [weak self] emitted in
            guard let self, let state = emitted as? PlayerSettingsUiState else { return }
            self.skipIntroEnabled = state.skipIntroEnabled
        }

        // The catalog list is derived from the installed add-ons; sync it whenever they change so
        // the Home Rows list stays current (tvOS has to call this itself).
        addonWatcher = FlowWatcherKt.watch(AddonRepository.shared.uiState) { [weak self] emitted in
            guard let self, let state = emitted as? AddonsUiState else { return }
            let enabled = AddonModelsKt.enabledAddons(state.addons)
            self.enabledAddons = enabled
            HomeCatalogSettingsRepository.shared.syncCatalogs(addons: enabled)
        }
        catalogWatcher = FlowWatcherKt.watch(HomeCatalogSettingsRepository.shared.uiState) { [weak self] emitted in
            guard let self, let state = emitted as? HomeCatalogSettingsUiState else { return }
            self.catalogs = state.items
        }
    }

    func stop() {
        playerWatcher?.cancel(); playerWatcher = nil
        catalogWatcher?.cancel(); catalogWatcher = nil
        addonWatcher?.cancel(); addonWatcher = nil
    }

    // MARK: - Actions

    func setSkipIntro(_ enabled: Bool) {
        PlayerSettingsRepository.shared.setSkipIntroEnabled(enabled: enabled)
    }

    func toggleCatalog(_ item: HomeCatalogSettingsItem) {
        HomeCatalogSettingsRepository.shared.setEnabled(key: item.key, enabled: !item.enabled)
        refreshHome()
    }

    func moveUp(_ item: HomeCatalogSettingsItem) {
        HomeCatalogSettingsRepository.shared.moveUp(key: item.key)
        refreshHome()
    }

    func moveDown(_ item: HomeCatalogSettingsItem) {
        HomeCatalogSettingsRepository.shared.moveDown(key: item.key)
        refreshHome()
    }

    /// Re-apply the new catalog preferences to Home so the change is visible when the user returns.
    private func refreshHome() {
        HomeRepository.shared.refresh(addons: enabledAddons, force: true)
    }

    deinit {
        playerWatcher?.cancel()
        catalogWatcher?.cancel()
        addonWatcher?.cancel()
    }
}
