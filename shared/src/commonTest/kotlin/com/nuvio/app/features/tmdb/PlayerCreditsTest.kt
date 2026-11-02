package com.nuvio.app.features.tmdb

import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertFalse
import kotlin.test.assertIs
import kotlin.test.assertNull
import kotlin.test.assertTrue

class PlayerCreditsTest {

    private fun resolved(type: String, id: String, s: Int? = null, e: Int? = null): PlayerCreditsIdentity =
        assertIs<PlayerCreditsIdentityParse.Resolved>(PlayerCreditsIdentity.parse(type, id, s, e)).identity

    private fun lookup(type: String, id: String, s: Int? = null, e: Int? = null) =
        assertIs<PlayerCreditsIdentityParse.NeedsLookup>(PlayerCreditsIdentity.parse(type, id, s, e))

    @Test
    fun movieImdbNeedsLookup() {
        val p = lookup("movie", "tt0133093", 1, 2)
        assertEquals("movie", p.mediaType)
        assertEquals("imdb_id", p.externalSource)
        assertEquals("tt0133093", p.externalId)
        assertNull(p.season)
        assertNull(p.episode)
    }

    @Test
    fun tmdbPrefixedAndBareIdsResolve() {
        assertEquals(PlayerCreditsIdentity("movie", 603), resolved("movie", "tmdb:603"))
        assertEquals(PlayerCreditsIdentity("movie", 603), resolved("film", "603"))
        assertEquals(PlayerCreditsIdentity("movie", 603), resolved("movie", "movie:tmdb:603"))
        assertEquals(PlayerCreditsIdentity("tv", 1399), resolved("series", "series:1399"))
    }

    @Test
    fun seriesWithEpisodeKeepsSeasonAndEpisode() {
        val p = lookup("series", "tt0944947:1:2", 1, 2)
        assertEquals("tv", p.mediaType)
        assertEquals("tt0944947", p.externalId)
        assertEquals(1, p.season)
        assertEquals(2, p.episode)
        val id = resolved("series", "tmdb:1399", 3, 4)
        assertEquals("tv:1399:s3:e4", id.key)
        assertTrue(id.isEpisode)
    }

    @Test
    fun seriesWithoutEpisodeIsShowLevel() {
        val id = resolved("tv", "tmdb:1399", null, null)
        assertEquals("tv:1399", id.key)
        assertFalse(id.isEpisode)
        assertEquals("tv:1399", resolved("show", "1399", 2, null).key)
    }

    @Test
    fun seasonZeroIsValidButEpisodeZeroFallsBackToShowLevel() {
        assertEquals("tv:1399:s0:e1", resolved("series", "tmdb:1399", 0, 1).key)
        assertEquals("tv:1399", resolved("series", "tmdb:1399", 1, 0).key)
        assertEquals("tv:1399", resolved("series", "tmdb:1399", -1, 1).key)
    }

    @Test
    fun movieKeyShape() {
        assertEquals("movie:603", resolved("movie", "tmdb:603", 1, 1).key)
    }

    @Test
    fun tvdbNeedsLookup() {
        val p = lookup("series", "tvdb:81189", 1, 1)
        assertEquals("tvdb_id", p.externalSource)
        assertEquals("81189", p.externalId)
        assertEquals("tv", p.mediaType)
    }

