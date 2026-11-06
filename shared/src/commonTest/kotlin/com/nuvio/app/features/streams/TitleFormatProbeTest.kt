package com.nuvio.app.features.streams

import com.nuvio.app.features.addons.AddonManifest
import com.nuvio.app.features.addons.AddonResource
import com.nuvio.app.features.addons.ManagedAddon
import com.nuvio.app.features.debrid.DebridSettings
import com.nuvio.app.features.debrid.DebridProviders
import com.nuvio.app.features.streams.TitleFormatBadge.DOLBY_ATMOS
import com.nuvio.app.features.streams.TitleFormatBadge.DOLBY_VISION
import com.nuvio.app.features.streams.TitleFormatBadge.DTS_X
import com.nuvio.app.features.streams.TitleFormatBadge.UHD_4K
import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.CompletableDeferred
import kotlinx.coroutines.ExperimentalCoroutinesApi
import kotlinx.coroutines.awaitCancellation
import kotlinx.coroutines.delay
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.test.TestScope
import kotlinx.coroutines.test.runCurrent
import kotlinx.coroutines.test.runTest
import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertFalse
import kotlin.test.assertTrue

/**
 * [TitleFormatProbeEngine] with a fake [TitleFormatFetcher], a fake clock and a `MutableStateFlow`
 * standing in for the picker. The engine's jobs and the picker fold run on `backgroundScope`.
 */
@OptIn(ExperimentalCoroutinesApi::class)
class TitleFormatProbeTest {

    private val movie = TitleFormatRequest(type = "movie", videoId = "tt0133093", season = null, episode = null)

    private val fourKDv = "Movie.2024.2160p.WEB-DL.DV.HDR10-GRP"
    private val everything = "Movie.2024.2160p.UHD.BluRay.REMUX.DV.HDR10.TrueHD.Atmos.DTS:X.7.1-GRP"

    private fun stream(addon: String, name: String) = StreamItem(
        name = name,
        url = "https://example.com/$addon.mkv",
        addonName = addon,
        addonId = "addon:$addon",
    )

    private fun addon(id: String, idPrefixes: List<String> = listOf("tt"), enabled: Boolean = true): ManagedAddon {
        val url = "https://$id.example.com/manifest.json"
        return ManagedAddon(
            manifestUrl = url,
            manifest = AddonManifest(
                id = id,
                name = id,
                description = "",
                version = "1.0.0",
                resources = listOf(AddonResource("stream", listOf("movie", "series"), idPrefixes)),
                types = listOf("movie", "series"),
                transportUrl = url,
            ),
            enabled = enabled,
        )
    }

    private class FakeFetcher : TitleFormatFetcher {
        val embedded = mutableMapOf<String, List<StreamItem>>()
        /** (add-on name, id asked) per fetch, in start order. */
        val fetched = mutableListOf<Pair<String, String>>()
        val imdbCalls = mutableListOf<Int>()
        var imdb: String? = null
        var behavior: suspend (InstalledStreamAddonTarget) -> List<StreamItem> = { emptyList() }

        override fun embeddedStreams(videoId: String): List<StreamItem> = embedded[videoId].orEmpty()

        override suspend fun streams(target: InstalledStreamAddonTarget, type: String): List<StreamItem> {
            fetched += target.addonName to target.videoId
            return behavior(target)
        }

        override suspend fun imdbFor(tmdbId: Int, type: String): String? {
            imdbCalls += tmdbId
            return imdb
        }

        override suspend fun annotateCache(group: AddonStreamGroup): AddonStreamGroup = group
    }

    private class Rig(
        val fetcher: FakeFetcher,
        val engine: TitleFormatProbeEngine,
        val picker: MutableStateFlow<StreamsUiState>,
    ) {
        var now = 1_000_000L
        var settings = DebridSettings()
        var addons: List<ManagedAddon> = emptyList()
        var plugins: List<String> = emptyList()
    }

    private fun TestScope.rig(vararg addonIds: String): Rig {
        val fetcher = FakeFetcher()
        val picker = MutableStateFlow(StreamsUiState())
        lateinit var rig: Rig
        val engine = TitleFormatProbeEngine(
            fetcher = fetcher,
            clock = { rig.now },
            scope = backgroundScope,
            settings = { rig.settings },
            installedAddons = { rig.addons },
            pickerState = picker,
            pluginScrapers = { rig.plugins },
        )
        rig = Rig(fetcher, engine, picker)
        rig.addons = addonIds.map { addon(it) }
        return rig
    }

