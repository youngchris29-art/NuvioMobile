package com.nuvio.app.features.debrid

import com.nuvio.app.features.streams.AddonStreamGroup
import com.nuvio.app.features.streams.StreamBehaviorHints
import com.nuvio.app.features.streams.StreamClientResolve
import com.nuvio.app.features.streams.StreamClientResolveParsed
import com.nuvio.app.features.streams.StreamClientResolveRaw
import com.nuvio.app.features.streams.StreamClientResolveStream
import com.nuvio.app.features.streams.StreamDebridCacheState
import com.nuvio.app.features.streams.StreamDebridCacheStatus
import com.nuvio.app.features.streams.StreamItem
import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertTrue

/**
 * Sources filters for every add-on on tvOS: `DebridStreamPresentation.apply(..., allStreams = true)`
 * runs the debrid sort / minimum-resolution / Dolby Vision / HDR preferences (and the new Cached
 * Sources Only flag) over every add-on's and plugin's streams, not just the managed debrid ones.
 * `allStreams = false` (mobile) keeps today's debrid-only behaviour.
 *
 * Streams are keyed by `behaviorHints.filename`: it survives the debrid formatter's rename, and
 * it is also what the resolution / HDR / DV parsing reads, so each fixture's filename carries its
 * own facts.
 */
class DebridStreamPresentationAllStreamsTest {

    private val uhdHdr = plain("Alpha", "Movie.2160p.WEB-DL.HDR10.mkv")
    private val fhd = plain("Bravo", "Movie.1080p.WEB-DL.x264.mkv")
    private val hd720 = plain("Charlie", "Movie.720p.WEB-DL.mkv")
    private val unknownResolution = plain("Delta", "Movie.WEB-DL.mkv")
    private val dolbyVision = plain("Echo", "Movie.2160p.DV.HDR10.mkv")

    // --- (i) mobile: allStreams = false leaves non-debrid streams alone -------------------------

    @Test
    fun `allStreams false leaves passthrough streams untouched with a resolver`() {
        val streams = listOf(hd720, uhdHdr, fhd, unknownResolution)
        val settings = debridSettings(
            resolver = true,
            streamMinimumQuality = DebridStreamMinimumQuality.P1080,
            streamHdrFilter = DebridStreamFeatureFilter.ONLY,
            streamSortMode = DebridStreamSortMode.QUALITY_DESC,
        )

        assertEquals(streams, present(streams, settings, allStreams = null), "default argument is false")
        assertEquals(streams, present(streams, settings, allStreams = false))
    }

    @Test
    fun `allStreams false leaves passthrough streams untouched without a resolver`() {
        val streams = listOf(hd720, uhdHdr, fhd, unknownResolution)
        val settings = debridSettings(
            resolver = false,
            streamMinimumQuality = DebridStreamMinimumQuality.P1080,
            streamHdrFilter = DebridStreamFeatureFilter.ONLY,
            streamSortMode = DebridStreamSortMode.QUALITY_DESC,
        )

        assertEquals(streams, present(streams, settings, allStreams = null))
        assertEquals(streams, present(streams, settings, allStreams = false))
    }

    // --- (ii) tvOS: allStreams = true filters and sorts every stream ----------------------------

    @Test
    fun `allStreams filters passthrough streams by minimum resolution and keeps UNKNOWN resolution`() {
        val plugin = plain("Foxtrot", "Movie.480p.WEB-DL.mkv", addonId = "plugin:scraper")
        val streams = listOf(hd720, uhdHdr, plugin, fhd, unknownResolution)

        for (resolver in listOf(true, false)) {
            val presented = present(
                streams,
                debridSettings(resolver = resolver, streamMinimumQuality = DebridStreamMinimumQuality.P1080),
                allStreams = true,
            )

            assertEquals(
                listOf(uhdHdr, fhd, unknownResolution).filenames(),
                presented.filenames(),
                "720p and 480p (add-on and plugin alike) drop; UNKNOWN passes; original order kept (resolver=$resolver)",
            )
        }
    }

