package com.nuvio.app.features.watchprogress

import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertTrue

/** [planLocalProgressRestore]: what the tvOS mpv player's undo of a live stream's resume saves writes. */
class WatchProgressRestoreTest {
    private fun entry(
        videoId: String,
        parentMetaId: String,
        lastUpdatedEpochMs: Long,
        positionMs: Long = 10_000L,
        completed: Boolean = false,
    ): WatchProgressEntry = WatchProgressEntry(
        contentType = "movie",
        parentMetaId = parentMetaId,
        parentMetaType = "movie",
        videoId = videoId,
        title = videoId,
        lastPositionMs = positionMs,
        durationMs = 100_000L,
        lastUpdatedEpochMs = lastUpdatedEpochMs,
        isCompleted = completed,
    )

    @Test
    fun `restored entry keeps its own timestamp and fields and its key is dirty`() {
        val prior = entry("tt1", "tt1", lastUpdatedEpochMs = 1_000L, positionMs = 600_000L, completed = true)
        val overwritten = prior.copy(lastPositionMs = 30_000L, lastUpdatedEpochMs = 9_000L, isCompleted = false)

        val plan = planLocalProgressRestore(current = listOf(overwritten), videoId = "tt1", captured = listOf(prior))

        assertEquals(listOf(prior.withResolvedProgressKey()), plan.upserts)
        assertEquals(1_000L, plan.upserts.single().lastUpdatedEpochMs)
        assertTrue(plan.upserts.single().isCompleted)
        assertEquals(setOf(prior.resolvedProgressKey()), plan.dirtyKeys)
        assertTrue(plan.removals.isEmpty(), "the session's write shares the prior's key: overwritten, not removed")
    }

    @Test
    fun `an entry the session wrote under another parent id is removed`() {
        // The save stored a provider-normalised parent id, the prior kept the add-on's.
        val prior = entry("tt1", "addon:tt1", lastUpdatedEpochMs = 1_000L)
        val sessionWrite = entry("tt1", "tt1", lastUpdatedEpochMs = 9_000L)

        val plan = planLocalProgressRestore(current = listOf(prior, sessionWrite), videoId = "tt1", captured = listOf(prior))

        assertEquals(listOf(prior.withResolvedProgressKey()), plan.upserts)
        assertEquals(listOf(sessionWrite), plan.removals)
    }

    @Test
    fun `nothing captured removes every local entry for the video and nothing else`() {
        val sessionWrite = entry("tt1", "tt1", lastUpdatedEpochMs = 9_000L)
        val other = entry("tt2", "tt2", lastUpdatedEpochMs = 5_000L)

        val plan = planLocalProgressRestore(current = listOf(sessionWrite, other), videoId = "tt1", captured = emptyList())

        assertTrue(plan.upserts.isEmpty())
        assertTrue(plan.dirtyKeys.isEmpty())
        assertEquals(listOf(sessionWrite), plan.removals)
    }
}
