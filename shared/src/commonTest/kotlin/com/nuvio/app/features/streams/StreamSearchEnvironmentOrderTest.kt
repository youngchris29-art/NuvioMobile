package com.nuvio.app.features.streams

import com.nuvio.app.features.addons.ManagedAddon
import com.nuvio.app.features.player.PlayerSourceFallbackCandidates
import com.nuvio.app.features.player.PlayerStreamsRepository
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.CoroutineStart
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.ExperimentalCoroutinesApi
import kotlinx.coroutines.Job
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.cancel
import kotlinx.coroutines.delay
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.first
import kotlinx.coroutines.launch
import kotlinx.coroutines.test.runTest
import kotlinx.coroutines.withContext
import kotlinx.coroutines.withTimeout
import kotlin.test.AfterTest
import kotlin.test.BeforeTest
import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertFalse
import kotlin.test.assertTrue

/**
 * Stage B review r10: a request built before a change of profile, debrid account, add-on set or a
 * wipe never affects a search built after it; and every builder reads the world first. The real
 * builders run against one store with a scripted fetcher. Pause points are synchronous hooks:
 * the store's first clock read during the old request's acquisition (the change and the newer
 * search land there), or the builder's second debrid read (the change lands after the stamp).
 */
@OptIn(ExperimentalCoroutinesApi::class)
class StreamSearchEnvironmentOrderTest {
    private val fetcher = ScriptedSearchFetcher()
    private val storeScope = CoroutineScope(SupervisorJob() + Dispatchers.Default.limitedParallelism(1))
    private val newerScope = CoroutineScope(SupervisorJob() + Dispatchers.Unconfined)

    /** Runs once, at the store's next clock read: inside an acquisition, before its decision. */
    private var atNextClockRead: (() -> Unit)? = null
    private val store = StreamSearchSessionStore(fetcher, now = {
        atNextClockRead?.also { atNextClockRead = null }?.invoke()
        0L
    }, scope = storeScope)

    private var profile = 1
    private var debridConfiguration = "none"
    private var addons: List<ManagedAddon> = listOf(SearchFixtures.managedAddon("a"), SearchFixtures.managedAddon("b"))
    private var debridReads = 0
    /** Runs once, at the given debrid read (1-based), before that read answers. */
    private var atDebridRead: Pair<Int, () -> Unit>? = null

    @BeforeTest
    fun setUp() {
        StreamsRepository.clear()
        PlayerStreamsRepository.clearAll()
        StreamSearchSessions.installForTesting(store)
        StreamSearchEnvironment.installedAddons = { addons }
        StreamSearchEnvironment.debrid = {
            debridReads++
            atDebridRead?.let { (at, action) -> if (debridReads == at) { atDebridRead = null; action() } }
            StreamSearchDebrid(debridConfiguration, null)
        }
        StreamSearchEnvironment.profileId = { profile }
    }

    @AfterTest
    fun tearDown() {
        StreamsRepository.clear()
        PlayerStreamsRepository.clearAll()
        StreamSearchSessions.resetForTesting()
        StreamSearchEnvironment.resetForTesting()
        storeScope.cancel()
        newerScope.cancel()
    }

    private suspend fun await(flow: StateFlow<StreamsUiState>, what: (StreamsUiState) -> Boolean): StreamsUiState =
        withContext(Dispatchers.Default) { withTimeout(10_000) { flow.first(what) } }

    private suspend fun awaitThat(what: () -> Boolean) {
        withContext(Dispatchers.Default) { withTimeout(10_000) { while (!what()) delay(5) } }
    }

    private val settled: (StreamsUiState) -> Boolean = { state ->
        state.groups.isNotEmpty() && !state.isAnyLoading && state.groups.none { it.isLoading }
    }

    private class Newer(val targets: StreamSearchTargets, val job: Job, val received: MutableList<StreamLoadCompletion>)

    /** A screen built after the change: its search is acquired synchronously, here. */
    private fun startNewer(profileId: Int, addonNames: List<String>, debrid: String): Newer {
        val targets = StreamSearchTargets(
            type = "series",
            videoId = EPISODE,
            season = 1,
            episode = 1,
            streamAddons = addonNames.map { SearchFixtures.target(it, EPISODE) },
            pluginProviderGroups = emptyList(),
            debrid = StreamSearchDebrid(debrid, null),
            pluginGeneration = store.pluginGeneration(),
        )
        val received = mutableListOf<StreamLoadCompletion>()
        val job = newerScope.launch(start = CoroutineStart.UNDISPATCHED) {
            store.search(profileId, targets, forceRefresh = false).collect { received += it }
        }
        return Newer(targets, job, received)
    }

    /** Every add-on answer waits, so both searches are still running when the test looks. */
    private fun holdEverything() {
        repeat(2) { fetcher.hold("a"); fetcher.hold("b") }
    }

    private fun assertTheNewerSearchSurvives(newer: Newer, newerProfile: Int) {
        assertEquals(listOf(newer.targets.key(newerProfile)), store.heldKeys(), "only the newer search is held")
        assertFalse(newer.job.isCompleted, "the newer search is not evicted by the request built before it")
    }

    // MARK: the three evictions

