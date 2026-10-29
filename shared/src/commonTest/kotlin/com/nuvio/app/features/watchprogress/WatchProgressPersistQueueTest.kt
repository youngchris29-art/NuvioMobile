package com.nuvio.app.features.watchprogress

import kotlinx.coroutines.CompletableDeferred
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.test.runCurrent
import kotlinx.coroutines.test.runTest
import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertFalse
import kotlin.test.assertNotNull
import kotlin.test.assertNull
import kotlin.test.assertTrue

/**
 * Upstream bb94cb1c1: watch-progress persists are snapshotted, sequenced, and encoded + written
 * off the caller's thread. The encode here suspends on a per-sequence gate so each case decides
 * the order in which in-flight encodes finish.
 */
class WatchProgressPersistQueueTest {

    private class Harness(scope: CoroutineScope) {
        val writes = mutableListOf<Pair<Int, String>>()
        val encodes = mutableListOf<Long>()
        private val gates = mutableMapOf<Long, CompletableDeferred<Unit>>()
        var holdEncodes = true

        val queue = WatchProgressPersistQueue(
            scope = scope,
            encode = { pending ->
                encodes += pending.sequence
                if (holdEncodes) gate(pending.sequence).await()
                "position=${pending.entries.single().lastPositionMs}"
            },
            write = { profileId, payload -> writes += profileId to payload },
        )

        fun gate(sequence: Long): CompletableDeferred<Unit> =
            gates.getOrPut(sequence) { CompletableDeferred() }

        fun release(sequence: Long) {
            gate(sequence).complete(Unit)
        }
    }

    @Test
    fun `encode and write run on the queue scope and not on the caller`() = runTest {
        val harness = Harness(this)
        harness.holdEncodes = false

        harness.queue.enqueue(profileId = 1, snapshot = snapshot(positionMs = 10_000L))

        assertTrue(harness.encodes.isEmpty())
        assertTrue(harness.writes.isEmpty())
        runCurrent()
        assertEquals(listOf(1 to "position=10000"), harness.writes)
    }

    @Test
    fun `an older encode that finishes last never overwrites the newer payload`() = runTest {
        val harness = Harness(this)
        harness.queue.enqueue(profileId = 1, snapshot = snapshot(positionMs = 10_000L))
        harness.queue.enqueue(profileId = 1, snapshot = snapshot(positionMs = 20_000L))
        runCurrent()
        assertEquals(listOf(1L, 2L), harness.encodes)

        harness.release(2L)
        runCurrent()
        harness.release(1L)
        runCurrent()

        assertEquals(listOf(1 to "position=20000"), harness.writes)
        assertNull(harness.queue.pending(1))
    }

    @Test
    fun `an older write that lands first keeps the newer snapshot pending`() = runTest {
        val harness = Harness(this)
        harness.queue.enqueue(profileId = 1, snapshot = snapshot(positionMs = 10_000L))
        harness.queue.enqueue(profileId = 1, snapshot = snapshot(positionMs = 20_000L))
        runCurrent()

        harness.release(1L)
        runCurrent()
        assertEquals(listOf(1 to "position=10000"), harness.writes)
        assertEquals(20_000L, harness.queue.pending(1)?.entries?.single()?.lastPositionMs)

        harness.release(2L)
        runCurrent()
        assertEquals(listOf(1 to "position=10000", 1 to "position=20000"), harness.writes)
        assertNull(harness.queue.pending(1))
    }

    @Test
    fun `a load during an in-flight persist sees the pending snapshot`() = runTest {
        val harness = Harness(this)
        val snapshot = snapshot(positionMs = 42_000L).copy(
            lastSuccessfulPushEpochMs = 5_000L,
            deltaCursorEventId = 7L,
            deltaInitialized = true,
            dirtyProgressKeys = setOf("tt123:1:1"),
        )
        harness.queue.enqueue(profileId = 2, snapshot = snapshot)
        runCurrent()

        val pending = assertNotNull(harness.queue.pending(2))
        assertTrue(harness.writes.isEmpty())
        assertEquals(snapshot.copy(sequence = 1L), pending)
        assertNull(harness.queue.pending(1))

        harness.release(1L)
        runCurrent()
        assertNull(harness.queue.pending(2))
        assertEquals(listOf(2 to "position=42000"), harness.writes)
    }

