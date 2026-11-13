package com.nuvio.app.features.trakt

import com.nuvio.app.features.library.LibraryItem
import com.nuvio.app.features.profiles.ProfileRepository
import kotlinx.coroutines.CompletableDeferred
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.CoroutineStart
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.async
import kotlinx.coroutines.cancelAndJoin
import kotlinx.coroutines.launch
import kotlinx.coroutines.runBlocking
import kotlinx.coroutines.withTimeout
import kotlin.test.AfterTest
import kotlin.test.BeforeTest
import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertFailsWith
import kotlin.test.assertFalse
import kotlin.test.assertTrue

/**
 * W7 (P1): a Trakt library refresh started under one profile publishes nothing into, and writes
 * nothing for, the profile that is active when it lands.
 */
class TraktLibraryProfileSwitchTest {

    private val watchlistTab = TraktListTab(key = "trakt:watchlist", title = "Watchlist", type = TraktListType.WATCHLIST)

    private fun state(vararg ids: String): TraktLibraryUiState {
        val items = ids.map { LibraryItem(id = it, type = "movie", name = it, savedAtEpochMs = 0L) }
        return TraktLibraryUiState(
            listTabs = listOf(watchlistTab),
            entriesByList = mapOf(watchlistTab.key to items),
            allItems = items,
            hasLoaded = true,
        )
    }

    private fun ids() = TraktLibraryRepository.uiState.value.allItems.map { it.id }

    private class Gate {
        val entered = CompletableDeferred<Unit>()
        val release = CompletableDeferred<Unit>()
    }

    /** Publishes [first] as a partial, parks until released, publishes [last] as a partial, returns [last]. */
    private fun gated(
        gate: Gate,
        first: TraktLibraryUiState,
        last: TraktLibraryUiState,
    ): suspend (Map<String, String>, (TraktLibraryUiState) -> Unit) -> TraktLibraryUiState = { _, onPartial ->
        onPartial(first)
        gate.entered.complete(Unit)
        gate.release.await()
        onPartial(last)
        last
    }

    private val originalHeaders = TraktLibraryRepository.authorizedHeadersSource
    private val originalFetcher = TraktLibraryRepository.snapshotFetcher
    private val originalLoader = TraktLibraryRepository.payloadLoader
    private val originalSaver = TraktLibraryRepository.payloadSaver
    private val originalWriter = TraktLibraryRepository.membershipWriter
    private val originalTabsFetcher = TraktLibraryRepository.listTabsFetcher
    private val saves = mutableListOf<Pair<Int, String>>()
    private val writes = mutableListOf<Pair<String, Boolean>>()

    private val toggledItem = LibraryItem(id = "tt-x", type = "movie", name = "x", savedAtEpochMs = 0L)
    private fun watchlistOn() = TraktMembershipChanges(mapOf("trakt:watchlist" to true))

    /** Profile [profile]'s persisted payload after a refresh that returned [ids]; leaves [profile] active. */
    private suspend fun payloadFor(profile: Int, vararg ids: String): String {
        ProfileRepository.selectProfile(profile)
        TraktLibraryRepository.onProfileChanged()
        TraktLibraryRepository.snapshotFetcher = { _, _ -> state(*ids) }
        TraktLibraryRepository.ensureFresh()
        return saves.last().second.also { saves.clear() }
    }

    @BeforeTest
    fun setUp() {
        ProfileRepository.clearInMemory()
        TraktLibraryRepository.payloadLoader = { _ -> null }
        TraktLibraryRepository.payloadSaver = { id, p -> saves += id to p }
        TraktLibraryRepository.membershipWriter = { _, k, add, _ -> writes += k to add }
        TraktLibraryRepository.authorizedHeadersSource = { mapOf("Authorization" to "Bearer test") }
        TraktLibraryRepository.onProfileChanged()
        saves.clear()
        writes.clear()
    }