    @Test
    fun aRequestBuiltBeforeAProfileSwitchNeverEvictsTheNewProfilesSearch() = runTest {
        holdEverything()
        var newer: Newer? = null
        atNextClockRead = {
            profile = 2                                             // the switch
            newer = startNewer(profileId = 2, addonNames = listOf("a", "b"), debrid = "none")
        }
        StreamsRepository.load(type = "series", videoId = EPISODE, season = 1, episode = 1)
        awaitThat { store.startedCount == 2 }
        assertTheNewerSearchSurvives(newer!!, newerProfile = 2)
    }

    @Test
    fun aRequestBuiltBeforeAnAccountChangeNeverEvictsTheNewAccountsSearch() = runTest {
        holdEverything()
        var newer: Newer? = null
        atNextClockRead = {
            debridConfiguration = "torbox:2"                        // the account change
            newer = startNewer(profileId = 1, addonNames = listOf("a", "b"), debrid = "torbox:2")
        }
        StreamsRepository.load(type = "series", videoId = EPISODE, season = 1, episode = 1)
        awaitThat { store.startedCount == 2 }
        assertTheNewerSearchSurvives(newer!!, newerProfile = 1)
    }

    @Test
    fun aRequestBuiltBeforeAnAddonRemovalNeverEvictsTheNewSetsSearch() = runTest {
        holdEverything()
        var newer: Newer? = null
        atNextClockRead = {
            addons = listOf(SearchFixtures.managedAddon("a"))       // add-on b removed
            newer = startNewer(profileId = 1, addonNames = listOf("a"), debrid = "none")
        }
        StreamsRepository.load(type = "series", videoId = EPISODE, season = 1, episode = 1)
        awaitThat { store.startedCount == 2 }
        assertTheNewerSearchSurvives(newer!!, newerProfile = 1)
    }

    // MARK: the wipe

    @Test
    fun aRequestBuiltBeforeAWipeFetchesNothingAfterIt() = runTest {
        debridConfiguration = "torbox:old"
        atNextClockRead = { StreamSearchSessions.clear() }          // the wipe lands before the acquisition
        StreamsRepository.load(type = "series", videoId = EPISODE, season = 1, episode = 1)
        val picker = await(StreamsRepository.uiState) { !it.isAnyLoading && it.groups.none { group -> group.isLoading } }
        assertEquals(emptyList(), fetcher.addonFetches, "nothing is fetched for the old account")
        assertEquals(0, fetcher.cacheChecks, "nothing is cache-checked with the old account")
        assertTrue(store.heldKeys().isEmpty(), "nothing is kept")
        assertTrue(picker.groups.all { it.streams.isEmpty() }, "nothing is delivered")
    }

    @Test
    fun aSearchRunningAtTheWipeDeliversAndKeepsNothingAfterIt() = runTest {
        debridConfiguration = "torbox:old"
        val gate = fetcher.hold("a")
        StreamsRepository.load(type = "series", videoId = EPISODE, season = 1, episode = 1)
        await(StreamsRepository.uiState) { state -> state.groups.any { it.streams.isNotEmpty() } }   // b answered
        val checksBefore = fetcher.cacheChecks
        StreamSearchSessions.clear()
        gate.complete(Result.success(listOf(SearchFixtures.stream(SearchFixtures.target("a").addonId, "late"))))
        awaitThat { store.heldKeys().isEmpty() }
        delay(50)
        val labels = StreamsRepository.uiState.value.groups.flatMap { group -> group.streams.map { it.name.orEmpty() } }
        assertFalse("late" in labels, "the old account's late answer is not delivered")
        assertEquals(checksBefore, fetcher.cacheChecks, "and never cache-checked")
        assertTrue(store.heldKeys().isEmpty(), "and never kept")
    }

    // MARK: every builder reads the world first

    /** The change lands at the builder's second debrid read: after its stamp, before its targets. */
    private fun changeTheAccountAfterTheStamp() {
        atDebridRead = 2 to { debridConfiguration = "torbox:2" }
    }

    private fun assertItRanPrivately() {
        assertEquals(1, store.startedCount, "one search ran")
        assertTrue(store.heldKeys().isEmpty(), "built across the change: run privately, never held")
    }

    @Test
    fun thePickerReadsTheWorldFirst() = runTest {
        changeTheAccountAfterTheStamp()
        StreamsRepository.load(type = "series", videoId = EPISODE, season = 1, episode = 1)
        await(StreamsRepository.uiState, settled)
        assertItRanPrivately()
    }

    @Test
    fun thePickerReloadReadsTheWorldFirst() = runTest {
        changeTheAccountAfterTheStamp()
        StreamsRepository.reload(type = "series", videoId = EPISODE, season = 1, episode = 1)
        await(StreamsRepository.uiState, settled)
        assertItRanPrivately()
    }

    @Test
    fun theInPlayerSourcesListReadsTheWorldFirst() = runTest {
        changeTheAccountAfterTheStamp()
        PlayerStreamsRepository.loadEpisodeStreams(type = "series", videoId = EPISODE, season = 1, episode = 1)
        await(PlayerStreamsRepository.episodeStreamsState, settled)
        assertItRanPrivately()
    }

    @Test
    fun theFallbackWalkReadsTheWorldFirst() = runTest {
        changeTheAccountAfterTheStamp()
        val candidates = withContext(Dispatchers.Default) {
            PlayerSourceFallbackCandidates.load("series", EPISODE, 1, 1, timeoutMs = 10_000)
        }
        assertEquals(2, candidates.size, "the private run still answers")
        assertItRanPrivately()
    }

    private companion object {
        const val EPISODE = "tt1:1:1"
    }
}
