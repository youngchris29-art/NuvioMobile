package com.nuvio.app.features.streams

import com.nuvio.app.features.streams.StreamSearchAdmission.Join
import com.nuvio.app.features.streams.StreamSearchAdmission.Private
import com.nuvio.app.features.streams.StreamSearchAdmission.Replace
import com.nuvio.app.features.streams.StreamSearchAdmission.Start
import kotlinx.coroutines.launch
import kotlinx.coroutines.test.runCurrent
import kotlinx.coroutines.test.runTest
import kotlin.test.Test
import kotlin.test.assertEquals

/**
 * Stage B review r8: [streamSearchAdmission] over every input, as a table written out by hand, and
 * the private runs' bookkeeping in the store.
 */
class StreamSearchAdmissionTest {
    private data class Row(
        val request: Long,
        val current: Long,
        val force: Boolean,
        val held: Boolean,
        val expected: StreamSearchAdmission,
    )

    // request vs current: older (0 < 1), same (1 = 1), newer (2 > 1: a replaced store; not stale).
    // Review r9: the rule does not read the plugin groups at all. An older request is private
    // whether it carries plugin targets or none (an add-on-only request read an empty plugin list
    // at the old generation, so it may predate a scraper the refresh added).
    private val table = listOf(
        Row(request = 0, current = 1, force = false, held = false, expected = Private),
        Row(request = 0, current = 1, force = false, held = true, expected = Private),
        Row(request = 0, current = 1, force = true, held = false, expected = Private),
        Row(request = 0, current = 1, force = true, held = true, expected = Private),
        Row(request = 1, current = 1, force = false, held = false, expected = Start),
        Row(request = 1, current = 1, force = false, held = true, expected = Join),
        Row(request = 1, current = 1, force = true, held = false, expected = Start),
        Row(request = 1, current = 1, force = true, held = true, expected = Replace),
        Row(request = 2, current = 1, force = false, held = false, expected = Start),
        Row(request = 2, current = 1, force = false, held = true, expected = Join),
        Row(request = 2, current = 1, force = true, held = false, expected = Start),
        Row(request = 2, current = 1, force = true, held = true, expected = Replace),
    )

    @Test
    fun everyInputHasItsWrittenOutAdmission() {
        assertEquals(12, table.map { listOf(it.request, it.force, it.held) }.toSet().size, "every combination once")
        table.forEach { row ->
            assertEquals(
                row.expected,
                streamSearchAdmission(row.request, row.current, row.force, row.held),
                row.toString(),
            )
        }
    }

    private val fetcher = ScriptedSearchFetcher()

    private fun staleTargets() = StreamSearchTargets(
        type = "series",
        videoId = "tt1:1:1",
        season = 1,
        episode = 1,
        streamAddons = listOf(SearchFixtures.target("a", "tt1:1:1")),
        pluginProviderGroups = listOf(PluginProviderGroup("plugin:p", "P", listOf(SearchFixtures.scraper("s1")))),
        debrid = StreamSearchDebrid("none", null),
        pluginGeneration = 0L,
    )

    @Test
    fun aPrivateRunLeavesTheStoreWhenItFinishes() = runTest {
        val store = StreamSearchSessionStore(fetcher, now = { 0L }, scope = backgroundScope)
        store.dropPluginSessions()
        val gate = fetcher.hold("a")
        val received = mutableListOf<StreamLoadCompletion>()
        val job = backgroundScope.launch { store.search(1, staleTargets(), forceRefresh = false).collect { received += it } }
        runCurrent()
        assertEquals(1, store.privateRunCount())
        gate.complete(Result.success(emptyList()))
        runCurrent()
        assertEquals(true, job.isCompleted)
        assertEquals(0, store.privateRunCount(), "a finished private run is forgotten")
        assertEquals(0, store.privateSessionsCancelled)
    }

    @Test
    fun aPrivateRunLeavesTheStoreWhenItsConsumerGoesAway() = runTest {
        val store = StreamSearchSessionStore(fetcher, now = { 0L }, scope = backgroundScope)
        store.dropPluginSessions()
        fetcher.hold("a")
        val job = backgroundScope.launch { store.search(1, staleTargets(), forceRefresh = false).collect { } }
        runCurrent()
        assertEquals(1, store.privateRunCount())
        job.cancel()
        runCurrent()
        assertEquals(0, store.privateRunCount(), "a private run whose consumer left is forgotten")
        assertEquals(1, store.privateSessionsCancelled)
    }
}
