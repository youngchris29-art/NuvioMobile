package com.nuvio.app.features.streams

import com.nuvio.app.features.player.PlayerSourceFallbackCandidates
import com.nuvio.app.features.player.PlayerStreamsRepository
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.ExperimentalCoroutinesApi
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.cancel
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.first
import kotlinx.coroutines.flow.toList
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
 * W4 spec 4.2, R1-R4 (plus R5-R7): the real [StreamsRepository] and [PlayerStreamsRepository]
 * wired to one session store with a scripted fetcher. The repositories run on their own
 * Dispatchers.Default scopes, so each step waits for the state it expects (bounded).
 */
@OptIn(ExperimentalCoroutinesApi::class)
class StreamsSessionSharingTest {
    private val fetcher = ScriptedSearchFetcher()
    private val storeScope = CoroutineScope(SupervisorJob() + Dispatchers.Default.limitedParallelism(1))
    private val store = StreamSearchSessionStore(fetcher, now = { 0L }, scope = storeScope)
    private var debridConfiguration = "none"

    @BeforeTest
    fun setUp() {
        StreamsRepository.clear()
        PlayerStreamsRepository.clearAll()
        StreamSearchSessions.installForTesting(store)
        StreamSearchEnvironment.installedAddons = { listOf(SearchFixtures.managedAddon("a"), SearchFixtures.managedAddon("b")) }
        StreamSearchEnvironment.debridConfiguration = { debridConfiguration }
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

    private suspend fun await(flow: StateFlow<StreamsUiState>, what: (StreamsUiState) -> Boolean): StreamsUiState =
        withContext(Dispatchers.Default) { withTimeout(10_000) { flow.first(what) } }

    private val settled: (StreamsUiState) -> Boolean = { state ->
        state.groups.isNotEmpty() && !state.isAnyLoading && state.groups.none { it.isLoading }
    }

    private fun StreamsUiState.labels(): List<String> = groups.flatMap { group -> group.streams.map { it.name.orEmpty() } }

    @Test
    fun r1PickerAndPlayerListShareOneSearchForTheSameEpisode() = runTest {
        StreamsRepository.load(type = "series", videoId = EPISODE, season = 1, episode = 1)
        val picker = await(StreamsRepository.uiState, settled)
        PlayerStreamsRepository.loadEpisodeStreams(type = "series", videoId = EPISODE, season = 1, episode = 1)
        val player = await(PlayerStreamsRepository.episodeStreamsState, settled)

        assertEquals(listOf("a@$EPISODE", "b@$EPISODE"), fetcher.addonFetches)
        assertEquals(1, store.startedCount)
        assertEquals(picker.groups, player.groups)
        assertEquals(listOf("a-$EPISODE", "b-$EPISODE"), player.labels())
    }

    @Test
    fun r2ClearedEpisodeListReplaysTheSearchOnReload() = runTest {
        PlayerStreamsRepository.loadEpisodeStreams(type = "series", videoId = EPISODE, season = 1, episode = 1)
        await(PlayerStreamsRepository.episodeStreamsState, settled)
        PlayerStreamsRepository.clearEpisodeStreams()
        PlayerStreamsRepository.loadEpisodeStreams(type = "series", videoId = EPISODE, season = 1, episode = 1)
        val replayed = await(PlayerStreamsRepository.episodeStreamsState, settled)

        assertEquals(2, fetcher.addonFetches.size)
        assertFalse(replayed.isAnyLoading)
        assertEquals(listOf("a-$EPISODE", "b-$EPISODE"), replayed.labels())
    }

    @Test
    fun r3PickerRefreshSettlesThePlayerListOfTheDroppedSearch() = runTest {
        fetcher.hold("b")
        PlayerStreamsRepository.loadEpisodeStreams(type = "series", videoId = EPISODE, season = 1, episode = 1)
        await(PlayerStreamsRepository.episodeStreamsState) { state -> state.labels() == listOf("a-$EPISODE") }
        StreamsRepository.reload(type = "series", videoId = EPISODE, season = 1, episode = 1)

        val player = await(PlayerStreamsRepository.episodeStreamsState) { !it.isAnyLoading }
        assertTrue(player.groups.none { it.isLoading }, "the dropped search leaves no source loading")
        assertEquals(listOf("a-$EPISODE"), player.labels())
        val picker = await(StreamsRepository.uiState, settled)
        assertEquals(listOf("a-$EPISODE", "b-$EPISODE"), picker.labels())
        assertEquals(2, fetcher.fetchCount("a"))
        assertEquals(2, store.startedCount)
    }

    @Test
    fun r4AnotherDebridAccountIsAnotherSearch() = runTest {
        debridConfiguration = "torbox:1"
        StreamsRepository.load(type = "series", videoId = EPISODE, season = 1, episode = 1)
        await(StreamsRepository.uiState, settled)
        debridConfiguration = "torbox:2"
        PlayerStreamsRepository.loadEpisodeStreams(type = "series", videoId = EPISODE, season = 1, episode = 1)
        await(PlayerStreamsRepository.episodeStreamsState, settled)

        assertEquals(2, store.startedCount)
        assertEquals(2, fetcher.fetchCount("a"))
        assertEquals(listOf("torbox:2"), store.heldKeys().map { it.sourceConfiguration.substringAfterLast("debrid:") })
    }

    @Test
    fun r5SupersededPickerLoadNeverWritesItsLateResults() = runTest {
        val gate = fetcher.hold("a")
        StreamsRepository.load(type = "movie", videoId = "tt5")
        await(StreamsRepository.uiState) { state -> state.labels() == listOf("b-tt5") }
        StreamsRepository.load(type = "movie", videoId = "tt6")
        val second = await(StreamsRepository.uiState, settled)
        gate.complete(Result.success(listOf(SearchFixtures.stream(SearchFixtures.target("a").addonId, "late-tt5"))))
        // The first title's search itself finishes (it outlives its consumer) ...
        val firstSearch = withContext(Dispatchers.Default) {
            withTimeout(10_000) {
                store.search(1, StreamSearchTargets("movie", "tt5", null, null, listOf(SearchFixtures.target("a", "tt5"), SearchFixtures.target("b", "tt5")), emptyList(), "none"), false).toList()
            }
        }
        assertEquals(2, firstSearch.size)

        // ... and its late answer is nowhere in the picker's state for the second title.
        assertEquals(listOf("a-tt6", "b-tt6"), second.labels())
        assertEquals(listOf("a-tt6", "b-tt6"), StreamsRepository.uiState.value.labels())
        assertEquals(StreamsRepository.requestToken("movie", "tt6"), StreamsRepository.uiState.value.requestToken)
    }

    @Test
    fun r6FallbackFacadeJoinsTheHeldSearchWithoutFetching() = runTest {
        PlayerStreamsRepository.loadEpisodeStreams(type = "series", videoId = EPISODE, season = 1, episode = 1)
        await(PlayerStreamsRepository.episodeStreamsState, settled)
        val candidates = PlayerSourceFallbackCandidates.load("series", EPISODE, 1, 1, timeoutMs = 10_000)

        assertEquals(listOf("a-$EPISODE", "b-$EPISODE"), candidates.map { it.name })
        assertEquals(2, fetcher.addonFetches.size)
        assertEquals(setOf("a", "b"), PlayerSourceFallbackCandidates.installedAddonNames(candidates))
    }

    @Test
    fun r7FacadeStartsAMissingSearchAndTheRepositoryJoinsIt() = runTest {
        val candidates = withContext(Dispatchers.Default) {
            PlayerSourceFallbackCandidates.load("series", EPISODE, 1, 1, timeoutMs = 10_000)
        }
        PlayerStreamsRepository.loadEpisodeStreams(type = "series", videoId = EPISODE, season = 1, episode = 1)
        await(PlayerStreamsRepository.episodeStreamsState, settled)

        assertEquals(2, candidates.size)
        assertEquals(1, store.startedCount)
        assertEquals(2, fetcher.addonFetches.size)
    }

    @Test
    fun r8FacadeReturnsWhatArrivedWhenItsTimeRunsOut() = runTest {
        fetcher.hold("b")
        val candidates = withContext(Dispatchers.Default) {
            PlayerSourceFallbackCandidates.load("series", EPISODE, 1, 1, timeoutMs = 500)
        }
        assertEquals(listOf("a-$EPISODE"), candidates.map { it.name })
    }

    private companion object {
        const val EPISODE = "tt1:1:1"
    }
}
