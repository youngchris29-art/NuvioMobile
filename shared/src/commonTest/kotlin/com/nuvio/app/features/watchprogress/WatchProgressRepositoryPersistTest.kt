package com.nuvio.app.features.watchprogress

import com.nuvio.app.features.player.PlayerPlaybackSnapshot
import kotlinx.coroutines.test.runCurrent
import kotlinx.coroutines.test.runTest
import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertNull
import kotlin.test.assertTrue

/**
 * The repository's own wiring of [WatchProgressPersistQueue] (upstream bb94cb1c1 + the fork's
 * sign-out guard), driven through the real singleton with its queue swapped for one over an
 * in-memory store ([WatchProgressRepository.persistQueue] is the seam).
 */
class WatchProgressRepositoryPersistTest {

    @Test
    fun `a profile load prefers the in-flight snapshot over the stored file`() = runTest {
        val harness = PersistQueueHarness(this)
        val original = WatchProgressRepository.persistQueue
        WatchProgressRepository.persistQueue = harness.queue
        try {
            harness.stored[PROFILE_ID] = StoredWatchProgressPayload(entries = listOf(entry("tt-stale")))
            harness.queue.enqueue(
                profileId = PROFILE_ID,
                snapshot = PendingWatchProgressPayload(
                    entries = listOf(entry("tt-fresh")),
                    lastSuccessfulPushEpochMs = 0L,
                    deltaCursorEventId = 0L,
                    deltaInitialized = false,
                    dirtyProgressKeys = emptySet(),
                ),
            )
            runCurrent()

            WatchProgressRepository.onProfileChanged(PROFILE_ID)

            assertEquals(
                listOf("tt-fresh"),
                WatchProgressRepository.uiState.value.entries.map(WatchProgressEntry::videoId),
            )
        } finally {
            WatchProgressRepository.clearLocalState()
            WatchProgressRepository.persistQueue = original
            harness.releaseAll()
            runCurrent()
        }
    }

    @Test
    fun `sign-out drops a persist launched before the wipe`() = runTest {
        val harness = PersistQueueHarness(this)
        val original = WatchProgressRepository.persistQueue
        WatchProgressRepository.persistQueue = harness.queue
        try {
            harness.queue.enqueue(
                profileId = PROFILE_ID,
                snapshot = PendingWatchProgressPayload(
                    entries = listOf(entry("tt-outgoing")),
                    lastSuccessfulPushEpochMs = 0L,
                    deltaCursorEventId = 0L,
                    deltaInitialized = false,
                    dirtyProgressKeys = emptySet(),
                ),
            )
            runCurrent()

            WatchProgressRepository.clearLocalState()

            assertNull(harness.queue.pending(PROFILE_ID))
            harness.releaseAll()
            runCurrent()
            assertTrue(harness.writes.isEmpty())
        } finally {
            WatchProgressRepository.persistQueue = original
        }
    }

    @Test
    fun `a cross-profile upsert keeps the in-flight persist of the outgoing profile and its own entry`() = runTest {
        val harness = PersistQueueHarness(this)
        val original = WatchProgressRepository.persistQueue
        WatchProgressRepository.persistQueue = harness.queue
        try {
            // Profile 7's last persist from while it was current, still encoding (sequence 1).
            harness.queue.enqueue(
                profileId = PROFILE_ID,
                snapshot = PendingWatchProgressPayload(
                    entries = listOf(entry("tt-outgoing")),
                    lastSuccessfulPushEpochMs = 0L,
                    deltaCursorEventId = 0L,
                    deltaInitialized = false,
                    dirtyProgressKeys = emptySet(),
                ),
            )
            runCurrent()
            WatchProgressRepository.onProfileChanged(OTHER_PROFILE_ID)

            // A scrobble for profile 7 while 8 is loaded takes upsertStoredProfileProgress (sequence 2).
            WatchProgressRepository.upsertPlaybackProgress(
                session = WatchProgressPlaybackSession(
                    profileId = PROFILE_ID,
                    contentType = "movie",
                    parentMetaId = "tt-scrobbled",
                    parentMetaType = "movie",
                    videoId = "tt-scrobbled",
                    title = "Title tt-scrobbled",
                ),
                snapshot = PlayerPlaybackSnapshot(
                    isLoading = false,
                    isPlaying = true,
                    durationMs = 1_200_000L,
                    positionMs = 60_000L,
                ),
                syncRemote = false,
            )
            runCurrent()

            // The upsert lands first, then the older persist finishes encoding and is dropped.
            harness.release(2L)
            runCurrent()
            harness.release(1L)
            runCurrent()

            val stored = harness.stored.getValue(PROFILE_ID)
            assertEquals(
                setOf("tt-outgoing", "tt-scrobbled"),
                stored.entries.map(WatchProgressEntry::videoId).toSet(),
            )
            assertEquals(60_000L, stored.entries.single { it.videoId == "tt-scrobbled" }.lastPositionMs)
            assertEquals(1, stored.dirtyProgressKeys.size)
            assertEquals(listOf(PROFILE_ID), harness.writes.map { it.first })
        } finally {
            WatchProgressRepository.clearLocalState()
            WatchProgressRepository.persistQueue = original
            harness.releaseAll()
            runCurrent()
        }
    }

    private companion object {
        // Slots no other test loads, so onProfileChanged() never short-circuits on them.
        const val PROFILE_ID = 7
        const val OTHER_PROFILE_ID = 8

        /** Complete display metadata, so loading it never starts a remote metadata fetch. */
        fun entry(videoId: String) = WatchProgressEntry(
            contentType = "movie",
            parentMetaId = videoId,
            parentMetaType = "movie",
            videoId = videoId,
            title = "Title $videoId",
            poster = "https://example.com/$videoId/poster.jpg",
            background = "https://example.com/$videoId/background.jpg",
            lastPositionMs = 9_000L,
            durationMs = 120_000L,
            lastUpdatedEpochMs = 1_000L,
        )
    }
}