    @Test
    fun unsupportedInputs() {
        assertEquals(PlayerCreditsIdentityParse.Unsupported, PlayerCreditsIdentity.parse("series", "kitsu:1", 1, 1))
        assertEquals(PlayerCreditsIdentityParse.Unsupported, PlayerCreditsIdentity.parse("series", "mal:5", 1, 1))
        // Anime without episode coordinates stays unsupported.
        assertEquals(PlayerCreditsIdentityParse.Unsupported, PlayerCreditsIdentity.parse("anime", "tt1", null, null))
        assertEquals(PlayerCreditsIdentityParse.Unsupported, PlayerCreditsIdentity.parse("anime", "tmdb:1399", 1, null))
        assertEquals(PlayerCreditsIdentityParse.Unsupported, PlayerCreditsIdentity.parse("anime", "tmdb:1399", 1, 0))
        assertEquals(PlayerCreditsIdentityParse.Unsupported, PlayerCreditsIdentity.parse("anime", "kitsu:1", 1, 1))
        assertEquals(PlayerCreditsIdentityParse.Unsupported, PlayerCreditsIdentity.parse("movie", "  ", null, null))
        assertEquals(PlayerCreditsIdentityParse.Unsupported, PlayerCreditsIdentity.parse("movie", "tvdb:abc", null, null))
        assertEquals(PlayerCreditsIdentityParse.Unsupported, PlayerCreditsIdentity.parse("movie", "addon:xyz", null, null))
    }

    @Test
    fun animeWithEpisodeCoordinatesMapsToTv() {
        val r = resolved("anime", "tmdb:1399", 1, 2)
        assertEquals(PlayerCreditsIdentity("tv", 1399, 1, 2), r)
        assertEquals("tv:1399:s1:e2", r.key)
        val imdb = lookup("anime", "tt0944947:1:2", 1, 2)
        assertEquals("tv", imdb.mediaType)
        assertEquals("imdb_id", imdb.externalSource)
        assertEquals("tt0944947", imdb.externalId)
        assertEquals(1, imdb.season)
        assertEquals(2, imdb.episode)
        val tvdb = lookup("ANIME", "tvdb:81189", 0, 1)
        assertEquals("tv", tvdb.mediaType)
        assertEquals(0, tvdb.season)
    }

    // ─── playerCreditsApiKey ───

    @Test
    fun castKeyIgnoresEnrichmentToggles() {
        val off = TmdbSettings(enabled = false, useCredits = false, apiKey = "personal")
        assertEquals("personal", playerCreditsApiKey(off))
        val bundled = TmdbSettings(enabled = false, useCredits = false)
        assertEquals(TmdbConfig.API_KEY.takeIf { it.isNotBlank() }, playerCreditsApiKey(bundled))
        assertEquals(playerCreditsApiKey(TmdbSettings(enabled = true, useCredits = true)), playerCreditsApiKey(bundled))
    }

    // ─── buildPlayerCredits ───

    private fun cast(id: Int?, name: String? = "P$id", order: Int? = id, character: String? = "C$id") =
        CreditCastInput(id, name, character, "/p$id.jpg", order)

    private fun crew(id: Int?, vararg jobs: String, name: String? = "Crew$id") =
        CreditCrewInput(id, name, jobs.toList(), null)

    @Test
    fun castFollowsBillingOrderMissingLast() {
        val out = buildPlayerCredits("k", listOf(cast(3, order = 5), cast(1, order = null), cast(2, order = 0)), emptyList(), emptyList())
        assertEquals(listOf(2, 3, 1), out.cast.map { it.personId })
        assertEquals("https://image.tmdb.org/t/p/w500/p2.jpg", out.cast.first().photoUrl)
    }

    @Test
    fun guestsFollowRegularsAndDedupe() {
        val out = buildPlayerCredits("k", listOf(cast(1), cast(2)), listOf(cast(2, order = 0), cast(9, order = 0)), emptyList())
        assertEquals(listOf(1, 2, 9), out.cast.map { it.personId })
        assertEquals(listOf(false, false, true), out.cast.map { it.isGuest })
    }

    @Test
    fun invalidEntriesDroppedAndBlankCharacterIsNull() {
        val out = buildPlayerCredits(
            "k",
            listOf(cast(null), cast(1, name = "  "), cast(2, character = " ")),
            emptyList(),
            emptyList(),
        )
        assertEquals(listOf(2), out.cast.map { it.personId })
        assertNull(out.cast.single().role)
    }

