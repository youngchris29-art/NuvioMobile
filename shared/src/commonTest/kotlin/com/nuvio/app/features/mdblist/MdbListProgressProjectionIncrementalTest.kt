package com.nuvio.app.features.mdblist

import com.nuvio.app.features.tracking.TrackingExternalIds
import com.nuvio.app.features.tracking.TrackingMediaKind
import com.nuvio.app.features.tracking.TrackingMediaReference
import com.nuvio.app.features.tracking.TrackingScrobbleAction
import com.nuvio.app.features.tracking.TrackingScrobbleEvent
import kotlinx.coroutines.test.runTest
import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertFalse
import kotlin.test.assertNotSame
import kotlin.test.assertSame
import kotlin.test.assertTrue

/**
 * An incremental projection (history shared, only playback rebuilt) must be observably the same as
 * a full rebuild over the resulting snapshot (NuvioTV 63719770f, 82886dac9, 0e1024a92, 48f58a0dc).
 */
class MdbListProgressProjectionIncrementalTest {
    private val showA = MdbListMedia(MdbListIds(imdb = "tt100", tmdb = 100), "Show A")
    private val showB = MdbListMedia(MdbListIds(imdb = "tt200", tmdb = 200), "Show B")
    private val showC = MdbListMedia(MdbListIds(tmdb = 300), "Show C")
    private val movie = MdbListMedia(MdbListIds(imdb = "tt500", tmdb = 500), "Movie")

    private fun episode(media: MdbListMedia, season: Int, number: Int, at: String = "2026-01-01T00:00:00Z") =
        MdbListWatchedRecord(MdbListItemType.EPISODE, media, at, season, number)

    private fun session(
        id: Long, media: MdbListMedia, season: Int?, number: Int?, progress: Float, at: String,
        type: MdbListItemType = MdbListItemType.EPISODE,
    ) = MdbListPlayback(id, type, media, progress, at, season, number)

    private val base = MdbListSyncSnapshot(
        accountId = 42,
        watched = listOf(
            episode(showA, 1, 1), episode(showA, 1, 2), episode(showA, 1, 3),
            episode(showB, 2, 1), episode(showC, 2, 5),
            MdbListWatchedRecord(MdbListItemType.MOVIE, movie, "2026-01-01T00:00:00Z"),
        ),
        playback = listOf(session(1, showA, 1, 4, 30f, "2026-02-01T00:00:00Z")),
        // Show B is dropped by its tvdb id only; the watched record knows imdb/tmdb. They only meet
        // once a playback session carries all three.
        dropped = listOf(MdbListDroppedRecord(MdbListIds(tvdb = 201)), MdbListDroppedRecord(MdbListIds(tmdb = 300), 2)),
    )

    private val probes = listOf("tt100", "tmdb:100", "tt200", "tmdb:200", "tvdb:201", "tmdb:300", "tt500", "tt999")

    private fun assertEquivalent(incremental: MdbListProgressProjection, snapshot: MdbListSyncSnapshot, label: String) {
        val full = MdbListProgressProjection(snapshot)
        assertEquals(full.progress, incremental.progress, "$label progress")
        assertEquals(full.nextUpSeeds, incremental.nextUpSeeds, "$label nextUpSeeds")
        assertEquals(full.watchedItems, incremental.watchedItems, "$label watchedItems")
        assertEquals(full.watchedKeys, incremental.watchedKeys, "$label watchedKeys")
        assertEquals(full.hiddenContentIds, incremental.hiddenContentIds, "$label hiddenContentIds")
        assertEquals(full.showIdSiblings, incremental.showIdSiblings, "$label showIdSiblings")
        for (id in probes) {
            assertEquals(full.isHidden(id), incremental.isHidden(id), "$label isHidden($id)")
            for (season in listOf(1, 2)) {
                assertEquals(full.isHidden(id, season), incremental.isHidden(id, season), "$label isHidden($id, $season)")
            }
            assertEquals(full.canonicalContentId(id), incremental.canonicalContentId(id), "$label canonical($id)")
        }
    }

    private fun receipt(
        media: MdbListMedia, season: Int?, number: Int?, action: TrackingScrobbleAction, progress: Float,
        at: String, type: MdbListItemType = MdbListItemType.EPISODE, id: Long? = null,
    ) = MdbListScrobbleReceipt(MdbListMutationTarget(type, media, season, number), action, progress, at, id)

