package com.nuvio.app.features.streams

import com.nuvio.app.core.profile.ProfileTransition
import com.nuvio.app.features.addons.ManagedAddon
import com.nuvio.app.features.player.PlayerSourceFallbackCandidates
import com.nuvio.app.features.player.PlayerStreamsRepository
import com.nuvio.app.features.plugins.PluginsUiState
import kotlinx.atomicfu.locks.SynchronizedObject
import kotlinx.atomicfu.locks.synchronized
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.ExperimentalCoroutinesApi
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.cancel
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.first
import kotlinx.coroutines.test.runTest
import kotlinx.coroutines.withContext
import kotlinx.coroutines.withTimeout
import kotlin.test.AfterTest
import kotlin.test.BeforeTest
import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertTrue

/**
 * Pre-cut follow-ups 1.4: the landed source-fallback rules, pinned without a production seam.
 *
 * (a) The profile transition is part of [StreamSearchEnvironmentStamp.sameAccountAs].
 * (b) One load is rebuilt at most [STREAM_SEARCH_MAX_WORLD_RETRIES] times, by the picker, the
 *     in-player list and the fallback walk alike.
 */
@OptIn(ExperimentalCoroutinesApi::class)
class StreamSearchWorldTest {

    // MARK: (a) the transition is part of the account

    private enum class TransitionCase(val built: ProfileTransition, val now: ProfileTransition) {
        Equal(ProfileTransition(5L, changing = false), ProfileTransition(5L, changing = false)),
        VersionDiffers(ProfileTransition(5L, changing = false), ProfileTransition(6L, changing = false)),
        // Design review r5 (B): the same version, changing in both stamps. The stamps are equal, so
        // only `!profileTransition.changing` refuses this row.
        BuiltWhileChanging(ProfileTransition(5L, changing = true), ProfileTransition(5L, changing = true)),
        ChangingNow(ProfileTransition(5L, changing = false), ProfileTransition(6L, changing = true)),
    }

    private fun stamp(transition: ProfileTransition, profileId: Int, debrid: String) = StreamSearchEnvironmentStamp(
        profileTransition = transition,
        profileId = profileId,
        debridConfiguration = debrid,
        addons = listOf(SearchFixtures.managedAddon("a")),
        plugins = PluginsUiState(pluginsEnabled = false),
    )

    @Test
    fun onlyTheSameSettledTransitionProfileAndAccountIsTheSameAccount() {
        var rows = 0
        for (transition in TransitionCase.entries) {
            for (sameProfile in listOf(true, false)) {
                for (sameDebrid in listOf(true, false)) {
                    rows++
                    val built = stamp(transition.built, profileId = 1, debrid = "torbox:1")
                    val now = stamp(
                        transition.now,
                        profileId = if (sameProfile) 1 else 2,
                        debrid = if (sameDebrid) "torbox:1" else "torbox:2",
                    )
                    val expected = transition == TransitionCase.Equal && sameProfile && sameDebrid
                    assertEquals(
                        expected,
                        built.sameAccountAs(now),
                        "transition=$transition sameProfile=$sameProfile sameDebrid=$sameDebrid",
                    )
                }
            }
        }
        assertEquals(16, rows, "every transition, profile and debrid combination")
    }

    // MARK: (b) at most three rebuilds per load

    private val fetcher = ScriptedSearchFetcher()
    private val storeScope = CoroutineScope(SupervisorJob() + Dispatchers.Default.limitedParallelism(1))
    private val counterLock = SynchronizedObject()
    private var environmentReads = 0

    /** Every acquisition with a built environment reads the store's world once (refused ones included). */
    private fun attempts(): Int = synchronized(counterLock) { environmentReads }

    /**
     * The real world with the transition version moved by one: an account difference, so every
     * request is told to rebuild (never run privately) and nothing is ever fetched.
     */
    private val store = StreamSearchSessionStore(
        fetcher,
        now = { 0L },
        scope = storeScope,
        currentEnvironment = {
            synchronized(counterLock) { environmentReads++ }
            StreamSearchEnvironment.stamp().let { real ->
                real.copy(profileTransition = real.profileTransition.copy(version = real.profileTransition.version + 1))
            }
        },
    )