    /**
     * Runs everything the engine launched on `backgroundScope`, including virtual-time delays and
     * timeouts. `advanceUntilIdle()` ignores background work (its idle check is non-strict), so it
     * would return before the probe even started.
     */
    private fun TestScope.settle() {
        testScheduler.advanceTimeBy(TitleFormatProbeEngine.PROBE_TIMEOUT_MS + 1)
        testScheduler.runCurrent()
    }

    private fun Rig.badges(request: TitleFormatRequest = movie) = engine.state(request).badges

    // --- targeting --------------------------------------------------------------------------

    @Test
    fun onlyTheFirstThreeMatchingAddonsAreAsked() = runTest {
        val rig = rig("a1", "a2", "a3", "a4", "a5")
        rig.engine.start(movie)
        settle()

        assertEquals(setOf("a1", "a2", "a3"), rig.fetcher.fetched.map { it.first }.toSet())
        assertEquals(3, rig.fetcher.fetched.size)
    }

    @Test
    fun disabledAndNonMatchingAddonsDoNotUseUpTheThreeSlots() = runTest {
        val rig = rig()
        rig.addons = listOf(
            addon("off", enabled = false),
            addon("tmdb-only", idPrefixes = listOf("tmdb:")),
            addon("a1"), addon("a2"), addon("a3"), addon("a4"),
        )
        rig.engine.start(movie)
        settle()

        assertEquals(setOf("a1", "a2", "a3"), rig.fetcher.fetched.map { it.first }.toSet())
    }

    @Test
    fun tmdbIdIsRemappedToImdbForATtOnlyAddon() = runTest {
        val rig = rig()
        rig.addons = listOf(addon("tt-only", listOf("tt")), addon("open", emptyList()))
        rig.fetcher.imdb = "tt0133093"
        val tmdbRequest = TitleFormatRequest("movie", "tmdb:603", null, null)

        rig.engine.start(tmdbRequest)
        settle()

        assertEquals(listOf(603), rig.fetcher.imdbCalls)
        assertEquals(
            setOf("tt-only" to "tt0133093", "open" to "tmdb:603"),
            rig.fetcher.fetched.toSet(),
        )
    }

    @Test
    fun tmdbIdWithNoImdbMatchSkipsTheTtOnlyAddon() = runTest {
        val rig = rig()
        rig.addons = listOf(addon("tt-only", listOf("tt")), addon("open", emptyList()))
        rig.fetcher.imdb = null

        rig.engine.start(TitleFormatRequest("movie", "tmdb:603", null, null))
        settle()

        assertEquals(listOf("open" to "tmdb:603"), rig.fetcher.fetched)
    }

    @Test
    fun imdbIdRequestNeverCallsTmdb() = runTest {
        val rig = rig("a1")
        rig.engine.start(movie)
        settle()
        assertTrue(rig.fetcher.imdbCalls.isEmpty())
    }

    // --- results ----------------------------------------------------------------------------

    @Test
    fun badgesAreAggregatedAcrossAddonsAndTheProbeSettles() = runTest {
        val rig = rig("a1", "a2")
        rig.fetcher.behavior = { target ->
            if (target.addonName == "a1") listOf(stream("a1", "Movie.2024.2160p.WEB-DL-GRP"))
            else listOf(stream("a2", "Movie.2024.1080p.WEB-DL.DV.Atmos-GRP"))
        }
        rig.engine.start(movie)
        assertTrue(rig.engine.state(movie).isProbing)

        settle()
        val state = rig.engine.state(movie)
        assertEquals(listOf(UHD_4K, DOLBY_VISION, DOLBY_ATMOS), state.badges)
        assertFalse(state.isProbing)
        assertEquals(TitleFormatSource.PROBE, state.source)
    }

    @Test
    fun aTimedOutAddonIsDroppedWhileTheOthersCount() = runTest {
        val rig = rig("slow", "fast")
        rig.fetcher.behavior = { target ->
            if (target.addonName == "slow") {
                delay(TitleFormatProbeEngine.ADDON_TIMEOUT_MS + 12_000)
                listOf(stream("slow", everything))
            } else {
                listOf(stream("fast", fourKDv))
            }
        }
        rig.engine.start(movie)
        settle()

        val state = rig.engine.state(movie)
        assertEquals(listOf(UHD_4K, DOLBY_VISION), state.badges)
        assertFalse(state.isProbing)
    }

