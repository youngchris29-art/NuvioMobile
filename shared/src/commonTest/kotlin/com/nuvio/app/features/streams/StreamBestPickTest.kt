package com.nuvio.app.features.streams

import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertFailsWith
import kotlin.test.assertFalse
import kotlin.test.assertNull
import kotlin.test.assertTrue

/** Direction C (D2): [StreamBestPick] over parsed facts, plus the `key(facts)` equivalence. */
class StreamBestPickTest {

    private val gb = 1_000_000_000L

    private fun plain(name: String, addon: String = "addon:a", size: Long? = null): StreamItem = StreamItem(
        name = name,
        url = "https://example.com/${name.replace(' ', '-')}.mkv",
        addonName = addon,
        addonId = addon,
        behaviorHints = StreamBehaviorHints(videoSize = size),
    )

    private fun torrent(name: String, state: StreamDebridCacheState?, provider: String = "torbox"): StreamItem =
        StreamItem(
            name = name,
            infoHash = "0123456789abcdef0123456789abcdef01234567",
            addonName = "Torrentio",
            addonId = "addon:t",
            debridCacheStatus = state?.let {
                StreamDebridCacheStatus(providerId = provider, providerName = provider, state = it)
            },
        )

    private fun cachedTorrent(name: String, provider: String = "torbox") =
        torrent(name, StreamDebridCacheState.CACHED, provider)

    private fun uncachedTorrent(name: String) = torrent(name, StreamDebridCacheState.NOT_CACHED)

    private fun directDebrid(name: String, service: String = "realdebrid"): StreamItem = StreamItem(
        name = name,
        url = null,
        addonName = "Debrid",
        addonId = "addon:d",
        clientResolve = StreamClientResolve(type = "debrid", service = service, isCached = true),
    )

    private fun pick(
        streams: List<StreamItem>,
        rejected: List<Boolean> = List(streams.size) { false },
        debridEnabled: Boolean = true,
        active: String? = "torbox",
        cachedOnly: Boolean = false,
    ): StreamBestPickResult = StreamBestPick.pick(
        streams = streams,
        facts = streams.map { StreamFactsParser.parse(it) },
        rejected = rejected,
        debridEnabled = debridEnabled,
        activeResolverProviderId = active,
        cachedOnly = cachedOnly,
    )

    @Test
    fun rankOrderIsResolutionThenHdrThenCached() {
        val result = pick(
            listOf(
                plain("1080p WEB-DL"),
                cachedTorrent("2160p WEB-DL"),
                cachedTorrent("2160p DV HDR WEB-DL"),
            ),
        )
        assertEquals(listOf(2, 1, 0), result.ranked)
        assertEquals(2, result.best)
    }

    @Test
    fun cachedBeatsUncachedAtEqualResolutionAndHdr() {
        val result = pick(listOf(plain("2160p", size = 50 * gb), cachedTorrent("2160p")))
        assertEquals(1, result.best)
    }

    @Test
    fun cachedOnlySkipsUncachedDebridAndPlain() {
        val result = pick(
            listOf(uncachedTorrent("2160p"), plain("2160p"), cachedTorrent("1080p")),
            cachedOnly = true,
        )
        assertEquals(listOf(2), result.ranked)
    }

    @Test
    fun torrentIsSkippedWithDebridOff() {
        val result = pick(
            listOf(cachedTorrent("2160p"), plain("720p")),
            debridEnabled = false,
        )
        assertEquals(listOf(1), result.ranked)
    }

    @Test
    fun resolverMismatchIsNotCachedUnderCachedOnly() {
        val result = pick(
            listOf(directDebrid("2160p", service = "realdebrid")),
            active = "torbox",
            cachedOnly = true,
        )
        assertEquals(emptyList(), result.ranked)
    }

    @Test
    fun cachedDebridLinkMatchesTheSwiftWalkFixture() {
        val sel = StreamAutoPlaySelector
        val direct = directDebrid("S", service = "realdebrid")
        assertTrue(sel.isCachedDebridLink(direct, true, "realdebrid"))
        assertTrue(sel.isCachedDebridLink(direct, true, "RealDebrid"))
        assertFalse(sel.isCachedDebridLink(direct, true, "torbox"))
        assertFalse(sel.isCachedDebridLink(direct, false, "realdebrid"))
        assertTrue(sel.isCachedDebridLink(cachedTorrent("S"), true, "torbox"))
        assertFalse(sel.isCachedDebridLink(uncachedTorrent("S"), true, "torbox"))
        assertFalse(sel.isCachedDebridLink(plain("S"), true, "torbox"))
    }

    private fun marked(name: String): StreamItem = StreamItem(
        name = name,
        url = "https://example.com/${name.replace(' ', '-')}.mkv",
        addonName = "Torrentio",
        addonId = "addon:t",
    )

    @Test
    fun addonMarkedCachedLinksQualifyUnderCachedOnlyForTheActiveService() {
        val sel = StreamAutoPlaySelector
        assertTrue(sel.isCachedDebridLink(marked("[TB+] Torrentio 2160p"), true, "torbox"))
        assertTrue(sel.isCachedDebridLink(marked("[TB+] Torrentio 2160p"), true, "TorBox"))
        assertFalse(sel.isCachedDebridLink(marked("[RD+] Torrentio 2160p"), true, "torbox"))
        assertFalse(sel.isCachedDebridLink(marked("[DL+] Torrentio 2160p"), true, "torbox"))
        assertTrue(sel.isCachedDebridLink(marked("2160p \u26A1"), true, "torbox"), "a bolt names no service")
        assertFalse(sel.isCachedDebridLink(marked("[TB download] Torrentio 2160p"), true, "torbox"))
        assertFalse(sel.isCachedDebridLink(marked("[TB+] Torrentio 2160p"), false, "torbox"))
    }

