package com.nuvio.app.features.debrid

import kotlinx.coroutines.CompletableDeferred
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.ExperimentalCoroutinesApi
import kotlinx.coroutines.Job
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.async
import kotlinx.coroutines.test.TestScope
import kotlinx.coroutines.test.runCurrent
import kotlinx.coroutines.test.runTest
import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertNull
import kotlin.test.assertTrue

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

        fun fail(index: Int, error: Throwable) {
            calls[index].completeExceptionally(error)
        }
    }

    // A plain supervisor under backgroundScope (like the production SupervisorJob scope): a
    // failed shared resolve stays in its Deferred instead of being reported as a test failure.
    private fun TestScope.singleFlight() = DebridResolveSingleFlight(
        CoroutineScope(backgroundScope.coroutineContext + SupervisorJob(backgroundScope.coroutineContext[Job])),
        now = { 0L },
    )

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

    @Test
    fun `a cancelled owner leaves the shared resolve to the other waiter and the key clean`() = runTest {
        val resolves = singleFlight()
        val provider = FakeProvider()

        val owner = async { resolves.resolve(KEY, forceRefresh = true) { provider.call() } }
        runCurrent()
        val waiter = async { resolves.resolve(KEY, forceRefresh = true) { provider.call() } }
        runCurrent()
        assertEquals(1, provider.calls.size)

        owner.cancel()
        runCurrent()
        provider.finish(0, "shared")
        assertEquals(link("shared"), waiter.await(), "cancelling the owner must not cancel the shared request")
        assertEquals(link("shared"), resolves.cached(KEY))

        // A stale forced entry would make this join the finished resolve without a new request.
        val next = async { resolves.resolve(KEY, forceRefresh = true) { provider.call() } }
        runCurrent()
        assertEquals(2, provider.calls.size)
        provider.finish(1, "fresh")
        assertEquals(link("fresh"), next.await())
    }

    @Test
    fun `a cancelled sole owner still finishes the bookkeeping and the next forced call asks again`() = runTest {
        val resolves = singleFlight()
        val provider = FakeProvider()

        val owner = async { resolves.resolve(KEY, forceRefresh = true) { provider.call() } }
        runCurrent()
        owner.cancel()
        runCurrent()

        provider.finish(0, "first")
        runCurrent()
        assertEquals(link("first"), resolves.cached(KEY), "the shared work caches its result without a waiter")

        val next = async { resolves.resolve(KEY, forceRefresh = true) { provider.call() } }
        runCurrent()
        assertEquals(2, provider.calls.size, "the next call must issue a fresh provider request")
        provider.finish(1, "fresh")
        assertEquals(link("fresh"), next.await())
        assertEquals(link("fresh"), resolves.cached(KEY))
    }

    @Test
    fun `a provider failure reaches every waiter and leaves no in-flight entry`() = runTest {
        val resolves = singleFlight()
        val provider = FakeProvider()

        // runCatching inside the waiters: a failed test-scope child would fail the test itself.
        val owner = async { runCatching { resolves.resolve(KEY, forceRefresh = false) { provider.call() } } }
        runCurrent()
        val waiter = async { runCatching { resolves.resolve(KEY, forceRefresh = false) { provider.call() } } }
        runCurrent()
        assertEquals(1, provider.calls.size)

        provider.fail(0, IllegalStateException("provider down"))
        val ownerError = owner.await().exceptionOrNull()
        val waiterError = waiter.await().exceptionOrNull()
        assertTrue(ownerError is IllegalStateException, "owner got $ownerError")
        assertTrue(waiterError is IllegalStateException, "waiter got $waiterError")
        assertNull(resolves.cached(KEY))

        val next = async { resolves.resolve(KEY, forceRefresh = false) { provider.call() } }
        runCurrent()
        assertEquals(2, provider.calls.size, "a failed resolve must not stay registered for the key")
        provider.finish(1, "link")
        assertEquals(link("link"), next.await())
    }

    private companion object {
        const val KEY = "torbox|fingerprint|abcdef|1|show s01e02 mkv|1|2"

        fun link(url: String) = DirectDebridResolveResult.Success(url = url, filename = null, videoSize = null)
    }
}