    @Test
    fun `allStreams filters passthrough streams by HDR and Dolby Vision`() {
        val streams = listOf(uhdHdr, fhd, dolbyVision)

        for (resolver in listOf(true, false)) {
            fun filtered(
                dolbyVisionFilter: DebridStreamFeatureFilter = DebridStreamFeatureFilter.ANY,
                hdrFilter: DebridStreamFeatureFilter = DebridStreamFeatureFilter.ANY,
            ) = present(
                streams,
                debridSettings(
                    resolver = resolver,
                    streamDolbyVisionFilter = dolbyVisionFilter,
                    streamHdrFilter = hdrFilter,
                ),
                allStreams = true,
            ).filenames()

            assertEquals(
                listOf(uhdHdr, dolbyVision).filenames(),
                filtered(hdrFilter = DebridStreamFeatureFilter.ONLY),
                "HDR only (resolver=$resolver)",
            )
            assertEquals(
                listOf(fhd).filenames(),
                filtered(hdrFilter = DebridStreamFeatureFilter.EXCLUDE),
                "HDR excluded (resolver=$resolver)",
            )
            assertEquals(
                listOf(dolbyVision).filenames(),
                filtered(dolbyVisionFilter = DebridStreamFeatureFilter.ONLY),
                "Dolby Vision only (resolver=$resolver)",
            )
            assertEquals(
                listOf(uhdHdr, fhd).filenames(),
                filtered(dolbyVisionFilter = DebridStreamFeatureFilter.EXCLUDE),
                "Dolby Vision excluded (resolver=$resolver)",
            )
        }
    }

    @Test
    fun `allStreams still applies an HDR filter to a stream whose resolution is UNKNOWN`() {
        // UNKNOWN only exempts the minimum-resolution rule, not the other filters.
        val presented = present(
            listOf(unknownResolution, uhdHdr),
            debridSettings(
                resolver = true,
                streamMinimumQuality = DebridStreamMinimumQuality.P1080,
                streamHdrFilter = DebridStreamFeatureFilter.ONLY,
            ),
            allStreams = true,
        )

        assertEquals(listOf(uhdHdr).filenames(), presented.filenames())
    }

    @Test
    fun `allStreams sorts passthrough streams by the chosen sort mode`() {
        val small = plain("Golf", "Movie.1080p.a.mkv", size = 1_000_000_000)
        val medium = plain("Hotel", "Movie.720p.b.mkv", size = 3_000_000_000)
        val large = plain("India", "Movie.2160p.c.mkv", size = 5_000_000_000)
        val streams = listOf(medium, large, small, unknownResolution)

        for (resolver in listOf(true, false)) {
            assertEquals(
                listOf(large, small, medium, unknownResolution).filenames(),
                present(
                    streams,
                    debridSettings(resolver = resolver, streamSortMode = DebridStreamSortMode.QUALITY_DESC),
                    allStreams = true,
                ).filenames(),
                "best quality first, UNKNOWN resolution last (resolver=$resolver)",
            )
            assertEquals(
                listOf(unknownResolution, small, medium, large).filenames(),
                present(
                    streams,
                    debridSettings(resolver = resolver, streamSortMode = DebridStreamSortMode.SIZE_ASC),
                    allStreams = true,
                ).filenames(),
                "smallest first, a stream with no known size counts as 0 (resolver=$resolver)",
            )
        }
    }

    @Test
    fun `allStreams with default preferences leaves the add-on order alone`() {
        val streams = listOf(hd720, uhdHdr, fhd, unknownResolution)

        assertEquals(streams, present(streams, debridSettings(resolver = true), allStreams = true))
        assertEquals(streams, present(streams, debridSettings(resolver = false), allStreams = true))
    }

    @Test
    fun `allStreams works with no debrid resolver and leaves resolver-only logic off`() {
        // An uncached torrent is hidden only by the resolver-only logic; without a resolver it
        // is just another stream (and gets no debrid formatting or result cap).
        val uncachedTorrent = torrent(
            "Movie.2160p.uncached.mkv",
            StreamDebridCacheState.NOT_CACHED,
        )
        val streams = listOf(hd720, uncachedTorrent, fhd)
        val presented = present(
            streams,
            debridSettings(
                resolver = false,
                streamMinimumQuality = DebridStreamMinimumQuality.P1080,
                streamSortMode = DebridStreamSortMode.QUALITY_DESC,
                streamMaxResults = 1,
            ),
            allStreams = true,
        )

        assertEquals(
            listOf(uncachedTorrent, fhd).filenames(),
            presented.filenames(),
            "filtered and sorted, not hidden, not capped by maxResults",
        )
        assertEquals(uncachedTorrent, presented.first(), "no debrid formatting without a resolver")
    }

