package com.nuvio.app.features.streams

import com.nuvio.app.features.debrid.DebridStreamAudioTag
import com.nuvio.app.features.debrid.DebridStreamMetadata
import com.nuvio.app.features.debrid.DebridStreamPreferences
import com.nuvio.app.features.debrid.DebridStreamQuality
import com.nuvio.app.features.debrid.DebridStreamResolution
import com.nuvio.app.features.debrid.DebridStreamVisualTag

/**
 * A format chip under the detail-page title. A badge means "available in": at least one
 * counted stream from the user's add-ons carries that format. It says nothing about which
 * stream plays by default.
 *
 * [label] is the English chip text; Swift localizes by [name] (stable across releases).
 * Declaration order is the display order.
 */
enum class TitleFormatBadge(val label: String) {
    UHD_4K("4K"),
    DOLBY_VISION("Dolby Vision"),
    HDR10_PLUS("HDR10+"),
    HDR("HDR"),
    DOLBY_ATMOS("Dolby Atmos"),
    DTS_X("DTS:X"),
}

/** The format facts of one stream that the badge rules read. */
internal data class TitleFormatSignal(
    val resolution: DebridStreamResolution,
    val quality: DebridStreamQuality,
    val visualTags: Set<DebridStreamVisualTag>,
    val audioTags: Set<DebridStreamAudioTag>,
)

/**
 * Folds a title's streams into "available in" badges.
 *
 * Rules:
 * - Streams whose source is CAM, TS, TC or SCR are ignored.
 * - An AI-upscaled stream (visual tag `AI`) counts for audio only, never for 4K or dynamic range.
 * - 4K: any counted stream at 2160p or above. There is no HD badge.
 * - One dynamic-range badge, highest wins: Dolby Vision (DV, DV Only, HDR+DV) over HDR10+ over
 *   HDR (HDR10, HDR, HLG, HDR Only). A "DV HDR10" stream counts as Dolby Vision.
 * - Dolby Atmos and DTS:X are independent. DTS-HD MA, TrueHD and DD+ light nothing.
 * - Output order is 4K, dynamic range, Atmos, DTS:X, so there are at most 4 badges.
 *
 * Listability and the user's Sources filters are NOT applied here: callers pass the streams the
 * picker would present and list (already filtered, cache-checked and listable).
 */
object TitleFormatBadges {
    /** Preferences only feed the sort ranks in [DebridStreamMetadata.facts]; the parsed tags ignore them. */
    private val neutralPreferences = DebridStreamPreferences()

    private val excludedQualities = setOf(
        DebridStreamQuality.CAM,
        DebridStreamQuality.TS,
        DebridStreamQuality.TC,
        DebridStreamQuality.SCR,
    )
    private val dolbyVisionTags = setOf(
        DebridStreamVisualTag.DV,
        DebridStreamVisualTag.DV_ONLY,
        DebridStreamVisualTag.HDR_DV,
    )
    private val hdrTags = setOf(
        DebridStreamVisualTag.HDR10,
        DebridStreamVisualTag.HDR,
        DebridStreamVisualTag.HLG,
        DebridStreamVisualTag.HDR_ONLY,
    )
    private val dynamicRangeBadges = setOf(
        TitleFormatBadge.DOLBY_VISION,
        TitleFormatBadge.HDR10_PLUS,
        TitleFormatBadge.HDR,
    )
    private val completeSet = setOf(
        TitleFormatBadge.UHD_4K,
        TitleFormatBadge.DOLBY_VISION,
        TitleFormatBadge.DOLBY_ATMOS,
        TitleFormatBadge.DTS_X,
    )

    internal fun signal(stream: StreamItem): TitleFormatSignal {
        val facts = DebridStreamMetadata.facts(stream, neutralPreferences)
        return TitleFormatSignal(
            resolution = facts.resolution,
            quality = facts.quality,
            visualTags = facts.visualTags.toSet(),
            audioTags = facts.audioTags.toSet(),
        )
    }

    internal fun aggregate(signals: List<TitleFormatSignal>): List<TitleFormatBadge> {
        val found = mutableSetOf<TitleFormatBadge>()
        for (signal in signals) {
            if (signal.quality in excludedQualities) continue
            if (DebridStreamAudioTag.ATMOS in signal.audioTags) found += TitleFormatBadge.DOLBY_ATMOS
            if (DebridStreamAudioTag.DTS_X in signal.audioTags) found += TitleFormatBadge.DTS_X
            if (DebridStreamVisualTag.AI in signal.visualTags) continue
            if (signal.resolution.value >= 2160) found += TitleFormatBadge.UHD_4K
            when {
                signal.visualTags.any { it in dolbyVisionTags } -> found += TitleFormatBadge.DOLBY_VISION
                DebridStreamVisualTag.HDR10_PLUS in signal.visualTags -> found += TitleFormatBadge.HDR10_PLUS
                signal.visualTags.any { it in hdrTags } -> found += TitleFormatBadge.HDR
            }
        }
        return normalize(found)
    }

    fun aggregateStreams(streams: List<StreamItem>): List<TitleFormatBadge> =
        aggregate(streams.map(::signal))

    /** True when no further stream can add a badge the probe would show (its early-exit test). */
    fun isComplete(badges: Collection<TitleFormatBadge>): Boolean = badges.containsAll(completeSet)

    /** Union of [a] and [b] in display order, keeping only the highest dynamic-range badge. */
    fun merge(a: List<TitleFormatBadge>, b: List<TitleFormatBadge>): List<TitleFormatBadge> =
        normalize(a.toSet() + b)

    /** Canonical order (enum declaration order) with a single dynamic-range badge, highest wins. */
    private fun normalize(badges: Set<TitleFormatBadge>): List<TitleFormatBadge> {
        val bestDynamicRange = TitleFormatBadge.entries.firstOrNull { it in dynamicRangeBadges && it in badges }
        return TitleFormatBadge.entries.filter { badge ->
            badge in badges && (badge !in dynamicRangeBadges || badge == bestDynamicRange)
        }
    }
}