    @Test
    fun castCapIsTwentyAcrossGuests() {
        val regulars = (1..15).map { cast(it) }
        val guests = (100..110).map { cast(it) }
        val out = buildPlayerCredits("k", regulars, guests, emptyList())
        assertEquals(20, out.cast.size)
        assertEquals(5, out.cast.count { it.isGuest })
    }

    @Test
    fun crewFilterPriorityAndJobJoin() {
        val out = buildPlayerCredits(
            "k", emptyList(), emptyList(),
            listOf(
                crew(1, "Gaffer"),
                crew(2, "Director of Photography"),
                crew(3, "Writer", "Screenplay", "Writer"),
                crew(4, "Original Music Composer"),
                crew(5, "Director", "Writer"),
            ),
        )
        assertEquals(listOf(5, 3, 4, 2), out.crew.map { it.personId })
        assertEquals("Director, Writer", out.crew.first().role)
        assertEquals("Writer, Screenplay", out.crew[1].role)
        assertTrue(out.crew.all { it.isCrew })
    }

    @Test
    fun producerJobsCappedAtTwoPeople() {
        val out = buildPlayerCredits(
            "k", emptyList(), emptyList(),
            listOf(crew(1, "Producer"), crew(2, "Executive Producer"), crew(3, "Producer"), crew(4, "Director")),
        )
        assertEquals(listOf(4, 1, 2), out.crew.map { it.personId })
    }

    @Test
    fun crewCapIsEight() {
        val out = buildPlayerCredits("k", emptyList(), emptyList(), (1..12).map { crew(it, "Director") })
        assertEquals(8, out.crew.size)
    }

    @Test
    fun actorDirectorGetsBothCards() {
        val out = buildPlayerCredits("k", listOf(cast(7)), emptyList(), listOf(crew(7, "Director"), crew(8, "Gaffer")))
        assertEquals(listOf(7), out.cast.map { it.personId })
        assertEquals(listOf(7), out.crew.map { it.personId })
        assertEquals("Director", out.crew.single().role)
        assertEquals(listOf(7, 7), out.people.map { it.personId })
    }

    @Test
    fun knownForTopTenByVotesDedupes() {
        val candidates = (1..12).map { KnownForCandidate("movie:$it", "T$it", "/x$it.jpg", it) } +
            KnownForCandidate("movie:12", "dup", null, 1)
        val out = selectKnownFor(candidates)
        assertEquals(10, out.size)
        assertEquals("movie:12", out.first().id)
        assertEquals("T12", out.first().title)
    }

    @Test
    fun failedEpisodeRequestServesTheFallbackUncached() {
        // A failed episode request (null) → aggregate fallback, not cached for the session.
        assertFalse(playerCreditsCacheable(isEpisode = true, episodeResponseDecoded = false))
        // A decoded episode answer (with credits, or empty → aggregate fallback) is cached.
        assertTrue(playerCreditsCacheable(isEpisode = true, episodeResponseDecoded = true))
        // Movies and show-level lookups never had an episode request.
        assertTrue(playerCreditsCacheable(isEpisode = false, episodeResponseDecoded = false))
    }

    @Test
    fun failureLogLineNamesEndpointAndClassButNeverTheMessageOrKey() {
        val error = IllegalStateException(
            "Request timeout: https://api.themoviedb.org/3/person/42?api_key=SECRET123&language=en",
        )
        val line = tmdbRequestFailureLogLine("person/42", error)
        assertEquals("TMDB request failed for person/42 (IllegalStateException)", line)
        assertFalse(line.contains("SECRET123"))
        assertFalse(line.contains("api_key"))
    }

    @Test
    fun failureLogLineDropsAnyQueryOnTheEndpoint() {
        val line = tmdbRequestFailureLogLine("find/123?api_key=SECRET", RuntimeException("x"))
        assertFalse(line.contains("SECRET"))
        assertTrue(line.startsWith("TMDB request failed for find/123 "))
    }
}
