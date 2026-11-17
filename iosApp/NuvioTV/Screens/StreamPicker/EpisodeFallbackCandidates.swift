import Foundation
import SharedCore

/// W4 (2b.3): the fallback candidates of an Up Next episode whose source failed to start in the
/// player, in rank order. Up Next's own filters first (the links that failed recently for the
/// episode, auto-play Cached Sources Only, direct or debrid-resolvable streams only: the Swift-only
/// knowledge), then the shared rule with Up Next's scope (`PlayerSourceFallback.rankedCandidates`:
/// the tried sources and other copies of the failed torrent from its add-on left out). The walk
/// controller keeps no rule of its own; it walks this list.
enum EpisodeFallbackCandidates {
    /// The live inputs: the episode's rejected links, the debrid connection, the settings.
    static func ranked(streams: [StreamItem], context ctx: PlaybackContext, settings: PlayerSettingsUiState?,
                       tried: PlayerSourceFallbackTried) -> [StreamItem] {
        guard let settings else { return [] }
        let debrid = DebridSettingsRepository.shared.snapshot()
        return ranked(
            streams: streams,
            tried: tried,
            failed: ctx.listedStream,
            rejected: RejectedStreamLinks.rejected(for: ctx.videoId),
            cachedOnly: NextEpisodeEngine.cachedOnlyInEffect(mode: settings.streamAutoPlayMode,
                                                             cachedOnly: settings.streamAutoPlayCachedOnly),
            scope: NextEpisodeEngine.autoPickScope(settings: settings, playingBingeGroup: ctx.bingeGroup),
            debridEnabled: debrid.canResolvePlayableLinks,
            activeResolverProviderId: { let id: String? = debrid.activeResolverProviderId; return id }())
    }

    /// The pure half (tests pass every input). `resolvesThroughDebrid` is
    /// `NextEpisodeEngine.isAutoPlayCandidate`'s debrid seam.
    static func ranked(streams: [StreamItem], tried: PlayerSourceFallbackTried, failed: StreamItem?,
                       rejected: Set<String>, cachedOnly: Bool, scope: StreamAutoPickScope,
                       debridEnabled: Bool, activeResolverProviderId: String?,
                       resolvesThroughDebrid: (StreamItem) -> Bool = NextEpisodeEngine.resolvesThroughDebrid) -> [StreamItem] {
        let pool = NextEpisodeEngine.selectable(
            streams.filter { NextEpisodeEngine.isAutoPlayCandidate($0, resolvesThroughDebrid: resolvesThroughDebrid) },
            rejected: rejected, cachedOnly: cachedOnly,
            debridEnabled: debridEnabled, activeResolverProviderId: activeResolverProviderId)
        guard !pool.isEmpty else { return [] }
        let failedHash: String? = failed?.p2pInfoHash
        return PlayerSourceFallback.shared.rankedCandidates(
            streams: pool,
            scope: scope,
            triedKeys: tried.keys,
            failedAddonId: failed?.addonId,
            failedInfoHash: failedHash,
            installedAddonNames: PlayerSourceFallbackCandidates.shared.installedAddonNames(streams: streams),
            debridEnabled: debridEnabled,
            activeResolverProviderId: activeResolverProviderId)
    }
}