    @AfterTest
    fun tearDown() {
        TraktLibraryRepository.authorizedHeadersSource = originalHeaders
        TraktLibraryRepository.snapshotFetcher = originalFetcher
        TraktLibraryRepository.payloadSaver = originalSaver
        TraktLibraryRepository.membershipWriter = originalWriter
        TraktLibraryRepository.listTabsFetcher = originalTabsFetcher
        TraktLibraryRepository.payloadLoader = { _ -> null }
        ProfileRepository.clearInMemory()
        TraktLibraryRepository.onProfileChanged()
        TraktLibraryRepository.payloadLoader = originalLoader
    }

    @Test
    fun aRefreshStartedForOneProfileNeverPublishesOrPersistsIntoTheNext() = runBlocking {
        withTimeout(10_000) {
            val gate = Gate()
            TraktLibraryRepository.snapshotFetcher = gated(gate, state("tt-a1"), state("tt-a1", "tt-a2"))
            val job = launch(Dispatchers.Default) { TraktLibraryRepository.ensureFresh() }
            gate.entered.await()
            assertEquals(listOf("tt-a1"), ids())

            ProfileRepository.selectProfile(2)
            TraktLibraryRepository.onProfileChanged()
            assertTrue(ids().isEmpty())

            val seen = mutableListOf<List<String>>()
            val collector = launch(Dispatchers.Default, start = CoroutineStart.UNDISPATCHED) {
                TraktLibraryRepository.uiState.collect { s -> seen += s.allItems.map { it.id } }
            }
            gate.release.complete(Unit)
            job.join()
            collector.cancelAndJoin()

            assertTrue(ids().isEmpty())
            assertTrue(seen.flatten().none { it.startsWith("tt-a") }, "$seen")
            assertTrue(saves.isEmpty(), "$saves")
        }
    }

    @Test
    fun theNextProfilesOwnRefreshStillRunsAfterTheOldOneIsDiscarded() = runBlocking {
        withTimeout(10_000) {
            // (a) profile 2 refreshes and persists its own library.
            ProfileRepository.selectProfile(2)
            TraktLibraryRepository.onProfileChanged()
            TraktLibraryRepository.snapshotFetcher = { _, _ -> state("tt-b0") }
            TraktLibraryRepository.ensureFresh()
            val payloadB = saves.single().also { assertEquals(2, it.first) }.second

            // (b) back to profile 1, with profile 2's file readable.
            TraktLibraryRepository.payloadLoader = { id -> if (id == 2) payloadB else null }
            ProfileRepository.selectProfile(1)
            TraktLibraryRepository.onProfileChanged()
            saves.clear()

            // (c) a gated profile 1 refresh, switched to profile 2 mid-flight.
            val gate = Gate()
            TraktLibraryRepository.snapshotFetcher = gated(gate, state("tt-a1"), state("tt-a1", "tt-a2"))
            val job = launch(Dispatchers.Default) { TraktLibraryRepository.ensureFresh() }
            gate.entered.await()
            ProfileRepository.selectProfile(2)
            TraktLibraryRepository.onProfileChanged()
            assertEquals(listOf("tt-b0"), ids())
            gate.release.complete(Unit)
            job.join()

            // (d) nothing of profile 1 landed.
            assertEquals(listOf("tt-b0"), ids())
            assertTrue(saves.isEmpty(), "$saves")

            // (e) profile 2's own refresh is not suppressed by profile 1's discarded stamp.
            TraktLibraryRepository.snapshotFetcher = { _, _ -> state("tt-b1") }
            TraktLibraryRepository.ensureFresh()
            assertEquals(listOf("tt-b1"), ids())
            val saved = saves.single()
            assertEquals(2, saved.first)
            assertTrue(saved.second.contains("tt-b1"), saved.second)
            assertFalse(saved.second.contains("tt-a"), saved.second)
        }
    }

