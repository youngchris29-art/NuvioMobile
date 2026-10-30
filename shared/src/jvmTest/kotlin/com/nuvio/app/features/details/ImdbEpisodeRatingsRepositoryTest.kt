package com.nuvio.app.features.details

import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.test.runTest
import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertFailsWith
import kotlin.test.assertTrue

class ImdbEpisodeRatingsRepositoryTest {
    private val imdbCalls = mutableListOf<String>()
    private val tmdbLookups = mutableListOf<String>()
    private val seriesGraphCalls = mutableListOf<Int>()

    private fun payload(rating: Double) = listOf(
        SeriesGraphSeasonRatingsDto(
            episodes = listOf(
                SeriesGraphEpisodeRatingDto(seasonNumber = 1, episodeNumber = 1, voteAverage = rating),
            ),
        ),
    )

    private suspend fun fetch(
        imdbId: String?,
        tmdbId: Int? = null,
        imdbKeyed: List<SeriesGraphSeasonRatingsDto>,
        seriesGraph: List<SeriesGraphSeasonRatingsDto> = emptyList(),
        resolvedTmdbId: String? = null,
    ) = ImdbEpisodeRatingsRepository.fetchEpisodeRatings(
        imdbId = imdbId,
        tmdbId = tmdbId,
        imdbKeyed = { id -> imdbCalls += id; imdbKeyed },
        tmdbKeyed = { id -> seriesGraphCalls += id; seriesGraph },
        resolveTmdbId = { id -> tmdbLookups += id; resolvedTmdbId },
    )

    @Test
    fun configuredImdbKeyedServiceIsUsedFirstWithoutATmdbLookup() = runTest {
        val ratings = fetch(imdbId = "tt0903747", imdbKeyed = payload(9.5), seriesGraph = payload(1.0), resolvedTmdbId = "1396")

        assertEquals(mapOf((1 to 1) to 9.5), ratings)
        assertEquals(listOf("tt0903747"), imdbCalls)
        assertTrue(tmdbLookups.isEmpty())
        assertTrue(seriesGraphCalls.isEmpty())
    }

    @Test
    fun imdbIdOnlyWithoutThePrivateServiceResolvesTheTmdbIdForSeriesGraph() = runTest {
        val ratings = fetch(imdbId = "tt0903747", imdbKeyed = emptyList(), seriesGraph = payload(8.7), resolvedTmdbId = "1396")

        assertEquals(mapOf((1 to 1) to 8.7), ratings)
        assertEquals(listOf("tt0903747"), imdbCalls)
        assertEquals(listOf("tt0903747"), tmdbLookups)
        assertEquals(listOf(1396), seriesGraphCalls)
    }

    @Test
    fun anUnresolvableTmdbIdGivesAnEmptyResultWithoutCallingSeriesGraph() = runTest {
        val ratings = fetch(imdbId = "tt0903747", imdbKeyed = emptyList(), seriesGraph = payload(8.7), resolvedTmdbId = null)

        assertTrue(ratings.isEmpty())
        assertEquals(listOf("tt0903747"), tmdbLookups)
        assertTrue(seriesGraphCalls.isEmpty())
    }

    @Test
    fun aFailingTmdbLookupGivesAnEmptyResult() = runTest {
        val ratings = ImdbEpisodeRatingsRepository.fetchEpisodeRatings(
            imdbId = "tt0903747",
            tmdbId = null,
            imdbKeyed = { emptyList() },
            tmdbKeyed = { id -> seriesGraphCalls += id; payload(8.7) },
            resolveTmdbId = { error("TMDB find failed") },
        )

        assertTrue(ratings.isEmpty())
        assertTrue(seriesGraphCalls.isEmpty())
    }

    @Test
    fun aKnownTmdbIdSkipsTheLookup() = runTest {
        val ratings = fetch(imdbId = null, tmdbId = 1396, imdbKeyed = emptyList(), seriesGraph = payload(8.7))

        assertEquals(mapOf((1 to 1) to 8.7), ratings)
        assertTrue(imdbCalls.isEmpty())
        assertTrue(tmdbLookups.isEmpty())
        assertEquals(listOf(1396), seriesGraphCalls)
    }

    @Test
    fun anUnconfiguredSeriesGraphSkipsTheTmdbLookup() = runTest {
        val ratings = ImdbEpisodeRatingsRepository.fetchEpisodeRatings(
            imdbId = "tt0903747",
            tmdbId = null,
            imdbKeyed = { id -> imdbCalls += id; emptyList() },
            tmdbKeyed = { id -> seriesGraphCalls += id; payload(8.7) },
            resolveTmdbId = { id -> tmdbLookups += id; "1396" },
            canUseSeriesGraph = false,
        )

        assertTrue(ratings.isEmpty())
        assertEquals(listOf("tt0903747"), imdbCalls)
        assertTrue(tmdbLookups.isEmpty())
        assertTrue(seriesGraphCalls.isEmpty())
    }

    @Test
    fun cancellationDuringTheTmdbLookupPropagates() = runTest {
        assertFailsWith<CancellationException> {
            ImdbEpisodeRatingsRepository.fetchEpisodeRatings(
                imdbId = "tt0903747",
                tmdbId = null,
                imdbKeyed = { emptyList() },
                tmdbKeyed = { id -> seriesGraphCalls += id; payload(8.7) },
                resolveTmdbId = { throw CancellationException("cancelled") },
            )
        }
        assertTrue(seriesGraphCalls.isEmpty())
    }
}