    @Test
    fun aFailingAddonDoesNotStopTheOthers() = runTest {
        val rig = rig("bad", "good")
        rig.fetcher.behavior = { target ->
            if (target.addonName == "bad") error("HTTP 500 from https://bad.example.com/secret-key/stream/movie/tt1.json")
            listOf(stream("good", fourKDv))
        }
        rig.engine.start(movie)
        settle()
        assertEquals(listOf(UHD_4K, DOLBY_VISION), rig.badges())
    }

    @Test
    fun embeddedStreamsReplaceTheFanOutWithNoFetch() = runTest {
        val rig = rig("a1")
        rig.fetcher.embedded[movie.videoId] = listOf(stream("embedded", fourKDv))
        rig.engine.start(movie)
        settle()

        assertTrue(rig.fetcher.fetched.isEmpty())
        assertEquals(listOf(UHD_4K, DOLBY_VISION), rig.badges())
        assertFalse(rig.engine.state(movie).isProbing)
    }

    // --- cancel and early exit --------------------------------------------------------------

    @Test
    fun cancelStopsInFlightFetches() = runTest {
        val rig = rig("a1", "a2", "a3")
        var cancelled = 0
        rig.fetcher.behavior = {
            try {
                awaitCancellation()
            } catch (e: CancellationException) {
                cancelled++
                throw e
            }
        }
        rig.engine.start(movie)
        runCurrent()
        assertEquals(3, rig.fetcher.fetched.size)
        assertTrue(rig.engine.state(movie).isProbing)

        rig.engine.cancel(movie)
        runCurrent()

        assertEquals(3, cancelled)
        assertFalse(rig.engine.state(movie).isProbing)
        // Nothing was learned, so nothing is cached: a later start probes again.
        rig.engine.start(movie)
        runCurrent()
        assertEquals(6, rig.fetcher.fetched.size)
    }

    @Test
    fun earlyExitFiresWhenFourKDolbyVisionAtmosAndDtsXAreAllLit() = runTest {
        val rig = rig("first", "second")
        var secondFinished = false
        var secondCancelled = false
        rig.fetcher.behavior = { target ->
            if (target.addonName == "first") {
                // Both add-ons are in flight before the first one completes the set.
                delay(100)
                listOf(stream("first", everything))
            } else {
                try {
                    delay(5_000)
                    secondFinished = true
                } catch (e: CancellationException) {
                    secondCancelled = true
                    throw e
                }
                emptyList()
            }
        }
        rig.engine.start(movie)
        settle()

        assertEquals(listOf(UHD_4K, DOLBY_VISION, DOLBY_ATMOS, DTS_X), rig.badges())
        assertTrue(secondCancelled)
        assertFalse(secondFinished)
        assertFalse(rig.engine.state(movie).isProbing)
    }

    @Test
    fun hdr10PlusAloneDoesNotStopTheProbeBecauseDolbyVisionCanStillArrive() = runTest {
        val rig = rig("first", "second")
        var secondFinished = false
        rig.fetcher.behavior = { target ->
            if (target.addonName == "first") {
                listOf(stream("first", "Movie.2024.2160p.UHD.BluRay.HDR10Plus.TrueHD.Atmos.DTS:X.7.1-GRP"))
            } else {
                delay(1_000)
                secondFinished = true
                listOf(stream("second", "Movie.2024.1080p.WEB-DL.DV-GRP"))
            }
        }
        rig.engine.start(movie)
        settle()

        assertTrue(secondFinished)
        assertEquals(listOf(UHD_4K, DOLBY_VISION, DOLBY_ATMOS, DTS_X), rig.badges())
    }

    @Test
    fun aFilteredOutSiblingWithTheSamePlaybackFieldsIsNeverAdvertised() {
        val saved = StreamPresentationPlatform.filtersApplyToAllStreams
        StreamPresentationPlatform.filtersApplyToAllStreams = true
        try {
            val dv = stream("a1", fourKDv)
            val plain = dv.copy(name = "Movie.2024.1080p.WEB-DL-GRP")
            val group = AddonStreamGroup(addonName = "a1", addonId = "addon:a1", streams = listOf(dv, plain), isLoading = false)
            val settings = DebridSettings(streamDolbyVisionFilter = com.nuvio.app.features.debrid.DebridStreamFeatureFilter.EXCLUDE)

            val presented = presentForBadges(group, settings)

            assertEquals(listOf(plain), presented)
            assertEquals(emptyList(), TitleFormatBadges.aggregateStreams(presented))
        } finally {
            StreamPresentationPlatform.filtersApplyToAllStreams = saved
        }
    }

