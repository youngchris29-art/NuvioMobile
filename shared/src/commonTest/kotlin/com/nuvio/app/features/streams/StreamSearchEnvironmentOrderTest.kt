package com.nuvio.app.features.streams

import com.nuvio.app.features.addons.ManagedAddon
import com.nuvio.app.features.player.PlayerSourceFallbackCandidates
import com.nuvio.app.features.player.PlayerStreamsRepository
import com.nuvio.app.features.profiles.ProfileLifecycleCoordinator
import com.nuvio.app.features.profiles.ProfileLifecycleProvider
import com.nuvio.app.features.profiles.ProfileRepository
import kotlinx.coroutines.CompletableDeferred
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
 * search land there), or a builder's Nth debrid or add-on read.
 *
 * Review r10 findings: a request for another profile or account is never run; the repositories
 * rebuild it in the current world.
 */
@OptIn(ExperimentalCoroutinesApi::class)
class StreamSearchEnvironmentOrderTest {
    private val fetcher = ScriptedSearchFetcher()
    private val storeScope = CoroutineScope(SupervisorJob() + Dispatchers.Default.limitedParallelism(1))
    private val newerScope = CoroutineScope(SupervisorJob() + Dispatchers.Unconfined)
    private val originalCoordinator = ProfileLifecycleProvider.coordinator

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
    private var addonReads = 0
    /** Runs once, at the given add-on read (1-based), before that read answers. */
    private var atAddonRead: Pair<Int, () -> Unit>? = null