    // Fork divergence: upstream keeps one global "already landed" sequence, so a newer persist for
    // the incoming profile dropped the outgoing profile's still-encoding last persist.
    @Test
    fun `the outgoing profile's last persist still lands after a switch`() = runTest {
        val harness = Harness(this)
        harness.queue.enqueue(profileId = 1, snapshot = snapshot(positionMs = 10_000L))
        harness.queue.enqueue(profileId = 2, snapshot = snapshot(positionMs = 99_000L))
        runCurrent()

        harness.release(2L)
        runCurrent()
        harness.release(1L)
        runCurrent()

        assertEquals(listOf(2 to "position=99000", 1 to "position=10000"), harness.writes)
        assertNull(harness.queue.pending(1))
        assertNull(harness.queue.pending(2))
    }

    @Test
    fun `a persist launched before the sign-out wipe never writes afterwards`() = runTest {
        val harness = Harness(this)
        harness.queue.enqueue(profileId = 1, snapshot = snapshot(positionMs = 10_000L))
        harness.queue.enqueue(profileId = 3, snapshot = snapshot(positionMs = 30_000L))
        runCurrent()

        harness.queue.invalidate()
        assertNull(harness.queue.pending(1))
        assertNull(harness.queue.pending(3))

        harness.release(1L)
        harness.release(2L)
        runCurrent()
        assertTrue(harness.writes.isEmpty())

        // The next account's persists still land.
        harness.holdEncodes = false
        harness.queue.enqueue(profileId = 1, snapshot = snapshot(positionMs = 5_000L))
        runCurrent()
        assertEquals(listOf(1 to "position=5000"), harness.writes)
        assertNull(harness.queue.pending(1))
    }

    private fun snapshot(positionMs: Long) = PendingWatchProgressPayload(
        entries = listOf(progressEntry(videoId = "tt123:1:1", positionMs = positionMs)),
        lastSuccessfulPushEpochMs = 0L,
        deltaCursorEventId = 0L,
        deltaInitialized = false,
        dirtyProgressKeys = emptySet(),
    )
}

/**
 * Upstream bb94cb1c1: an entry whose metadata enrichment keeps failing is retried at most three
 * times per video id. The repository filters `resolveRemoteMetadata`'s candidates through
 * [MetadataEnrichmentBackoff.withoutBackedOff], gates the upsert path's re-resolve on
 * [MetadataEnrichmentBackoff.isBackedOff], and calls `clear()` on profile load and sign-out.
 */
class MetadataEnrichmentBackoffTest {
    private val failing = progressEntry(videoId = "tt-missing", positionMs = 1_000L)
    private val healthy = progressEntry(videoId = "tt-healthy", positionMs = 1_000L)

    @Test
    fun `three failed enrichments back an entry off`() {
        val backoff = MetadataEnrichmentBackoff()
        repeat(2) { backoff.recordFailure(listOf(failing)) }
        assertFalse(backoff.isBackedOff(failing))
        assertEquals(listOf(failing, healthy), backoff.withoutBackedOff(listOf(failing, healthy)))

        backoff.recordFailure(listOf(failing))
        assertTrue(backoff.isBackedOff(failing))
        assertFalse(backoff.isBackedOff(healthy))
        assertEquals(listOf(healthy), backoff.withoutBackedOff(listOf(failing, healthy)))
    }

    @Test
    fun `the count is per video id and not per entry instance`() {
        val backoff = MetadataEnrichmentBackoff()
        repeat(3) { backoff.recordFailure(listOf(failing)) }
        assertTrue(backoff.isBackedOff(failing.copy(lastPositionMs = 50_000L, title = "Renamed")))
    }

    @Test
    fun `a success clears the video id's count`() {
        val backoff = MetadataEnrichmentBackoff()
        repeat(2) { backoff.recordFailure(listOf(failing)) }
        backoff.recordSuccess(listOf(failing))
        repeat(2) { backoff.recordFailure(listOf(failing)) }
        assertFalse(backoff.isBackedOff(failing))
    }

    @Test
    fun `clear on profile switch or sign-out forgets every count`() {
        val backoff = MetadataEnrichmentBackoff()
        repeat(3) { backoff.recordFailure(listOf(failing, healthy)) }
        assertTrue(backoff.isBackedOff(failing))
        assertTrue(backoff.isBackedOff(healthy))

        backoff.clear()
        assertFalse(backoff.isBackedOff(failing))
        assertFalse(backoff.isBackedOff(healthy))
    }
}

private fun progressEntry(
    videoId: String,
    positionMs: Long,
) = WatchProgressEntry(
    contentType = "series",
    parentMetaId = "tt123",
    parentMetaType = "series",
    videoId = videoId,
    title = "Episode",
    seasonNumber = 1,
    episodeNumber = 1,
    lastPositionMs = positionMs,
    durationMs = 60_000L,
    lastUpdatedEpochMs = 1_000L,
)
