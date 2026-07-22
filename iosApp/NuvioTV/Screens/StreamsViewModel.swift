import Combine
import Foundation
import SharedCore

/// Resolves and observes playable streams for a title via the shared `StreamsRepository`.
///
/// `load(type:videoId:...)` kicks off resolution across installed streaming addons; `uiState`
/// (`StateFlow<StreamsUiState>`) emits `groups` of `StreamItem`s as each addon responds.
///
/// A stream is surfaced when it either carries a direct HTTP(S) URL, or is a debrid candidate
/// (torrent/`clientResolve` result from an installed addon) while in-app debrid resolution is
/// enabled — those resolve to a direct link at click time in `StreamPickerView` (mobile parity:
/// `StreamsScreen.kt` / `App.kt` click paths). Also observes the shared badge + debrid settings
/// so the picker can render badge packs, file-size chips, placement, addon logos and the
/// "Instant" cached suffix exactly like mobile's `StreamCard`.
@MainActor
final class StreamsViewModel: ObservableObject {
    /// One playable, addon-grouped section for the picker UI.
    struct Group: Identifiable {
        let id: String           // addonId
        let addonName: String
        let streams: [StreamItem]
        /// Mirrors the shared `AddonStreamGroup.isLoading` — this addon hasn't finished
        /// responding yet (more streams may still arrive). Drives the per-group header spinner.
        let isLoading: Bool
    }

    @Published private(set) var groups: [Group] = []
    @Published private(set) var isLoading: Bool = false
    @Published private(set) var emptyReason: String?
    /// Focus key of the first stream row; the picker moves initial focus here when rows arrive.
    @Published private(set) var firstRowKey: String?
    /// Shared badge settings (imported packs, file-size toggle, placement, addon logo).
    @Published private(set) var badgeSettings: StreamBadgeSettingsUiState?
    /// Whether in-app debrid can resolve torrent results (drives filtering + "Instant" suffix).
    @Published private(set) var debridResolveEnabled = false
    /// Mobile parity (`StreamsScreen.kt:229`): append "- <Provider> Instant" to cached rows
    /// only when debrid resolution is on and no custom stream-name template is active.
    @Published private(set) var instantSuffixEnabled = false

    private var watcher: FlowWatcher?
    private var badgeWatcher: FlowWatcher?
    private var debridWatcher: FlowWatcher?
    /// Last raw state, kept so a debrid-settings flip re-filters without a reload.
    private var lastState: StreamsUiState?
    private let type: String
    private let videoId: String
    private let parentMetaId: String?
    private let season: KotlinInt?
    private let episode: KotlinInt?

    init(type: String, videoId: String, parentMetaId: String? = nil, season: Int? = nil, episode: Int? = nil) {
        self.type = type
        self.videoId = videoId
        self.parentMetaId = parentMetaId
        self.season = season.map { KotlinInt(int: Int32($0)) }
        self.episode = episode.map { KotlinInt(int: Int32($0)) }
    }

    // MARK: - Derived badge-setting conveniences (defaults mirror the shared repository)

    var showFileSizeBadges: Bool { badgeSettings?.showFileSizeBadges ?? true }
    var showAddonLogo: Bool { badgeSettings?.showAddonLogo ?? false }
    var badgesOnTop: Bool { badgeSettings?.badgePlacement == .top }

    static func rowKey(groupId: String, index: Int) -> String { "\(groupId)#\(index)" }

    func start() {
        guard watcher == nil else { return }

        StreamBadgeSettingsRepository.shared.ensureLoaded()
        DebridSettingsRepository.shared.ensureLoaded()

        watcher = FlowWatcherKt.watch(StreamsRepository.shared.uiState) { [weak self] emitted in
            guard let self, let state = emitted as? StreamsUiState else { return }
            self.lastState = state
            self.apply(state)
        }
        badgeWatcher = FlowWatcherKt.watch(StreamBadgeSettingsRepository.shared.uiState) { [weak self] emitted in
            guard let self, let value = emitted as? StreamBadgeSettingsUiState else { return }
            self.badgeSettings = value
        }
        debridWatcher = FlowWatcherKt.watch(DebridSettingsRepository.shared.uiState) { [weak self] emitted in
            guard let self, let value = emitted as? DebridSettings else { return }
            let canResolve = value.canResolvePlayableLinks
            self.instantSuffixEnabled = canResolve && !value.hasCustomStreamFormatting
            if self.debridResolveEnabled != canResolve {
                self.debridResolveEnabled = canResolve
                // Filtering depends on this flag — re-derive the visible groups.
                if let last = self.lastState { self.apply(last) }
            } else {
                self.debridResolveEnabled = canResolve
            }
        }

        StreamsRepository.shared.load(
            type: type,
            videoId: videoId,
            parentMetaId: parentMetaId,
            season: season,
            episode: episode,
            manualSelection: true
        )
    }

    func stop() {
        watcher?.cancel()
        watcher = nil
        badgeWatcher?.cancel()
        badgeWatcher = nil
        debridWatcher?.cancel()
        debridWatcher = nil
        StreamsRepository.shared.clear()
    }

    /// Full re-fetch — used when a debrid resolve reports the picked link went stale
    /// (mobile shows the same "Refreshing results" toast and reloads).
    func reload() {
        lastState = nil
        StreamsRepository.shared.clear()
        StreamsRepository.shared.load(
            type: type,
            videoId: videoId,
            parentMetaId: parentMetaId,
            season: season,
            episode: episode,
            manualSelection: true
        )
    }

    private func apply(_ state: StreamsUiState) {
        isLoading = state.isAnyLoading
        let debridEnabled = debridResolveEnabled

        groups = state.groups.compactMap { group in
            // Widen through an explicit String? — Kotlin's nullable String surfaces here as a
            // non-optional Swift String, so direct optional-chaining/binding won't compile.
            let playable = group.streams.filter { stream in
                let direct: String? = stream.playableDirectUrl
                if !(direct ?? "").isEmpty { return true }
                // Torrent / clientResolve results from installed addons resolve at click time
                // through the in-app debrid connection (DirectDebridPlaybackResolver).
                return debridEnabled && stream.isAddonDebridCandidate
            }
            guard !playable.isEmpty else { return nil }
            return Group(id: group.addonId, addonName: group.addonName, streams: playable, isLoading: group.isLoading)
        }
        firstRowKey = groups.first.map { Self.rowKey(groupId: $0.id, index: 0) }

        if groups.isEmpty && !isLoading {
            emptyReason = Self.describe(state.emptyStateReason)
        } else {
            emptyReason = nil
        }
    }

    private static func describe(_ reason: StreamsEmptyStateReason?) -> String {
        switch reason?.name {
        case "NoAddonsInstalled":  return "No addons installed."
        case "NoCompatibleAddons": return "No streaming addons installed \u{2014} only a metadata catalog (Cinemeta) is set up."
        case "NoStreamsFound":     return "No streams found for this title."
        case "StreamFetchFailed":  return "Stream lookup failed."
        default:                   return "No playable streams. Install a streaming addon, or connect a debrid account in Settings to play torrent results."
        }
    }

    deinit {
        watcher?.cancel()
        badgeWatcher?.cancel()
        debridWatcher?.cancel()
    }
}
