import Combine
import Foundation
import SharedCore

/// Resolves and observes playable streams for a title via the shared `StreamsRepository`.
///
/// `load(type:videoId:...)` kicks off resolution across installed streaming addons; `uiState`
/// (`StateFlow<StreamsUiState>`) emits `groups` of `StreamItem`s as each addon responds.
///
/// AVPlayer can only play direct HTTP/HLS URLs, so we surface only streams with a non-nil `url`
/// (torrent `infoHash`-only streams need a debrid resolver and are filtered out here).
@MainActor
final class StreamsViewModel: ObservableObject {
    /// One playable, addon-grouped section for the picker UI.
    struct Group: Identifiable {
        let id: String           // addonId
        let addonName: String
        let streams: [StreamItem]
    }

    @Published private(set) var groups: [Group] = []
    @Published private(set) var isLoading: Bool = false
    @Published private(set) var emptyReason: String?

    private var watcher: FlowWatcher?
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

    func start() {
        guard watcher == nil else { return }
        watcher = FlowWatcherKt.watch(StreamsRepository.shared.uiState) { [weak self] emitted in
            guard let self, let state = emitted as? StreamsUiState else { return }
            self.apply(state)
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
        StreamsRepository.shared.clear()
    }

    private func apply(_ state: StreamsUiState) {
        isLoading = state.isAnyLoading

        groups = state.groups.compactMap { group in
            // Widen through an explicit String? — Kotlin's nullable String surfaces here as a
            // non-optional Swift String, so direct optional-chaining/binding won't compile.
            let playable = group.streams.filter {
                let direct: String? = $0.playableDirectUrl
                return !(direct ?? "").isEmpty
            }
            guard !playable.isEmpty else { return nil }
            return Group(id: group.addonId, addonName: group.addonName, streams: playable)
        }

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
        default:                   return "No playable streams. Install a streaming addon that returns direct links."
        }
    }

    deinit {
        watcher?.cancel()
    }
}
