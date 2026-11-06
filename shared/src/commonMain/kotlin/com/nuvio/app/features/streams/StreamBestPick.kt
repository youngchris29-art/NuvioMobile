package com.nuvio.app.features.streams

/**
 * Direction C (D2): the stream picker's best-pick card and its two alternatives, by the walk's
 * rules: eligibility = the auto-play walk's playability ([StreamAutoPlaySelector.isAutoPlayableStream])
 * plus, when cachedOnly, a cached debrid link ([StreamAutoPlaySelector.isCachedDebridLink]);
 * recently failed links (rejected) never qualify; order = [StreamQualityRank] (resolution >
 * HDR/DV > cached > size, input order on ties). The user's Sort Sources setting is not consulted,
 * exactly as Auto-Play Best Source ignores it. Pure: no parsing (the facts are the caller's).
 */
data class StreamBestPickResult(
    /** Input indices of every eligible stream, best first. Empty = no card. */
    val ranked: List<Int>,
    /** Best eligible stream in [StreamTier.FHD]; null when ranked is empty, when ranked[0] is FHD, or when none is FHD. */
    val bestFhd: Int?,
    /** Best stream that plays as a plain direct link; null when none or when it is ranked[0]. */
    val bestDirect: Int?,
) {
    val best: Int? get() = ranked.firstOrNull()
}

object StreamBestPick {
    fun pick(
        streams: List<StreamItem>,
        facts: List<StreamFacts>,
        rejected: List<Boolean>,
        debridEnabled: Boolean,
        activeResolverProviderId: String?,
        cachedOnly: Boolean,
    ): StreamBestPickResult {
        require(streams.size == facts.size && streams.size == rejected.size) {
            "streams, facts and rejected must be parallel lists"
        }
        if (streams.isEmpty()) return StreamBestPickResult(emptyList(), null, null)

        // Add-on-marked cached links rank as cached for the active service (rank time: the facts
        // are cached per stream and know no resolver).
        val keys = facts.mapIndexed { i, f -> StreamQualityRank.key(f, streams[i], activeResolverProviderId) }
        val order: Comparator<Int> =
            compareByDescending<Int> { keys[it].resolution }
                .thenByDescending { keys[it].dynamicRange }
                .thenByDescending { keys[it].cached }
                .thenByDescending { keys[it].size }

        val playable = streams.indices.map { i ->
            !rejected[i] && StreamAutoPlaySelector.isAutoPlayableStream(
                streams[i], debridEnabled, activeResolverProviderId,
            )
        }
        val ranked = streams.indices
            .filter { i ->
                playable[i] && (
                    !cachedOnly || StreamAutoPlaySelector.isCachedDebridLink(
                        streams[i], debridEnabled, activeResolverProviderId,
                    )
                    )
            }
            .sortedWith(order)

        val best = ranked.firstOrNull()
        val bestFhd = if (best == null || StreamTier.forResolution(facts[best].resolution) == StreamTier.FHD) {
            null
        } else {
            ranked.firstOrNull { StreamTier.forResolution(facts[it].resolution) == StreamTier.FHD }
        }
        val direct = streams.indices
            .filter { playable[it] && streams[it].playableDirectUrl != null && !streams[it].isAddonDebridCandidate }
            .sortedWith(order)
            .firstOrNull()
        val bestDirect = if (direct == best) null else direct
        return StreamBestPickResult(ranked, bestFhd, bestDirect)
    }
}
