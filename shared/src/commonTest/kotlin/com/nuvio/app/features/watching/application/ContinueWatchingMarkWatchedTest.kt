package com.nuvio.app.features.watching.application

import com.nuvio.app.features.cloud.CloudLibraryContentType
import com.nuvio.app.features.watchprogress.WatchProgressEntry
import com.nuvio.app.features.watched.WatchedScopeToken
import com.nuvio.app.features.tracking.WatchProgressSource
import com.nuvio.app.features.watchprogress.WatchProgressSourceNextUp
import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertFalse
import kotlin.test.assertTrue

/** Upstream NuvioMobile 7c57f775e, re-expressed on the fork's [WatchProgressEntry]. */
class ContinueWatchingMarkWatchedTest {
    private val now = 10_000L

    private fun entry(
        type: String = "movie",
        season: Int? = null,
        episode: Int? = null,
        videoId: String = "tt1",
        source: String = "local",
        contentType: String = type,
    ) = WatchProgressEntry(
        contentType = contentType,
        parentMetaId = "tt1",
        parentMetaType = type,
        videoId = videoId,
        title = "Title",
        seasonNumber = season,
        episodeNumber = episode,
        lastPositionMs = 5L,
        durationMs = 10L,
        lastUpdatedEpochMs = 1L,
        source = source,
    )

    @Test
    fun movieMarkClearsProgressWithoutReconcile() {
        val plan = continueWatchingMarkWatchedPlan(entry(), now)
        assertEquals("movie", plan.item.type)
        assertEquals(now, plan.item.markedAtEpochMs)
        assertTrue(plan.clearProgress)
        assertFalse(plan.reconcileSeries)
    }

    @Test
    fun episodeMarkReconcilesSeries() {
        val plan = continueWatchingMarkWatchedPlan(entry("series", 2, 5, "tt1:2:5"), now)
        assertEquals(2, plan.item.season)
        assertEquals(5, plan.item.episode)
        assertTrue(plan.clearProgress)
        assertTrue(plan.reconcileSeries)
    }

    @Test
    fun nextUpMarkKeepsProgressAndStillReconciles() {
        val plan = continueWatchingMarkWatchedPlan(
            entry("series", 2, 6, "tt1:2:6", source = WatchProgressSourceNextUp), now,
        )
        assertFalse(plan.clearProgress)
        assertTrue(plan.reconcileSeries)
    }

    @Test
    fun unairedNextUpCannotMark() {
        val nextUp = entry("series", 2, 6, source = WatchProgressSourceNextUp)
        assertFalse(canMarkWatched(nextUp, now, releaseAtEpochMs = now + 1))
        assertTrue(canMarkWatched(nextUp, now, releaseAtEpochMs = now))
        assertTrue(canMarkWatched(nextUp, now))
        // A progress card is never "unaired".
        assertTrue(canMarkWatched(entry("series", 2, 6), now, releaseAtEpochMs = now + 1))
    }

    @Test
    fun cloudItemCannotMark() {
        assertFalse(canMarkWatched(entry(type = CloudLibraryContentType), now))
        assertFalse(canMarkWatched(entry(type = "movie", contentType = CloudLibraryContentType), now))
    }

    @Test
    fun videoIdIsCarried() {
        assertEquals("tt1:2:5", watchedItemFromProgress(entry("series", 2, 5, "tt1:2:5"), now).videoId)
        assertEquals("tt1", watchedItemFromProgress(entry(), now).videoId)
    }

    @Test
    fun `a series entry without both coordinates gets no action`() {
        // Review r2: Simkl can carry an episode number with no season.
        assertFalse(canMarkWatched(entry(type = "series", season = null, episode = 3), now))
        assertFalse(canMarkWatched(entry(type = "series", season = 1, episode = null), now))
        assertFalse(canMarkWatched(entry(type = "series"), now), "a bare series entry")
        assertTrue(canMarkWatched(entry(type = "series", season = 1, episode = 3), now))
        assertTrue(canMarkWatched(entry(type = "movie"), now))
        assertTrue(canMarkWatched(entry(type = "film"), now))
        // Review r3: an add-on `anime` entry without coordinates would only lose its resume point
        // (the tracker-history guard drops a coordinate-free anime mark).
        assertFalse(canMarkWatched(entry(type = "anime"), now))
        assertTrue(canMarkWatched(entry(type = "anime", season = 1, episode = 2), now), "a full anime episode marks")
    }

    @Test
    fun `a series reconcile is dropped when the profile or the source changed while the meta loaded`() {
        // Review r1: the meta fetch runs on a process-wide scope; the write must stay with the
        // profile and tracker source the mark was made in.
        val started = WatchedScopeToken(profileId = 1, profileGeneration = 3L, source = WatchProgressSource.NUVIO_SYNC, sourceGeneration = 7L)
        assertTrue(reconcileScopeStillCurrent(started, started.copy()))
        assertFalse(reconcileScopeStillCurrent(started, started.copy(profileId = 2, profileGeneration = 4L)), "profile switched")
        assertFalse(reconcileScopeStillCurrent(started, started.copy(profileGeneration = 4L)), "same profile reloaded")
        assertFalse(reconcileScopeStillCurrent(started, started.copy(source = WatchProgressSource.TRAKT, sourceGeneration = 8L)), "source switched")
    }
}
