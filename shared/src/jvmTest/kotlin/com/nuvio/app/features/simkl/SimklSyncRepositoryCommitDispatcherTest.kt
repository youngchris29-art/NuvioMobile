package com.nuvio.app.features.simkl

import com.nuvio.app.features.tracking.TrackingMutationResult
import kotlinx.coroutines.CoroutineDispatcher
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.runBlocking
import kotlinx.serialization.json.JsonPrimitive
import java.util.concurrent.atomic.AtomicInteger
import kotlin.coroutines.CoroutineContext
import kotlin.test.AfterTest
import kotlin.test.BeforeTest
import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertTrue

/**
 * Commits run their snapshot work (reconcile, JSON encode, file write) on
 * [SimklSyncRepository.commitDispatcher], not on whichever thread resumed the network call.
 * JVM-only: the repository is a process-wide object backed by the in-memory JVM storage actual.
 */
class SimklSyncRepositoryCommitDispatcherTest {
    private class RecordingDispatcher : CoroutineDispatcher() {
        val dispatches = AtomicInteger()
        override fun dispatch(context: CoroutineContext, block: Runnable) {
            dispatches.incrementAndGet()
            Dispatchers.Default.dispatch(context, block)
        }
    }

    private val recorder = RecordingDispatcher()
    private var original: CoroutineDispatcher = Dispatchers.Default

    @BeforeTest
    fun install() {
        original = SimklSyncRepository.commitDispatcher
        SimklSyncRepository.commitDispatcher = recorder
        SimklSyncRepository.clearLocalState()
        SimklSyncRepository.ensureLoaded()
    }

    @AfterTest
    fun restore() {
        SimklSyncRepository.commitDispatcher = original
        SimklSyncRepository.clearLocalState()
    }

    private val movie = SimklMedia(title = "Movie", year = 2020, ids = mapOf("imdb" to JsonPrimitive("tt1234567")))

    private fun pause(playbackId: Long) = SimklScrobbleResult(
        outcome = SimklScrobbleOutcome.PAUSE,
        playbackId = playbackId,
        progress = 40.0,
        mediaType = SimklMediaType.MOVIES,
        media = movie,
        episode = null,
    )

    @Test
    fun `scrobble commits hop to the commit dispatcher and still publish the snapshot`() = runBlocking {
        val before = recorder.dispatches.get()
        SimklSyncRepository.commitScrobble(pause(5))
        assertTrue(recorder.dispatches.get() > before, "commitScrobble must dispatch through commitDispatcher")
        assertEquals(listOf(5L), SimklSyncRepository.state.value.snapshot.playback.map { it.id })
    }

    @Test
    fun `playback removal hops to the commit dispatcher and removes the session`() = runBlocking {
        SimklSyncRepository.commitScrobble(pause(6))
        val before = recorder.dispatches.get()
        SimklSyncRepository.commitPlaybackRemoval(setOf(6L))
        assertTrue(recorder.dispatches.get() > before, "commitPlaybackRemoval must dispatch through commitDispatcher")
        assertTrue(SimklSyncRepository.state.value.snapshot.playback.isEmpty())
    }

    @Test
    fun `mutation commits hop to the commit dispatcher`() = runBlocking {
        val before = recorder.dispatches.get()
        SimklSyncRepository.commitMutation(
            SimklMutationReceipt(TrackingMutationResult(attemptedCount = 0), SimklCommittedMutation.MoveToList(emptyList())),
        )
        assertTrue(recorder.dispatches.get() > before, "commitMutation must dispatch through commitDispatcher")
    }
}
