package com.nuvio.app.features.mdblist

import com.nuvio.app.features.tracking.TrackingExternalIds
import com.nuvio.app.features.tracking.TrackingMediaKind
import com.nuvio.app.features.tracking.TrackingMediaReference
import com.nuvio.app.features.tracking.buildTrackingMediaReference
import kotlinx.coroutines.CompletableDeferred
import kotlinx.coroutines.async
import kotlinx.coroutines.launch
import kotlinx.coroutines.test.runCurrent
import kotlinx.coroutines.test.runTest
import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertFalse
import kotlin.test.assertNull
import kotlin.test.assertSame
import kotlin.test.assertTrue

/** Upstream NuvioTV facf25ec3: episodes move between the add-on's seasons and TMDB's. */
@OptIn(kotlinx.coroutines.ExperimentalCoroutinesApi::class)
class MdbListEpisodeMappingServiceTest {
    @Test
    fun `episodes move between one TMDB season and the add-on's two seasons in both directions`() = runTest {
        val mapping = splitAnimeMapping()
        assertTrue(mapping.remaps)
        assertEquals(2, mapping.toAddon(1, 35)?.season)
        assertEquals(11, mapping.toAddon(1, 35)?.episode)
        assertEquals("tt1:2:11", mapping.toAddon(1, 35)?.videoId)
        assertEquals(1 to 35, mapping.toTmdb(2, 11, "tt1:2:11")?.let { it.season to it.episode })
        assertEquals(1 to 35, mapping.toTmdb(2, 11)?.let { it.season to it.episode })
        assertEquals(1 to 24, mapping.toTmdb(1, 24)?.let { it.season to it.episode })
        assertEquals(1 to 1, mapping.toAddon(1, 1)?.let { it.season to it.episode })
        assertNull(mapping.toAddon(1, 49))
        assertFalse(MdbListEpisodeMapping.Unchanged.remaps)
        assertNull(MdbListEpisodeMapping.Unchanged.toAddon(1, 35))
        assertNull(MdbListEpisodeMapping.Unchanged.toTmdb(2, 11))
    }

    @Test
    fun `a matching title wins over the position in the list`() = runTest {
        // The add-on drops a recap episode TMDB keeps as S1E3, so positions drift by one from there.
        val addon = MdbListTestAddonEpisodes(seasons = listOf(2, 2), titles = mapOf(
            1 to 1 to "Pilot", 1 to 2 to "Second", 2 to 1 to "Fourth", 2 to 2 to "Fifth",
        ))
        val tmdb = MdbListTestTmdbSeasons(seasons = listOf(5), titles = mapOf(
            1 to 1 to "Pilot", 1 to 2 to "Second", 1 to 3 to "Recap", 1 to 4 to "Fourth", 1 to 5 to "Fifth",
        ))
        val mapping = mdbListTestEpisodeMappings(addon, tmdb).resolve("tt1", 1)!!
        assertEquals(2 to 2, mapping.toAddon(1, 5)?.let { it.season to it.episode })
        assertEquals(1 to 5, mapping.toTmdb(2, 2)?.let { it.season to it.episode })
        // The recap has no add-on episode with its title, so it falls back to its position.
        assertEquals(2 to 1, mapping.toAddon(1, 3)?.let { it.season to it.episode })
    }

    @Test
    fun `add-on episodes are written to MDBList in TMDB numbering`() = runTest {
        val tmdb = MdbListTestTmdbSeasons(seasons = listOf(48), lookup = mapOf("tt1" to 1))
        val service = mdbListTestEpisodeMappings(MdbListTestAddonEpisodes(seasons = listOf(24, 24)), tmdb)
        val mapped = service.toMdbListNumbering(episodeReference(2, 11), mediaIndex = null)
        assertEquals(1, mapped.episode?.season)
        assertEquals(35, mapped.episode?.number)
        assertEquals("tt1:2:11", mapped.catalog?.videoId)
        assertTrue(service.cached("tt1")!!.remaps)
        // The TMDB id came from the imdb lookup, once.
        assertEquals(listOf("find:tt1:", "counts:1", "season:1:1"), tmdb.calls)
    }

    @Test
    fun `the show's TMDB id from MDBList's own records skips the lookup`() = runTest {
        val tmdb = MdbListTestTmdbSeasons(seasons = listOf(48))
        val service = mdbListTestEpisodeMappings(MdbListTestAddonEpisodes(seasons = listOf(24, 24)), tmdb)
        val index = MdbListMediaIndex.watchedOnly(listOf(mdbListTestEpisode(1, 1)))
        val mapped = service.toMdbListNumbering(episodeReference(2, 11), mediaIndex = index)
        assertEquals(1 to 35, mapped.episode?.let { it.season to it.number })
        assertEquals(listOf("counts:1", "season:1:1"), tmdb.calls)
    }