    @Test
    fun bestSourceCardKeepsWhatTheCachedOnlyListShows() {
        // Both Cached Sources Only settings on: the list (Settings -> Sources) keeps the [TB+] row and
        // the bolt row; the Best Source card must rank them, not fall back to nothing.
        val settings = com.nuvio.app.features.debrid.DebridSettings(
            enabled = true,
            providerApiKeys = mapOf(com.nuvio.app.features.debrid.DebridProviders.TORBOX_ID to "key"),
            streamCachedOnly = true,
        )
        val listed = com.nuvio.app.features.debrid.DebridStreamPresentation.apply(
            listOf(
                AddonStreamGroup(
                    addonName = "Torrentio",
                    addonId = "addon:t",
                    streams = listOf(
                        marked("[TB+] Torrentio 1080p"),
                        marked("Plain 2160p"),
                        marked("2160p \u26A1"),
                    ),
                ),
            ),
            settings,
            allStreams = true,
        ).single().streams
        assertEquals(listOf("[TB+] Torrentio 1080p", "2160p \u26A1"), listed.map { it.name })

        val result = pick(listed, active = "torbox", cachedOnly = true)
        assertEquals(listOf(1, 0), result.ranked)
    }

    @Test
    fun rejectedStreamsAreExcluded() {
        val result = pick(
            listOf(plain("2160p"), plain("1080p")),
            rejected = listOf(true, false),
        )
        assertEquals(listOf(1), result.ranked)
        assertEquals(1, result.best)
    }

    @Test
    fun bestFhdIsTheBestOfTheFhdTier() {
        val result = pick(
            listOf(plain("2160p"), plain("1080p", size = 2 * gb), plain("1080p", size = 4 * gb)),
        )
        assertEquals(2, result.bestFhd)
    }

    @Test
    fun bestFhdIsNullWhenBestIsFhd() {
        assertNull(pick(listOf(plain("1080p"), plain("720p"))).bestFhd)
    }

    @Test
    fun bestFhdIsNullWithNoFhd() {
        assertNull(pick(listOf(plain("2160p"), plain("720p"))).bestFhd)
    }

    @Test
    fun bestDirectIsThePlainLinkWhenBestIsDebrid() {
        val result = pick(listOf(cachedTorrent("2160p"), plain("1080p"), plain("720p")))
        assertEquals(0, result.best)
        assertEquals(1, result.bestDirect)
    }

    @Test
    fun bestDirectIsNullWhenItIsTheBest() {
        assertNull(pick(listOf(plain("2160p"), cachedTorrent("1080p"))).bestDirect)
    }

    @Test
    fun bestDirectIgnoresCachedOnly() {
        val result = pick(listOf(cachedTorrent("2160p"), plain("1080p")), cachedOnly = true)
        assertEquals(0, result.best)
        assertEquals(1, result.bestDirect)
    }

    @Test
    fun bestDirectSkipsRejected() {
        val result = pick(
            listOf(cachedTorrent("2160p"), plain("1080p")),
            rejected = listOf(false, true),
        )
        assertNull(result.bestDirect)
    }

    @Test
    fun emptyInputGivesNoPick() {
        val result = pick(emptyList())
        assertEquals(emptyList(), result.ranked)
        assertNull(result.best)
        assertNull(result.bestFhd)
        assertNull(result.bestDirect)
    }

    @Test
    fun tiesKeepInputOrder() {
        val result = pick(listOf(plain("1080p"), plain("1080p"), plain("1080p")))
        assertEquals(listOf(0, 1, 2), result.ranked)
    }

    @Test
    fun sizeMismatchThrows() {
        val streams = listOf(plain("1080p"), plain("720p"))
        assertFailsWith<IllegalArgumentException> {
            StreamBestPick.pick(
                streams = streams,
                facts = listOf(StreamFactsParser.parse(streams[0])),
                rejected = listOf(false, false),
                debridEnabled = true,
                activeResolverProviderId = null,
                cachedOnly = false,
            )
        }
        assertFailsWith<IllegalArgumentException> {
            StreamBestPick.pick(
                streams = streams,
                facts = streams.map { StreamFactsParser.parse(it) },
                rejected = listOf(false),
                debridEnabled = true,
                activeResolverProviderId = null,
                cachedOnly = false,
            )
        }
    }

    @Test
    fun keyFromFactsEqualsKeyFromStream() {
        val fixtures = listOf(
            plain("2160p DV", size = 10 * gb),
            plain("2160p HDR", size = 10 * gb),
            plain("2160p DV HDR10", size = 10 * gb),
            plain("1080p HLG", size = 3 * gb),
            plain("720p"),
            cachedTorrent("2160p HDR10+"),
            uncachedTorrent("1080p"),
            directDebrid("2160p DV HDR"),
        )
        fixtures.forEach { stream ->
            assertEquals(
                StreamQualityRank.key(stream),
                StreamQualityRank.key(StreamFactsParser.parse(stream)),
                stream.name,
            )
        }
    }

    @Test
    fun pickAgreesWithRankBest() {
        val streams = listOf(
            plain("1080p WEB-DL", size = 4 * gb),
            plain("2160p HDR WEB-DL", size = 20 * gb),
            plain("2160p DV HDR REMUX", size = 60 * gb),
            plain("2160p WEB-DL", size = 25 * gb),
        )
        val result = pick(streams)
        assertEquals(StreamQualityRank.rankBest(streams), result.ranked.map { streams[it] })
    }
}
