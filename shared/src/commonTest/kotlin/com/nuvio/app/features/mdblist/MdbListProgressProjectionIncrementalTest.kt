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

    // Normalised like any snapshot the repository has committed, so the legacy and the current
    // applyScrobble start from the same state.
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
    ).normalizeMedia()

    /** `applyScrobble` before the incremental port (3f119f987), the oracle for what it must still produce. */
    private fun legacyApplyScrobble(snapshot: MdbListSyncSnapshot, receipt: MdbListScrobbleReceipt): MdbListSyncSnapshot {
        val target = receipt.target
        val remainingPlayback = snapshot.playback.filterNot(target::matches)
        if (receipt.action == TrackingScrobbleAction.START) return snapshot.copy(playback = remainingPlayback)
        val watched = if (receipt.isWatched) snapshot.watched.filterNot(target::matches) + target.watched(receipt.timestamp) else snapshot.watched
        val playback = if (receipt.isWatched) remainingPlayback else remainingPlayback + MdbListPlayback(
            id = receipt.playbackId ?: snapshot.playback.firstOrNull(target::matches)?.id,
            type = target.type,
            media = target.media,
            progress = receipt.progress,
            updatedAt = receipt.timestamp,
            season = target.season,
            episode = target.episode,
            episodeTitle = target.episodeTitle,
            episodeTmdbId = target.episodeTmdbId,
            episodeTvdbId = target.episodeTvdbId,
        )
        return snapshot.copy(watched = watched, playback = playback).normalizeMedia()
    }

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

    private val bridgeMedia = showB.copy(ids = showB.ids.copy(tvdb = 201))
    private val aliasedShowC = MdbListMedia(MdbListIds(imdb = "tt300", tmdb = 300), "Show C")
    private val newShow = MdbListMedia(MdbListIds(imdb = "tt999", tmdb = 999), "New")

    private val scenarios = linkedMapOf(
        "start replaces the paused session" to receipt(showA, 1, 4, TrackingScrobbleAction.START, 0f, "2026-02-02T00:00:00Z"),
        "pause updates the existing session" to receipt(showA, 1, 4, TrackingScrobbleAction.PAUSE, 55f, "2026-02-02T00:00:00Z"),
        "stop below completion on a new episode" to receipt(showA, 1, 5, TrackingScrobbleAction.STOP, 45f, "2026-02-02T00:00:00Z", id = 9),
        "pause on a movie" to receipt(movie, null, null, TrackingScrobbleAction.PAUSE, 10f, "2026-02-02T00:00:00Z", MdbListItemType.MOVIE, 10),
        "pause on a dropped season" to receipt(showC, 2, 6, TrackingScrobbleAction.PAUSE, 20f, "2026-02-02T00:00:00Z", id = 12),
        "pause on an episode watched later than the session" to receipt(showA, 1, 3, TrackingScrobbleAction.PAUSE, 20f, "2025-12-01T00:00:00Z", id = 14),
        // The session brings aliases or fields history lacks: history is re-resolved, as before.
        "pause on a brand new show" to receipt(newShow, 1, 1, TrackingScrobbleAction.PAUSE, 20f, "2026-02-02T00:00:00Z", id = 11),
        "pause on a dropped show whose aliases only meet in the session" to receipt(bridgeMedia, 2, 2, TrackingScrobbleAction.PAUSE, 20f, "2026-02-02T00:00:00Z", id = 13),
        "stop with an alias the history lacks" to receipt(aliasedShowC, 2, 6, TrackingScrobbleAction.STOP, 20f, "2026-02-02T00:00:00Z", id = 15),
    )
    private val rewritesHistory = setOf(
        "pause on a brand new show",
        "pause on a dropped show whose aliases only meet in the session",
        "stop with an alias the history lacks",
    )

    @Test
    fun `scrobbles produce what the pre-port code produced and update the projection like a rebuild`() {
        val projection = MdbListProgressProjection(base)
        for ((label, receipt) in scenarios) {
            val applied = base.applyScrobble(receipt, projection.mediaIndex)
            assertEquals(legacyApplyScrobble(base, receipt), applied, "$label: same snapshot as the pre-port code")
            assertEquals(applied, base.applyScrobble(receipt, null), "$label: indexed and unindexed apply agree")
            if (label in rewritesHistory) {
                assertNotSame(base.watched, applied.watched, "$label rewrites history")
            } else {
                assertSame(base.watched, applied.watched, "$label keeps the watched list")
                assertEquivalent(projection.withUpdatedPlayback(applied.playback), applied, label)
            }
        }
    }

    @Test
    fun `a session with a new alias leaves one id per show instead of two`() {
        val applied = base.applyScrobble(scenarios.getValue("stop with an alias the history lacks"), MdbListProgressProjection(base).mediaIndex)
        val projection = MdbListProgressProjection(applied)
        assertTrue(applied.watched.filter { it.media.ids.tmdb == 300L }.all { it.media.ids.imdb == "tt300" })
        assertTrue(projection.watchedItems.none { it.id == "tmdb:300" })
        assertTrue(projection.nextUpSeeds.none { it.parentMetaId == "tmdb:300" })
        assertTrue(projection.watchedKeys.any { "tt300" in it })
    }

    private fun commitLike(previous: MdbListSyncSnapshot, previousProjection: MdbListProgressProjection, next: MdbListSyncSnapshot) =
        if (previous.watched === next.watched && previous.dropped === next.dropped) {
            previousProjection.withUpdatedPlayback(next.playback)
        } else {
            MdbListProgressProjection(next)
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
            receipt(bridgeMedia, 2, 3, TrackingScrobbleAction.PAUSE, 12f, "2026-03-06T00:00:00Z", id = 5),
            receipt(bridgeMedia, 2, 3, TrackingScrobbleAction.START, 0f, "2026-03-07T00:00:00Z"),
            receipt(showA, 1, 4, TrackingScrobbleAction.START, 0f, "2026-03-08T00:00:00Z"),
        )
        steps.forEachIndexed { index, step ->
            val next = snapshot.applyScrobble(step, projection.mediaIndex)
            assertEquals(legacyApplyScrobble(snapshot, step), next, "step $index matches the pre-port snapshot")
            projection = commitLike(snapshot, projection, next)
            snapshot = next
            assertEquivalent(projection, snapshot, "step $index")
        }
    }

    @Test
    fun `removing a session that bridged aliases restores the full rebuild result`() {
        // A synced session knows show B under tvdb 201 as well, which is how the dropped record
        // (tvdb 201) reaches the watched history; once it goes the link must go with it.
        val bridging = session(20, bridgeMedia, 2, 2, 30f, "2026-02-04T00:00:00Z")
        val withBridge = base.copy(playback = base.playback + bridging)
        val projection = MdbListProgressProjection(withBridge)
        assertTrue(projection.isHidden("tt200"), "the bridging session links tt200 to the dropped tvdb id")

        val afterStart = withBridge.applyScrobble(
            receipt(bridgeMedia, 2, 2, TrackingScrobbleAction.START, 0f, "2026-02-05T00:00:00Z"), projection.mediaIndex,
        )
        assertSame(withBridge.watched, afterStart.watched)
        val incrementalStart = projection.withUpdatedPlayback(afterStart.playback)
        assertEquivalent(incrementalStart, afterStart, "start on the bridging session")
        assertFalse(incrementalStart.isHidden("tt200"))
        assertTrue(incrementalStart.nextUpSeeds.any { it.parentMetaId == "tt200" })

        val afterClear = withBridge.copy(playback = withBridge.playback.filterNot { it.id == 20L })
        assertEquivalent(projection.withUpdatedPlayback(afterClear.playback), afterClear, "clear of the bridging session")

        // And back again: the bridge reappears, then goes, on the same projection lineage.
        val readded = incrementalStart.withUpdatedPlayback(withBridge.playback)
        assertEquivalent(readded, withBridge, "bridging session returns")
        assertTrue(readded.isHidden("tt200"))
        assertEquivalent(readded.withUpdatedPlayback(emptyList()), withBridge.copy(playback = emptyList()), "everything cleared")
    }

    @Test
    fun `a completed scrobble rewrites history and needs a full rebuild`() {
        val projection = MdbListProgressProjection(base)
        val completed = base.applyScrobble(
            receipt(showA, 1, 4, TrackingScrobbleAction.STOP, 95f, "2026-02-03T00:00:00Z", id = 1), projection.mediaIndex,
        )
        assertEquals(legacyApplyScrobble(base, receipt(showA, 1, 4, TrackingScrobbleAction.STOP, 95f, "2026-02-03T00:00:00Z", id = 1)), completed)
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
    fun `an overlay index resolves exactly like an index built over history and playback`() {
        val sessions = listOf(
            session(30, bridgeMedia, 2, 2, 10f, "2026-02-04T00:00:00Z"),
            session(31, newShow, 1, 1, 10f, "2026-02-04T00:00:00Z"),
            session(32, aliasedShowC, 2, 7, 10f, "2026-02-04T00:00:00Z"),
            session(33, movie.copy(ids = movie.ids.copy(trakt = 55)), null, null, 10f, "2026-02-04T00:00:00Z", MdbListItemType.MOVIE),
        )
        val snapshot = base.copy(playback = sessions)
        val full = MdbListMediaIndex(snapshot)
        val watchedBase = MdbListMediaIndex.watchedOnly(snapshot.watched)
        val overlay = watchedBase.withPlayback(sessions)
        assertNotSame(watchedBase, overlay)
        val probes = listOf(
            MdbListIds(imdb = "tt200"), MdbListIds(tmdb = 200), MdbListIds(tvdb = 201), MdbListIds(imdb = "tt300"),
            MdbListIds(tmdb = 300), MdbListIds(imdb = "tt999"), MdbListIds(tmdb = 999), MdbListIds(trakt = 55),
            MdbListIds(imdb = "tt500"), MdbListIds(imdb = "tt100"), MdbListIds(imdb = "tt404"),
        )
        for (type in listOf(MdbListItemType.SHOW, MdbListItemType.MOVIE)) {
            for (ids in probes) {
                assertEquals(full.resolve(type, ids), overlay.resolve(type, ids), "resolve $type $ids")
                assertEquals(
                    full.resolveMedia(type, MdbListMedia(ids, "probe")), overlay.resolveMedia(type, MdbListMedia(ids, "probe")),
                    "resolveMedia $type $ids",
                )
            }
        }
        assertEquals(null, watchedBase.resolve(MdbListItemType.SHOW, MdbListIds(imdb = "tt999")).ids.tmdb, "the base is untouched")
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
