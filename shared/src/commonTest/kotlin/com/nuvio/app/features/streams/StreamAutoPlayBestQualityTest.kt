package com.nuvio.app.features.streams

import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertNull

/**
 * beta.19-rc1 verdict (A, BUG-136): Auto-Play Best Source ranks the streams that arrived,
 * resolution > HDR/DV (one tier) > cached > size, and keeps list order for full ties.
 */
class StreamAutoPlayBestQualityTest {

    @Test
    fun higherResolutionWinsAcrossGroups() {
        val first = plain("Lizzie Borden 1080p WEB-DL", addon = "Alpha", size = GB * 8)
        val second = plain("Lizzie Borden 2160p WEB-DL", addon = "Beta", size = GB * 4)
        val streams = listOf(first, second)

        assertEquals(second, evaluate(streams, StreamAutoPlayRanking.BEST_QUALITY).stream)
        // LIST_ORDER keeps the historical first-in-list pick.
        assertEquals(first, evaluate(streams, StreamAutoPlayRanking.LIST_ORDER).stream)
    }

    @Test
    fun hdrWinsAtSameResolution() {
        // The Lizzie Borden case: the plain 2160p listed (and larger) first, the HDR copy later.
        val sdr = plain("Lizzie Borden 2160p WEB-DL", addon = "Alpha", size = GB * 30)
        val hdr = plain("Lizzie Borden 2160p WEB-DL HDR10", addon = "Beta", size = GB * 12)

        assertEquals(hdr, evaluate(listOf(sdr, hdr), StreamAutoPlayRanking.BEST_QUALITY).stream)
        assertEquals(sdr, evaluate(listOf(sdr, hdr), StreamAutoPlayRanking.LIST_ORDER).stream)
    }

    @Test
    fun resolutionOutranksHdr() {
        val hdr1080 = plain("Movie 1080p BluRay HDR10", addon = "Alpha", size = GB * 40)
        val sdr2160 = plain("Movie 2160p WEB-DL", addon = "Beta", size = GB * 2)

        assertEquals(sdr2160, evaluate(listOf(hdr1080, sdr2160), StreamAutoPlayRanking.BEST_QUALITY).stream)
    }

    @Test
    fun dolbyVisionAndHdrShareOneTier() {
        val dolbyVision = plain("Movie 2160p WEB-DL DV", addon = "Alpha", size = GB * 10)
        val hdr10 = plain("Movie 2160p WEB-DL HDR10", addon = "Beta", size = GB * 20)

        // Same tier, so the larger file decides, in either list order.
        assertEquals(hdr10, evaluate(listOf(dolbyVision, hdr10), StreamAutoPlayRanking.BEST_QUALITY).stream)
        assertEquals(hdr10, evaluate(listOf(hdr10, dolbyVision), StreamAutoPlayRanking.BEST_QUALITY).stream)

        val bigDolbyVision = plain("Movie 2160p WEB-DL DV", addon = "Alpha", size = GB * 30)
        assertEquals(
            bigDolbyVision,
            evaluate(listOf(hdr10, bigDolbyVision), StreamAutoPlayRanking.BEST_QUALITY).stream,
        )

        // Every flavour is in the tier: HDR10+, HLG, "HDR" alone and Dolby Vision + HDR.
        val tagged = listOf(
            "Movie 2160p HDR10+",
            "Movie 2160p HLG",
            "Movie 2160p HDR",
            "Movie 2160p DV HDR",
        ).map { StreamQualityRank.key(plain(it, addon = "Alpha", size = GB)) }
        assertEquals(listOf(1, 1, 1, 1), tagged.map { it.dynamicRange })
        assertEquals(0, StreamQualityRank.key(plain("Movie 2160p WEB-DL", addon = "Alpha", size = GB)).dynamicRange)
    }

    @Test
    fun cachedWinsAtSameResolutionAndRange() {
        val direct = plain("Movie 1080p WEB-DL HDR", addon = "Alpha", size = GB * 20)
        val cached = cachedTorrent("Movie 1080p WEB-DL HDR", addon = "Beta", infoHash = "hash-cached", size = GB * 5)

        assertEquals(cached, evaluate(listOf(direct, cached), StreamAutoPlayRanking.BEST_QUALITY).stream)
        assertEquals(direct, evaluate(listOf(direct, cached), StreamAutoPlayRanking.LIST_ORDER).stream)
        assertEquals(1, StreamQualityRank.key(cached).cached)
        assertEquals(0, StreamQualityRank.key(direct).cached)
    }

