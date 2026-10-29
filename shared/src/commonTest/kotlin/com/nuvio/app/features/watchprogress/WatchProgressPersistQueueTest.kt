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
 * the order in which in-flight encodes finish; the store is an in-memory map.
 */
class WatchProgressPersistQueueTest {

    @Test
    fun `encode and write run on the queue scope and not on the caller`() = runTest {
        val harness = PersistQueueHarness(this)
        harness.holdEncodes = false

        harness.queue.enqueue(profileId = 1, snapshot = snapshot(entry("a", 10_000L)))

        assertTrue(harness.encodes.isEmpty())
        assertTrue(harness.writes.isEmpty())
        runCurrent()
        assertEquals(listOf(1 to "a@10000"), harness.writes)
    }

    @Test
    fun `an older encode that finishes last never overwrites the newer payload`() = runTest {
        val harness = PersistQueueHarness(this)
        harness.queue.enqueue(profileId = 1, snapshot = snapshot(entry("a", 10_000L)))
        harness.queue.enqueue(profileId = 1, snapshot = snapshot(entry("a", 20_000L)))
        runCurrent()
        assertEquals(listOf(1L, 2L), harness.encodes)

        harness.release(2L)
        runCurrent()
        harness.release(1L)
        runCurrent()

        assertEquals(listOf(1 to "a@20000"), harness.writes)
        assertNull(harness.queue.pending(1))
    }

    @Test
    fun `an older write that lands first keeps the newer snapshot pending`() = runTest {
        val harness = PersistQueueHarness(this)
        harness.queue.enqueue(profileId = 1, snapshot = snapshot(entry("a", 10_000L)))
        harness.queue.enqueue(profileId = 1, snapshot = snapshot(entry("a", 20_000L)))
        runCurrent()

        harness.release(1L)
        runCurrent()
        assertEquals(listOf(1 to "a@10000"), harness.writes)
        assertEquals(20_000L, harness.queue.pending(1)?.entries?.single()?.lastPositionMs)

        harness.release(2L)
        runCurrent()
        assertEquals(listOf(1 to "a@10000", 1 to "a@20000"), harness.writes)
        assertNull(harness.queue.pending(1))
    }

    @Test
    fun `latest prefers an in-flight snapshot over the stored payload`() = runTest {
        val harness = PersistQueueHarness(this)
        assertNull(harness.queue.latest(2))
        harness.stored[2] = StoredWatchProgressPayload(entries = listOf(entry("a", 1_000L)))
        assertEquals(listOf(entry("a", 1_000L)), harness.queue.latest(2)?.entries)

        val snapshot = snapshot(entry("a", 42_000L)).copy(
            lastSuccessfulPushEpochMs = 5_000L,
            deltaCursorEventId = 7L,
            deltaInitialized = true,
            dirtyProgressKeys = setOf("a"),
        )
        harness.queue.enqueue(profileId = 2, snapshot = snapshot)
        runCurrent()

        assertEquals(snapshot.copy(sequence = 1L), assertNotNull(harness.queue.pending(2)))
        assertEquals(
            StoredWatchProgressPayload(
                entries = listOf(entry("a", 42_000L)),
                lastSuccessfulPushEpochMs = 5_000L,
                deltaCursorEventId = 7L,
                deltaInitialized = true,
                dirtyProgressKeys = setOf("a"),
            ),
            harness.queue.latest(2),
        )
        assertTrue(harness.writes.isEmpty())

        harness.release(1L)
        runCurrent()
        assertNull(harness.queue.pending(2))
        assertEquals(listOf(entry("a", 42_000L)), harness.queue.latest(2)?.entries)
    }

    // Fork divergence: upstream keeps one global "already landed" sequence, so a newer persist for
    // the incoming profile dropped the outgoing profile's still-encoding last persist.
    @Test
    fun `the outgoing profile's last persist still lands after a switch`() = runTest {
        val harness = PersistQueueHarness(this)
        harness.queue.enqueue(profileId = 1, snapshot = snapshot(entry("a", 10_000L)))
        harness.queue.enqueue(profileId = 2, snapshot = snapshot(entry("b", 99_000L)))
        runCurrent()

        harness.release(2L)
        runCurrent()
        harness.release(1L)
        runCurrent()

        assertEquals(listOf(2 to "b@99000", 1 to "a@10000"), harness.writes)
        assertNull(harness.queue.pending(1))
        assertNull(harness.queue.pending(2))
    }