    @Test
    fun `playback only scrobbles produce the same projection as a full rebuild`() {
        val scenarios = linkedMapOf(
            "start replaces the paused session" to receipt(showA, 1, 4, TrackingScrobbleAction.START, 0f, "2026-02-02T00:00:00Z"),
            "pause updates the existing session" to receipt(showA, 1, 4, TrackingScrobbleAction.PAUSE, 55f, "2026-02-02T00:00:00Z"),
            "stop below completion on a new episode" to receipt(showA, 1, 5, TrackingScrobbleAction.STOP, 45f, "2026-02-02T00:00:00Z", id = 9),
            "pause on a movie" to receipt(movie, null, null, TrackingScrobbleAction.PAUSE, 10f, "2026-02-02T00:00:00Z", MdbListItemType.MOVIE, 10),
            "pause on a brand new show" to receipt(MdbListMedia(MdbListIds(imdb = "tt999", tmdb = 999), "New"), 1, 1, TrackingScrobbleAction.PAUSE, 20f, "2026-02-02T00:00:00Z", id = 11),
            "pause on a dropped season" to receipt(showC, 2, 6, TrackingScrobbleAction.PAUSE, 20f, "2026-02-02T00:00:00Z", id = 12),
            "pause on a dropped show whose aliases only meet in the session" to
                receipt(MdbListMedia(MdbListIds(imdb = "tt200", tmdb = 200, tvdb = 201), "Show B"), 2, 2, TrackingScrobbleAction.PAUSE, 20f, "2026-02-02T00:00:00Z", id = 13),
            "pause on an episode watched later than the session" to receipt(showA, 1, 3, TrackingScrobbleAction.PAUSE, 20f, "2025-12-01T00:00:00Z", id = 14),
        )
        val projection = MdbListProgressProjection(base)
        for ((label, receipt) in scenarios) {
            val applied = base.applyScrobble(receipt, projection.mediaIndex)
            assertSame(base.watched, applied.watched, "$label keeps the watched list")
            assertEquals(applied, base.applyScrobble(receipt, null), "$label: indexed and unindexed apply agree")
            assertEquivalent(projection.withUpdatedPlayback(applied.playback), applied, label)
        }
    }

    @Test
    fun `chained scrobbles stay equivalent to a rebuild at every step`() {
        var snapshot = base
        var projection = MdbListProgressProjection(base)
        val steps = listOf(
            receipt(showA, 1, 4, TrackingScrobbleAction.PAUSE, 40f, "2026-03-01T00:00:00Z", id = 1),
            receipt(showB, 2, 2, TrackingScrobbleAction.PAUSE, 25f, "2026-03-02T00:00:00Z", id = 2),
            receipt(showA, 1, 5, TrackingScrobbleAction.START, 0f, "2026-03-03T00:00:00Z"),
            receipt(showA, 1, 5, TrackingScrobbleAction.STOP, 62f, "2026-03-04T00:00:00Z", id = 3),
            receipt(movie, null, null, TrackingScrobbleAction.PAUSE, 12f, "2026-03-05T00:00:00Z", MdbListItemType.MOVIE, 4),
            receipt(showA, 1, 4, TrackingScrobbleAction.START, 0f, "2026-03-06T00:00:00Z"),
        )
        steps.forEachIndexed { index, step ->
            snapshot = snapshot.applyScrobble(step, projection.mediaIndex)
            projection = projection.withUpdatedPlayback(snapshot.playback)
            assertEquivalent(projection, snapshot, "step $index")
        }
    }

    @Test
    fun `a completed scrobble rewrites history and needs a full rebuild`() {
        val projection = MdbListProgressProjection(base)
        val completed = base.applyScrobble(
            receipt(showA, 1, 4, TrackingScrobbleAction.STOP, 95f, "2026-02-03T00:00:00Z", id = 1), projection.mediaIndex,
        )
        assertNotSame(base.watched, completed.watched)
        assertEquals(base.watched.size + 1, completed.watched.size)
        assertTrue(completed.playback.isEmpty())
        assertTrue(videoIdWatched(MdbListProgressProjection(completed), "tt100:1:4"))
        assertFalse(videoIdWatched(projection, "tt100:1:4"))
    }