    // --- cache ------------------------------------------------------------------------------

    @Test
    fun aCacheHitOnASecondStartMakesNoFetch() = runTest {
        val rig = rig("a1", "a2")
        rig.fetcher.behavior = { target -> listOf(stream(target.addonName, fourKDv)) }
        rig.engine.start(movie)
        settle()
        assertEquals(2, rig.fetcher.fetched.size)

        rig.engine.start(movie)
        settle()

        assertEquals(2, rig.fetcher.fetched.size)
        assertEquals(listOf(UHD_4K, DOLBY_VISION), rig.badges())
        assertFalse(rig.engine.state(movie).isProbing)
    }

    @Test
    fun aPositiveCacheEntryExpiresAfterSixHours() = runTest {
        val rig = rig("a1")
        rig.fetcher.behavior = { listOf(stream("a1", fourKDv)) }
        rig.engine.start(movie)
        settle()
        assertEquals(1, rig.fetcher.fetched.size)

        rig.now += TitleFormatProbeCache.POSITIVE_TTL_MS - 1
        rig.engine.start(movie)
        settle()
        assertEquals(1, rig.fetcher.fetched.size)

        rig.now += 1
        rig.engine.start(movie)
        settle()
        assertEquals(2, rig.fetcher.fetched.size)
    }

    @Test
    fun anExpiredAnswerIsNotCarriedIntoTheFreshProbe() = runTest {
        val rig = rig("a1")
        var name = fourKDv
        rig.fetcher.behavior = { listOf(stream("a1", name)) }
        rig.engine.start(movie)
        settle()
        val firstGeneration = rig.engine.state(movie).generation
        assertEquals(listOf(UHD_4K, DOLBY_VISION), rig.badges())

        name = "Movie.2024.1080p.WEB-DL-GRP"
        rig.now += TitleFormatProbeCache.POSITIVE_TTL_MS
        rig.engine.start(movie)
        settle()

        assertEquals(2, rig.fetcher.fetched.size)
        assertEquals(emptyList(), rig.badges())
        assertTrue(rig.engine.state(movie).generation != firstGeneration)
        // And the cache holds the fresh answer only: a restart is a hit with no 4K.
        rig.engine.start(movie)
        settle()
        assertEquals(2, rig.fetcher.fetched.size)
        assertEquals(emptyList(), rig.badges())
    }

    @Test
    fun changingTheDebridApiKeyMissesTheCache() = runTest {
        val rig = rig("a1")
        rig.fetcher.behavior = { listOf(stream(it.addonName, fourKDv)) }
        rig.settings = DebridSettings(enabled = true, providerApiKeys = mapOf(DebridProviders.TORBOX_ID to "key-a"))
        rig.engine.start(movie)
        settle()
        assertEquals(1, rig.fetcher.fetched.size)

        rig.settings = DebridSettings(enabled = true, providerApiKeys = mapOf(DebridProviders.TORBOX_ID to "key-b"))
        rig.engine.start(movie)
        settle()

        assertEquals(2, rig.fetcher.fetched.size)
    }

    @Test
    fun anExpiredPickerAnswerAfterACancelledProbeIsNotCarriedOn() = runTest {
        val rig = rig("a1")
        val gate = CompletableDeferred<List<StreamItem>>()
        rig.fetcher.behavior = { gate.await() }
        rig.engine.start(movie)
        runCurrent()
        rig.engine.cancel(movie)
        rig.picker.value = pickerState(token(manual = true), stream("picker", fourKDv))
        runCurrent()
        assertEquals(listOf(UHD_4K, DOLBY_VISION), rig.badges())
        rig.picker.value = StreamsUiState()
        runCurrent()

        rig.now += TitleFormatProbeCache.POSITIVE_TTL_MS
        rig.fetcher.behavior = { listOf(stream("a1", "Movie.2024.1080p.WEB-DL-GRP")) }
        rig.engine.start(movie)
        settle()

        assertEquals(emptyList(), rig.badges())
    }

