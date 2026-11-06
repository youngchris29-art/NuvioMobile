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

    private fun torrent(
        name: String,
        state: StreamDebridCacheState?,
        provider: String = "torbox",
        size: Long? = null,
    ): StreamItem =
        StreamItem(
            name = name,
            infoHash = "0123456789abcdef0123456789abcdef01234567",
            addonName = "Torrentio",
            addonId = "addon:t",
            behaviorHints = StreamBehaviorHints(videoSize = size),
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

    private fun marked(name: String, description: String? = null, size: Long? = null): StreamItem = StreamItem(
        name = name,
        description = description,
        url = "https://example.com/${name.replace(' ', '-')}.mkv",
        addonName = "Torrentio",
        addonId = "addon:t",
        behaviorHints = StreamBehaviorHints(videoSize = size),
    )

    @Test
    fun aNamedServiceIsTheMarkedLinksServiceUnderCachedOnly() {
        val sel = StreamAutoPlaySelector
        // The AIOStreams format: a bolt in the name, the service on its own cloud line.
        val aio = marked("4K \u26A1", "\uD83C\uDFAC Animals (2026)\n\uD83D\uDFE2 INSTANT PLAY\n\u2601\uFE0F TorBox")
        assertTrue(sel.isCachedDebridLink(aio, true, "torbox"))
        assertFalse(sel.isCachedDebridLink(aio, true, "premiumize"))
        // A display-name spelling in the name field.
        val rd = marked("RealDebrid 2160p \u26A1")
        assertTrue(sel.isCachedDebridLink(rd, true, "realdebrid"))
        assertFalse(sel.isCachedDebridLink(rd, true, "torbox"))
        assertFalse(sel.isCachedDebridLink(marked("Real-Debrid 2160p \u26A1"), true, "torbox"))
        assertFalse(sel.isCachedDebridLink(marked("2160p \u26A1", "4K \u00B7 \u2601\uFE0F Debrid-Link \u00B7 12 GB"), true, "torbox"))
        // A release or film title containing a service word names no service: the bolt matches any.
        assertTrue(sel.isCachedDebridLink(marked("2160p \u26A1", "\uD83C\uDFAC Premiumize Story (2024)"), true, "torbox"))
        assertTrue(sel.isCachedDebridLink(marked("2160p \u26A1", "Premiumize.Story.2160p.WEB-DL.mkv"), true, "torbox"))
    }

    @Test
    fun aPreparedCachedTorrentStaysCachedUnderCachedOnly() {
        val sel = StreamAutoPlaySelector
        // The background preparer resolved it: it carries the debrid URL and keeps its status.
        val prepared = cachedTorrent("2160p").copy(url = "https://torbox.example/dl/abc.mkv")
        assertFalse(prepared.isAddonDebridCandidate, "no longer a debrid candidate once it has a URL")
        assertTrue(sel.isCachedDebridLink(prepared, true, "torbox"))
        assertTrue(sel.isCachedDebridLink(prepared, true, null), "no active resolver matches")
        assertFalse(sel.isCachedDebridLink(prepared, true, "premiumize"))
        assertFalse(sel.isCachedDebridLink(prepared, false, "torbox"))
        assertFalse(sel.isCachedDebridLink(uncachedTorrent("2160p").copy(url = "https://torbox.example/dl/u.mkv"), true, "torbox"))
        assertFalse(
            sel.isCachedDebridLink(prepared.copy(addonId = "plugin:scraper"), true, "torbox"),
            "only an installed add-on's torrent carries a local cache status",
        )
        assertEquals(listOf(0), pick(listOf(prepared, plain("2160p")), cachedOnly = true).ranked)
    }

    @Test
    fun anAuthoritativeProviderBeatsAMarkerThatNamesNoService() {
        val sel = StreamAutoPlaySelector
        // Prepared through TorBox (its cache status says so), with a generic bolt in its name; the
        // active resolver then changed to Premiumize.
        val prepared = cachedTorrent("2160p \u26A1", provider = "torbox").copy(url = "https://torbox.example/dl/abc.mkv")
        assertTrue(with(com.nuvio.app.features.debrid.DebridStreamPresentation) { prepared.isAddonMarkedCachedDirectLink })
        assertFalse(sel.isCachedDebridLink(prepared, true, "premiumize"), "the cache status decides, not the bolt")
        assertTrue(sel.isCachedDebridLink(prepared, true, "torbox"))
        assertEquals(0, StreamQualityRank.key(prepared, "premiumize").cached)
        assertEquals(1, StreamQualityRank.key(prepared, "torbox").cached)
        assertEquals(0, StreamQualityRank.key(StreamFactsParser.parse(prepared), prepared, "premiumize").cached)
        assertEquals(emptyList(), pick(listOf(prepared), active = "premiumize", cachedOnly = true).ranked)

        // A direct-debrid result's service decides the same way.
        val direct = directDebrid("2160p \u26A1", service = "realdebrid").copy(url = "https://rd.example/dl/x.mkv")
        assertFalse(sel.isCachedDebridLink(direct, true, "torbox"))

        // Without any provider data the marker still decides: a bolt matches any active service.
        val marked = marked("2160p \u26A1")
        assertTrue(sel.isCachedDebridLink(marked, true, "premiumize"))
        assertEquals(1, StreamQualityRank.key(marked, "premiumize").cached)
    }

    @Test
    fun aCometBoltTagNamesItsService() {
        val sel = StreamAutoPlaySelector
        // The Comet row from StreamFactsParserTest.cometRow.
        val comet = StreamItem(
            name = "[TB\u26A1] Comet\n2160p",
            description = "\uD83D\uDCC4 Animals.2026.2160p.NF.WEB-DL.DDP5.1.Atmos.DV.HDR.H.265-XEBEC\n" +
                "\uD83D\uDCF9 hevc \u2022 DV \u2022 HDR | \uD83D\uDD0A Atmos \u2022 Dolby Digital Plus \u2022 5.1\n" +
                "\u2B50 WEB-DL | \uD83C\uDFF7\uFE0F XEBEC\n" +
                "\uD83D\uDCBE 12.2 GB \uD83D\uDD0E StremThru",
            url = "https://comet.example/playback/torbox/xyz",
            addonName = "Comet",
            addonId = "addon:comet.elfhosted.com",
        )
        assertEquals("torbox", with(com.nuvio.app.features.debrid.DebridStreamPresentation) { comet.addonMarkedCachedService })
        assertTrue(sel.isCachedDebridLink(comet, true, "torbox"))
        assertFalse(sel.isCachedDebridLink(comet, true, "premiumize"))
        // The bolt alone marks it cached; an hourglass tag is uncached whatever the service.
        assertEquals(
            com.nuvio.app.features.debrid.DebridStreamPresentation.AddonCachedMarker.CACHED,
            with(com.nuvio.app.features.debrid.DebridStreamPresentation) { marked("[RD\u26A1] Comet 2160p").addonCachedMarker },
        )
        assertEquals(
            com.nuvio.app.features.debrid.DebridStreamPresentation.AddonCachedMarker.UNCACHED,
            with(com.nuvio.app.features.debrid.DebridStreamPresentation) { marked("[TB\u23F3] Comet 2160p").addonCachedMarker },
        )
        assertFalse(sel.isCachedDebridLink(marked("[TB\u23F3] Comet 2160p"), true, "torbox"))
    }

    @Test
    fun aMarkedCachedLinkRanksAsCachedSoSizeBreaksTheTie() {
        val torrent = torrent("Movie 2160p HDR", StreamDebridCacheState.CACHED, size = 10 * gb)
        val link = marked("[TB+] Torrentio Movie 2160p HDR", size = 40 * gb)
        val streams = listOf(torrent, link)

        assertEquals(listOf(link, torrent), StreamQualityRank.rankBest(streams, "torbox"))
        assertEquals(listOf(1, 0), pick(streams, active = "torbox").ranked)
        // Cached on another service than the active one: the managed cached torrent wins.
        val rdTorrent = torrent("Movie 2160p HDR", StreamDebridCacheState.CACHED, provider = "realdebrid", size = 10 * gb)
        assertEquals(listOf(rdTorrent, link), StreamQualityRank.rankBest(listOf(rdTorrent, link), "realdebrid"))
        assertEquals(listOf(0, 1), pick(listOf(rdTorrent, link), active = "realdebrid").ranked)
        // The walk ranks the same way.
        val walk = StreamAutoPlaySelector.selectAutoPlayStream(
            streams = streams,
            mode = StreamAutoPlayMode.FIRST_STREAM,
            regexPattern = "",
            source = StreamAutoPlaySource.ALL_SOURCES,
            installedAddonNames = setOf("Torrentio"),
            selectedAddons = emptySet(),
            selectedPlugins = emptySet(),
            debridEnabled = true,
            activeResolverProviderId = "torbox",
            ranking = StreamAutoPlayRanking.BEST_QUALITY,
        )
        assertEquals(link, walk)
    }

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