    /** A non-empty add-on that matches the request, so every builder reaches the store with a built environment. */
    private val addons: List<ManagedAddon> = listOf(SearchFixtures.managedAddon("a"))

    @BeforeTest
    fun setUp() {
        StreamsRepository.clear()
        PlayerStreamsRepository.clearAll()
        StreamSearchSessions.installForTesting(store)
        StreamSearchEnvironment.installedAddons = { addons }
        StreamSearchEnvironment.debrid = { StreamSearchDebrid("none", null) }
        StreamSearchEnvironment.profileId = { 1 }
    }

    @AfterTest
    fun tearDown() {
        StreamsRepository.clear()
        PlayerStreamsRepository.clearAll()
        StreamSearchSessions.resetForTesting()
        StreamSearchEnvironment.resetForTesting()
        storeScope.cancel()
    }

    /**
     * Design review r5 (A): the repositories run in their own `Dispatchers.Default` scopes, so the
     * test waits (bounded) for the current request's terminal state: its placeholder groups settled
     * by the last refusal. Every rebuild takes the state over with no groups and then with loading
     * placeholders, so this state appears only once no rebuild follows, whatever the retry bound.
     */
    private val settledAfterTheLastRefusal: (StreamsUiState) -> Boolean = { state ->
        state.groups.isNotEmpty() && !state.isAnyLoading && state.groups.none { it.isLoading }
    }

    private suspend fun awaitTerminal(flow: StateFlow<StreamsUiState>): StreamsUiState =
        withContext(Dispatchers.Default) { withTimeout(10_000) { flow.first(settledAfterTheLastRefusal) } }

    @Test
    fun thePickerRebuildsALoadAtMostThreeTimes() = runTest {
        StreamsRepository.load(type = "series", videoId = EPISODE, season = 1, episode = 1)
        val terminal = awaitTerminal(StreamsRepository.uiState)
        assertEquals(STREAM_SEARCH_MAX_WORLD_RETRIES + 1, attempts(), "one attempt and three rebuilds, no fifth")
        assertNothingRan(terminal)
    }

    @Test
    fun theInPlayerListRebuildsALoadAtMostThreeTimes() = runTest {
        PlayerStreamsRepository.loadEpisodeStreams(type = "series", videoId = EPISODE, season = 1, episode = 1)
        val terminal = awaitTerminal(PlayerStreamsRepository.episodeStreamsState)
        assertEquals(STREAM_SEARCH_MAX_WORLD_RETRIES + 1, attempts(), "one attempt and three rebuilds, no fifth")
        assertNothingRan(terminal)
    }

    @Test
    fun theFallbackWalkRebuildsAtMostThreeTimes() = runTest {
        // The call's own completion is awaited before its attempts are counted.
        val candidates = withContext(Dispatchers.Default) {
            PlayerSourceFallbackCandidates.load("series", EPISODE, 1, 1, timeoutMs = 10_000)
        }
        assertEquals(STREAM_SEARCH_MAX_WORLD_RETRIES + 1, attempts(), "one attempt and three rebuilds, no fifth")
        assertTrue(candidates.isEmpty(), "a refused request answers nothing")
        assertEquals(emptyList(), fetcher.addonFetches, "nothing is fetched for a refused request")
        assertEquals(0, store.startedCount, "no search ever started")
    }

    private fun assertNothingRan(terminal: StreamsUiState) {
        assertTrue(terminal.groups.all { it.streams.isEmpty() }, "nothing is delivered")
        assertEquals(emptyList(), fetcher.addonFetches, "nothing is fetched for a refused request")
        assertEquals(0, store.startedCount, "no search ever started")
    }

    private companion object {
        const val EPISODE = "tt1:1:1"
    }
}