    @Test
    fun badgesCarriedFromAnInterruptedRunDoNotStopTheFreshProbeEarly() = runTest {
        val rig = rig("first", "second")
        val gate = CompletableDeferred<List<StreamItem>>()
        rig.fetcher.behavior = { target ->
            if (target.addonName == "first") listOf(stream("first", "Movie.2024.2160p.WEB-DL.DV.Atmos-GRP")) else gate.await()
        }
        rig.engine.start(movie)
        runCurrent()
        rig.engine.cancel(movie) // interrupted with 4K + DV + Atmos showing, nothing cached

        var secondFinished = false
        rig.fetcher.behavior = { target ->
            if (target.addonName == "first") {
                listOf(stream("first", "Movie.2024.1080p.WEB-DL.DTS:X-GRP"))
            } else {
                delay(1_000)
                secondFinished = true
                listOf(stream("second", "Movie.2024.2160p.WEB-DL.DV.Atmos-GRP"))
            }
        }
        rig.engine.start(movie)
        settle()

        assertTrue(secondFinished, "the run's own answer was not complete, so it kept fetching")
    }

    @Test
    fun anEmptyCacheEntryExpiresAfterThirtyMinutes() = runTest {
        val rig = rig("a1")
        rig.engine.start(movie) // the add-on answers, with nothing format-worthy
        settle()
        assertEquals(1, rig.fetcher.fetched.size)

        rig.now += TitleFormatProbeCache.EMPTY_TTL_MS - 1
        rig.engine.start(movie)
        settle()
        assertEquals(1, rig.fetcher.fetched.size)

        rig.now += 1
        rig.engine.start(movie)
        settle()
        assertEquals(2, rig.fetcher.fetched.size)
    }

    @Test
    fun changingTheAddonSetMissesTheCache() = runTest {
        val rig = rig("a1")
        rig.fetcher.behavior = { listOf(stream(it.addonName, fourKDv)) }
        rig.engine.start(movie)
        settle()
        assertEquals(1, rig.fetcher.fetched.size)

        rig.addons = rig.addons + addon("a2")
        rig.engine.start(movie)
        settle()

        assertEquals(3, rig.fetcher.fetched.size)
    }

    @Test
    fun changingTheDebridFlagMissesTheCache() = runTest {
        val rig = rig("a1")
        rig.fetcher.behavior = { listOf(stream(it.addonName, fourKDv)) }
        rig.engine.start(movie)
        settle()
        assertEquals(1, rig.fetcher.fetched.size)

        rig.settings = DebridSettings(enabled = true, providerApiKeys = mapOf(DebridProviders.TORBOX_ID to "key"))
        assertTrue(rig.settings.canResolvePlayableLinks)
        rig.engine.start(movie)
        settle()

        assertEquals(2, rig.fetcher.fetched.size)
    }

    @Test
    fun anAllFailedProbeIsNotCached() = runTest {
        val rig = rig("a1", "a2")
        rig.fetcher.behavior = { error("boom") }
        rig.engine.start(movie)
        settle()
        assertEquals(emptyList(), rig.badges())
        assertFalse(rig.engine.state(movie).isProbing)
        assertEquals(2, rig.fetcher.fetched.size)

        rig.engine.start(movie)
        settle()
        assertEquals(4, rig.fetcher.fetched.size)
    }

    @Test
    fun anAllTimedOutProbeIsNotCached() = runTest {
        val rig = rig("a1")
        rig.fetcher.behavior = { delay(60_000); emptyList() }
        rig.engine.start(movie)
        settle()
        assertFalse(rig.engine.state(movie).isProbing)

        rig.engine.start(movie)
        settle()
        assertEquals(2, rig.fetcher.fetched.size)
    }

    // --- picker fold ------------------------------------------------------------------------

    private fun pickerState(token: String, vararg streams: StreamItem, loading: Boolean = false) = StreamsUiState(
        requestToken = token,
        groups = listOf(AddonStreamGroup(addonName = "picker", addonId = "addon:picker", streams = streams.toList())),
        isAnyLoading = loading,
    )

    private fun token(manual: Boolean) =
        StreamsRepository.requestToken("movie", movie.videoId, null, null, manualSelection = manual)