    // Fork: a cross-profile write (a scrobble for a profile that is not loaded) while that
    // profile's own last persist is still encoding.
    @Test
    fun `an upsert for a stored profile with a persist in flight is not lost`() = runTest {
        val harness = PersistQueueHarness(this)
        harness.stored[1] = StoredWatchProgressPayload(entries = listOf(entry("a", 1_000L)))
        harness.queue.enqueue(profileId = 1, snapshot = snapshot(entry("a", 10_000L)))
        runCurrent()

        var base: List<WatchProgressEntry>? = null
        harness.queue.update(profileId = 1) { stored ->
            base = stored?.entries
            stored?.let { it.copy(entries = it.entries + entry("b", 5_000L)) }
        }
        runCurrent()
        assertEquals(listOf(entry("a", 10_000L)), base)
        assertEquals(listOf(entry("a", 10_000L), entry("b", 5_000L)), harness.queue.latest(1)?.entries)

        // The cross-profile write finishes first; the older persist must not land on top of it.
        harness.release(2L)
        runCurrent()
        harness.release(1L)
        runCurrent()

        assertEquals(listOf(1 to "a@10000,b@5000"), harness.writes)
        assertEquals(listOf(entry("a", 10_000L), entry("b", 5_000L)), harness.stored[1]?.entries)
        assertNull(harness.queue.pending(1))
    }

    @Test
    fun `an update that declines to write issues nothing`() = runTest {
        val harness = PersistQueueHarness(this)
        var base: StoredWatchProgressPayload? = StoredWatchProgressPayload()

        assertNull(harness.queue.update(profileId = 4) { stored -> base = stored; null })
        runCurrent()

        assertNull(base)
        assertNull(harness.queue.pending(4))
        assertTrue(harness.encodes.isEmpty())
        assertTrue(harness.writes.isEmpty())
    }

    @Test
    fun `a persist launched before the sign-out wipe never writes afterwards`() = runTest {
        val harness = PersistQueueHarness(this)
        harness.queue.enqueue(profileId = 1, snapshot = snapshot(entry("a", 10_000L)))
        harness.queue.update(profileId = 3) {
            StoredWatchProgressPayload(entries = listOf(entry("c", 30_000L)))
        }
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
        harness.queue.enqueue(profileId = 1, snapshot = snapshot(entry("a", 5_000L)))
        runCurrent()
        assertEquals(listOf(1 to "a@5000"), harness.writes)
        assertNull(harness.queue.pending(1))
    }
}

/**
 * Upstream bb94cb1c1: an entry whose metadata enrichment keeps failing is retried at most three
 * times per video id. The repository filters `resolveRemoteMetadata`'s candidates through
 * [MetadataEnrichmentBackoff.withoutBackedOff], gates the upsert path's re-resolve on
 * [MetadataEnrichmentBackoff.isBackedOff], and calls `clear()` on profile load and sign-out.
 */
class MetadataEnrichmentBackoffTest {
    private val failing = entry("tt-missing", 1_000L)
    private val healthy = entry("tt-healthy", 1_000L)

    @Test
    fun `three failed enrichments back an entry off`() {
        val backoff = MetadataEnrichmentBackoff()
        repeat(2) { backoff.recordFailure(listOf(failing), providersReady = true) }
        assertFalse(backoff.isBackedOff(failing))
        assertEquals(listOf(failing, healthy), backoff.withoutBackedOff(listOf(failing, healthy)))

        backoff.recordFailure(listOf(failing), providersReady = true)
        assertTrue(backoff.isBackedOff(failing))
        assertFalse(backoff.isBackedOff(healthy))
        assertEquals(listOf(healthy), backoff.withoutBackedOff(listOf(failing, healthy)))
    }

