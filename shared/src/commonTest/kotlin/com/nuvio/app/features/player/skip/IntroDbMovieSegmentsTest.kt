package com.nuvio.app.features.player.skip

import kotlinx.coroutines.runBlocking
import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertFalse
import kotlin.test.assertNull
import kotlin.test.assertTrue

/** Upstream cbe4dc0a..a72e536c (IntroDB movie segments + skip-control unification), shared half. */
class IntroDbMovieSegmentsTest {

    private fun seg(start: Double, end: Double) = IntroDbSegment(startSec = start, endSec = end)

    private fun interval(start: Double, end: Double, type: String) = SkipInterval(start, end, type, "test")

    // --- URL ---

    @Test
    fun movieSegmentsUrlUsesIsMovieFlag() {
        assertEquals(
            "https://x.test/segments?imdb_id=tt1&is_movie=true",
            introDbMovieSegmentsUrl("https://x.test/", "tt1"),
        )
    }

    // --- resolveMovieSkipImdbId ---

    private fun resolve(contentId: String?, videoId: String? = null) = runBlocking {
        resolveMovieSkipImdbId(
            contentId, videoId,
            resolveTmdb = { if (it == 603) "tt0133093" else null },
            resolveAnime = { source, id -> if (source == "mal" && id == "5114") "tt1355642" else null },
        )
    }

    @Test
    fun plainAndPrefixedImdbIdsNeedNoNetwork() {
        assertEquals("tt0133093", resolve("tt0133093"))
        assertEquals("tt0133093", resolve("tt0133093:1:2"))
        assertEquals("tt0133093", resolve("other:1", "tt0133093"))
    }

    @Test
    fun tmdbAndAnimeIdsResolveThroughTheirResolvers() {
        assertEquals("tt0133093", resolve("tmdb:603"))
        assertEquals("tt1355642", resolve("mal:5114"))
        assertNull(resolve("tmdb:999"))
        assertNull(resolve("kitsu:1"))
    }

    @Test
    fun unknownOrMalformedIdsResolveToNull() {
        assertNull(resolve(null))
        assertNull(resolve("tmdb:abc"))
        assertNull(resolve("tmdb:0"))
        assertNull(resolve("foo:123"))
    }

    // --- movieSkipIntervals ---

    @Test
    fun creditsAndSceneAreEmittedWhenDisjoint() {
        val list = IntroDbSegmentsResponse(outro = seg(100.0, 200.0), postCredits = seg(230.0, 260.0)).movieSkipIntervals()
        assertEquals(listOf("movie-credits", "post-credits"), list.map { it.type })
        assertEquals(200.0, list[0].endTime)
    }

    @Test
    fun creditsAreClippedToEndBeforeOverlappingScene() {
        val list = IntroDbSegmentsResponse(outro = seg(100.0, 200.0), postCredits = seg(180.0, 260.0)).movieSkipIntervals()
        assertEquals(180.0, list.first { it.type == "movie-credits" }.endTime)
    }

    @Test
    fun creditsSwallowedBySceneAreDropped() {
        val list = IntroDbSegmentsResponse(outro = seg(100.0, 200.0), postCredits = seg(90.0, 260.0)).movieSkipIntervals()
        assertEquals(listOf("post-credits"), list.map { it.type })
    }

    @Test
    fun millisecondFieldsAndInvalidSegmentsAreHandled() {
        val ms = IntroDbSegmentsResponse(outro = IntroDbSegment(startMs = 1_000, endMs = 5_000)).movieSkipIntervals()
        assertEquals(1.0, ms.single().startTime)
        assertEquals(5.0, ms.single().endTime)
        assertTrue(IntroDbSegmentsResponse(outro = seg(10.0, 10.0)).movieSkipIntervals().isEmpty())
        assertTrue(IntroDbSegmentsResponse().movieSkipIntervals().isEmpty())
    }

    // --- shouldAutoSkip / intervalsAtSeekPositions ---

