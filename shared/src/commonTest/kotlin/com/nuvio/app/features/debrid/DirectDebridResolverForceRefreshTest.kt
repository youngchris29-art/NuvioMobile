package com.nuvio.app.features.debrid

import kotlinx.coroutines.CompletableDeferred
import kotlinx.coroutines.ExperimentalCoroutinesApi
import kotlinx.coroutines.async
import kotlinx.coroutines.test.TestScope
import kotlinx.coroutines.test.runCurrent
import kotlinx.coroutines.test.runTest
import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertNull

/**
 * Pins how [DebridResolveSingleFlight] (the coordination behind
 * `DirectDebridPlaybackResolver.resolve`) treats `forceRefresh`: a forced resolve always issues
 * a fresh provider request and its result wins over an older in-flight resolve, while
 * non-forced callers keep the join-or-cache behaviour.
 */
@OptIn(ExperimentalCoroutinesApi::class)
class DirectDebridResolverForceRefreshTest {
    private class FakeProvider {
        val calls = mutableListOf<CompletableDeferred<DirectDebridResolveResult>>()

        suspend fun call(): DirectDebridResolveResult {
            val pending = CompletableDeferred<DirectDebridResolveResult>()
            calls += pending
            return pending.await()
        }

        fun finish(index: Int, url: String) {
            calls[index].complete(link(url))
        }
    }

    private fun TestScope.singleFlight() = DebridResolveSingleFlight(backgroundScope, now = { 0L })

    @Test
    fun `a forced resolve during a non-forced one requests a fresh link and returns it`() = runTest {
        val resolves = singleFlight()
        val provider = FakeProvider()

        val older = async { resolves.resolve(KEY, forceRefresh = false) { provider.call() } }
        runCurrent()
        val forced = async { resolves.resolve(KEY, forceRefresh = true) { provider.call() } }
        runCurrent()

        assertEquals(2, provider.calls.size, "the forced call must not join the older in-flight resolve")

        provider.finish(1, "fresh")
        assertEquals(link("fresh"), forced.await())
        assertEquals(link("fresh"), resolves.cached(KEY))

        provider.finish(0, "old")
        assertEquals(link("old"), older.await(), "the older caller still gets its own result")
        assertEquals(link("fresh"), resolves.cached(KEY), "the late older result must not replace the forced one")

        assertEquals(link("fresh"), resolves.resolve(KEY, forceRefresh = false) { provider.call() })
        assertEquals(2, provider.calls.size)
    }

    @Test
    fun `an older resolve finishing before the forced one does not fill the cache`() = runTest {
        val resolves = singleFlight()
        val provider = FakeProvider()

        val older = async { resolves.resolve(KEY, forceRefresh = false) { provider.call() } }
        runCurrent()
        val forced = async { resolves.resolve(KEY, forceRefresh = true) { provider.call() } }
        runCurrent()

        provider.finish(0, "old")
        assertEquals(link("old"), older.await())
        assertNull(resolves.cached(KEY), "the replaced older resolve must not publish its link")

        provider.finish(1, "fresh")
        assertEquals(link("fresh"), forced.await())
        assertEquals(link("fresh"), resolves.cached(KEY))
    }

    @Test
    fun `a forced resolve skips a cached link and replaces it`() = runTest {
        val resolves = singleFlight()
        val provider = FakeProvider()

        val first = async { resolves.resolve(KEY, forceRefresh = false) { provider.call() } }
        runCurrent()
        provider.finish(0, "old")
        assertEquals(link("old"), first.await())
        assertEquals(link("old"), resolves.cached(KEY))

        val forced = async { resolves.resolve(KEY, forceRefresh = true) { provider.call() } }
        runCurrent()
        assertEquals(2, provider.calls.size)
        assertNull(resolves.cached(KEY), "the forced call evicts the old link when it starts")

        provider.finish(1, "fresh")
        assertEquals(link("fresh"), forced.await())
        assertEquals(link("fresh"), resolves.cached(KEY))
    }

    @Test
    fun `concurrent forced resolves share one fresh request`() = runTest {
        val resolves = singleFlight()
        val provider = FakeProvider()

        val first = async { resolves.resolve(KEY, forceRefresh = true) { provider.call() } }
        runCurrent()
        val second = async { resolves.resolve(KEY, forceRefresh = true) { provider.call() } }
        runCurrent()
        assertEquals(1, provider.calls.size)

        provider.finish(0, "fresh")
        assertEquals(link("fresh"), first.await())
        assertEquals(link("fresh"), second.await())
    }

    @Test
    fun `a non-forced resolve joins an in-flight forced one`() = runTest {
        val resolves = singleFlight()
        val provider = FakeProvider()

        val forced = async { resolves.resolve(KEY, forceRefresh = true) { provider.call() } }
        runCurrent()
        val plain = async { resolves.resolve(KEY, forceRefresh = false) { provider.call() } }
        runCurrent()
        assertEquals(1, provider.calls.size)

        provider.finish(0, "fresh")
        assertEquals(link("fresh"), forced.await())
        assertEquals(link("fresh"), plain.await())
    }

    @Test
    fun `non-forced resolves share one request and then read the cache`() = runTest {
        val resolves = singleFlight()
        val provider = FakeProvider()

        val first = async { resolves.resolve(KEY, forceRefresh = false) { provider.call() } }
        runCurrent()
        val second = async { resolves.resolve(KEY, forceRefresh = false) { provider.call() } }
        runCurrent()
        assertEquals(1, provider.calls.size)

        provider.finish(0, "link")
        assertEquals(link("link"), first.await())
        assertEquals(link("link"), second.await())

        assertEquals(link("link"), resolves.resolve(KEY, forceRefresh = false) { provider.call() })
        assertEquals(1, provider.calls.size)
    }

    @Test
    fun `evict drops the cached link but leaves an in-flight resolve alone`() = runTest {
        val resolves = singleFlight()
        val provider = FakeProvider()

        val first = async { resolves.resolve(KEY, forceRefresh = false) { provider.call() } }
        runCurrent()
        resolves.evict(KEY)
        val joined = async { resolves.resolve(KEY, forceRefresh = false) { provider.call() } }
        runCurrent()
        assertEquals(1, provider.calls.size)

        provider.finish(0, "link")
        assertEquals(link("link"), first.await())
        assertEquals(link("link"), joined.await())
        assertEquals(link("link"), resolves.cached(KEY))

        resolves.evict(KEY)
        assertNull(resolves.cached(KEY))
    }

    private companion object {
        const val KEY = "torbox|fingerprint|abcdef|1|show s01e02 mkv|1|2"

        fun link(url: String) = DirectDebridResolveResult.Success(url = url, filename = null, videoSize = null)
    }
}
