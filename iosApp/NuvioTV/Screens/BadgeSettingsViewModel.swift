import Combine
import Foundation
import SharedCore

/// Native "Stream Badges" settings for tvOS, backed by the shared
/// `StreamBadgeSettingsRepository` (per-profile, synced across devices via the
/// `stream_badge_settings` blob in `ProfileSettingsSync` — a pack imported on the phone shows up
/// here automatically and vice versa).
///
/// Badge packs are JSON files (hosted at a URL) of regex filters + chip images for video
/// quality / HDR type / audio channels etc. Import fetches + parses + persists + activates;
/// up to 3 packs are kept with one active at a time (`STREAM_BADGE_IMPORT_LIMIT`).
@MainActor
final class BadgeSettingsViewModel: ObservableObject {
    @Published private(set) var state: StreamBadgeSettingsUiState?
    @Published private(set) var isImporting = false
    @Published private(set) var statusMessage: String?

    private var watcher: FlowWatcher?

    func start() {
        guard watcher == nil else { return }
        StreamBadgeSettingsRepository.shared.ensureLoaded()
        watcher = FlowWatcherKt.watch(StreamBadgeSettingsRepository.shared.uiState) { [weak self] emitted in
            guard let self, let value = emitted as? StreamBadgeSettingsUiState else { return }
            self.state = value
        }
    }

    func stop() {
        watcher?.cancel()
        watcher = nil
    }

    // MARK: - Derived state (defaults mirror the shared repository)

    var imports: [StreamBadgeImport] { state?.rules.imports ?? [] }
    var showFileSizeBadges: Bool { state?.showFileSizeBadges ?? true }
    var showAddonLogo: Bool { state?.showAddonLogo ?? false }
    var badgesOnTop: Bool { state?.badgePlacement == .top }
    /// Player badges (upstream 344117e73): chips for what is playing in the player's top panel.
    /// Off by default.
    var showInPlayer: Bool { state?.showInPlayer ?? false }
    /// Upstream 83e528f00: the pack the player matches; "" (the default) = the stream list's pack.
    /// A source that is no longer imported reads as "" (the shared rules fall back the same way).
    var playerBadgeSource: String {
        let source = state?.playerBadgeSource ?? ""
        return imports.contains { $0.sourceUrl.caseInsensitiveCompare(source) == .orderedSame } ? source : ""
    }
    /// Stream picker A (P4.1): the picker's backdrop mode; the platform default (Cinematic on tvOS,
    /// decision D1) until the repository has emitted.
    var backgroundMode: StreamBackgroundMode {
        state?.backgroundMode ?? StreamBackgroundDefaults.shared.platformDefault
    }
    /// Polish batch D5: how the picker groups its source rows (Quality or Add-on). Quality is the
    /// default before the repository has emitted.
    var groupingMode: StreamGroupingMode { state?.groupingMode ?? .quality }
    /// Direction C D9: the default before the repository has emitted.
    var listOpensWith: StreamListOpensWith { state?.listOpensWith ?? .bestPick }

    // MARK: - Actions (thin passthroughs to the shared repository)

    func importPack(url: String) {
        let trimmed = url.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, !isImporting else { return }
        isImporting = true
        statusMessage = nil
        StreamBadgeSettingsRepository.shared.importStreamBadgeRulesFromUrl(url: trimmed) { [weak self] result, error in
            DispatchQueue.main.async {
                guard let self else { return }
                self.isImporting = false
                if let success = result as? StreamBadgeImportResultSuccess {
                    let count = Int(success.rules.enabledFilterCount)
                    self.statusMessage = count == 1 ? String(localized: "Imported 1 badge filter.") : String(localized: "Imported \(count) badge filters.")
                } else if let failure = result as? StreamBadgeImportResultError {
                    self.statusMessage = failure.message
                } else {
                    self.statusMessage = error?.localizedDescription ?? String(localized: "Badge import failed.")
                }
            }
        }
    }

    func setActive(_ sourceUrl: String) {
        StreamBadgeSettingsRepository.shared.setActiveStreamBadgeRulesSource(sourceUrl: sourceUrl)
    }

    func deletePack(_ sourceUrl: String) {
        StreamBadgeSettingsRepository.shared.deleteStreamBadgeRulesSource(sourceUrl: sourceUrl)
        statusMessage = nil
    }

    func setShowFileSizeBadges(_ enabled: Bool) {
        StreamBadgeSettingsRepository.shared.setShowFileSizeBadges(enabled: enabled)
    }

    func setShowAddonLogo(_ enabled: Bool) {
        StreamBadgeSettingsRepository.shared.setShowAddonLogo(enabled: enabled)
    }

    func setShowInPlayer(_ enabled: Bool) {
        StreamBadgeSettingsRepository.shared.setShowInPlayer(enabled: enabled)
    }

    func setPlayerBadgeSource(_ sourceUrl: String) {
        StreamBadgeSettingsRepository.shared.setPlayerBadgeSource(source: sourceUrl)
    }

    func setBadgesOnTop(_ top: Bool) {
        StreamBadgeSettingsRepository.shared.setBadgePlacement(placement: top ? .top : .bottom)
    }

    func setBackgroundMode(_ mode: StreamBackgroundMode) {
        StreamBadgeSettingsRepository.shared.setBackgroundMode(mode: mode)
    }

    func setGroupingMode(_ mode: StreamGroupingMode) {
        StreamBadgeSettingsRepository.shared.setGroupingMode(mode: mode)
    }

    func setListOpensWith(_ mode: StreamListOpensWith) {
        StreamBadgeSettingsRepository.shared.setListOpensWith(mode: mode)
    }

    /// Short display label for an imported pack (URL tail without query noise).
    static func packLabel(_ sourceUrl: String) -> String {
        guard let url = URL(string: sourceUrl) else { return sourceUrl }
        let name = url.lastPathComponent
        return name.isEmpty || name == "/" ? (url.host ?? sourceUrl) : name
    }

    deinit {
        watcher?.cancel()
    }
}
