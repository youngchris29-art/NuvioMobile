package com.nuvio.app.features.mdblist

import com.nuvio.app.features.tracking.TrackingExternalIds
import com.nuvio.app.features.tracking.TrackingMediaKind
import com.nuvio.app.features.tracking.TrackingMediaReference
import com.nuvio.app.features.tracking.buildTrackingMediaReference
import kotlinx.coroutines.test.runTest
import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertFalse
import kotlin.test.assertNull
import kotlin.test.assertSame
import kotlin.test.assertTrue

/** Upstream NuvioTV facf25ec3: episodes move between the add-on's seasons and TMDB's. */
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
