package com.nuvio.app.features.simkl

import com.nuvio.app.core.profile.ActiveProfileIdProvider
import com.nuvio.app.core.profile.ActiveProfileProvider
import com.nuvio.app.core.storage.ProfileScopedKey
import com.nuvio.app.core.storage.jvmSharedPreferences
import com.nuvio.app.features.profiles.ProfileRepository
import com.nuvio.app.features.tracking.TrackingExternalIds
import com.nuvio.app.features.tracking.TrackingMediaKind
import com.nuvio.app.features.tracking.TrackingMediaReference
import com.nuvio.app.features.tracking.TrackingMutationResult
import kotlinx.atomicfu.locks.synchronized
import kotlinx.coroutines.CoroutineDispatcher
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.cancel
import kotlinx.coroutines.flow.launchIn
import kotlinx.coroutines.flow.onEach
import kotlinx.coroutines.runBlocking
import kotlinx.serialization.json.JsonPrimitive
import java.util.concurrent.ConcurrentLinkedQueue
import java.util.concurrent.CountDownLatch
import java.util.concurrent.TimeUnit
import kotlin.concurrent.thread
import kotlin.coroutines.CoroutineContext
import kotlin.test.AfterTest
import kotlin.test.BeforeTest
import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertFalse
import kotlin.test.assertNull
import kotlin.test.assertTrue

/**
 * Commits run their snapshot work (reconcile, JSON encode, file write, publish) on
 * [SimklSyncRepository.commitDispatcher], not on whichever thread resumed the network call, and
 * never write a snapshot into a profile or sign-in state that has moved on.
 * JVM-only: the repository is a process-wide object backed by the in-memory JVM storage actual.
 */
class SimklSyncRepositoryCommitDispatcherTest {
    private class RecordingDispatcher : CoroutineDispatcher() {
        val threads = ConcurrentLinkedQueue<Thread>()
        override fun dispatch(context: CoroutineContext, block: Runnable) {
            Dispatchers.Default.dispatch(context, Runnable {
                threads.add(Thread.currentThread())
                block.run()
            })
        }
    }

    private val recorder = RecordingDispatcher()
    private val saveThreads = ConcurrentLinkedQueue<Thread>()
    private val publishThreads = ConcurrentLinkedQueue<Thread>()
    private var original: CoroutineDispatcher = Dispatchers.Default
    private var originalProfileProvider = ActiveProfileProvider.provider
    private var publishScope: CoroutineScope? = null

    @BeforeTest
    fun install() {
        // The repository captures ProfileRepository.activeProfileId while the storage's active-profile
        // key comes from ActiveProfileProvider. Production wires the second to the first (see
        // TvOsProviderInstaller); do the same here so another test class that left the process-wide
        // profile at a different slot cannot split them.
        originalProfileProvider = ActiveProfileProvider.provider
        ActiveProfileProvider.provider = ActiveProfileIdProvider { ProfileRepository.activeProfileId }
        original = SimklSyncRepository.commitDispatcher
        SimklSyncRepository.commitDispatcher = recorder
        SimklSyncRepository.beforeSaveHook = { saveThreads.add(Thread.currentThread()) }
        SimklSyncRepository.clearLocalState()
        SimklSyncRepository.ensureLoaded()
        // Unconfined: the collector resumes on the thread that sets the state, i.e. the publisher.
        val scope = CoroutineScope(Dispatchers.Unconfined)
        publishScope = scope
        SimklSyncRepository.state
            .onEach { state -> if (state.snapshot != SimklSyncSnapshot()) publishThreads.add(Thread.currentThread()) }
            .launchIn(scope)
        publishThreads.clear()
    }