    @Test
    fun `shows split the same way keep their numbers without loading TMDB seasons`() = runTest {
        val tmdb = MdbListTestTmdbSeasons(seasons = listOf(24, 24), lookup = mapOf("tt1" to 1))
        val service = mdbListTestEpisodeMappings(MdbListTestAddonEpisodes(seasons = listOf(24, 24)), tmdb)
        val reference = episodeReference(2, 11)
        assertSame(reference, service.toMdbListNumbering(reference, mediaIndex = null))
        assertFalse(service.cached("tt1")!!.remaps)
        assertEquals(listOf("find:tt1:", "counts:1"), tmdb.calls)
    }

    @Test
    fun `shows with the same seasons but merged two-parters keep their numbers`() = runTest {
        val tmdb = MdbListTestTmdbSeasons(seasons = listOf(23, 24), lookup = mapOf("tt1" to 1))
        val service = mdbListTestEpisodeMappings(MdbListTestAddonEpisodes(seasons = listOf(24, 24)), tmdb)
        val reference = episodeReference(2, 1)
        assertSame(reference, service.toMdbListNumbering(reference, mediaIndex = null))
        assertFalse(service.cached("tt1")!!.remaps)
        assertEquals(listOf("find:tt1:", "counts:1"), tmdb.calls)
    }

    @Test
    fun `movies and references without a catalog or season pass through untouched`() = runTest {
        val service = mdbListTestEpisodeMappings(MdbListTestAddonEpisodes(seasons = listOf(24, 24)), MdbListTestTmdbSeasons(seasons = listOf(48)))
        val movie = TrackingMediaReference(TrackingMediaKind.MOVIE, ids = TrackingExternalIds(imdb = "tt1", tmdb = 1))
        assertSame(movie, service.toMdbListNumbering(movie, mediaIndex = null))
        val noCatalog = episodeReference(2, 11).copy(catalog = null)
        assertSame(noCatalog, service.toMdbListNumbering(noCatalog, mediaIndex = null))
        assertNull(service.cached("tt1"))
    }

    @Test
    fun `missing add-on episodes or an unknown TMDB show leave the mapping unresolved`() = runTest {
        val noAddon = mdbListTestEpisodeMappings(MdbListTestAddonEpisodes(), MdbListTestTmdbSeasons(seasons = listOf(48)))
        assertNull(noAddon.resolve("tt1", 1))
        assertNull(noAddon.cached("tt1"))
        val noTmdb = mdbListTestEpisodeMappings(MdbListTestAddonEpisodes(seasons = listOf(24, 24)), MdbListTestTmdbSeasons(seasons = listOf(48)))
        assertNull(noTmdb.resolve("tt1"))
        assertNull(noTmdb.cached("tt1"))
        val unknown = mdbListTestEpisodeMappings(MdbListTestAddonEpisodes(seasons = listOf(24, 24)), MdbListTestTmdbSeasons(seasons = listOf(48)))
        assertNull(unknown.resolve("tt1", 2))
        assertNull(unknown.cached("tt1"))
    }

    // ── Codex r1 ────────────────────────────────────────────────────────────────────────────

    @Test
    fun `a TMDB season that fails or comes back short leaves the mapping unresolved until it loads`() = runTest {
        // r1 #1: add-on 3 × 10, TMDB 15 + 15; season 1 failing would make season 2 the start of the list.
        val tmdb = MdbListTestTmdbSeasons(seasons = listOf(15, 15), failingSeasons = setOf(1))
        val service = mdbListTestEpisodeMappings(MdbListTestAddonEpisodes(seasons = listOf(10, 10, 10)), tmdb)
        assertNull(service.resolve("tt1", 1))
        assertNull(service.cached("tt1"))
        assertTrue("season:1:1" in tmdb.calls && "season:1:2" in tmdb.calls)

        tmdb.failingSeasons = emptySet()
        tmdb.shortSeasons = mapOf(2 to 3)
        assertNull(service.resolve("tt1", 1))
        assertNull(service.cached("tt1"))

        tmdb.shortSeasons = emptyMap()
        val mapping = service.resolve("tt1", 1)!!
        assertTrue(mapping.remaps)
        assertEquals(1 to 1, mapping.toTmdb(1, 1)?.let { it.season to it.episode })
        assertEquals(2 to 6, mapping.toTmdb(3, 1)?.let { it.season to it.episode })
    }

    @Test
    fun `equal season numbers with a moved boundary still remap`() = runTest {
        // r1 #2: add-on 12 + 36 vs TMDB 24 + 24 share seasons 1 and 2, but add-on S2E1 is TMDB S1E13.
        val tmdb = MdbListTestTmdbSeasons(seasons = listOf(24, 24))
        val mapping = mdbListTestEpisodeMappings(MdbListTestAddonEpisodes(seasons = listOf(12, 36)), tmdb).resolve("tt1", 1)!!
        assertTrue(mapping.remaps)
        assertEquals(1 to 13, mapping.toTmdb(2, 1)?.let { it.season to it.episode })
        assertEquals(2 to 1, mapping.toAddon(1, 13)?.let { it.season to it.episode })
        assertEquals(listOf("counts:1", "season:1:1", "season:1:2"), tmdb.calls)
    }

