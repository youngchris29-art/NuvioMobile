package com.nuvio.app.features.tmdb

import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertNull

/**
 * Device session 2026-10-04: TMDB's 0 runtime for an unreleased film reached the Detail meta line
 * as "0m". Zero is unknown for both the runtime and the vote average.
 */
class TmdbKnownValuesTest {

    @Test
    fun zeroRuntimeIsUnknown() {
        assertNull(tmdbKnownRuntimeMinutes(0, emptyList()))
        assertNull(tmdbKnownRuntimeMinutes(null, emptyList()))
        assertNull(tmdbKnownRuntimeMinutes(0, listOf(0)))
    }

    @Test
    fun aFilmRuntimeWinsAndASeriesFallsBackToItsFirstRealEpisodeRunTime() {
        assertEquals(100, tmdbKnownRuntimeMinutes(100, listOf(45)))
        assertEquals(45, tmdbKnownRuntimeMinutes(null, listOf(45, 50)))
        assertEquals(45, tmdbKnownRuntimeMinutes(0, listOf(45)), "a 0 film runtime no longer hides the episode run time")
        assertEquals(50, tmdbKnownRuntimeMinutes(null, listOf(0, 50)))
    }

    @Test
    fun zeroVoteAverageIsUnknown() {
        assertNull(tmdbKnownVoteAverage(0.0))
        assertNull(tmdbKnownVoteAverage(null))
        assertEquals(6.2, tmdbKnownVoteAverage(6.2))
    }

    /** Review r4 P2-1: previews (More Like This, collection parts) format the vote themselves. */
    @Test
    fun theVoteFormatterGivesNoRatingForZero() {
        assertNull(0.0.formatRating())
        assertNull((-1.0).formatRating())
        assertEquals("6.2", 6.2.formatRating())
        assertEquals("7.5", 7.46.formatRating())
    }
}