    @Test
    fun pickerFoldGrowsBadgesAndRecordsPickerSourceAndStillWorksAfterCancel() = runTest {
        val rig = rig("a1")
        val gate = CompletableDeferred<List<StreamItem>>()
        rig.fetcher.behavior = { gate.await() }
        rig.engine.start(movie)
        runCurrent()
        assertTrue(rig.engine.state(movie).isProbing)

        rig.picker.value = pickerState(token(manual = true), stream("picker", fourKDv))
        runCurrent()
        assertEquals(listOf(UHD_4K, DOLBY_VISION), rig.badges())
        assertEquals(TitleFormatSource.PICKER, rig.engine.state(movie).source)

        rig.engine.cancel(movie)
        runCurrent()
        assertFalse(rig.engine.state(movie).isProbing)

        // The fold is independent of the probe job: it keeps landing after cancel, and only grows.
        rig.picker.value = pickerState(
            token(manual = false),
            stream("picker", fourKDv),
            stream("picker", "Movie.2024.1080p.BluRay.TrueHD.Atmos.DTS:X.7.1-GRP"),
        )
        runCurrent()
        assertEquals(listOf(UHD_4K, DOLBY_VISION, DOLBY_ATMOS, DTS_X), rig.badges())
        assertEquals(TitleFormatSource.PICKER, rig.engine.state(movie).source)

        // The fold wrote the cache entry (source PICKER), so a restart answers without a fetch.
        val fetchesBefore = rig.fetcher.fetched.size
        rig.engine.start(movie)
        runCurrent()
        assertEquals(fetchesBefore, rig.fetcher.fetched.size)
        assertEquals(TitleFormatSource.PICKER, rig.engine.state(movie).source)
        assertEquals(listOf(UHD_4K, DOLBY_VISION, DOLBY_ATMOS, DTS_X), rig.badges())
    }

    @Test
    fun aPartialPickerAnswerShowsButIsNotCached() = runTest {
        val rig = rig("a1")
        val gate = CompletableDeferred<List<StreamItem>>()
        rig.fetcher.behavior = { gate.await() }
        rig.engine.start(movie)
        runCurrent()

        rig.picker.value = pickerState(token(manual = true), stream("picker", fourKDv), loading = true)
        runCurrent()
        assertEquals(listOf(UHD_4K, DOLBY_VISION), rig.badges())

        rig.engine.cancel(movie)
        runCurrent()
        val fetchesBefore = rig.fetcher.fetched.size
        rig.engine.start(movie)
        runCurrent()
        assertEquals(fetchesBefore + 1, rig.fetcher.fetched.size, "a partial picker answer must not be a cache hit")
    }

    @Test
    fun aPickerThatSettledBeforeStartIsFolded() = runTest {
        val rig = rig("a1")
        val other = TitleFormatRequest(type = "movie", videoId = "tt9999999", season = null, episode = null)
        rig.engine.start(other) // the fold collector is already running
        settle()
        rig.picker.value = pickerState(token(manual = true), stream("picker", fourKDv))
        runCurrent()
        assertEquals(emptyList(), rig.badges())

        rig.fetcher.behavior = { CompletableDeferred<List<StreamItem>>().await() }
        rig.engine.start(movie)
        runCurrent()

        assertEquals(listOf(UHD_4K, DOLBY_VISION), rig.badges())
        assertEquals(TitleFormatSource.PICKER, rig.engine.state(movie).source)
    }

    @Test
    fun aPickerOpenedAfterAConfigChangeDoesNotWriteTheOldEntry() = runTest {
        val rig = rig("a1")
        rig.engine.start(movie)
        settle() // answered empty under the default settings, cached
        rig.settings = DebridSettings(enabled = true, providerApiKeys = mapOf(DebridProviders.TORBOX_ID to "key-b"))

        rig.picker.value = pickerState(token(manual = true), stream("picker", fourKDv))
        runCurrent()
        assertEquals(emptyList(), rig.badges(), "not folded into the old configuration's entry")

        rig.settings = DebridSettings()
        val fetchesBefore = rig.fetcher.fetched.size
        rig.picker.value = StreamsUiState()
        runCurrent()
        rig.engine.start(movie)
        settle()
        assertEquals(fetchesBefore, rig.fetcher.fetched.size, "the old entry is still a hit")
        assertEquals(emptyList(), rig.badges(), "and holds no formats from the other configuration")
    }

