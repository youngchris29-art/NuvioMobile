package com.nuvio.app.features.player.skip

import com.nuvio.app.features.player.skip.SimklIdResolver.AnimeSeasonEntry
import com.nuvio.app.features.player.skip.SimklIdResolver.EpisodeMapping
import kotlinx.serialization.json.Json
import kotlinx.serialization.json.jsonObject
import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertNull
import kotlin.test.assertTrue

/**
 * Upstream aa748fa8 (IMDB -> MAL mapping): the pure halves of the sibling-season lookup and the
 * TVDB -> anime-native episode remap. `httpGetText` is an expect/actual with no test seam, so the
 * network calls in [SimklIdResolver.resolveIdsForImdbEpisode] are not exercised here.
 */
class SimklAnimeSeasonMappingTest {

    private fun parse(text: String) = Json.parseToJsonElement(text).jsonObject

    @Test
    fun parsesMappedTvdbSeasonsAndPicksTheSeasonTwoSibling() {
        // Base resolved to the season-1 entry (simkl 1001); season 2 lives on entry 1002.
        val details = parse(
            """
            {
              "ids": { "simkl": 1001, "mal": "100" },
              "season": 1,
              "mapped_tvdb_seasons": [
                { "simkl_id": 1001, "tvdb_season": 1 },
                { "simkl_id": 1002, "tvdb_season": 2 },
                { "simkl_id": 1003, "tvdb_season": 3 }
              ]
            }
            """.trimIndent()
        )
        val seasons = SimklIdResolver.parseAnimeSeasonEntries(details)
        assertEquals(
            listOf(AnimeSeasonEntry(1001, 1), AnimeSeasonEntry(1002, 2), AnimeSeasonEntry(1003, 3)),
            seasons,
        )
        assertEquals(1002L, SimklIdResolver.selectSiblingSimklId(seasons, 2))
        assertNull(SimklIdResolver.selectSiblingSimklId(seasons, 4))
    }

    @Test
    fun skipsMalformedSeasonEntriesIndividually() {
        val details = parse(
            """
            {
              "mapped_tvdb_seasons": [
                { "simkl_id": 0, "tvdb_season": 1 },
                { "simkl_id": "abc", "tvdb_season": 2 },
                { "tvdb_season": 3 },
                { "simkl_id": 2004, "tvdb_season": null },
                "not-an-object",
                { "simkl_id": 2005, "tvdb_season": 5 }
              ]
            }
            """.trimIndent()
        )
        assertEquals(listOf(AnimeSeasonEntry(2005, 5)), SimklIdResolver.parseAnimeSeasonEntries(details))
    }

    @Test
    fun missingOrNullSeasonListYieldsNoSiblings() {
        assertTrue(SimklIdResolver.parseAnimeSeasonEntries(parse("""{ "ids": {} }""")).isEmpty())
        assertTrue(SimklIdResolver.parseAnimeSeasonEntries(parse("""{ "mapped_tvdb_seasons": null }""")).isEmpty())
    }

    @Test
    fun remapsTvdbEpisodeToAnimeNativeEpisode() {
        // A split-cour entry whose own numbering continues past the TVDB season break:
        // TVDB S2E1..E3 are the entry's episodes 13..15.
        val mapping = listOf(
            EpisodeMapping(animeEpisode = 12, tvdbSeason = 1, tvdbEpisode = 12),
            EpisodeMapping(animeEpisode = 13, tvdbSeason = 2, tvdbEpisode = 1),
            EpisodeMapping(animeEpisode = 14, tvdbSeason = 2, tvdbEpisode = 2),
            EpisodeMapping(animeEpisode = 15, tvdbSeason = 2, tvdbEpisode = 3),
        )
        assertEquals(15, SimklIdResolver.animeEpisodeFor(mapping, season = 2, episode = 3))
        // Same TVDB episode number in another season must not match.
        assertEquals(12, SimklIdResolver.animeEpisodeFor(mapping, season = 1, episode = 12))
    }

    @Test
    fun unmappedEpisodeKeepsTheTvdbEpisode() {
        val mapping = listOf(EpisodeMapping(animeEpisode = 1, tvdbSeason = 2, tvdbEpisode = 1))
        assertEquals(7, SimklIdResolver.animeEpisodeFor(mapping, season = 2, episode = 7))
        assertEquals(3, SimklIdResolver.animeEpisodeFor(emptyList(), season = 2, episode = 3))
    }

    @Test
    fun splitCourPicksTheCandidateWhoseMappingContainsTheEpisode() {
        val cour1 = AnimeSeasonEntry(2001, 3)
        val cour2 = AnimeSeasonEntry(2002, 3)
        val m1 = (1..12).map { EpisodeMapping(it, 3, it) }
        val m2 = (1..12).map { EpisodeMapping(it, 3, it + 12) }
        val candidates = listOf(cour1 to m1, cour2 to m2)
        assertEquals(2002L, SimklIdResolver.selectSiblingByEpisode(candidates, 3, 15))
        assertEquals(2001L, SimklIdResolver.selectSiblingByEpisode(candidates, 3, 5))
    }

    @Test
    fun splitCourFallsBackToFirstWhenNoCandidateMapsTheEpisode() {
        val candidates = listOf(
            AnimeSeasonEntry(2001, 3) to listOf(EpisodeMapping(1, 3, 1)),
            AnimeSeasonEntry(2002, 3) to emptyList(),
        )
        assertEquals(2001L, SimklIdResolver.selectSiblingByEpisode(candidates, 3, 99))
    }

    @Test
    fun singleCandidateIsUnchangedAndEmptyIsNull() {
        val only = listOf(AnimeSeasonEntry(2001, 3) to emptyList<EpisodeMapping>())
        assertEquals(2001L, SimklIdResolver.selectSiblingByEpisode(only, 3, 15))
        assertNull(SimklIdResolver.selectSiblingByEpisode(emptyList(), 3, 15))
    }

    @Test
    fun shouldLookForSiblingDecisions() {
        val m = (1..12).map { EpisodeMapping(it, 1, it) }
        assertEquals(false, SimklIdResolver.shouldLookForSibling("anime", 1, 1, m, 5))
        assertEquals(true, SimklIdResolver.shouldLookForSibling("anime", 1, 1, m, 20))
        assertEquals(false, SimklIdResolver.shouldLookForSibling("anime", 1, 1, emptyList(), 20))
        assertEquals(false, SimklIdResolver.shouldLookForSibling("tv", 1, 1, m, 20))
    }
}
