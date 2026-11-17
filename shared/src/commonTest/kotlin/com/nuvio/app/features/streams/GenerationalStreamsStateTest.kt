package com.nuvio.app.features.streams

import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.toList
import kotlinx.coroutines.flow.take
import kotlinx.coroutines.launch
import kotlinx.coroutines.test.runCurrent
import kotlinx.coroutines.test.runTest
import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertFalse
import kotlin.test.assertTrue

/**
 * Review r1 (finding 2): a superseded load's write can never commit, because the owning
 * generation is inside the compared value. The ABA sequence is driven exactly: the old write
 * reads the state and passes its ownership check, a new load installs an EQUAL initial state, and
 * the old write then tries to commit.
 */
class GenerationalStreamsStateTest {
    private val loading = StreamsUiState(
        groups = listOf(AddonStreamGroup("a", "addon:a", emptyList(), isLoading = true)),
        isAnyLoading = true,
    )
    private val oldEpisodeGroup = AddonStreamGroup("a", "addon:a", listOf(SearchFixtures.stream("addon:a", "old-episode")))

    private fun StreamsUiState.withOld() = copy(groups = listOf(oldEpisodeGroup), isAnyLoading = false)

    @Test
    fun oldWriteNeverCommitsOntoAnEqualNewerState() {
        val state = GenerationalStreamsState()
        val oldLoad = state.takeOver(loading)
        var newLoad = -1L
        val committed = state.updateIfCurrent(oldLoad) { read ->
            // The old completion has read the state and passed its check; now a new load installs
            // an equal initial state before the old completion commits.
            if (newLoad < 0) newLoad = state.takeOver(loading)
            read.withOld()
        }

        assertFalse(committed)
        assertEquals(loading, state.value)
        assertEquals(newLoad, state.generation)
        assertTrue(state.updateIfCurrent(newLoad) { it.withOld() }, "the new load still writes")
    }

    @Test
    fun theSameSequenceOnAPlainStateFlowWithAnOutsideCheckAcceptsTheOldWrite() {
        // Control: the pattern this replaced (generation checked outside StateFlow's compare-and-set).
        val flow = MutableStateFlow(loading)
        var generation = 1L
        val oldLoad = generation
        var interleaved = false
        while (true) {
            val read = flow.value
            if (generation != oldLoad) break
            val next = read.withOld()
            if (!interleaved) {
                interleaved = true
                generation += 1
                flow.value = loading.copy() // the newer load's equal initial state
            }
            if (flow.compareAndSet(read, next)) break
        }
        assertEquals(listOf(oldEpisodeGroup), flow.value.groups, "the old episode's group landed in the new load")
    }

    @Test
    fun setIfCurrentRefusesAnOldGenerationAndUpdateKeepsTheOwner() {
        val state = GenerationalStreamsState()
        val first = state.takeOver(loading)
        val second = state.takeOver { it.copy(requestToken = "next") }
        assertFalse(state.setIfCurrent(first, StreamsUiState()))
        state.update { it.copy(selectedFilter = "addon:a") }
        assertEquals(second, state.generation)
        assertEquals("addon:a", state.value.selectedFilter)
        assertTrue(state.setIfCurrent(second, StreamsUiState()))
    }

    @Test
    fun viewConflatesLikeAPlainStateFlow() = runTest {
        val state = GenerationalStreamsState()
        val seen = mutableListOf<StreamsUiState>()
        val job = launch { state.view.take(3).toList(seen) }
        runCurrent()
        state.takeOver(loading)
        runCurrent()
        state.takeOver(loading) // equal state under a new generation: nothing new to observe
        runCurrent()
        state.update { it.withOld() }
        runCurrent()

        assertEquals(listOf(StreamsUiState(), loading, loading.withOld()), seen)
        assertEquals(loading.withOld(), state.view.value)
        job.cancel()
    }
}