    @Test
    fun aSwitchAwayAndBackStillDiscardsTheOlderRequest() = runBlocking {
        withTimeout(10_000) {
            val gate = Gate()
            TraktLibraryRepository.snapshotFetcher = gated(gate, state("tt-a1"), state("tt-a1", "tt-a2"))
            val job = launch(Dispatchers.Default) { TraktLibraryRepository.ensureFresh() }
            gate.entered.await()
            ProfileRepository.selectProfile(2)
            TraktLibraryRepository.onProfileChanged()
            ProfileRepository.selectProfile(1)
            TraktLibraryRepository.onProfileChanged()
            gate.release.complete(Unit)
            job.join()

            assertTrue(ids().isEmpty(), "${ids()}")
            assertTrue(saves.isEmpty(), "$saves")
        }
    }

    @Test
    fun signOutDuringARefreshWritesNothingBack() = runBlocking {
        withTimeout(10_000) {
            val gate = Gate()
            TraktLibraryRepository.snapshotFetcher = gated(gate, state("tt-a1"), state("tt-a1", "tt-a2"))
            val job = launch(Dispatchers.Default) { TraktLibraryRepository.ensureFresh() }
            gate.entered.await()
            TraktLibraryRepository.clearLocalState()
            gate.release.complete(Unit)
            job.join()

            assertTrue(ids().isEmpty(), "${ids()}")
            assertEquals(listOf(1 to ""), saves.toList())
        }
    }

    @Test
    fun aRefreshWithNoSwitchPublishesAndPersistsAsBefore() = runBlocking {
        withTimeout(10_000) {
            val gate = Gate()
            TraktLibraryRepository.snapshotFetcher = gated(gate, state("tt-a1"), state("tt-a1", "tt-a2"))
            val job = launch(Dispatchers.Default) { TraktLibraryRepository.ensureFresh() }
            gate.entered.await()
            gate.release.complete(Unit)
            job.join()

            assertEquals(listOf("tt-a1", "tt-a2"), ids())
            val saved = saves.single()
            assertEquals(1, saved.first)
            assertTrue(saved.second.contains("tt-a2"), saved.second)
        }
    }

    @Test
    fun aToggleStartedForOneProfileIsAbandonedWhenTheProfileChangesFirst() = runBlocking {
        withTimeout(10_000) {
            val payloadA = payloadFor(1, "tt-a1")
            TraktLibraryRepository.payloadLoader = { id -> if (id == 1) payloadA else null }
            ProfileRepository.selectProfile(1)
            TraktLibraryRepository.onProfileChanged()
            val gate = Gate()
            TraktLibraryRepository.snapshotFetcher = gated(gate, state("tt-a1"), state("tt-a1"))
            val job = launch(Dispatchers.Default) {
                TraktLibraryRepository.applyMembershipChanges(toggledItem, watchlistOn())
            }
            gate.entered.await()
            ProfileRepository.selectProfile(2)
            TraktLibraryRepository.onProfileChanged()
            gate.release.complete(Unit)
            job.join()

            assertTrue(writes.isEmpty(), "$writes")
            assertFalse("tt-x" in ids(), "${ids()}")
            assertTrue(saves.isEmpty(), "$saves")
        }
    }

    @Test
    fun aToggleWithNoSwitchWritesOnceAndShowsAtOnce() = runBlocking {
        withTimeout(10_000) {
            val payloadA = payloadFor(1, "tt-a1")
            TraktLibraryRepository.payloadLoader = { id -> if (id == 1) payloadA else null }
            ProfileRepository.selectProfile(1)
            TraktLibraryRepository.onProfileChanged()
            TraktLibraryRepository.snapshotFetcher = { _, _ -> state("tt-a1") }
            TraktLibraryRepository.ensureFresh()

            TraktLibraryRepository.applyMembershipChanges(toggledItem, watchlistOn())

            assertEquals(listOf("trakt:watchlist" to true), writes.toList())
            assertTrue("tt-x" in ids(), "${ids()}")
        }
    }