    @Test
    fun sizeBreaksRemainingTies() {
        val small = plain("Movie 1080p WEB-DL", addon = "Alpha", size = GB * 3)
        val large = plain("Movie 1080p WEB-DL", addon = "Beta", size = GB * 9)
        val unknownSize = plain("Movie 1080p WEB-DL", addon = "Gamma", size = null)

        val evaluation = evaluate(listOf(unknownSize, small, large), StreamAutoPlayRanking.BEST_QUALITY)

        assertEquals(large, evaluation.stream)
        assertEquals(listOf(large, small, unknownSize), evaluation.readyStreams)
    }

    @Test
    fun fullTieKeepsListOrder() {
        val a = plain("Movie 1080p WEB-DL", addon = "Alpha", size = GB * 4)
        val b = plain("Movie 1080p WEB-DL", addon = "Beta", size = GB * 4)
        val c = plain("Movie 1080p WEB-DL", addon = "Gamma", size = GB * 4)

        val evaluation = evaluate(listOf(a, b, c), StreamAutoPlayRanking.BEST_QUALITY)

        assertEquals(a, evaluation.stream)
        assertEquals(listOf(a, b, c), evaluation.readyStreams)
        assertEquals(listOf(a, b, c), StreamQualityRank.rankBest(listOf(a, b, c)))
    }

    @Test
    fun untaggedResolutionRanksLast() {
        val untagged = plain("Some Movie WEB-DL HDR", addon = "Alpha", size = GB * 90)
        val low = plain("Some Movie 720p WEB-DL", addon = "Beta", size = GB)

        val evaluation = evaluate(listOf(untagged, low), StreamAutoPlayRanking.BEST_QUALITY)

        assertEquals(0, StreamQualityRank.key(untagged).resolution)
        assertEquals(low, evaluation.stream)
        assertEquals(listOf(low, untagged), evaluation.readyStreams)
    }

    @Test
    fun preferredBingeGroupStaysFirst() {
        val top = plain("Show 2160p WEB-DL HDR10", addon = "Alpha", size = GB * 6)
        val mid = plain("Show 1080p WEB-DL", addon = "Beta", size = GB * 3)
        val binge = plain("Show 720p WEB-DL", addon = "Gamma", size = GB, bingeGroup = "release-group-1")

        val evaluation = StreamAutoPlaySelector.evaluateAutoPlayStream(
            streams = listOf(mid, binge, top),
            mode = StreamAutoPlayMode.FIRST_STREAM,
            regexPattern = "",
            source = StreamAutoPlaySource.ALL_SOURCES,
            installedAddonNames = ADDONS,
            selectedAddons = emptySet(),
            selectedPlugins = emptySet(),
            preferredBingeGroup = "release-group-1",
            preferBingeGroupInSelection = true,
            debridEnabled = true,
            activeResolverProviderId = "realdebrid",
            ranking = StreamAutoPlayRanking.BEST_QUALITY,
        )

        assertEquals(binge, evaluation.stream)
        // The rest of the walk is still best first.
        assertEquals(listOf(binge, top, mid), evaluation.readyStreams)
    }

    @Test
    fun regexModeIgnoresRanking() {
        val low = plain("Movie 1080p WEB-DL", addon = "Alpha", size = GB * 3)
        val high = plain("Movie 2160p WEB-DL HDR10", addon = "Beta", size = GB * 20)

        val evaluation = StreamAutoPlaySelector.evaluateAutoPlayStream(
            streams = listOf(low, high),
            mode = StreamAutoPlayMode.REGEX_MATCH,
            regexPattern = "1080p|2160p",
            source = StreamAutoPlaySource.ALL_SOURCES,
            installedAddonNames = ADDONS,
            selectedAddons = emptySet(),
            selectedPlugins = emptySet(),
            debridEnabled = true,
            activeResolverProviderId = "realdebrid",
            ranking = StreamAutoPlayRanking.BEST_QUALITY,
        )

        assertEquals(low, evaluation.stream)
        assertEquals(listOf(low, high), evaluation.readyStreams)
    }

    @Test
    fun manualModeStillSelectsNothingWhenRanked() {
        val evaluation = StreamAutoPlaySelector.evaluateAutoPlayStream(
            streams = listOf(plain("Movie 2160p", addon = "Alpha", size = GB)),
            mode = StreamAutoPlayMode.MANUAL,
            regexPattern = "",
            source = StreamAutoPlaySource.ALL_SOURCES,
            installedAddonNames = ADDONS,
            selectedAddons = emptySet(),
            selectedPlugins = emptySet(),
            ranking = StreamAutoPlayRanking.BEST_QUALITY,
        )

        assertNull(evaluation.stream)
        assertEquals(emptyList(), evaluation.readyStreams)
    }

