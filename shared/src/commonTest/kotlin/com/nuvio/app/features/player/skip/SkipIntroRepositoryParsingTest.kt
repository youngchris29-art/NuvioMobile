package com.nuvio.app.features.player.skip

import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertNull

/** Upstream 8c7a9745 (TV parity): episode parser guard, Anime-Skip type names, public segmentCategory. */
class SkipIntroRepositoryParsingTest {

    // --- toSkipIntervalOrNull (IntroDB episode segments) ---

    @Test
    fun episodeSegmentParsesSecondsAndMilliseconds() {
        assertEquals(
            SkipInterval(10.0, 95.5, "intro", "introdb"),
            IntroDbSegment(startSec = 10.0, endSec = 95.5).toSkipIntervalOrNull("intro"),
        )
        assertEquals(
            SkipInterval(1.5, 30.0, "recap", "introdb"),
            IntroDbSegment(startMs = 1_500, endMs = 30_000).toSkipIntervalOrNull("recap"),
        )
    }

    @Test
    fun secondsWinOverMilliseconds() {
        assertEquals(
            SkipInterval(5.0, 6.0, "outro", "introdb"),
            IntroDbSegment(startSec = 5.0, endSec = 6.0, startMs = 9_000, endMs = 10_000).toSkipIntervalOrNull("outro"),
        )
    }

    @Test
    fun startAtZeroIsKept() {
        assertEquals(0.0, IntroDbSegment(startSec = 0.0, endSec = 45.0).toSkipIntervalOrNull("recap")?.startTime)
    }

    @Test
    fun missingOrEmptyRangesAreRejected() {
        val nullSegment: IntroDbSegment? = null
        assertNull(nullSegment.toSkipIntervalOrNull("intro"))
        assertNull(IntroDbSegment(startSec = 10.0).toSkipIntervalOrNull("intro"))
        assertNull(IntroDbSegment(endSec = 10.0).toSkipIntervalOrNull("intro"))
        assertNull(IntroDbSegment(startSec = 10.0, endSec = 10.0).toSkipIntervalOrNull("intro"))
        assertNull(IntroDbSegment(startSec = 20.0, endSec = 10.0).toSkipIntervalOrNull("intro"))
    }

    @Test
    fun nonFiniteOrNegativeValuesAreRejected() {
        assertNull(IntroDbSegment(startSec = Double.NaN, endSec = 10.0).toSkipIntervalOrNull("intro"))
        assertNull(IntroDbSegment(startSec = 0.0, endSec = Double.NaN).toSkipIntervalOrNull("intro"))
        assertNull(IntroDbSegment(startSec = 0.0, endSec = Double.POSITIVE_INFINITY).toSkipIntervalOrNull("intro"))
        assertNull(IntroDbSegment(startSec = Double.NEGATIVE_INFINITY, endSec = 10.0).toSkipIntervalOrNull("intro"))
        assertNull(IntroDbSegment(startSec = -1.0, endSec = 10.0).toSkipIntervalOrNull("intro"))
        assertNull(IntroDbSegment(startMs = -500, endMs = 10_000).toSkipIntervalOrNull("intro"))
    }

    // --- animeSkipSegmentType ---

    @Test
    fun animeSkipTypeNamesMapToSegmentTypes() {
        assertEquals("op", animeSkipSegmentType("Intro"))
        assertEquals("op", animeSkipSegmentType("New Intro"))
        assertEquals("ed", animeSkipSegmentType("Credits"))
        assertEquals("ed", animeSkipSegmentType("New Credits"))
        assertEquals("mixed-op", animeSkipSegmentType("Mixed Intro"))
        assertEquals("mixed-ed", animeSkipSegmentType("Mixed Credits"))
        assertEquals("recap", animeSkipSegmentType("Recap"))
    }

    @Test
    fun animeSkipUnskippableTypeNamesMapToNull() {
        assertNull(animeSkipSegmentType("Canon"))
        assertNull(animeSkipSegmentType("Filler"))
        assertNull(animeSkipSegmentType("Preview"))
        assertNull(animeSkipSegmentType("Title Card"))
        assertNull(animeSkipSegmentType(""))
    }

    // --- segmentCategory ---

    @Test
    fun segmentCategoryGroupsProviderTypes() {
        listOf("intro", "op", "mixed-op", "OP").forEach { assertEquals("opening", segmentCategory(it), it) }
        listOf("outro", "ed", "mixed-ed", "credits", "ending", "Outro").forEach {
            assertEquals("ending", segmentCategory(it), it)
        }
        assertEquals("recap", segmentCategory("recap"))
    }

    @Test
    fun movieAndUnknownTypesHaveNoCategory() {
        assertNull(segmentCategory("movie-credits"))
        assertNull(segmentCategory("post-credits"))
        assertNull(segmentCategory("preview"))
        assertNull(segmentCategory(""))
    }
}