    @Test
    fun aFailedToggleRollsBackOnlyItsOwnProfile() = runBlocking {
        withTimeout(10_000) {
            val payloadA = payloadFor(1, "tt-a1")
            TraktLibraryRepository.payloadLoader = { id -> if (id == 1) payloadA else null }
            ProfileRepository.selectProfile(1)
            TraktLibraryRepository.onProfileChanged()
            TraktLibraryRepository.snapshotFetcher = { _, _ -> state("tt-a1") }
            TraktLibraryRepository.ensureFresh()

            // (a) the profile switches while the write is in flight, then the write fails.
            val gate = Gate()
            TraktLibraryRepository.membershipWriter = { _, _, _, _ ->
                gate.entered.complete(Unit)
                gate.release.await()
                error("boom")
            }
            val scope = CoroutineScope(SupervisorJob() + Dispatchers.Default)
            val job = scope.async { TraktLibraryRepository.applyMembershipChanges(toggledItem, watchlistOn()) }
            gate.entered.await()
            ProfileRepository.selectProfile(2)
            TraktLibraryRepository.onProfileChanged()
            gate.release.complete(Unit)
            assertFailsWith<IllegalStateException> { job.await() }
            assertTrue(ids().isEmpty(), "${ids()}")

            // (b) no switch: the failure rolls the profile's own state back.
            ProfileRepository.selectProfile(1)
            TraktLibraryRepository.onProfileChanged()
            TraktLibraryRepository.snapshotFetcher = { _, _ -> state("tt-a1") }
            TraktLibraryRepository.ensureFresh()
            val before = ids()
            TraktLibraryRepository.membershipWriter = { _, _, _, _ -> error("boom") }
            assertFailsWith<IllegalStateException> {
                TraktLibraryRepository.applyMembershipChanges(toggledItem, watchlistOn())
            }
            assertEquals(before, ids())
        }
    }

    @Test
    fun aListTabPreloadFinishingAfterASwitchIsDiscarded() = runBlocking {
        withTimeout(10_000) {
            val gate = Gate()
            TraktLibraryRepository.listTabsFetcher = {
                gate.entered.complete(Unit)
                gate.release.await()
                listOf(watchlistTab)
            }
            val job = launch(Dispatchers.Default) { TraktLibraryRepository.ensureListTabs() }
            gate.entered.await()
            ProfileRepository.selectProfile(2)
            TraktLibraryRepository.onProfileChanged()
            gate.release.complete(Unit)
            job.join()

            assertTrue(TraktLibraryRepository.currentListTabs().isEmpty(), "${TraktLibraryRepository.currentListTabs()}")
        }
    }

    @Test
    fun ensureLoadedReloadsForTheSelectedProfileAfterABootTimeLoad() = runBlocking {
        withTimeout(10_000) {
            val payloadA = payloadFor(1, "tt-a1")
            val payloadB = payloadFor(2, "tt-b1")
            TraktLibraryRepository.payloadLoader = { id -> mapOf(1 to payloadA, 2 to payloadB)[id] }
            ProfileRepository.clearInMemory()
            TraktLibraryRepository.onProfileChanged()
            assertEquals(listOf("tt-a1"), ids())

            // A profile change without the fan-out (the test coordinator is a no-op).
            ProfileRepository.selectProfile(2)
            TraktLibraryRepository.ensureLoaded()
            assertEquals(listOf("tt-b1"), ids())
        }
    }

    @Test
    fun aDiskLoadFinishingAfterASwitchIsDiscarded() = runBlocking {
        withTimeout(10_000) {
            val payloadA = payloadFor(1, "tt-a1")
            val payloadB = payloadFor(2, "tt-b1")
            TraktLibraryRepository.payloadLoader = { id ->
                if (id == 1) {
                    // The switch, and profile 2's own load, happen while profile 1's read is in progress.
                    ProfileRepository.selectProfile(2)
                    TraktLibraryRepository.onProfileChanged()
                    payloadA
                } else {
                    payloadB
                }
            }
            ProfileRepository.clearInMemory()
            TraktLibraryRepository.onProfileChanged()

            assertEquals(listOf("tt-b1"), ids())
        }
    }
}