    @Test
    fun readyStreamsAreRankedForFailover() {
        val p720 = plain("Movie 720p WEB-DL", addon = "Alpha", size = GB * 2)
        val cached2160Hdr = cachedTorrent("Movie 2160p WEB-DL HDR10", addon = "Beta", infoHash = "hash-uhd", size = GB * 25)
        val p1080 = plain("Movie 1080p WEB-DL", addon = "Gamma", size = GB * 6)
        val p2160 = plain("Movie 2160p WEB-DL", addon = "Alpha", size = GB * 25)
        // Cached-state unknown: not auto-playable, so it never joins the walk.
        val checking = cachedTorrent(
            name = "Movie 2160p WEB-DL HDR10 DV",
            addon = "Beta",
            infoHash = "hash-checking",
            size = GB * 60,
            state = StreamDebridCacheState.CHECKING,
        )

        val evaluation = evaluate(
            listOf(p720, cached2160Hdr, p1080, checking, p2160),
            StreamAutoPlayRanking.BEST_QUALITY,
        )

        assertEquals(cached2160Hdr, evaluation.stream)
        // The whole candidate list is ranked: HDR 2160p, plain 2160p, 1080p, 720p.
        assertEquals(listOf(cached2160Hdr, p2160, p1080, p720), evaluation.readyStreams)
    }

    @Test
    fun defaultRankingIsListOrder() {
        val first = plain("Movie 1080p WEB-DL", addon = "Alpha", size = GB)
        val better = plain("Movie 2160p WEB-DL HDR10", addon = "Beta", size = GB * 30)

        // No `ranking` argument: the Kotlin default, which mobile callers rely on.
        val evaluation = StreamAutoPlaySelector.evaluateAutoPlayStream(
            streams = listOf(first, better),
            mode = StreamAutoPlayMode.FIRST_STREAM,
            regexPattern = "",
            source = StreamAutoPlaySource.ALL_SOURCES,
            installedAddonNames = ADDONS,
            selectedAddons = emptySet(),
            selectedPlugins = emptySet(),
            debridEnabled = true,
            activeResolverProviderId = "realdebrid",
        )
        val selected = StreamAutoPlaySelector.selectAutoPlayStream(
            streams = listOf(first, better),
            mode = StreamAutoPlayMode.FIRST_STREAM,
            regexPattern = "",
            source = StreamAutoPlaySource.ALL_SOURCES,
            installedAddonNames = ADDONS,
            selectedAddons = emptySet(),
            selectedPlugins = emptySet(),
        )

        assertEquals(first, evaluation.stream)
        assertEquals(listOf(first, better), evaluation.readyStreams)
        assertEquals(first, selected)
        // The platform seam starts on list order; only the tvOS installer flips it.
        assertEquals(StreamAutoPlayRanking.LIST_ORDER, StreamAutoPlayPlatform.firstStreamRanking)
    }

    private fun evaluate(
        streams: List<StreamItem>,
        ranking: StreamAutoPlayRanking,
    ): StreamAutoPlayEvaluation =
        StreamAutoPlaySelector.evaluateAutoPlayStream(
            streams = streams,
            mode = StreamAutoPlayMode.FIRST_STREAM,
            regexPattern = "",
            source = StreamAutoPlaySource.ALL_SOURCES,
            installedAddonNames = ADDONS,
            selectedAddons = emptySet(),
            selectedPlugins = emptySet(),
            debridEnabled = true,
            activeResolverProviderId = "realdebrid",
            ranking = ranking,
        )

    private fun plain(
        name: String,
        addon: String,
        size: Long?,
        bingeGroup: String? = null,
    ): StreamItem = StreamItem(
        name = name,
        url = "https://example.com/${addon.lowercase()}/${name.replace(' ', '-')}.mp4",
        addonName = addon,
        addonId = "addon:$addon",
        behaviorHints = StreamBehaviorHints(bingeGroup = bingeGroup, videoSize = size),
    )

    private fun cachedTorrent(
        name: String,
        addon: String,
        infoHash: String,
        size: Long?,
        state: StreamDebridCacheState = StreamDebridCacheState.CACHED,
    ): StreamItem = StreamItem(
        name = name,
        infoHash = infoHash,
        addonName = addon,
        addonId = "addon:$addon",
        behaviorHints = StreamBehaviorHints(videoSize = size),
        debridCacheStatus = StreamDebridCacheStatus(
            providerId = "realdebrid",
            providerName = "Real-Debrid",
            state = state,
        ),
    )

    private companion object {
        const val GB = 1_000_000_000L
        val ADDONS = setOf("Alpha", "Beta", "Gamma")
    }
}