    @BeforeTest
    fun setUp() {
        StreamsRepository.clear()
        PlayerStreamsRepository.clearAll()
        StreamSearchSessions.installForTesting(store)
        StreamSearchEnvironment.installedAddons = {
            addonReads++
            atAddonRead?.let { (at, action) -> if (addonReads == at) { atAddonRead = null; action() } }
            addons
        }
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
        ProfileLifecycleProvider.coordinator = originalCoordinator
        ProfileRepository.clearInMemory()
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

    private fun StreamsUiState.labels(): List<String> = groups.flatMap { group -> group.streams.map { it.name.orEmpty() } }

    private class Newer(val targets: StreamSearchTargets, val job: Job, val received: MutableList<StreamLoadCompletion>)

    /** A screen built after the change: its search is acquired synchronously, here. */
    private fun startNewer(profileId: Int, addonNames: List<String>, debrid: String): Newer {
        val targets = StreamSearchTargets(
            type = "series",
            videoId = EPISODE,
            season = 1,
            episode = 1,
            streamAddons = addonNames.map { name -> SearchFixtures.target(name, EPISODE) },
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

    /**
     * Review r10 findings: the request built for the old profile or account never ran (one search,
     * the newer one, ever started), and the picker, rebuilt in the new world, joined it.
     */
    private suspend fun assertTheOldRequestWasRebuiltIntoTheNewer(newer: Newer, newerProfile: Int, gates: List<CompletableDeferred<Result<List<StreamItem>>>>) {
        awaitThat { atNextClockRead == null && store.heldKeys() == listOf(newer.targets.key(newerProfile)) }
        assertTheNewerSearchSurvives(newer, newerProfile)
        gates.forEach { it.complete(Result.success(listOf(SearchFixtures.stream(SearchFixtures.target("a").addonId, "new")))) }
        awaitThat { newer.job.isCompleted }
        assertEquals(1, store.startedCount, "the request built for the old world never ran")
        assertEquals(2, newer.received.size, "the newer search was not cut short")
        val picker = await(StreamsRepository.uiState, settled)
        assertEquals(listOf("new", "new"), picker.labels(), "the rebuilt picker shows the newer search's answers")
    }

    // MARK: the three evictions

    @Test
    fun aRequestBuiltBeforeAProfileSwitchNeverEvictsTheNewProfilesSearch() = runTest {
        val gates = listOf(fetcher.hold("a"), fetcher.hold("b"))
        var newer: Newer? = null
        atNextClockRead = {
            profile = 2                                             // the switch
            newer = startNewer(profileId = 2, addonNames = listOf("a", "b"), debrid = "none")
        }
        StreamsRepository.load(type = "series", videoId = EPISODE, season = 1, episode = 1)
        awaitThat { newer != null }
        assertTheOldRequestWasRebuiltIntoTheNewer(newer!!, newerProfile = 2, gates = gates)
    }

    @Test
    fun aRequestBuiltBeforeAnAccountChangeNeverEvictsTheNewAccountsSearch() = runTest {
        val gates = listOf(fetcher.hold("a"), fetcher.hold("b"))
        var newer: Newer? = null
        atNextClockRead = {
            debridConfiguration = "torbox:2"                        // the account change
            newer = startNewer(profileId = 1, addonNames = listOf("a", "b"), debrid = "torbox:2")
        }
        StreamsRepository.load(type = "series", videoId = EPISODE, season = 1, episode = 1)
        awaitThat { newer != null }
        assertTheOldRequestWasRebuiltIntoTheNewer(newer!!, newerProfile = 1, gates = gates)
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
        val labels = StreamsRepository.uiState.value.labels()
        assertFalse("late" in labels, "the old account's late answer is not delivered")
        assertEquals(checksBefore, fetcher.cacheChecks, "and never cache-checked")
        assertTrue(store.heldKeys().isEmpty(), "and never kept")
    }

    // MARK: every builder reads the world first

    /** The change lands at the builder's second debrid read: after its stamp, before its targets. */
    private fun changeTheAccountAfterTheStamp() {
        atDebridRead = 2 to { debridConfiguration = "torbox:2" }
    }

    /**
     * Review r10 findings: the request built across the change was refused and rebuilt in the new
     * world: one search ran, for the new account (a builder that read its stamp late would have
     * run one under the old account's key).
     */
    private fun assertItWasRebuiltForTheNewAccount() {
        assertEquals(1, store.startedCount, "one search ran")
        assertEquals(
            listOf("torbox:2"),
            store.heldKeys().map { it.sourceConfiguration.substringAfterLast("debrid:") },
            "the search that ran is the new account's",
        )
    }

    @Test
    fun thePickerReadsTheWorldFirst() = runTest {
        changeTheAccountAfterTheStamp()
        StreamsRepository.load(type = "series", videoId = EPISODE, season = 1, episode = 1)
        awaitThat { store.heldKeys().isNotEmpty() }
        await(StreamsRepository.uiState, settled)
        assertItWasRebuiltForTheNewAccount()
    }

    @Test
    fun thePickerReloadReadsTheWorldFirst() = runTest {
        changeTheAccountAfterTheStamp()
        StreamsRepository.reload(type = "series", videoId = EPISODE, season = 1, episode = 1)
        awaitThat { store.heldKeys().isNotEmpty() }
        await(StreamsRepository.uiState, settled)
        assertItWasRebuiltForTheNewAccount()
    }

    @Test
    fun theInPlayerSourcesListReadsTheWorldFirst() = runTest {
        changeTheAccountAfterTheStamp()
        PlayerStreamsRepository.loadEpisodeStreams(type = "series", videoId = EPISODE, season = 1, episode = 1)
        awaitThat { store.heldKeys().isNotEmpty() }
        await(PlayerStreamsRepository.episodeStreamsState, settled)
        assertItWasRebuiltForTheNewAccount()
    }

    @Test
    fun theFallbackWalkReadsTheWorldFirst() = runTest {
        changeTheAccountAfterTheStamp()
        val candidates = withContext(Dispatchers.Default) {
            PlayerSourceFallbackCandidates.load("series", EPISODE, 1, 1, timeoutMs = 10_000)
        }
        assertEquals(2, candidates.size, "the rebuilt request answers")
        assertItWasRebuiltForTheNewAccount()
    }

    // MARK: Stage B review r10 findings

    /** Finding 1: a wipe between a builder's stamp and its add-on read. */
    private fun wipeAtTheBuildersAddonRead() {
        atAddonRead = 2 to { StreamSearchSessions.clear() }       // read 1 is the stamp's
    }

    private fun assertNothingRanForTheWipedAccount() {
        assertEquals(emptyList(), fetcher.addonFetches, "nothing is fetched after the wipe")
        assertEquals(0, fetcher.cacheChecks, "nothing is cache-checked after the wipe")
        assertTrue(store.heldKeys().isEmpty(), "nothing is kept")
    }

    @Test
    fun aWipeDuringThePickersBuildRefusesItsRequest() = runTest {
        wipeAtTheBuildersAddonRead()
        StreamsRepository.load(type = "series", videoId = EPISODE, season = 1, episode = 1)
        await(StreamsRepository.uiState) { !it.isAnyLoading && it.groups.none { group -> group.isLoading } }
        assertNothingRanForTheWipedAccount()
    }

    @Test
    fun aWipeDuringTheInPlayerBuildRefusesItsRequest() = runTest {
        wipeAtTheBuildersAddonRead()
        PlayerStreamsRepository.loadEpisodeStreams(type = "series", videoId = EPISODE, season = 1, episode = 1)
        await(PlayerStreamsRepository.episodeStreamsState) { !it.isAnyLoading && it.groups.none { group -> group.isLoading } }
        assertNothingRanForTheWipedAccount()
    }

    @Test
    fun aWipeDuringTheFallbackWalksBuildRefusesItsRequest() = runTest {
        wipeAtTheBuildersAddonRead()
        val candidates = withContext(Dispatchers.Default) {
            PlayerSourceFallbackCandidates.load("series", EPISODE, 1, 1, timeoutMs = 10_000)
        }
        assertTrue(candidates.isEmpty())
        assertNothingRanForTheWipedAccount()
    }

    /**
     * Finding 2: a search built and admitted inside a profile selection, after the id moved and
     * before the fan-out reloaded the account, is never run.
     */
    @Test
    fun aSearchBuiltDuringAProfileSwitchNeverRunsTheMixedWorld() = runTest {
        StreamSearchEnvironment.profileId = { ProfileRepository.activeProfileId }
        debridConfiguration = "torbox:profile1"
        var startedInsideTheSwitch = -1
        ProfileLifecycleProvider.coordinator = object : ProfileLifecycleCoordinator {
            override fun onProfileSelected(profileIndex: Int) {
                // The id is already the new profile; the account is still the old one's.
                newerScope.launch(start = CoroutineStart.UNDISPATCHED) {
                    val targets = StreamSearchRequests.resolveTargets("series", EPISODE, 1, 1)!!
                    store.search(StreamSearchEnvironment.profileId(), targets, forceRefresh = false).collect { }
                }
                startedInsideTheSwitch = store.startedCount
                debridConfiguration = "torbox:profile2"              // the fan-out's account step
            }

            override fun onProfilesCached() {}
        }
        ProfileRepository.selectProfile(profileIndex = 2)
        assertEquals(0, startedInsideTheSwitch, "a search built across the switch is never run")
        assertTrue(store.heldKeys().none { it.sourceConfiguration.endsWith("debrid:torbox:profile1") })
    }

    /** Finding 3: a manifest refresh that moves an add-on's fetch URL is a new search. */
    @Test
    fun aMovedManifestIsNeverServedFromTheOldSearch() = runTest {
        StreamsRepository.load(type = "series", videoId = EPISODE, season = 1, episode = 1)
        await(StreamsRepository.uiState, settled)
        val a = SearchFixtures.managedAddon("a")
        addons = listOf(a.copy(manifest = a.manifest!!.copy(transportUrl = "https://a-moved.example.com/manifest.json")), SearchFixtures.managedAddon("b"))
        StreamsRepository.load(type = "series", videoId = EPISODE, season = 1, episode = 1)
        awaitThat { store.startedCount == 2 }
        await(StreamsRepository.uiState, settled)
        assertEquals(2, store.startedCount, "the repeat is not skipped and does not join the old manifest's search")
    }

    /** Finding 8: an add-on refresh that changes nothing keeps the request shared. */
    @Test
    fun anUnchangedAddonRefreshKeepsTheRequestShared() = runTest {
        atDebridRead = 2 to { addons = addons.map { it.copy(isRefreshing = true) } }
        StreamsRepository.load(type = "series", videoId = EPISODE, season = 1, episode = 1)
        await(StreamsRepository.uiState, settled)
        assertEquals(1, store.heldKeys().size, "held and joinable, not run privately")
    }

    private companion object {
        const val EPISODE = "tt1:1:1"
    }
}