    // Fork: upstream counted these, so cold-start runs ahead of the add-ons parked the rows.
    @Test
    fun `a fetch before any metadata provider was ready does not count`() {
        val backoff = MetadataEnrichmentBackoff()
        repeat(5) { backoff.recordFailure(listOf(failing), providersReady = false) }
        assertFalse(backoff.isBackedOff(failing))

        repeat(3) { backoff.recordFailure(listOf(failing), providersReady = true) }
        assertTrue(backoff.isBackedOff(failing))
    }

    @Test
    fun `the count is per video id and not per entry instance`() {
        val backoff = MetadataEnrichmentBackoff()
        repeat(3) { backoff.recordFailure(listOf(failing), providersReady = true) }
        assertTrue(backoff.isBackedOff(failing.copy(lastPositionMs = 50_000L, title = "Renamed")))
    }

    @Test
    fun `a success clears the video id's count`() {
        val backoff = MetadataEnrichmentBackoff()
        repeat(2) { backoff.recordFailure(listOf(failing), providersReady = true) }
        backoff.recordSuccess(listOf(failing))
        repeat(2) { backoff.recordFailure(listOf(failing), providersReady = true) }
        assertFalse(backoff.isBackedOff(failing))
    }

    @Test
    fun `clear on profile switch or sign-out forgets every count`() {
        val backoff = MetadataEnrichmentBackoff()
        repeat(3) { backoff.recordFailure(listOf(failing, healthy), providersReady = true) }
        assertTrue(backoff.isBackedOff(failing))
        assertTrue(backoff.isBackedOff(healthy))

        backoff.clear()
        assertFalse(backoff.isBackedOff(failing))
        assertFalse(backoff.isBackedOff(healthy))
    }
}

/** A [WatchProgressPersistQueue] over an in-memory store, with one encode gate per sequence. */
internal class PersistQueueHarness(scope: CoroutineScope) {
    val stored = mutableMapOf<Int, StoredWatchProgressPayload>()
    val writes = mutableListOf<Pair<Int, String>>()
    val encodes = mutableListOf<Long>()
    private val encoded = mutableMapOf<String, StoredWatchProgressPayload>()
    private val gates = mutableMapOf<Long, CompletableDeferred<Unit>>()
    var holdEncodes = true

    val queue = WatchProgressPersistQueue(
        scope = scope,
        encode = { pending ->
            encodes += pending.sequence
            if (holdEncodes) gate(pending.sequence).await()
            describe(pending.entries).also { payload ->
                encoded[payload] = StoredWatchProgressPayload(
                    entries = pending.entries,
                    lastSuccessfulPushEpochMs = pending.lastSuccessfulPushEpochMs,
                    deltaCursorEventId = pending.deltaCursorEventId,
                    deltaInitialized = pending.deltaInitialized,
                    dirtyProgressKeys = pending.dirtyProgressKeys,
                )
            }
        },
        write = { profileId, payload ->
            writes += profileId to payload
            stored[profileId] = encoded.getValue(payload)
        },
        read = { profileId -> stored[profileId] },
    )

    fun release(sequence: Long) {
        gate(sequence).complete(Unit)
    }

    fun releaseAll() {
        encodes.forEach(::release)
    }

    private fun gate(sequence: Long): CompletableDeferred<Unit> =
        gates.getOrPut(sequence) { CompletableDeferred() }

    private fun describe(entries: List<WatchProgressEntry>): String =
        entries.joinToString(separator = ",") { "${it.videoId}@${it.lastPositionMs}" }
}

private fun snapshot(vararg entries: WatchProgressEntry) = PendingWatchProgressPayload(
    entries = entries.toList(),
    lastSuccessfulPushEpochMs = 0L,
    deltaCursorEventId = 0L,
    deltaInitialized = false,
    dirtyProgressKeys = emptySet(),
)

private fun entry(videoId: String, positionMs: Long) = WatchProgressEntry(
    contentType = "movie",
    parentMetaId = videoId,
    parentMetaType = "movie",
    videoId = videoId,
    title = "Title $videoId",
    lastPositionMs = positionMs,
    durationMs = 120_000L,
    lastUpdatedEpochMs = 1_000L,
)