    @Test
    fun shouldAutoSkipMapsProviderTypesToSelectedSegmentTypes() {
        val intro = setOf(AutoSkipSegmentType.INTRO)
        assertTrue(interval(0.0, 90.0, "op").shouldAutoSkip(intro))
        assertTrue(interval(0.0, 90.0, "mixed-op").shouldAutoSkip(intro))
        assertFalse(interval(0.0, 90.0, "recap").shouldAutoSkip(intro))
        assertTrue(interval(0.0, 30.0, "recap").shouldAutoSkip(setOf(AutoSkipSegmentType.RECAP)))
        for (t in listOf("ed", "ending", "mixed-ed", "outro", "credits")) {
            assertTrue(interval(10.0, 20.0, t).shouldAutoSkip(setOf(AutoSkipSegmentType.OUTRO)), t)
        }
        assertTrue(interval(10.0, 20.0, "movie-credits").shouldAutoSkip(setOf(AutoSkipSegmentType.MOVIE_CREDITS)))
        assertFalse(interval(10.0, 20.0, "movie-credits").shouldAutoSkip(setOf(AutoSkipSegmentType.OUTRO)))
        assertFalse(interval(10.0, 20.0, "post-credits").shouldAutoSkip(AutoSkipSegmentType.entries.toSet()))
        assertFalse(interval(0.0, 90.0, "op").shouldAutoSkip(emptySet()))
        assertFalse(interval(20.0, 10.0, "op").shouldAutoSkip(intro))
        assertFalse(interval(0.0, Double.POSITIVE_INFINITY, "op").shouldAutoSkip(intro))
        assertTrue(interval(0.0, 90.0, "op").shouldAutoSkipForTypes(listOf(AutoSkipSegmentType.INTRO)))
    }

    @Test
    fun intervalsAtSeekPositionsMatchesEitherEndAndIgnoresUnknownTypes() {
        val list = listOf(interval(10.0, 20.0, "op"), interval(30.0, 40.0, "post-credits"), interval(50.0, 60.0, "ed"))
        assertEquals(listOf("op"), list.intervalsAtSeekPositions(0, 15_000).map { it.type })
        assertEquals(listOf("op", "ed"), list.intervalsAtSeekPositions(12_000, 55_000).map { it.type })
        assertTrue(list.intervalsAtSeekPositions(35_000, 35_000).isEmpty())
        assertTrue(list.intervalsAtSeekPositions(20_000, 20_000).isEmpty()) // end is exclusive
    }

    @Test
    fun storedValuesRoundTrip() {
        AutoSkipSegmentType.entries.forEach {
            assertEquals(it, AutoSkipSegmentType.fromStoredValue(it.storedValue))
        }
        assertNull(AutoSkipSegmentType.fromStoredValue("bogus"))
    }

    // --- internalSkipAction ---

    @Test
    fun movieCreditsFollowedByASceneLandOnTheSceneStart() {
        val credits = interval(6000.0, 6300.0, "movie-credits")
        val scene = interval(6400.0, 6500.0, "post-credits")
        val action = credits.internalSkipAction(listOf(credits, scene), durationMs = 6_600_000)!!
        assertEquals(6_400_000L, action.targetMs)
        assertTrue(action.skipsToPostCredits)
    }

    @Test
    fun creditsWithNoSceneLandAtIntervalEnd() {
        val credits = interval(6000.0, 6300.0, "movie-credits")
        val action = credits.internalSkipAction(listOf(credits), durationMs = 6_302_000)!!
        assertEquals(6_300_000L, action.targetMs)
        assertFalse(action.skipsToPostCredits)
    }

    @Test
    fun longTailAfterEpisodeOutroCountsAsPostCredits() {
        val outro = interval(1300.0, 1400.0, "ed")
        val action = outro.internalSkipAction(listOf(outro), durationMs = 1_500_000)!!
        assertEquals(1_400_000L, action.targetMs)
        assertTrue(action.skipsToPostCredits) // 100 s tail > 5 s gap
    }

