package com.nuvio.app.features.streams

import com.nuvio.app.features.streams.StreamSearchAdmission.Join
import com.nuvio.app.features.streams.StreamSearchAdmission.Private
import com.nuvio.app.features.streams.StreamSearchAdmission.Rebuild
import com.nuvio.app.features.streams.StreamSearchAdmission.Reject
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
        val cleared: Long,
        val current: Long,
        val sameAccount: Boolean,
        val sameSources: Boolean,
        val force: Boolean,
        val held: Boolean,
        val expected: StreamSearchAdmission,
    )

    // Review r9: the rule does not read the plugin groups at all; an older request is private
    // whether it carries plugin targets or none.
    // Review r10 findings: the generation relation (before the last wipe, before the last refresh,
    // current, newer) x the same profile and account x the same add-ons and plugins x forced x
    // held: every combination once. Another account is refused (Rebuild), never run privately.
    private val table = listOf(
        // Request before a wipe: request 0, cleared 1, current 2.
        Row(request = 0, cleared = 1, current = 2, sameAccount = true, sameSources = true, force = false, held = false, expected = Reject),
        Row(request = 0, cleared = 1, current = 2, sameAccount = true, sameSources = true, force = false, held = true, expected = Reject),
        Row(request = 0, cleared = 1, current = 2, sameAccount = true, sameSources = true, force = true, held = false, expected = Reject),
        Row(request = 0, cleared = 1, current = 2, sameAccount = true, sameSources = true, force = true, held = true, expected = Reject),
        Row(request = 0, cleared = 1, current = 2, sameAccount = true, sameSources = false, force = false, held = false, expected = Reject),
        Row(request = 0, cleared = 1, current = 2, sameAccount = true, sameSources = false, force = false, held = true, expected = Reject),
        Row(request = 0, cleared = 1, current = 2, sameAccount = true, sameSources = false, force = true, held = false, expected = Reject),
        Row(request = 0, cleared = 1, current = 2, sameAccount = true, sameSources = false, force = true, held = true, expected = Reject),
        Row(request = 0, cleared = 1, current = 2, sameAccount = false, sameSources = true, force = false, held = false, expected = Reject),
        Row(request = 0, cleared = 1, current = 2, sameAccount = false, sameSources = true, force = false, held = true, expected = Reject),
        Row(request = 0, cleared = 1, current = 2, sameAccount = false, sameSources = true, force = true, held = false, expected = Reject),
        Row(request = 0, cleared = 1, current = 2, sameAccount = false, sameSources = true, force = true, held = true, expected = Reject),
        Row(request = 0, cleared = 1, current = 2, sameAccount = false, sameSources = false, force = false, held = false, expected = Reject),
        Row(request = 0, cleared = 1, current = 2, sameAccount = false, sameSources = false, force = false, held = true, expected = Reject),
        Row(request = 0, cleared = 1, current = 2, sameAccount = false, sameSources = false, force = true, held = false, expected = Reject),
        Row(request = 0, cleared = 1, current = 2, sameAccount = false, sameSources = false, force = true, held = true, expected = Reject),
        // Request after the wipe, before a refresh: request 1, cleared 1, current 2.
        Row(request = 1, cleared = 1, current = 2, sameAccount = true, sameSources = true, force = false, held = false, expected = Private),
        Row(request = 1, cleared = 1, current = 2, sameAccount = true, sameSources = true, force = false, held = true, expected = Private),
        Row(request = 1, cleared = 1, current = 2, sameAccount = true, sameSources = true, force = true, held = false, expected = Private),
        Row(request = 1, cleared = 1, current = 2, sameAccount = true, sameSources = true, force = true, held = true, expected = Private),
        Row(request = 1, cleared = 1, current = 2, sameAccount = true, sameSources = false, force = false, held = false, expected = Private),
        Row(request = 1, cleared = 1, current = 2, sameAccount = true, sameSources = false, force = false, held = true, expected = Private),
        Row(request = 1, cleared = 1, current = 2, sameAccount = true, sameSources = false, force = true, held = false, expected = Private),
        Row(request = 1, cleared = 1, current = 2, sameAccount = true, sameSources = false, force = true, held = true, expected = Private),
        Row(request = 1, cleared = 1, current = 2, sameAccount = false, sameSources = true, force = false, held = false, expected = Rebuild),
        Row(request = 1, cleared = 1, current = 2, sameAccount = false, sameSources = true, force = false, held = true, expected = Rebuild),
        Row(request = 1, cleared = 1, current = 2, sameAccount = false, sameSources = true, force = true, held = false, expected = Rebuild),
        Row(request = 1, cleared = 1, current = 2, sameAccount = false, sameSources = true, force = true, held = true, expected = Rebuild),
        Row(request = 1, cleared = 1, current = 2, sameAccount = false, sameSources = false, force = false, held = false, expected = Rebuild),
        Row(request = 1, cleared = 1, current = 2, sameAccount = false, sameSources = false, force = false, held = true, expected = Rebuild),
        Row(request = 1, cleared = 1, current = 2, sameAccount = false, sameSources = false, force = true, held = false, expected = Rebuild),
        Row(request = 1, cleared = 1, current = 2, sameAccount = false, sameSources = false, force = true, held = true, expected = Rebuild),
        // Request current: request 2, cleared 1, current 2.
        Row(request = 2, cleared = 1, current = 2, sameAccount = true, sameSources = true, force = false, held = false, expected = Start),
        Row(request = 2, cleared = 1, current = 2, sameAccount = true, sameSources = true, force = false, held = true, expected = Join),
        Row(request = 2, cleared = 1, current = 2, sameAccount = true, sameSources = true, force = true, held = false, expected = Start),
        Row(request = 2, cleared = 1, current = 2, sameAccount = true, sameSources = true, force = true, held = true, expected = Replace),
        Row(request = 2, cleared = 1, current = 2, sameAccount = true, sameSources = false, force = false, held = false, expected = Private),
        Row(request = 2, cleared = 1, current = 2, sameAccount = true, sameSources = false, force = false, held = true, expected = Private),
        Row(request = 2, cleared = 1, current = 2, sameAccount = true, sameSources = false, force = true, held = false, expected = Private),
        Row(request = 2, cleared = 1, current = 2, sameAccount = true, sameSources = false, force = true, held = true, expected = Private),
        Row(request = 2, cleared = 1, current = 2, sameAccount = false, sameSources = true, force = false, held = false, expected = Rebuild),
        Row(request = 2, cleared = 1, current = 2, sameAccount = false, sameSources = true, force = false, held = true, expected = Rebuild),
        Row(request = 2, cleared = 1, current = 2, sameAccount = false, sameSources = true, force = true, held = false, expected = Rebuild),
        Row(request = 2, cleared = 1, current = 2, sameAccount = false, sameSources = true, force = true, held = true, expected = Rebuild),
        Row(request = 2, cleared = 1, current = 2, sameAccount = false, sameSources = false, force = false, held = false, expected = Rebuild),
        Row(request = 2, cleared = 1, current = 2, sameAccount = false, sameSources = false, force = false, held = true, expected = Rebuild),
        Row(request = 2, cleared = 1, current = 2, sameAccount = false, sameSources = false, force = true, held = false, expected = Rebuild),
        Row(request = 2, cleared = 1, current = 2, sameAccount = false, sameSources = false, force = true, held = true, expected = Rebuild),
        // Request newer than the store (a replaced store): request 3, cleared 1, current 2.
        Row(request = 3, cleared = 1, current = 2, sameAccount = true, sameSources = true, force = false, held = false, expected = Start),
        Row(request = 3, cleared = 1, current = 2, sameAccount = true, sameSources = true, force = false, held = true, expected = Join),
        Row(request = 3, cleared = 1, current = 2, sameAccount = true, sameSources = true, force = true, held = false, expected = Start),
        Row(request = 3, cleared = 1, current = 2, sameAccount = true, sameSources = true, force = true, held = true, expected = Replace),
        Row(request = 3, cleared = 1, current = 2, sameAccount = true, sameSources = false, force = false, held = false, expected = Private),
        Row(request = 3, cleared = 1, current = 2, sameAccount = true, sameSources = false, force = false, held = true, expected = Private),
        Row(request = 3, cleared = 1, current = 2, sameAccount = true, sameSources = false, force = true, held = false, expected = Private),
        Row(request = 3, cleared = 1, current = 2, sameAccount = true, sameSources = false, force = true, held = true, expected = Private),
        Row(request = 3, cleared = 1, current = 2, sameAccount = false, sameSources = true, force = false, held = false, expected = Rebuild),
        Row(request = 3, cleared = 1, current = 2, sameAccount = false, sameSources = true, force = false, held = true, expected = Rebuild),
        Row(request = 3, cleared = 1, current = 2, sameAccount = false, sameSources = true, force = true, held = false, expected = Rebuild),
        Row(request = 3, cleared = 1, current = 2, sameAccount = false, sameSources = true, force = true, held = true, expected = Rebuild),
        Row(request = 3, cleared = 1, current = 2, sameAccount = false, sameSources = false, force = false, held = false, expected = Rebuild),
        Row(request = 3, cleared = 1, current = 2, sameAccount = false, sameSources = false, force = false, held = true, expected = Rebuild),
        Row(request = 3, cleared = 1, current = 2, sameAccount = false, sameSources = false, force = true, held = false, expected = Rebuild),
        Row(request = 3, cleared = 1, current = 2, sameAccount = false, sameSources = false, force = true, held = true, expected = Rebuild),
    )

    @Test
    fun everyInputHasItsWrittenOutAdmission() {
        assertEquals(
            64,
            table.map { listOf(it.request, it.sameAccount, it.sameSources, it.force, it.held) }.toSet().size,
            "every combination once",
        )
        table.forEach { row ->
            assertEquals(
                row.expected,
                streamSearchAdmission(row.request, row.current, row.cleared, row.sameAccount, row.sameSources, row.force, row.held),
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