    @Test
    fun `allStreams caps debrid streams but not passthrough streams`() {
        val cached1080 = torrent("Movie.1080p.cached.mkv", StreamDebridCacheState.CACHED)
        val cached2160 = torrent("Movie.2160p.cached.mkv", StreamDebridCacheState.CACHED)
        val plain2160 = plain("Juliet", "Movie.2160p.plain.mkv")
        val streams = listOf(hd720, cached1080, plain2160, cached2160, unknownResolution)

        val presented = present(
            streams,
            debridSettings(
                resolver = true,
                streamSortMode = DebridStreamSortMode.QUALITY_DESC,
                streamMaxResults = 1,
            ),
            allStreams = true,
        )

        assertEquals(
            listOf(cached2160, plain2160, hd720, unknownResolution).filenames(),
            presented.filenames(),
            "managed debrid streams first and capped to one; every passthrough stream stays, sorted",
        )
    }

    @Test
    fun `allStreams keeps the strict minimum resolution for managed debrid streams`() {
        val unknownResolutionTorrent = torrent("Movie.cached.mkv", StreamDebridCacheState.CACHED)
        val presented = present(
            listOf(unknownResolutionTorrent, unknownResolution),
            debridSettings(resolver = true, streamMinimumQuality = DebridStreamMinimumQuality.P1080),
            allStreams = true,
        )

        assertEquals(
            listOf(unknownResolution).filenames(),
            presented.filenames(),
            "the UNKNOWN-resolution exemption is passthrough-only; the debrid branch still drops it",
        )
    }

    // --- (iii) Cached Sources Only ------------------------------------------------------------

    @Test
    fun `cached only keeps cached torrents and direct debrid links and drops plain add-on links`() {
        val streams = cachedOnlyFixture()

        val presented = present(
            streams.all,
            debridSettings(resolver = true, streamCachedOnly = true),
            allStreams = true,
        )

        assertEquals(
            listOf(streams.cachedTorrent, streams.directDebrid).filenames(),
            presented.filenames(),
        )
    }

    @Test
    fun `cached only leaves the group empty when it has only plain links`() {
        val group = presentGroup(
            listOf(fhd, plain("Kilo", "Movie.720p.plugin.mkv", addonId = "plugin:scraper")),
            debridSettings(resolver = true, streamCachedOnly = true),
            allStreams = true,
        )

        assertTrue(group.streams.isEmpty())
    }

    @Test
    fun `without cached only the same fixture keeps plain links and unverified torrents`() {
        val streams = cachedOnlyFixture()

        val presented = present(
            streams.all,
            debridSettings(resolver = true, streamCachedOnly = false),
            allStreams = true,
        )

        assertEquals(
            listOf(streams.cachedTorrent, streams.directDebrid, streams.plainLink, streams.unverifiedTorrent).filenames(),
            presented.filenames(),
            "debrid first, then passthrough in add-on order; the NOT_CACHED torrent stays hidden",
        )
    }

    @Test
    fun `cached only is ignored without a resolver`() {
        val streams = cachedOnlyFixture()

        // Key saved but link resolving off, and no key at all: neither can resolve.
        for (noResolverSettings in listOf(
            debridSettings(resolver = false, streamCachedOnly = true),
            DebridSettings(streamCachedOnly = true),
        )) {
            assertEquals(streams.all, present(streams.all, noResolverSettings, allStreams = true))
            assertEquals(streams.all, present(streams.all, noResolverSettings, allStreams = false))
        }
    }

    @Test
    fun `cached only is ignored when allStreams is false`() {
        val streams = cachedOnlyFixture()
        val settings = debridSettings(resolver = true, streamCachedOnly = true)
        val expected = listOf(
            streams.cachedTorrent,
            streams.directDebrid,
            streams.plainLink,
            streams.unverifiedTorrent,
        ).filenames()

        assertEquals(expected, present(streams.all, settings, allStreams = null).filenames())
        assertEquals(expected, present(streams.all, settings, allStreams = false).filenames())
    }

    // --- helpers ------------------------------------------------------------------------------