    private fun videoIdWatched(projection: MdbListProgressProjection, videoId: String) =
        projection.watchedItems.any { it.videoId == videoId }

    @Test
    fun `history derived collections are shared when playback changes`() {
        val projection = MdbListProgressProjection(base)
        val next = projection.withUpdatedPlayback(listOf(session(1, showA, 1, 4, 61f, "2026-02-05T00:00:00Z")))
        assertSame(projection.watchedItems, next.watchedItems)
        assertSame(projection.watchedKeys, next.watchedKeys)
        assertSame(projection.hiddenContentIds, next.hiddenContentIds)
        assertSame(projection.nextUpSeeds, next.nextUpSeeds)
        assertSame(projection.mediaIndex, next.mediaIndex, "a known show adds no aliases")
        assertEquals(61f, next.progress.single().progressPercent)
    }

    @Test
    fun `show siblings are shared when playback holds only movies and extended for new shows`() {
        val projection = MdbListProgressProjection(base)
        val movieOnly = projection.withUpdatedPlayback(listOf(session(2, movie, null, null, 20f, "2026-02-05T00:00:00Z", MdbListItemType.MOVIE)))
        val knownShow = projection.withUpdatedPlayback(listOf(session(1, showA, 1, 4, 61f, "2026-02-05T00:00:00Z")))
        val newShow = projection.withUpdatedPlayback(listOf(session(3, MdbListMedia(MdbListIds(imdb = "tt999", tmdb = 999)), 1, 1, 20f, "2026-02-05T00:00:00Z")))
        assertEquals(setOf("tt100", "imdb:tt100", "tmdb:100"), knownShow.showIdSiblings["tt100"])
        assertEquals(setOf("tt999", "imdb:tt999", "tmdb:999"), newShow.showIdSiblings["tt999"])
        assertEquals(setOf("tt100", "imdb:tt100", "tmdb:100"), newShow.showIdSiblings["tt100"])
        assertFalse("tt999" in movieOnly.showIdSiblings)
    }

    @Test
    fun `media index is shared when sessions add nothing and copied when they add aliases`() {
        val index = MdbListProgressProjection(base).mediaIndex
        assertSame(index, index.withPlayback(emptyList()))
        assertSame(index, index.withPlayback(base.playback))
        val widened = index.withPlayback(listOf(session(5, showB.copy(ids = showB.ids.copy(tvdb = 201)), 2, 2, 10f, "2026-02-05T00:00:00Z")))
        assertNotSame(index, widened)
        assertEquals(201L, widened.resolve(MdbListItemType.SHOW, MdbListIds(imdb = "tt200")).ids.tvdb)
        assertEquals(null, index.resolve(MdbListItemType.SHOW, MdbListIds(imdb = "tt200")).ids.tvdb, "the published index is not mutated")
    }

    @Test
    fun `a scrobble through the repository keeps the history projections and updates progress`() = runTest {
        val harness = MdbListSyncTestHarness(backgroundScope)
        harness.seed(harness.snapshot().copy(watched = base.watched, dropped = base.dropped, playback = emptyList()))
        harness.repository.ensureLoaded()
        val before = harness.repository.currentProjection()
        val service = MdbListScrobbleService(harness.http.api, harness.repository)
        val event = TrackingScrobbleEvent(
            TrackingMediaReference(TrackingMediaKind.MOVIE, "Movie", ids = TrackingExternalIds(imdb = "tt500", tmdb = 500)), 33.0,
        )
        harness.http.reply(body = """{"action":"pause","progress":33,"paused_at":"2026-09-06T00:00:00Z","id":77}""")

        service.scrobble(harness.repository.currentScope(), TrackingScrobbleAction.PAUSE, event)

        val after = harness.repository.currentProjection()
        assertNotSame(before, after)
        assertSame(before.watchedItems, after.watchedItems)
        assertSame(before.watchedKeys, after.watchedKeys)
        assertSame(before.nextUpSeeds, after.nextUpSeeds)
        assertEquals(1, after.progress.size)
        assertEquals(33f, after.progress.single().progressPercent)
        assertEquals(base.watched, harness.repository.currentSnapshot()!!.watched)
    }
}
