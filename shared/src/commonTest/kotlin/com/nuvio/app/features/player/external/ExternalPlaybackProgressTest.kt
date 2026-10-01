package com.nuvio.app.features.player.external

import com.nuvio.app.features.player.PlayerPlaybackSnapshot
import com.nuvio.app.features.tracking.TrackingScrobbleEvent
import com.nuvio.app.features.watching.domain.isProgressComplete
import com.nuvio.app.features.watching.domain.shouldStoreProgress
import com.nuvio.app.features.watchprogress.WatchProgressPlaybackSession
import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertFalse
import kotlin.test.assertNotNull
import kotlin.test.assertNull
import kotlin.test.assertTrue

/**
 * Ported from upstream `99ced26a` (`ExternalPlaybackProgressTest.kt`, a Robolectric
 * `androidHostTest` that wrote through the real `WatchProgressRepository`). In `commonTest` the
 * repository write and the tracker scrobble are injected sinks (`writeExternalPlaybackProgress`),
 * so these cases assert what reaches `WatchProgressRepository.upsertPlaybackProgress` (the
 * snapshot it turns into an entry with the shared `isProgressComplete`/`shouldStoreProgress`
 * rules) and what reaches the STOP scrobble. Upstream's fourth case (Android intent extras of the
 * `android_system` player) is composeApp-only and has no `shared/` counterpart.
 */
class ExternalPlaybackProgressTest {
    private val source = "https://example.com/movie.mkv"
    private val upserts = mutableListOf<Pair<WatchProgressPlaybackSession, PlayerPlaybackSnapshot>>()
    private val scrobbles = mutableListOf<Pair<Int, TrackingScrobbleEvent>>()

    private fun playback(profileId: Int = 1) = WatchProgressPlaybackSession(
        profileId = profileId, contentType = "movie", parentMetaId = "tt123", parentMetaType = "movie",
        videoId = "tt123", title = "Movie", lastSourceUrl = source,
    )

    private fun session(
        durationMs: Long?,
        playback: WatchProgressPlaybackSession = playback(),
    ) = ExternalPlaybackSession(
        id = "session-1",
        playerId = "infuse",
        sourceUrl = source,
        playbackSession = playback,
        durationMs = durationMs,
    )

    private fun record(
        session: ExternalPlaybackSession,
        positionSec: Double,
        storedDurationMs: Long? = null,
    ) = writeExternalPlaybackProgress(
        session = session,
        positionSec = positionSec,
        existingDurationMs = { storedDurationMs },
        upsert = { playback, snapshot -> upserts += playback to snapshot },
        scrobbleStop = { profileId, event -> scrobbles += profileId to event },
    )

    @Test
    fun infuseReturnWithoutDurationPersistsResumeWithoutMarkingWatched() {
        record(session(durationMs = null), positionSec = 1800.0)
        val (_, snapshot) = upserts.single()
        assertEquals(1_800_000L, snapshot.positionMs)
        assertEquals(0L, snapshot.durationMs)
        assertFalse(snapshot.isEnded)
        assertFalse(snapshot.isPlaying)
        assertFalse(snapshot.isLoading)
        assertTrue(shouldStoreProgress(snapshot.positionMs, snapshot.durationMs))
        assertFalse(isProgressComplete(snapshot.positionMs, snapshot.durationMs, snapshot.isEnded))
        assertTrue(scrobbles.isEmpty())
    }

    @Test
    fun infuseUsesKnownDurationToRecognizeCompletion() {
        record(session(durationMs = 3_600_000L), positionSec = 3300.0)
        val (_, snapshot) = upserts.single()
        assertEquals(3_600_000L, snapshot.durationMs)
        assertTrue(isProgressComplete(snapshot.positionMs, snapshot.durationMs, snapshot.isEnded))
        val (profileId, event) = scrobbles.single()
        assertEquals(1, profileId)
        assertEquals(3300.0 / 3600.0 * 100.0, event.progressPercent, absoluteTolerance = 1e-9)
        assertEquals("tt123", event.media.catalog?.contentId)
    }

    @Test
    fun infuseReturnIsSavedForItsOriginalProfile() {
        record(session(durationMs = 3_600_000L, playback = playback(profileId = 99)), positionSec = 1800.0)
        assertEquals(99, upserts.single().first.profileId)
        assertEquals(99, scrobbles.single().first)
    }

    @Test
    fun durationFallsBackToTheStoredProgressEntry() {
        record(session(durationMs = null), positionSec = 1800.0, storedDurationMs = 3_600_000L)
        assertEquals(3_600_000L, upserts.single().second.durationMs)
        assertEquals(50.0, scrobbles.single().second.progressPercent, absoluteTolerance = 1e-9)
    }

    @Test
    fun sessionDurationWinsOverTheStoredProgressEntry() {
        record(session(durationMs = 2_400_000L), positionSec = 1200.0, storedDurationMs = 3_600_000L)
        assertEquals(2_400_000L, upserts.single().second.durationMs)
        assertEquals(50.0, scrobbles.single().second.progressPercent, absoluteTolerance = 1e-9)
    }

    @Test
    fun nonPositivePositionsWriteNothing() {
        listOf(0.0, -5.0, Double.NaN, Double.NEGATIVE_INFINITY, Double.POSITIVE_INFINITY, 0.0004).forEach { position ->
            record(session(durationMs = 3_600_000L), positionSec = position)
            assertTrue(upserts.isEmpty(), "position $position")
            assertTrue(scrobbles.isEmpty(), "position $position")
        }
        assertNull(planExternalPlaybackProgress(positionSec = 0.0, durationMs = null))
    }

    @Test
    fun shortPlaceholderDurationWritesNothing() {
        record(session(durationMs = 60_000L), positionSec = 55.0)
        assertTrue(upserts.isEmpty())
        assertTrue(scrobbles.isEmpty())
        record(session(durationMs = null), positionSec = 55.0, storedDurationMs = 60_000L)
        assertTrue(upserts.isEmpty())
        assertTrue(scrobbles.isEmpty())
    }

    @Test
    fun scrobblePercentIsClampedWhenThePlayerReportsPastTheEnd() {
        val plan = assertNotNull(planExternalPlaybackProgress(positionSec = 4000.0, durationMs = 3_600_000L))
        assertEquals(100.0, plan.stopScrobblePercent)
        assertNull(assertNotNull(planExternalPlaybackProgress(positionSec = 10.0, durationMs = 0L)).stopScrobblePercent)
    }
}
