package com.nuvio.app.features.streams

import com.nuvio.app.features.debrid.DebridStreamMetadata
import com.nuvio.app.features.debrid.DebridStreamPreferences
import com.nuvio.app.features.debrid.DebridStreamVisualTag

/**
 * beta.19-rc1 verdict (A, BUG-136): how `StreamAutoPlayMode.FIRST_STREAM` orders the streams that
 * have arrived. [LIST_ORDER] is the historical behaviour (the first auto-playable stream in the
 * list's group order); [BEST_QUALITY] ranks them with [StreamQualityRank] first.
 */
enum class StreamAutoPlayRanking { LIST_ORDER, BEST_QUALITY }

/**
 * Platform seam, like [StreamPresentationPlatform]: tvOS sets [StreamAutoPlayRanking.BEST_QUALITY]
 * at bootstrap (`installTvOsSharedProviders`), where "Auto-Play Best Source" is the shared
 * `FIRST_STREAM` mode. Mobile keeps [StreamAutoPlayRanking.LIST_ORDER], so mobile behaviour does
 * not change.
 *
 * Read at stream-load time by `StreamsRepository` and `DirectDebridStreamPreparer`, and by the
 * tvOS up-next engine (`NextEpisodeAutoPlay.swift`), which has to pass it to the selector
 * explicitly because Kotlin default arguments do not bridge to Swift.
 */
object StreamAutoPlayPlatform {
    var firstStreamRanking: StreamAutoPlayRanking = StreamAutoPlayRanking.LIST_ORDER
}

/**
 * "Best" source: resolution, then HDR / Dolby Vision (one tier), then cached, then file size;
 * streams that tie on all four keep their list order (the sort is stable).
 *
 * The facts come from the same parser the Sources filters use
 * (`DebridStreamMetadata.facts`), so a stream the filters read as 2160p HDR ranks as 2160p HDR
 * here. The user's sort preferences are deliberately NOT consulted: the order is fixed.
 */
object StreamQualityRank {

    /** Higher is better on every field. */
    data class Key(
        /** [com.nuvio.app.features.debrid.DebridStreamResolution.value]; 0 when the tag is missing. */
        val resolution: Int,
        /** 1 when the stream carries any HDR or Dolby Vision tag, else 0. */
        val dynamicRange: Int,
        /** 1 for a debrid link the add-on says is cached / direct, else 0. */
        val cached: Int,
        /** Bytes; 0 when no size is known. */
        val size: Long,
    )

    private val defaultPreferences = DebridStreamPreferences()

    // Dolby Vision and every HDR flavour share one tier (approved order, 2026-10-03).
    private val dynamicRangeTags = setOf(
        DebridStreamVisualTag.DV,
        DebridStreamVisualTag.DV_ONLY,
        DebridStreamVisualTag.HDR_DV,
        DebridStreamVisualTag.HDR,
        DebridStreamVisualTag.HDR10,
        DebridStreamVisualTag.HDR10_PLUS,
        DebridStreamVisualTag.HLG,
        DebridStreamVisualTag.HDR_ONLY,
    )

    private val bestFirst: Comparator<Pair<StreamItem, Key>> =
        compareByDescending<Pair<StreamItem, Key>> { it.second.resolution }
            .thenByDescending { it.second.dynamicRange }
            .thenByDescending { it.second.cached }
            .thenByDescending { it.second.size }

    fun key(stream: StreamItem): Key {
        val facts = DebridStreamMetadata.facts(stream, defaultPreferences)
        val isCachedDebridLink = stream.isAddonDebridCandidate &&
            (stream.isDirectDebridStream || stream.isCachedDebridTorrentStream)
        return Key(
            resolution = facts.resolution.value,
            dynamicRange = if (facts.visualTags.any { it in dynamicRangeTags }) 1 else 0,
            cached = if (isCachedDebridLink) 1 else 0,
            size = facts.size ?: 0L,
        )
    }

    /** [streams] best first. Keys are computed once per stream; full ties keep their list order. */
    fun rankBest(streams: List<StreamItem>): List<StreamItem> {
        if (streams.size < 2) return streams
        val keyed = streams.map { stream -> stream to key(stream) }
        return keyed.sortedWith(bestFirst).map { it.first }
    }
}