    @Test
    fun postCreditsTypeShortPlaceholdersAndOpenEndedCreditsHaveNoAction() {
        val scene = interval(100.0, 200.0, "post-credits")
        assertNull(scene.internalSkipAction(listOf(scene), 1_000_000))
        val credits = interval(10.0, 20.0, "movie-credits")
        assertNull(credits.internalSkipAction(listOf(credits), durationMs = 30_000)) // short placeholder
        val open = interval(10.0, Double.MAX_VALUE, "movie-credits")
        assertNull(open.internalSkipAction(listOf(open), 6_000_000))
        // Open-ended episode outro is still actionable (upstream sentinel handling).
        val openOutro = interval(10.0, Double.MAX_VALUE, "outro")
        assertEquals(true, openOutro.internalSkipAction(listOf(openOutro), 0L) != null)
    }

    @Test
    fun introSegmentsNeverSkipToPostCredits() {
        val intro = interval(0.0, 90.0, "op")
        val scene = interval(100.0, 200.0, "post-credits")
        val action = intro.internalSkipAction(listOf(intro, scene), 6_000_000)!!
        assertEquals(90_000L, action.targetMs)
        assertFalse(action.skipsToPostCredits)
    }

    // --- nextEpisodeHoldUntilMs ---

    @Test
    fun holdIsMaxOfSceneEndAndUserThresholdWhenASceneFollows() {
        val outro = interval(1300.0, 1380.0, "ed")
        val scene = interval(1400.0, 1440.0, "post-credits")
        val hold = nextEpisodeHoldUntilMs(
            listOf(outro, scene), 1_450_000, NextEpisodeThresholdMode.PERCENTAGE, 99f, 2f,
        )
        // scene ends at 1440 s, 99% of 1450 s = 1435.5 s -> scene end wins
        assertEquals(1_440_000L, hold)
        val minutes = nextEpisodeHoldUntilMs(
            listOf(outro, scene), 1_450_000, NextEpisodeThresholdMode.MINUTES_BEFORE_END, 99f, 0f,
        )
        assertEquals(1_450_000L, minutes) // 0 min before end -> duration beats scene end
    }

    @Test
    fun noExplicitPostCreditsSceneMeansNoHold() {
        val outro = interval(1300.0, 1380.0, "ed")
        // Fork: upstream's heuristic tail scene is not used for the hold; 120 s of video after the
        // outro with no explicit post-credits interval leaves the normal threshold in charge.
        assertNull(nextEpisodeHoldUntilMs(listOf(outro), 1_500_000, NextEpisodeThresholdMode.PERCENTAGE, 99f, 2f))
        val outroThenSixtySeconds = interval(1300.0, 1440.0, "outro")
        assertNull(nextEpisodeHoldUntilMs(listOf(outroThenSixtySeconds), 1_500_000, NextEpisodeThresholdMode.PERCENTAGE, 99f, 2f))
        assertNull(nextEpisodeHoldUntilMs(listOf(outro), 1_382_000, NextEpisodeThresholdMode.PERCENTAGE, 99f, 2f))
        assertNull(nextEpisodeHoldUntilMs(emptyList(), 1_500_000, NextEpisodeThresholdMode.PERCENTAGE, 99f, 2f))
        assertNull(nextEpisodeHoldUntilMs(listOf(outro), 0L, NextEpisodeThresholdMode.PERCENTAGE, 99f, 2f))
    }

    @Test
    fun explicitPostCreditsIntervalStillHoldsUntilSceneEnd() {
        val outro = interval(1300.0, 1380.0, "outro")
        val scene = interval(1400.0, 1440.0, "post-credits")
        assertEquals(
            1_440_000L,
            nextEpisodeHoldUntilMs(listOf(outro, scene), 1_450_000, NextEpisodeThresholdMode.PERCENTAGE, 99f, 2f),
        )
    }
}
