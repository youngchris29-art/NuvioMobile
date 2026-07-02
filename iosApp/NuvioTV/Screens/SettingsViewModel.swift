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
    /// TMDB enrichment (cast profiles, studios/networks, collections, artwork). Gated on a user key.
    @Published private(set) var tmdbEnabled = false
    @Published private(set) var tmdbHasKey = false
    /// Subtitle appearance (applied by the player on file load). Nil until settings load.
    @Published private(set) var subtitleStyle: SubtitleStyleState?

    private var playerWatcher: FlowWatcher?
    private var catalogWatcher: FlowWatcher?
    private var addonWatcher: FlowWatcher?
    private var tmdbWatcher: FlowWatcher?
    private var enabledAddons: [ManagedAddon] = []

    func start() {
        guard playerWatcher == nil else { return }

        PlayerSettingsRepository.shared.ensureLoaded()
        playerWatcher = FlowWatcherKt.watch(PlayerSettingsRepository.shared.uiState) { [weak self] emitted in
            guard let self, let state = emitted as? PlayerSettingsUiState else { return }
            self.skipIntroEnabled = state.skipIntroEnabled
            self.subtitleStyle = state.subtitleStyle
        }

        TmdbSettingsRepository.shared.ensureLoaded()
        tmdbWatcher = FlowWatcherKt.watch(TmdbSettingsRepository.shared.uiState) { [weak self] emitted in
            guard let self, let state = emitted as? TmdbSettings else { return }
            self.tmdbEnabled = state.enabled
            self.tmdbHasKey = state.hasApiKey
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
        tmdbWatcher?.cancel(); tmdbWatcher = nil
    }

    // MARK: - Actions

    func setSkipIntro(_ enabled: Bool) {
        PlayerSettingsRepository.shared.setSkipIntroEnabled(enabled: enabled)
    }

    // MARK: - TMDB

    /// Save a key and turn enrichment on. Order matters: `setEnabled(true)` is a no-op while the key
    /// is blank, so set the key first (the repo trims it and persists via NSUserDefaults).
    func saveTmdbKey(_ key: String) {
        TmdbSettingsRepository.shared.setApiKey(value: key)
        TmdbSettingsRepository.shared.setEnabled(value: true)
    }

    func setTmdbEnabled(_ enabled: Bool) {
        TmdbSettingsRepository.shared.setEnabled(value: enabled)
    }

    /// Clearing the key also disables enrichment (handled inside the repo).
    func clearTmdbKey() {
        TmdbSettingsRepository.shared.setApiKey(value: "")
    }

    // MARK: - Subtitles

    /// Rebuild the whole `SubtitleStyleState` with one field changed (KMP has no partial copy in
    /// Swift), then persist. Colors are argb longs (0xAARRGGBB). No-ops until the style has loaded.
    private func updateSubtitleStyle(_ transform: (SubtitleStyleState) -> SubtitleStyleState) {
        guard let current = subtitleStyle else { return }
        PlayerSettingsRepository.shared.setSubtitleStyle(style: transform(current))
    }

    func setSubtitleTextColor(_ argb: Int64) {
        updateSubtitleStyle {
            SubtitleStyleState(textColor: argb, backgroundColor: $0.backgroundColor, outlineColor: $0.outlineColor, outlineEnabled: $0.outlineEnabled, outlineWidth: $0.outlineWidth, bold: $0.bold, fontSizeSp: $0.fontSizeSp, bottomOffset: $0.bottomOffset, useForcedSubtitles: $0.useForcedSubtitles, showOnlyPreferredLanguages: $0.showOnlyPreferredLanguages)
        }
    }

    func setSubtitleFontSize(_ sizeSp: Int32) {
        updateSubtitleStyle {
            SubtitleStyleState(textColor: $0.textColor, backgroundColor: $0.backgroundColor, outlineColor: $0.outlineColor, outlineEnabled: $0.outlineEnabled, outlineWidth: $0.outlineWidth, bold: $0.bold, fontSizeSp: sizeSp, bottomOffset: $0.bottomOffset, useForcedSubtitles: $0.useForcedSubtitles, showOnlyPreferredLanguages: $0.showOnlyPreferredLanguages)
        }
    }

    func setSubtitleBackground(_ argb: Int64) {
        updateSubtitleStyle {
            SubtitleStyleState(textColor: $0.textColor, backgroundColor: argb, outlineColor: $0.outlineColor, outlineEnabled: $0.outlineEnabled, outlineWidth: $0.outlineWidth, bold: $0.bold, fontSizeSp: $0.fontSizeSp, bottomOffset: $0.bottomOffset, useForcedSubtitles: $0.useForcedSubtitles, showOnlyPreferredLanguages: $0.showOnlyPreferredLanguages)
        }
    }

    func setSubtitleBold(_ bold: Bool) {
        updateSubtitleStyle {
            SubtitleStyleState(textColor: $0.textColor, backgroundColor: $0.backgroundColor, outlineColor: $0.outlineColor, outlineEnabled: $0.outlineEnabled, outlineWidth: $0.outlineWidth, bold: bold, fontSizeSp: $0.fontSizeSp, bottomOffset: $0.bottomOffset, useForcedSubtitles: $0.useForcedSubtitles, showOnlyPreferredLanguages: $0.showOnlyPreferredLanguages)
        }
    }

    func setSubtitleOutline(_ enabled: Bool) {
        updateSubtitleStyle {
            SubtitleStyleState(textColor: $0.textColor, backgroundColor: $0.backgroundColor, outlineColor: $0.outlineColor, outlineEnabled: enabled, outlineWidth: $0.outlineWidth, bold: $0.bold, fontSizeSp: $0.fontSizeSp, bottomOffset: $0.bottomOffset, useForcedSubtitles: $0.useForcedSubtitles, showOnlyPreferredLanguages: $0.showOnlyPreferredLanguages)
        }
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
        tmdbWatcher?.cancel()
    }
}