    @Test
    fun stateBeforeStartHidesAnswersFromAnotherConfigurationOrPastExpiry() = runTest {
        val rig = rig("a1")
        rig.fetcher.behavior = { listOf(stream("a1", fourKDv)) }
        rig.engine.start(movie)
        settle()
        assertEquals(listOf(UHD_4K, DOLBY_VISION), rig.badges())

        rig.settings = DebridSettings(streamDolbyVisionFilter = com.nuvio.app.features.debrid.DebridStreamFeatureFilter.EXCLUDE)
        assertEquals(emptyList(), rig.badges(), "filters changed: not shown before the next start")
        rig.settings = DebridSettings()
        assertEquals(listOf(UHD_4K, DOLBY_VISION), rig.badges())

        rig.now += TitleFormatProbeCache.POSITIVE_TTL_MS
        assertEquals(emptyList(), rig.badges(), "expired: not shown before the next start")
    }

    @Test
    fun aPickerOpenedDuringTheDwellIsFoldedIntoAWatchedRequest() = runTest {
        val rig = rig("a1")
        rig.engine.watch(movie) // Detail appeared; the dwell has not elapsed, nothing fetched
        runCurrent()
        rig.picker.value = pickerState(token(manual = true), stream("picker", fourKDv))
        runCurrent()
        rig.picker.value = StreamsUiState() // the picker closed and cleared
        runCurrent()

        assertEquals(listOf(UHD_4K, DOLBY_VISION), rig.badges())
        assertEquals(0, rig.fetcher.fetched.size)
        rig.engine.start(movie) // the picker's settled answer was cached
        settle()
        assertEquals(0, rig.fetcher.fetched.size)
        assertEquals(listOf(UHD_4K, DOLBY_VISION), rig.badges())
    }

    @Test
    fun aPickerAnswerAfterExpiryStartsAFreshGeneration() = runTest {
        val rig = rig("a1")
        rig.fetcher.behavior = { listOf(stream("a1", fourKDv)) }
        rig.engine.start(movie)
        settle()
        val firstGeneration = rig.engine.state(movie).generation

        rig.now += TitleFormatProbeCache.POSITIVE_TTL_MS
        rig.engine.watch(movie)
        rig.picker.value = pickerState(token(manual = true), stream("picker", "Movie.2024.1080p.WEB-DL-GRP"))
        runCurrent()

        assertEquals(emptyList(), rig.badges())
        assertTrue(rig.engine.state(movie).generation != firstGeneration)
        rig.picker.value = StreamsUiState()
        runCurrent()
        rig.engine.start(movie) // the picker's fresh empty answer is the hit, with no 4K
        settle()
        assertEquals(1, rig.fetcher.fetched.size)
        assertEquals(emptyList(), rig.badges())
    }

    @Test
    fun changingThePluginScrapersMissesTheCache() = runTest {
        val rig = rig("a1")
        rig.plugins = listOf("https://repo.example.com#p1")
        rig.engine.watch(movie)
        rig.picker.value = pickerState(token(manual = true), stream("picker", fourKDv))
        runCurrent()
        rig.picker.value = StreamsUiState()
        runCurrent()

        rig.plugins = emptyList() // the plugin that supplied the 4K was disabled
        rig.engine.start(movie)
        settle()

        assertEquals(1, rig.fetcher.fetched.size)
        assertEquals(emptyList(), rig.badges())
    }

    @Test
    fun pickerEmissionsForAnotherTitleAreIgnored() = runTest {
        val rig = rig("a1")
        rig.engine.start(movie)
        settle()

        val other = StreamsRepository.requestToken("movie", "tt9999999", null, null, manualSelection = true)
        rig.picker.value = pickerState(other, stream("picker", fourKDv))
        runCurrent()

        assertEquals(emptyList(), rig.badges())
    }

    @Test
    fun badgesNeverShrinkWhenALaterPickerEmissionHasFewerFormats() = runTest {
        val rig = rig("a1")
        rig.engine.start(movie)
        settle()

        rig.picker.value = pickerState(token(true), stream("picker", fourKDv))
        runCurrent()
        rig.picker.value = pickerState(token(true), stream("picker", "Movie.2024.1080p.WEB-DL-GRP"))
        runCurrent()

        assertEquals(listOf(UHD_4K, DOLBY_VISION), rig.badges())
    }
}