    @AfterTest
    fun restore() {
        publishScope?.cancel()
        SimklSyncRepository.commitDispatcher = original
        SimklSyncRepository.beforeSaveHook = {}
        SimklSyncRepository.afterSaveHook = {}
        SimklSyncRepository.clearLocalState()
        ActiveProfileProvider.provider = originalProfileProvider
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

    private fun addToWatchlist() = SimklMutationReceipt(
        TrackingMutationResult(attemptedCount = 1),
        SimklCommittedMutation.MoveToList(
            listOf(
                SimklResolvedListMutation(
                    request = TrackingMediaReference(
                        TrackingMediaKind.MOVIE, "Watchlist movie", ids = TrackingExternalIds(imdb = "tt7654321"),
                    ),
                    status = SimklListStatus.entries.first(),
                    responseMedia = SimklMedia(title = "Watchlist movie", ids = mapOf("imdb" to JsonPrimitive("tt7654321"))),
                ),
            ),
        ),
    )

    private fun assertOffCallerThread(caller: Thread, label: String) {
        assertTrue(saveThreads.isNotEmpty(), "$label: the save ran")
        assertTrue(saveThreads.all { it !== caller && it in recorder.threads }, "$label: save on the commit dispatcher")
        assertTrue(publishThreads.isNotEmpty(), "$label: the snapshot was published")
        assertTrue(publishThreads.all { it !== caller && it in recorder.threads }, "$label: publish on the commit dispatcher")
    }

    @Test
    fun `scrobble commit saves and publishes on the commit dispatcher`() = runBlocking {
        SimklSyncRepository.commitScrobble(pause(5))
        assertEquals(listOf(5L), SimklSyncRepository.state.value.snapshot.playback.map { it.id })
        assertOffCallerThread(Thread.currentThread(), "commitScrobble")
        assertTrue(SimklSyncStorage.loadPayload().orEmpty().contains("\"id\":5"), "snapshot persisted for the active profile")
    }

    @Test
    fun `playback removal saves and publishes on the commit dispatcher`() = runBlocking {
        SimklSyncRepository.commitScrobble(pause(6))
        saveThreads.clear()
        publishThreads.clear()
        SimklSyncRepository.commitPlaybackRemoval(setOf(6L))
        assertTrue(SimklSyncRepository.state.value.snapshot.playback.isEmpty())
        assertTrue(saveThreads.all { it !== Thread.currentThread() && it in recorder.threads } && saveThreads.isNotEmpty(), "save on the commit dispatcher")
        assertFalse(SimklSyncStorage.loadPayload().orEmpty().contains("\"id\":6"), "removal persisted")
    }

    @Test
    fun `mutation commit that changes the snapshot saves and publishes on the commit dispatcher`() = runBlocking {
        SimklSyncRepository.commitMutation(addToWatchlist())
        assertEquals(1, SimklSyncRepository.state.value.snapshot.entries.size)
        assertOffCallerThread(Thread.currentThread(), "commitMutation")
        assertTrue(SimklSyncStorage.loadPayload().orEmpty().contains("tt7654321"))
    }

    @Test
    fun `a profile change landing after the encode stops the write and the publish`() = runBlocking {
        SimklSyncRepository.beforeSaveHook = { SimklSyncRepository.onProfileChanged() }
        SimklSyncRepository.commitScrobble(pause(7))
        assertTrue(SimklSyncRepository.state.value.snapshot.playback.isEmpty(), "stale snapshot not published")
        assertTrue(SimklSyncStorage.loadPayload().isNullOrBlank(), "stale snapshot not written")

        SimklSyncRepository.commitMutation(addToWatchlist())
        assertTrue(SimklSyncRepository.state.value.snapshot.entries.isEmpty())
        assertTrue(SimklSyncStorage.loadPayload().isNullOrBlank())
    }

    @Test
    fun `a sign out landing after the encode does not recreate the wiped file`() = runBlocking {
        SimklSyncRepository.beforeSaveHook = { SimklSyncRepository.clearLocalState() }
        SimklSyncRepository.commitScrobble(pause(8))
        assertTrue(SimklSyncRepository.state.value.snapshot.playback.isEmpty())
        assertTrue(SimklSyncStorage.loadPayload().isNullOrBlank(), "wiped file stays wiped")
    }

    @Test
    fun `playback removal is dropped when the profile changed after the encode`() = runBlocking {
        SimklSyncRepository.commitScrobble(pause(9))
        val persisted = SimklSyncStorage.loadPayload()
        SimklSyncRepository.beforeSaveHook = { SimklSyncRepository.onProfileChanged() }
        SimklSyncRepository.commitPlaybackRemoval(setOf(9L))
        assertEquals(persisted, SimklSyncStorage.loadPayload(), "removal not written over the reloaded profile")
    }

    @Test
    fun `a sign out landing between the write and the publish publishes nothing`() = runBlocking {
        SimklSyncRepository.afterSaveHook = { SimklSyncRepository.clearLocalState() }
        SimklSyncRepository.commitScrobble(pause(10))
        assertTrue(SimklSyncRepository.state.value.snapshot.playback.isEmpty(), "old snapshot not published over the cleared state")
        assertTrue(SimklSyncStorage.loadPayload().isNullOrBlank())

        SimklSyncRepository.commitMutation(addToWatchlist())
        assertTrue(SimklSyncRepository.state.value.snapshot.entries.isEmpty())

        SimklSyncRepository.afterSaveHook = {}
        SimklSyncRepository.commitScrobble(pause(11))
        SimklSyncRepository.afterSaveHook = { SimklSyncRepository.clearLocalState() }
        SimklSyncRepository.commitPlaybackRemoval(setOf(11L))
        assertTrue(SimklSyncRepository.state.value.snapshot.playback.isEmpty())
        assertTrue(SimklSyncStorage.loadPayload().isNullOrBlank())
    }

    @Test
    fun `publishing keeps changes made to the state while the commit was writing`() = runBlocking {
        SimklSyncRepository.afterSaveHook = { SimklSyncRepository.invalidateProjections() }
        val before = SimklSyncRepository.state.value.projectionVersion
        SimklSyncRepository.commitScrobble(pause(12))
        val after = SimklSyncRepository.state.value
        assertEquals(listOf(12L), after.snapshot.playback.map { it.id })
        assertEquals(before + 1, after.projectionVersion, "the concurrent projection bump survives the publish")
    }

    private fun holdSaveLock() = holdLock(SimklSyncRepository.saveLock)

    private fun holdLock(lock: kotlinx.atomicfu.locks.SynchronizedObject): Pair<Thread, CountDownLatch> {
        val entered = CountDownLatch(1)
        val release = CountDownLatch(1)
        val holder = thread {
            synchronized(lock) {
                entered.countDown()
                release.await(10, TimeUnit.SECONDS)
            }
        }
        assertTrue(entered.await(5, TimeUnit.SECONDS))
        return holder to release
    }

    @Test
    fun `sign out waits for a write that already passed its check`() {
        val (holder, release) = holdSaveLock()
        val cleared = CountDownLatch(1)
        val signOut = thread { SimklSyncRepository.clearLocalState(); cleared.countDown() }
        assertFalse(cleared.await(300, TimeUnit.MILLISECONDS), "clearLocalState must wait for the save lock")
        release.countDown()
        assertTrue(cleared.await(5, TimeUnit.SECONDS))
        holder.join(); signOut.join()
    }

    @Test
    fun `a commit write waits while sign out holds the save lock`() {
        val (holder, release) = holdSaveLock()
        val committed = CountDownLatch(1)
        val commit = thread { runBlocking { SimklSyncRepository.commitScrobble(pause(13)) }; committed.countDown() }
        assertFalse(committed.await(300, TimeUnit.MILLISECONDS), "the write must wait for the save lock")
        assertTrue(SimklSyncStorage.loadPayload().isNullOrBlank())
        release.countDown()
        assertTrue(committed.await(5, TimeUnit.SECONDS))
        assertTrue(SimklSyncStorage.loadPayload().orEmpty().contains("\"id\":13"))
        holder.join(); commit.join()
    }

    @Test
    fun `a profile change never waits for a file write but does wait for a publish`() {
        val (writer, endWrite) = holdSaveLock()
        val changedDuringWrite = CountDownLatch(1)
        val first = thread { SimklSyncRepository.onProfileChanged(); changedDuringWrite.countDown() }
        assertTrue(changedDuringWrite.await(5, TimeUnit.SECONDS), "onProfileChanged must not wait for the save lock")
        endWrite.countDown()
        writer.join(); first.join()

        val (publisher, endPublish) = holdLock(SimklSyncRepository.stateLock)
        val changedDuringPublish = CountDownLatch(1)
        val second = thread { SimklSyncRepository.onProfileChanged(); changedDuringPublish.countDown() }
        assertFalse(changedDuringPublish.await(300, TimeUnit.MILLISECONDS), "onProfileChanged must wait for a publish in progress")
        endPublish.countDown()
        assertTrue(changedDuringPublish.await(5, TimeUnit.SECONDS))
        publisher.join(); second.join()
    }

    @Test
    fun `a publish waits for the state lock so it cannot land in a state reset after its check`() {
        val (resetter, endReset) = holdLock(SimklSyncRepository.stateLock)
        val committed = CountDownLatch(1)
        val commit = thread { runBlocking { SimklSyncRepository.commitScrobble(pause(14)) }; committed.countDown() }
        assertFalse(committed.await(300, TimeUnit.MILLISECONDS), "the publish must wait for the state lock")
        assertTrue(SimklSyncRepository.state.value.snapshot.playback.isEmpty())
        endReset.countDown()
        assertTrue(committed.await(5, TimeUnit.SECONDS))
        assertEquals(listOf(14L), SimklSyncRepository.state.value.snapshot.playback.map { it.id })
        resetter.join(); commit.join()
    }

    @Test
    fun `save by profile id writes that profile's file and leaves the active one alone`() {
        val active = ProfileRepository.activeProfileId
        val other = active + 6
        val preferences = jvmSharedPreferences("nuvio_simkl_sync")
        try {
            SimklSyncStorage.savePayload("active-payload")
            SimklSyncStorage.savePayload(other, "other-payload")
            assertEquals("other-payload", preferences.getString(ProfileScopedKey.of("simkl_sync_snapshot", other), null))
            assertEquals("active-payload", SimklSyncStorage.loadPayload())
            assertEquals("active-payload", preferences.getString(ProfileScopedKey.of("simkl_sync_snapshot", active), null))
        } finally {
            SimklSyncStorage.removeProfile(other)
            assertNull(preferences.getString(ProfileScopedKey.of("simkl_sync_snapshot", other), null))
        }
    }
}
