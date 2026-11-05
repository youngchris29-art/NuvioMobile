package com.nuvio.app.features.mdblist

import com.nuvio.app.features.tracking.TrackingExternalIds
import com.nuvio.app.features.tracking.TrackingMediaKind
import com.nuvio.app.features.tracking.TrackingMediaReference
import com.nuvio.app.features.tracking.buildTrackingMediaReference
import com.nuvio.app.features.trakt.EpisodeMappingEntry
import kotlinx.coroutines.CompletableDeferred
import kotlinx.coroutines.async
import kotlinx.coroutines.launch
import kotlinx.coroutines.test.runCurrent
import kotlinx.coroutines.test.runTest
import kotlin.time.Duration.Companion.hours
import kotlin.time.Duration.Companion.minutes
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
        // The recap has no add-on episode with its title, and its position is the add-on's "Fourth",
        // which TMDB S1E4 owns by title: the recap maps to nothing (Codex r4 #2).
        assertNull(mapping.toAddon(1, 3))
    }

    @Test
    fun `add-on episodes are written to MDBList in TMDB numbering`() = runTest {
        val tmdb = MdbListTestTmdbSeasons(seasons = listOf(48), lookup = mapOf("tt1" to 1))
        val service = mdbListTestEpisodeMappings(MdbListTestAddonEpisodes(seasons = listOf(24, 24)), tmdb)
        val mapped = service.toMdbListNumbering(episodeReference(2, 11), mediaIndex = null)
        assertEquals(1, mapped!!.episode?.season)
        assertEquals(35, mapped!!.episode?.number)
        assertEquals("tt1:2:11", mapped!!.catalog?.videoId)
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
        assertEquals(1 to 35, mapped!!.episode?.let { it.season to it.number })
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
        // The seasons are loaded to check the episodes' identities (Codex r2 #2); untitled, they keep their numbers.
        assertEquals(listOf("find:tt1:", "counts:1", "season:1:1", "season:1:2"), tmdb.calls)
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
    fun `a longer last season keeps the numbers`() = runTest {
        // r1 #2: an airing season the add-on lists in part moves no episode.
        val tmdb = MdbListTestTmdbSeasons(seasons = listOf(24, 24))
        val service = mdbListTestEpisodeMappings(MdbListTestAddonEpisodes(seasons = listOf(24, 12)), tmdb)
        val mapping = service.resolve("tt1", 1)!!
        // r4 #1: the seasons are loaded and the episodes checked even when only the last differs.
        assertEquals(listOf("counts:1", "season:1:1", "season:1:2"), tmdb.calls)
        // r5 #3: TMDB's twelve unaired episodes have no add-on counterpart, so the mapping is kept;
        // the add-on's episodes keep their numbers.
        assertTrue(mapping.remaps)
        assertEquals(2 to 12, mapping.toTmdb(2, 12)?.let { it.season to it.episode })
        assertEquals(2 to 1, mapping.toAddon(2, 1)?.let { it.season to it.episode })
        assertNull(mapping.toAddon(2, 20))
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
    fun `a source change during a load is loaded again under the new source`() = runTest {
        // r1 #3 / r2 #4: the result built on the old list is dropped, not handed back.
        val addon = MdbListTestAddonEpisodes(seasons = listOf(24, 24)).apply { gate = CompletableDeferred() }
        val service = mdbListTestEpisodeMappings(addon, MdbListTestTmdbSeasons(seasons = listOf(48)))
        val loading = async { service.resolve("tt1", 1) }
        runCurrent()
        val gate = addon.gate!!
        addon.gate = null
        addon.generation = 1
        gate.complete(Unit)
        assertTrue(loading.await()!!.remaps)
        assertEquals(2, addon.calls.size)
        assertTrue(service.cached("tt1")!!.remaps)
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
        assertEquals(1 to 35, mapped!!.episode?.let { it.season to it.number })
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

    // ── Codex r2 ────────────────────────────────────────────────────────────────────────────

    @Test
    fun `a boundary moved by one episode remaps when the titles say so`() = runTest {
        // r2 #2: add-on 12 + 13 vs TMDB 13 + 12; the add-on's S2E1 is TMDB's S1E13 by title.
        fun titles(counts: List<Int>, offset: Int) = buildMap {
            var n = offset
            counts.forEachIndexed { index, count -> (1..count).forEach { put(index + 1 to it, "Chapter ${n++}") } }
        }
        val addon = MdbListTestAddonEpisodes(seasons = listOf(12, 13), titles = titles(listOf(12, 13), 1))
        val tmdb = MdbListTestTmdbSeasons(seasons = listOf(13, 12), titles = titles(listOf(13, 12), 1))
        val mapping = mdbListTestEpisodeMappings(addon, tmdb).resolve("tt1", 1)!!
        assertTrue(mapping.remaps)
        assertEquals(1 to 13, mapping.toTmdb(2, 1)?.let { it.season to it.episode })
        assertEquals(2 to 1, mapping.toAddon(1, 13)?.let { it.season to it.episode })
    }

    @Test
    fun `a merged two-parter keeps the numbers when the titles say the seasons hold the same episodes`() = runTest {
        // r2 #2: the add-on merges TMDB's S1E3 and S1E4; every add-on title is one of TMDB's season-1 titles.
        val tmdb = MdbListTestTmdbSeasons(seasons = listOf(13, 12), titles = buildMap {
            (1..13).forEach { put(1 to it, "One $it") }; (1..12).forEach { put(2 to it, "Two $it") }
        })
        val addon = MdbListTestAddonEpisodes(seasons = listOf(12, 12), titles = buildMap {
            put(1 to 1, "One 1"); put(1 to 2, "One 2"); put(1 to 3, "One 3")
            (4..12).forEach { put(1 to it, "One ${it + 1}") }
            (1..12).forEach { put(2 to it, "Two $it") }
        })
        val mapping = mdbListTestEpisodeMappings(addon, tmdb).resolve("tt1", 1)!!
        // r3 #2: the episodes after the merged one are off by one within season 1; season 2 is untouched.
        assertTrue(mapping.remaps)
        assertEquals(1 to 3, mapping.toTmdb(1, 3)?.let { it.season to it.episode })
        assertEquals(1 to 5, mapping.toTmdb(1, 4)?.let { it.season to it.episode })
        assertEquals(1 to 13, mapping.toTmdb(1, 12)?.let { it.season to it.episode })
        assertEquals(1 to 12, mapping.toAddon(1, 13)?.let { it.season to it.episode })
        assertEquals(1 to 4, mapping.toAddon(1, 5)?.let { it.season to it.episode })
        assertNull(mapping.toAddon(1, 4)) // r4 #2: TMDB's "One 4" has no add-on episode; add-on S1E4 is "One 5"
        assertEquals(2 to 5, mapping.toTmdb(2, 5)?.let { it.season to it.episode })
        assertEquals(2 to 12, mapping.toAddon(2, 12)?.let { it.season to it.episode })
    }

    @Test
    fun `a single-season show whose add-on skips a recap is matched by title`() = runTest {
        // r4 #1: TMDB A, B, Recap, C; the add-on has A, B, C.
        val tmdb = MdbListTestTmdbSeasons(seasons = listOf(4), titles = mapOf(1 to 1 to "A", 1 to 2 to "B", 1 to 3 to "Recap", 1 to 4 to "C"))
        val addon = MdbListTestAddonEpisodes(seasons = listOf(3), titles = mapOf(1 to 1 to "A", 1 to 2 to "B", 1 to 3 to "C"))
        val mapping = mdbListTestEpisodeMappings(addon, tmdb).resolve("tt1", 1)!!
        assertTrue(mapping.remaps)
        assertEquals(1 to 4, mapping.toTmdb(1, 3)?.let { it.season to it.episode })
        assertEquals(1 to 3, mapping.toAddon(1, 4)?.let { it.season to it.episode })
        assertEquals(1 to 2, mapping.toAddon(1, 2)?.let { it.season to it.episode })
        assertNull(mapping.toAddon(1, 3)) // the recap has no add-on counterpart
    }

    @Test
    fun `seasons that hold the same episodes in the same places stay unchanged after the identity check`() = runTest {
        // A dropped untitled recap at the end of season 1: every titled episode keeps its number.
        val tmdb = MdbListTestTmdbSeasons(seasons = listOf(13, 12), titles = buildMap {
            (1..12).forEach { put(1 to it, "One $it") }; put(1 to 13, "Recap"); (1..12).forEach { put(2 to it, "Two $it") }
        })
        val addon = MdbListTestAddonEpisodes(seasons = listOf(12, 12), titles = buildMap {
            (1..12).forEach { put(1 to it, "One $it") }; (1..12).forEach { put(2 to it, "Two $it") }
        })
        val mapping = mdbListTestEpisodeMappings(addon, tmdb).resolve("tt1", 1)!!
        // r5 #3: every matched episode keeps its number, but TMDB's recap has no add-on counterpart,
        // so the mapping is kept and the recap maps to nothing instead of being shown as an episode.
        assertTrue(mapping.remaps)
        assertEquals(1 to 12, mapping.toTmdb(1, 12)?.let { it.season to it.episode })
        assertEquals(2 to 3, mapping.toAddon(2, 3)?.let { it.season to it.episode })
        assertNull(mapping.toAddon(1, 13))
    }

    @Test
    fun `air dates decide a small count difference when titles are generic`() = runTest {
        fun dates(counts: List<Int>, from: Int) = buildMap {
            var day = from
            counts.forEachIndexed { index, count -> (1..count).forEach { put(index + 1 to it, "2026-01-${(day++).toString().padStart(2, '0')}") } }
        }
        val generic = buildMap { (1..2).forEach { s -> (1..13).forEach { put(s to it, "Episode $it") } } }
        // Moved boundary: the add-on's S2E1 aired on TMDB's S1E13 day.
        val moved = mdbListTestEpisodeMappings(
            MdbListTestAddonEpisodes(seasons = listOf(12, 13), titles = generic, airDates = dates(listOf(12, 13), 1)),
            MdbListTestTmdbSeasons(seasons = listOf(13, 12), titles = generic, airDates = dates(listOf(13, 12), 1)),
        ).resolve("tt1", 1)!!
        assertTrue(moved.remaps)
        // Nothing to go by: the numbers are kept, as upstream does; TMDB's thirteenth episode of
        // season 1 has no add-on counterpart, so the mapping stays to hide it (r5 #3).
        val unknown = mdbListTestEpisodeMappings(
            MdbListTestAddonEpisodes(seasons = listOf(12, 13), titles = generic),
            MdbListTestTmdbSeasons(seasons = listOf(13, 12), titles = generic),
        ).resolve("tt1", 1)!!
        assertEquals(2 to 1, unknown.toTmdb(2, 1)?.let { it.season to it.episode })
        assertEquals(2 to 13, unknown.toTmdb(2, 13)?.let { it.season to it.episode })
        assertNull(unknown.toAddon(1, 13))
    }

    @Test
    fun `a load that straddles an add-on change is dropped and done again for owner and writer`() = runTest {
        // r2 #4: the add-on set changes while the show loads; the writer must see the new list's mapping.
        val addon = MdbListTestAddonEpisodes(seasons = listOf(24, 24)).apply { gate = CompletableDeferred() }
        val tmdb = MdbListTestTmdbSeasons(seasons = listOf(48), lookup = mapOf("tt1" to 1))
        val service = mdbListTestEpisodeMappings(addon, tmdb)
        val owner = async { service.resolve("tt1", 1) }
        runCurrent()
        val writer = async { service.toMdbListNumbering(episodeReference(2, 11), mediaIndex = null) }
        runCurrent()
        val gate = addon.gate!!
        addon.gate = null
        addon.generation = 1
        addon.seasons = listOf(48) // the new add-on numbers the show as TMDB does
        gate.complete(Unit)
        assertFalse(owner.await()!!.remaps)
        val reference = episodeReference(2, 11)
        assertEquals(2 to 11, writer.await()!!.episode?.let { it.season to it.number })
        assertSame(reference, service.toMdbListNumbering(reference, mediaIndex = null))
        // Two loads for the source change, and one reload because the new list has no S2E11 (r8 #1).
        assertEquals(3, addon.calls.size)
        assertFalse(service.cached("tt1")!!.remaps)
    }

    @Test
    fun `clearing the cache during a load drops that load and later callers start afresh`() = runTest {
        // r2 #5: a profile switch while a show loads; the new profile's caller must not join or inherit it.
        val addon = MdbListTestAddonEpisodes(seasons = listOf(24, 24)).apply { gate = CompletableDeferred() }
        val service = mdbListTestEpisodeMappings(addon, MdbListTestTmdbSeasons(seasons = listOf(48)))
        val old = async { service.resolve("tt1", 1) }
        runCurrent()
        service.clearCache()
        val fresh = async { service.resolve("tt1", 1) }
        runCurrent()
        assertEquals(2, addon.calls.size) // the new-epoch caller did not join the old load
        addon.gate!!.complete(Unit)
        assertTrue(old.await()!!.remaps)
        assertTrue(fresh.await()!!.remaps)
        assertTrue(service.cached("tt1")!!.remaps)
    }

    @Test
    fun `a show that grows a season is mapped again once the mapping has aged`() = runTest {
        // r2 #8: one add-on season vs one TMDB season → Unchanged; later the add-on starts a second season.
        val clock = kotlin.time.TestTimeSource()
        val addon = MdbListTestAddonEpisodes(seasons = listOf(24))
        val tmdb = MdbListTestTmdbSeasons(seasons = listOf(24))
        val service = mdbListTestEpisodeMappings(addon, tmdb, timeSource = clock)
        assertFalse(service.resolve("tt1", 1)!!.remaps)
        addon.seasons = listOf(24, 10)
        tmdb.seasons = listOf(34)
        assertFalse(service.resolve("tt1", 1)!!.remaps) // still fresh: the cached answer stands
        clock += 6.hours
        assertFalse(service.cached("tt1")!!.remaps) // the old answer is still served while…
        assertTrue(service.resolve("tt1", 1)!!.remaps) // …an explicit resolve reloads it
        assertTrue(service.cached("tt1")!!.remaps)
        assertEquals(1 to 25, service.cached("tt1")!!.toTmdb(2, 1)?.let { it.season to it.episode })
    }

    @Test
    fun `a source change that lands as the load returns is neither kept nor handed out`() = runTest {
        // r3 #5: the add-on fake bumps its generation inside the fetch, after the list is read.
        val addon = object : MdbListTestAddonEpisodes(seasons = listOf(24, 24)) {
            override suspend fun episodes(contentId: String, contentType: String, refresh: Boolean): List<EpisodeMappingEntry> {
                val list = super.episodes(contentId, contentType, refresh)
                if (calls.size == 1) { generation = 1; seasons = listOf(48) }
                return list
            }
        }
        val service = mdbListTestEpisodeMappings(addon, MdbListTestTmdbSeasons(seasons = listOf(48)))
        assertFalse(service.resolve("tt1", 1)!!.remaps) // the second load, under the new source
        assertEquals(2, addon.calls.size)
        assertFalse(service.cached("tt1")!!.remaps)
    }

    // ── Codex r5 ────────────────────────────────────────────────────────────────────────────

    @Test
    fun `one shared title is not evidence for a moved boundary`() = runTest {
        // r5 #1: add-on 12 + 36 vs TMDB 24 + 24 with only the pilot titled; the count fallback decides.
        val addon = MdbListTestAddonEpisodes(seasons = listOf(12, 36), titles = mapOf(1 to 1 to "Pilot"))
        val tmdb = MdbListTestTmdbSeasons(seasons = listOf(24, 24), titles = mapOf(1 to 1 to "Pilot"))
        val mapping = mdbListTestEpisodeMappings(addon, tmdb).resolve("tt1", 1)!!
        assertEquals(1 to 13, mapping.toTmdb(2, 1)?.let { it.season to it.episode })
    }

    @Test
    fun `titles on both sides of a boundary are evidence that the seasons hold the same episodes`() = runTest {
        // add-on 12 + 36 vs TMDB 24 + 24, where the add-on's S1E12 and S2E1 are TMDB's S1E12 and S2E1 by title.
        val addon = MdbListTestAddonEpisodes(seasons = listOf(12, 36), titles = mapOf(1 to 12 to "Twelve", 2 to 1 to "Opener"))
        val tmdb = MdbListTestTmdbSeasons(seasons = listOf(24, 24), titles = mapOf(1 to 12 to "Twelve", 2 to 1 to "Opener"))
        val mapping = mdbListTestEpisodeMappings(addon, tmdb).resolve("tt1", 1)!!
        assertEquals(2 to 1, mapping.toTmdb(2, 1)?.let { it.season to it.episode })
        assertEquals(1 to 12, mapping.toTmdb(1, 12)?.let { it.season to it.episode })
    }

    @Test
    fun `an add-on episode with no TMDB counterpart is not written`() = runTest {
        // r5 #2: add-on A, B, Recap, C vs TMDB A, B, C; the recap must not go out as TMDB S1E3 (C).
        val addon = MdbListTestAddonEpisodes(seasons = listOf(4), titles = mapOf(1 to 1 to "A", 1 to 2 to "B", 1 to 3 to "Recap", 1 to 4 to "C"))
        val tmdb = MdbListTestTmdbSeasons(seasons = listOf(3), titles = mapOf(1 to 1 to "A", 1 to 2 to "B", 1 to 3 to "C"), lookup = mapOf("tt1" to 1))
        val service = mdbListTestEpisodeMappings(addon, tmdb)
        assertNull(service.toMdbListNumbering(episodeReference(1, 3), mediaIndex = null))
        assertEquals(1 to 3, service.toMdbListNumbering(episodeReference(1, 4), mediaIndex = null)?.episode?.let { it.season to it.number })
        // An unresolved show still passes through unchanged.
        val unresolved = mdbListTestEpisodeMappings(MdbListTestAddonEpisodes(), tmdb)
        val reference = episodeReference(1, 3)
        assertSame(reference, unresolved.toMdbListNumbering(reference, mediaIndex = null))
    }

    @Test
    fun `an airing season the add-on lists further than TMDB keeps the newest episode's number`() = runTest {
        // The add-on has S2E13 before TMDB does; everything before it matched in place, so it is written as S2E13.
        val addon = MdbListTestAddonEpisodes(seasons = listOf(24, 13))
        val tmdb = MdbListTestTmdbSeasons(seasons = listOf(24, 12), lookup = mapOf("tt1" to 1))
        val service = mdbListTestEpisodeMappings(addon, tmdb)
        assertEquals(2 to 13, service.toMdbListNumbering(episodeReference(2, 13), mediaIndex = null)?.episode?.let { it.season to it.number })
    }

    // ── Codex r6 ────────────────────────────────────────────────────────────────────────────

    @Test
    fun `equal counts with an add-on that numbers season 2 from 13 still remap`() = runTest {
        // r6 #1: twelve episodes on both sides, but the add-on's are E13..E24 and TMDB's E1..E12.
        val addon = MdbListTestAddonEpisodes(seasons = listOf(12, 12), firstEpisode = mapOf(2 to 13))
        val tmdb = MdbListTestTmdbSeasons(seasons = listOf(12, 12))
        val mapping = mdbListTestEpisodeMappings(addon, tmdb).resolve("tt1", 1)!!
        assertTrue(mapping.remaps)
        assertEquals(listOf("counts:1", "season:1:1", "season:1:2"), tmdb.calls)
        assertEquals(2 to 1, mapping.toTmdb(2, 13)?.let { it.season to it.episode })
        assertEquals(2 to 13, mapping.toAddon(2, 1)?.let { it.season to it.episode })
        assertEquals(1 to 5, mapping.toTmdb(1, 5)?.let { it.season to it.episode })
        // Contiguous identical numbering keeps the cheap path.
        val plain = MdbListTestTmdbSeasons(seasons = listOf(12, 12))
        assertFalse(mdbListTestEpisodeMappings(MdbListTestAddonEpisodes(seasons = listOf(12, 12)), plain).resolve("tt1", 1)!!.remaps)
        assertEquals(listOf("counts:1"), plain.calls)
    }

    @Test
    fun `specials keep their coordinates on a show that remaps`() = runTest {
        // r6 #2: neither list carries season 0.
        val mapping = splitAnimeMapping()
        assertEquals(0 to 3, mapping.toTmdb(0, 3)?.let { it.season to it.episode })
        assertEquals(0 to 3, mapping.toAddon(0, 3)?.let { it.season to it.episode })
        val service = splitAnimeMappings()
        val special = episodeReference(0, 3)
        assertSame(special, service.toMdbListNumbering(special, mediaIndex = null))
        assertEquals(setOf(0), mapping.addonSeasonsOf(setOf(0)))
    }

    @Test
    fun `matching air dates stand in for localized titles before the positional fallback`() = runTest {
        // r6 #3: TMDB A, B, Recap, C vs the add-on's A, B, C with other-language titles and the same air dates.
        val tmdb = MdbListTestTmdbSeasons(
            seasons = listOf(4),
            titles = mapOf(1 to 1 to "A", 1 to 2 to "B", 1 to 3 to "Recap", 1 to 4 to "C"),
            airDates = mapOf(1 to 1 to "2026-01-01", 1 to 2 to "2026-01-08", 1 to 3 to "2026-01-15", 1 to 4 to "2026-01-22"),
        )
        val addon = MdbListTestAddonEpisodes(
            seasons = listOf(3),
            titles = mapOf(1 to 1 to "Un", 1 to 2 to "Deux", 1 to 3 to "Trois"),
            airDates = mapOf(1 to 1 to "2026-01-01", 1 to 2 to "2026-01-08", 1 to 3 to "2026-01-22"),
        )
        val mapping = mdbListTestEpisodeMappings(addon, tmdb).resolve("tt1", 1)!!
        assertTrue(mapping.remaps)
        assertEquals(1 to 4, mapping.toTmdb(1, 3)?.let { it.season to it.episode })
        assertEquals(1 to 3, mapping.toAddon(1, 4)?.let { it.season to it.episode })
        assertNull(mapping.toAddon(1, 3)) // the recap has no counterpart by title, date or free position
    }

    // ── Codex r7 ────────────────────────────────────────────────────────────────────────────

    @Test
    fun `a failed refresh keeps writing through the last known split mapping`() = runTest {
        // r7 #1: TMDB is down after the mapping aged; add-on S2E11 must still go out as TMDB S1E35.
        val clock = kotlin.time.TestTimeSource()
        val addon = MdbListTestAddonEpisodes(seasons = listOf(24, 24))
        val tmdb = MdbListTestTmdbSeasons(seasons = listOf(48), lookup = mapOf("tt1" to 1))
        val service = mdbListTestEpisodeMappings(addon, tmdb, timeSource = clock)
        assertTrue(service.resolve("tt1", 1)!!.remaps)
        clock += 6.hours
        tmdb.tmdbShowId = 2 // every TMDB request now answers nothing
        val mapped = service.toMdbListNumbering(episodeReference(2, 11), mediaIndex = null)
        assertEquals(1 to 35, mapped!!.episode?.let { it.season to it.number })
        assertTrue(service.cached("tt1")!!.remaps)
        assertTrue(service.resolve("tt1", 1)!!.remaps)
        // With no mapping ever resolved, the reference passes through as the add-on numbers it.
        val never = mdbListTestEpisodeMappings(MdbListTestAddonEpisodes(seasons = listOf(24, 24)), MdbListTestTmdbSeasons(seasons = listOf(48), tmdbShowId = 2))
        val reference = episodeReference(2, 11)
        assertSame(reference, never.toMdbListNumbering(reference, mediaIndex = null))
    }

    @Test
    fun `an episode the lists did not have reloads them once before counting as unmatched`() = runTest {
        // r7 #2: the add-on lists S2E1 while TMDB has 24 episodes; TMDB adds the 25th within the TTL.
        val clock = kotlin.time.TestTimeSource()
        val addon = MdbListTestAddonEpisodes(seasons = listOf(24, 1))
        val tmdb = MdbListTestTmdbSeasons(seasons = listOf(24), lookup = mapOf("tt1" to 1))
        val service = mdbListTestEpisodeMappings(addon, tmdb, timeSource = clock)
        assertNull(service.toMdbListNumbering(episodeReference(2, 1), mediaIndex = null))
        assertEquals(listOf(false, true), addon.refreshes) // the first load, then the reload past the caches
        clock += 10.minutes
        tmdb.seasons = listOf(25)
        assertNull(service.toMdbListNumbering(episodeReference(2, 1), mediaIndex = null)) // within the hour: no reload
        assertEquals(2, addon.calls.size)
        clock += 1.hours
        val mapped = service.toMdbListNumbering(episodeReference(2, 1), mediaIndex = null)
        assertEquals(1 to 25, mapped!!.episode?.let { it.season to it.number })
        assertEquals(3, addon.calls.size)
        // Mapped now: no further reloads for it.
        assertEquals(1 to 25, service.toMdbListNumbering(episodeReference(2, 1), mediaIndex = null)!!.episode?.let { it.season to it.number })
        assertEquals(3, addon.calls.size)
    }

    // ── Codex r8 ────────────────────────────────────────────────────────────────────────────

    @Test
    fun `an unchanged show reloads its lists for an episode past them before trusting the numbers`() = runTest {
        // r8 #1: both lists ended at S1E24; the add-on now lists S2E1, TMDB lists it as S1E25.
        val clock = kotlin.time.TestTimeSource()
        val addon = MdbListTestAddonEpisodes(seasons = listOf(24))
        val tmdb = MdbListTestTmdbSeasons(seasons = listOf(24), lookup = mapOf("tt1" to 1))
        val service = mdbListTestEpisodeMappings(addon, tmdb, timeSource = clock)
        assertFalse(service.resolve("tt1", 1)!!.remaps)
        clock += 1.hours
        addon.seasons = listOf(24, 1)
        tmdb.seasons = listOf(25)
        // A covered episode needs no reload.
        val covered = episodeReference(1, 5)
        assertSame(covered, service.toMdbListNumbering(covered, mediaIndex = null))
        assertEquals(1, addon.calls.size)
        // One past the lists does, and comes back as TMDB's S1E25.
        val mapped = service.toMdbListNumbering(episodeReference(2, 1), mediaIndex = null)
        assertEquals(1 to 25, mapped!!.episode?.let { it.season to it.number })
        assertEquals(2, addon.calls.size)
        assertTrue(service.cached("tt1")!!.remaps)
    }

    @Test
    fun `an episode past the lists that TMDB does not have either passes through`() = runTest {
        val addon = MdbListTestAddonEpisodes(seasons = listOf(24))
        val tmdb = MdbListTestTmdbSeasons(seasons = listOf(24), lookup = mapOf("tt1" to 1))
        val service = mdbListTestEpisodeMappings(addon, tmdb)
        assertFalse(service.resolve("tt1", 1)!!.remaps)
        addon.seasons = listOf(24, 1)
        val reference = episodeReference(2, 1)
        // The reload finds add-on S2E1 with no TMDB counterpart: the mapping remaps and withholds it.
        assertNull(service.toMdbListNumbering(reference, mediaIndex = null))
        assertEquals(2, addon.calls.size)
        // The same within the hour: no further reload.
        assertNull(service.toMdbListNumbering(reference, mediaIndex = null))
        assertEquals(2, addon.calls.size)
    }

    @Test
    fun `a failed reload keeps the cached mapping's age and is tried again after the backoff`() = runTest {
        // r8 #3: TMDB is down when the mapping expires and back ten minutes later.
        val clock = kotlin.time.TestTimeSource()
        val addon = MdbListTestAddonEpisodes(seasons = listOf(24, 24))
        val tmdb = MdbListTestTmdbSeasons(seasons = listOf(48), lookup = mapOf("tt1" to 1))
        val service = mdbListTestEpisodeMappings(addon, tmdb, timeSource = clock)
        assertTrue(service.resolve("tt1", 1)!!.remaps)
        clock += 6.hours
        tmdb.tmdbShowId = 2
        assertTrue(service.resolve("tt1", 1)!!.remaps) // the old mapping, after a failed reload
        val loadsAfterFailure = addon.calls.size
        clock += 1.minutes
        assertTrue(service.resolve("tt1", 1)!!.remaps)
        assertEquals(loadsAfterFailure, addon.calls.size) // within the backoff: answered from the cache
        tmdb.tmdbShowId = 1
        addon.seasons = listOf(24, 25)
        tmdb.seasons = listOf(49)
        clock += 10.minutes
        val reloaded = service.resolve("tt1", 1)!!
        assertEquals(loadsAfterFailure + 1, addon.calls.size) // the backoff passed: loaded again
        assertEquals(1 to 49, reloaded.toTmdb(2, 25)?.let { it.season to it.episode })
        clock += 5.hours
        assertEquals(loadsAfterFailure + 1, addon.calls.size)
        service.resolve("tt1", 1)
        assertEquals(loadsAfterFailure + 1, addon.calls.size) // fresh again for six hours from the reload
    }

    // ── Codex r9 ────────────────────────────────────────────────────────────────────────────

    @Test
    fun `concurrent writers for an episode past the lists share one reload and both get its answer`() = runTest {
        // r9 #1: both lists ended at S1E24; two scrobbles for the add-on's S2E1 arrive while TMDB lists 25.
        val addon = MdbListTestAddonEpisodes(seasons = listOf(24))
        val tmdb = MdbListTestTmdbSeasons(seasons = listOf(24), lookup = mapOf("tt1" to 1))
        val service = mdbListTestEpisodeMappings(addon, tmdb)
        assertFalse(service.resolve("tt1", 1)!!.remaps)
        addon.seasons = listOf(24, 1)
        tmdb.seasons = listOf(25)
        addon.gate = CompletableDeferred()
        val first = async { service.toMdbListNumbering(episodeReference(2, 1), mediaIndex = null) }
        runCurrent()
        val second = async { service.toMdbListNumbering(episodeReference(2, 1), mediaIndex = null) }
        runCurrent()
        assertEquals(2, addon.calls.size) // the initial load and one shared reload
        addon.gate!!.complete(Unit)
        assertEquals(1 to 25, first.await()!!.episode?.let { it.season to it.number })
        assertEquals(1 to 25, second.await()!!.episode?.let { it.season to it.number })
        assertEquals(2, addon.calls.size)
    }

    @Test
    fun `a forced reload that fails is tried again after the backoff even though the mapping is fresh`() = runTest {
        // r9 #2: TMDB is down when a write for the add-on's new S2E1 forces a reload, and back ten minutes later.
        val clock = kotlin.time.TestTimeSource()
        val addon = MdbListTestAddonEpisodes(seasons = listOf(24))
        val tmdb = MdbListTestTmdbSeasons(seasons = listOf(24), lookup = mapOf("tt1" to 1))
        val service = mdbListTestEpisodeMappings(addon, tmdb, timeSource = clock)
        assertFalse(service.resolve("tt1", 1)!!.remaps)
        addon.seasons = listOf(24, 1)
        tmdb.tmdbShowId = 2
        val raw = episodeReference(2, 1)
        assertSame(raw, service.toMdbListNumbering(raw, mediaIndex = null)) // the reload failed: the old mapping
        assertEquals(2, addon.calls.size)
        clock += 1.minutes
        assertSame(raw, service.toMdbListNumbering(raw, mediaIndex = null))
        assertEquals(2, addon.calls.size) // within the backoff: no reload
        tmdb.tmdbShowId = 1
        tmdb.seasons = listOf(25)
        clock += 10.minutes
        val mapped = service.toMdbListNumbering(episodeReference(2, 1), mediaIndex = null)
        assertEquals(1 to 25, mapped!!.episode?.let { it.season to it.number })
        assertEquals(3, addon.calls.size)
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
