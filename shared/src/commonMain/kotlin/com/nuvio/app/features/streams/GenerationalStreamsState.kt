package com.nuvio.app.features.streams

import kotlinx.coroutines.ExperimentalForInheritanceCoroutinesApi
import kotlinx.coroutines.awaitCancellation
import kotlinx.coroutines.flow.FlowCollector
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.distinctUntilChanged
import kotlinx.coroutines.flow.map

/**
 * W4 (review r1): a repository's stream state together with the generation of the load that owns
 * it, compared and swapped as ONE value. A load takes the state over ([takeOver]: generation + 1,
 * fresh state, atomically) and from then on writes only through [setIfCurrent] / [updateIfCurrent]
 * with the generation it got. Because the generation sits inside the compare-and-set, a write of a
 * superseded load can never commit, not even onto a newer load's state that is EQUAL to the one it
 * read (StateFlow compares by equality, so a check outside the CAS left an ABA window).
 *
 * [view] is what the repository publishes: the state alone, with the same conflation as a plain
 * StateFlow of it (a takeover that installs an equal state emits nothing new).
 */
internal class GenerationalStreamsState(initial: StreamsUiState = StreamsUiState()) {
    data class Snapshot(val generation: Long, val state: StreamsUiState)

    private val flow = MutableStateFlow(Snapshot(0L, initial))

    val view: StateFlow<StreamsUiState> = StateView(flow)

    val value: StreamsUiState
        get() = flow.value.state

    val generation: Long
        get() = flow.value.generation

    /** A new owner: [transform] of the current state under the next generation, returned. */
    fun takeOver(transform: (StreamsUiState) -> StreamsUiState): Long {
        while (true) {
            val current = flow.value
            val next = Snapshot(current.generation + 1, transform(current.state))
            if (flow.compareAndSet(current, next)) return next.generation
        }
    }

    fun takeOver(state: StreamsUiState): Long = takeOver { state }

    /** Replaces the state if [generation] still owns it. */
    fun setIfCurrent(generation: Long, state: StreamsUiState): Boolean = updateIfCurrent(generation) { state }

    /**
     * Applies [transform] if [generation] still owns the state; the generation is part of the
     * compared value, so a takeover in between makes the swap fail and the retry stop. [transform]
     * may run more than once and must be pure.
     */
    fun updateIfCurrent(generation: Long, transform: (StreamsUiState) -> StreamsUiState): Boolean {
        while (true) {
            val current = flow.value
            if (current.generation != generation) return false
            val next = current.copy(state = transform(current.state))
            if (flow.compareAndSet(current, next)) return true
        }
    }

    /** A change that belongs to whichever load owns the state (a filter chip, the overlay). */
    fun update(transform: (StreamsUiState) -> StreamsUiState) {
        while (true) {
            val current = flow.value
            val next = current.copy(state = transform(current.state))
            if (flow.compareAndSet(current, next)) return
        }
    }

    @OptIn(ExperimentalForInheritanceCoroutinesApi::class)
    private class StateView(private val source: StateFlow<Snapshot>) : StateFlow<StreamsUiState> {
        override val value: StreamsUiState
            get() = source.value.state

        override val replayCache: List<StreamsUiState>
            get() = listOf(value)

        override suspend fun collect(collector: FlowCollector<StreamsUiState>): Nothing {
            source.map { it.state }.distinctUntilChanged().collect(collector)
            awaitCancellation()
        }
    }
}