    private class CachedOnlyFixture(
        val cachedTorrent: StreamItem,
        val directDebrid: StreamItem,
        val plainLink: StreamItem,
        val uncachedTorrent: StreamItem,
        val unverifiedTorrent: StreamItem,
    ) {
        val all: List<StreamItem> =
            listOf(plainLink, uncachedTorrent, cachedTorrent, unverifiedTorrent, directDebrid)
    }

    private fun cachedOnlyFixture() = CachedOnlyFixture(
        cachedTorrent = torrent("Movie.2160p.cached.mkv", StreamDebridCacheState.CACHED),
        directDebrid = directDebrid("Movie.1080p.direct.mkv"),
        plainLink = plain("Lima", "Movie.1080p.plain.mkv"),
        uncachedTorrent = torrent("Movie.2160p.uncached.mkv", StreamDebridCacheState.NOT_CACHED),
        // UNKNOWN = the cache check failed; such a row is passthrough, never "cached".
        unverifiedTorrent = torrent("Movie.1080p.unverified.mkv", StreamDebridCacheState.UNKNOWN),
    )

    private fun debridSettings(
        resolver: Boolean,
        streamMaxResults: Int = 0,
        streamSortMode: DebridStreamSortMode = DebridStreamSortMode.DEFAULT,
        streamMinimumQuality: DebridStreamMinimumQuality = DebridStreamMinimumQuality.ANY,
        streamDolbyVisionFilter: DebridStreamFeatureFilter = DebridStreamFeatureFilter.ANY,
        streamHdrFilter: DebridStreamFeatureFilter = DebridStreamFeatureFilter.ANY,
        streamCachedOnly: Boolean = false,
    ) = DebridSettings(
        enabled = resolver,
        providerApiKeys = mapOf(DebridProviders.TORBOX_ID to "key"),
        streamMaxResults = streamMaxResults,
        streamSortMode = streamSortMode,
        streamMinimumQuality = streamMinimumQuality,
        streamDolbyVisionFilter = streamDolbyVisionFilter,
        streamHdrFilter = streamHdrFilter,
        streamCachedOnly = streamCachedOnly,
    )

    /** [allStreams] null = omit the argument, to cover the default value. */
    private fun presentGroup(
        streams: List<StreamItem>,
        settings: DebridSettings,
        allStreams: Boolean?,
    ): AddonStreamGroup {
        val groups = listOf(
            AddonStreamGroup(
                addonName = "Addon",
                addonId = "addon:test",
                streams = streams,
            ),
        )
        return if (allStreams == null) {
            DebridStreamPresentation.apply(groups, settings).single()
        } else {
            DebridStreamPresentation.apply(groups, settings, allStreams = allStreams).single()
        }
    }

    private fun present(
        streams: List<StreamItem>,
        settings: DebridSettings,
        allStreams: Boolean?,
    ): List<StreamItem> = presentGroup(streams, settings, allStreams).streams

    private fun List<StreamItem>.filenames(): List<String?> = map { it.behaviorHints.filename }

    private fun plain(
        name: String,
        filename: String,
        size: Long? = null,
        addonId: String = "addon:test",
    ): StreamItem =
        StreamItem(
            name = name,
            url = "https://example.test/$filename",
            addonName = "Addon",
            addonId = addonId,
            behaviorHints = StreamBehaviorHints(filename = filename, videoSize = size),
        )

    private fun torrent(filename: String, state: StreamDebridCacheState): StreamItem =
        StreamItem(
            name = "Torrent",
            infoHash = "abcdef1234567890abcdef1234567890abcdef12",
            addonName = "Addon",
            addonId = "addon:test",
            behaviorHints = StreamBehaviorHints(filename = filename),
            debridCacheStatus = StreamDebridCacheStatus(
                providerId = DebridProviders.TORBOX_ID,
                providerName = DebridProviders.Torbox.displayName,
                state = state,
                cachedName = filename,
            ),
        )

    private fun directDebrid(filename: String): StreamItem =
        StreamItem(
            name = "Direct",
            addonName = "Addon",
            addonId = "addon:test",
            behaviorHints = StreamBehaviorHints(filename = filename),
            clientResolve = StreamClientResolve(
                type = "debrid",
                service = DebridProviders.TORBOX_ID,
                filename = filename,
                isCached = true,
                stream = StreamClientResolveStream(
                    raw = StreamClientResolveRaw(
                        filename = filename,
                        parsed = StreamClientResolveParsed(resolution = "1080p"),
                    ),
                ),
            ),
        )
}