    @Test
    fun `a longer last season keeps the numbers without loading the seasons`() = runTest {
        // r1 #2: nothing comes after the last season, so an airing season the add-on lists in part moves no episode.
        val tmdb = MdbListTestTmdbSeasons(seasons = listOf(24, 24))
        val service = mdbListTestEpisodeMappings(MdbListTestAddonEpisodes(seasons = listOf(24, 12)), tmdb)
        assertFalse(service.resolve("tt1", 1)!!.remaps)
        assertEquals(listOf("counts:1"), tmdb.calls)
    }

    @Test
    fun `a mapping built on an older add-on set is not reused`() = runTest {
        // r1 #3: the add-on set (or the metadata language) changed; what was built on it is a miss.
        val addon = MdbListTestAddonEpisodes(seasons = listOf(24, 24))
        val service = mdbListTestEpisodeMappings(addon, MdbListTestTmdbSeasons(seasons = listOf(48)))
        assertTrue(service.resolve("tt1", 1)!!.remaps)
        addon.generation = 1
        assertNull(service.cached("tt1"))
        addon.seasons = listOf(48)
        assertFalse(service.resolve("tt1", 1)!!.remaps)
        assertEquals(2, addon.calls.size)

        service.clearCache()
        assertNull(service.cached("tt1"))
    }

    @Test
    fun `a source change during a load hands the result back but does not cache it`() = runTest {
        val addon = MdbListTestAddonEpisodes(seasons = listOf(24, 24)).apply { gate = CompletableDeferred() }
        val service = mdbListTestEpisodeMappings(addon, MdbListTestTmdbSeasons(seasons = listOf(48)))
        val loading = async { service.resolve("tt1", 1) }
        runCurrent()
        addon.generation = 1
        addon.gate!!.complete(Unit)
        assertTrue(loading.await()!!.remaps)
        assertNull(service.cached("tt1"))
    }

    @Test
    fun `a writer waiting on a cancelled load resolves the mapping itself`() = runTest {
        // r1 #4: the owner's cancellation must not read as "no mapping" to the scrobble behind it.
        val addon = MdbListTestAddonEpisodes(seasons = listOf(24, 24)).apply { gate = CompletableDeferred() }
        val service = mdbListTestEpisodeMappings(addon, MdbListTestTmdbSeasons(seasons = listOf(48), lookup = mapOf("tt1" to 1)))
        val owner = launch { service.resolve("tt1", 1) }
        runCurrent()
        val writer = async { service.toMdbListNumbering(episodeReference(2, 11), mediaIndex = null) }
        runCurrent()
        owner.cancel()
        runCurrent()
        addon.gate!!.complete(Unit)
        val mapped = writer.await()
        assertEquals(1 to 35, mapped.episode?.let { it.season to it.number })
        assertEquals(2, addon.calls.size)
        assertTrue(service.cached("tt1")!!.remaps)
    }

    @Test
    fun `a mapping resolved under one id is found under the show's other ids`() = runTest {
        // r1 #8: the detail screen asked for tmdb:1; MDBList's records use tt1 as their canonical id.
        val service = mdbListTestEpisodeMappings(MdbListTestAddonEpisodes(seasons = listOf(24, 24)), MdbListTestTmdbSeasons(seasons = listOf(48)))
        val mapping = service.resolve("tmdb:1", 1, aliases = setOf("tt1", "imdb:tt1", "tmdb:1"))!!
        assertSame(mapping, service.cached("tt1"))
        assertSame(mapping, service.cached("imdb:tt1"))
        assertSame(mapping, service.cached("tmdb:1"))
        assertNull(service.cached("tt2"))
    }

    private fun episodeReference(season: Int, episode: Int) = buildTrackingMediaReference(
        contentType = "series", parentMetaId = "tt1", videoId = "tt1:$season:$episode",
        seasonNumber = season, episodeNumber = episode,
    )
}

/** One TMDB season of 48 episodes that the add-on splits into two seasons of 24. */
internal suspend fun splitAnimeMapping(): MdbListEpisodeMapping = mdbListTestEpisodeMappings(
    MdbListTestAddonEpisodes(seasons = listOf(24, 24)),
    MdbListTestTmdbSeasons(seasons = listOf(48)),
).resolve("tt1", 1)!!

/** A mapping service whose fakes describe the same split show, for the adapter tests. */
internal fun splitAnimeMappings(scope: kotlinx.coroutines.CoroutineScope? = null) = mdbListTestEpisodeMappings(
    MdbListTestAddonEpisodes(seasons = listOf(24, 24)),
    MdbListTestTmdbSeasons(seasons = listOf(48), lookup = mapOf("tt1" to 1)),
    scope,
)
