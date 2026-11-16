package com.nuvio.app.features.debrid

import com.nuvio.app.features.streams.StreamDebridCacheState
import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.test.runTest
import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertFailsWith
import kotlin.test.assertNull

class LocalDebridServiceTest {
    private val canonical = "7db44b3713094e622246b715de410bb9b6d91230"
    private val requested = "b72ca5570c56c2387526b6aab184f0cf0075cff0"

    @Test
    fun exactMatchesStayUntouchedWithoutExtraRequests() = runTest {
        val cached = mapOf("abc123" to LocalDebridCachedItem(name = "exact.mkv", size = 1L))

        val resolved = resolveTorboxAliasMatches(cached, listOf("abc123")) {
            error("no extra request expected")
        }

        assertEquals(LocalDebridCacheCheck(cached), resolved)
    }

    @Test
    fun singleAliasedAnswerMapsBackToTheRequestedHash() = runTest {
        val item = LocalDebridCachedItem(name = "aliased.mkv", size = 2L)

        val resolved = resolveTorboxAliasMatches(mapOf(canonical to item), listOf(requested)) {
            error("no extra request expected")
        }

        assertEquals(LocalDebridCacheCheck(mapOf(requested to item)), resolved)
    }

    @Test
    fun onlyTheHashesMissingFromABatchAreAskedAgain() = runTest {
        val exact = LocalDebridCachedItem(name = "exact.mkv", size = 3L)
        val aliased = LocalDebridCachedItem(name = "aliased.mkv", size = 2L)
        val asked = mutableListOf<String>()

        val resolved = resolveTorboxAliasMatches(
            cached = mapOf("abc123" to exact, canonical to aliased),
            requestedHashes = listOf("abc123", requested),
        ) { hash ->
            asked += hash
            mapOf(canonical to aliased)
        }

        assertEquals(listOf(requested), asked)
        assertEquals(
            LocalDebridCacheCheck(mapOf("abc123" to exact, canonical to aliased, requested to aliased)),
            resolved,
        )
    }

    @Test
    fun `a re-ask that throws reports the hash as unknown and keeps the batch answers`() = runTest {
        val exact = LocalDebridCachedItem(name = "exact.mkv", size = 3L)
        val aliased = LocalDebridCachedItem(name = "aliased.mkv", size = 2L)

        val resolved = resolveTorboxAliasMatches(
            cached = mapOf("abc123" to exact, canonical to aliased),
            requestedHashes = listOf("abc123", requested),
        ) { error("network down") }

        assertEquals(mapOf("abc123" to exact, canonical to aliased), resolved.cached)
        assertEquals(setOf(requested), resolved.unknown)
        assertEquals(StreamDebridCacheState.CACHED, resolved.stateFor("abc123"))
        assertEquals(StreamDebridCacheState.UNKNOWN, resolved.stateFor(requested))
        assertNull(resolved.isCached(requested))
    }

    @Test
    fun `a re-ask with an error answer reports the hash as unknown`() = runTest {
        val aliased = LocalDebridCachedItem(name = "aliased.mkv", size = 2L)

        val resolved = resolveTorboxAliasMatches(
            cached = mapOf(canonical to aliased),
            requestedHashes = listOf("abc123", requested),
        ) { null }

        assertEquals(setOf("abc123", requested), resolved.unknown)
        assertEquals(StreamDebridCacheState.UNKNOWN, resolved.stateFor(requested))
        assertEquals(StreamDebridCacheState.UNKNOWN, resolved.stateFor("abc123"))
    }

    @Test
    fun `a mixed batch keeps hits confirmed misses and failed lookups apart`() = runTest {
        val exact = LocalDebridCachedItem(name = "exact.mkv", size = 3L)
        val aliased = LocalDebridCachedItem(name = "aliased.mkv", size = 2L)
        val failing = "c0ffee00c0ffee00c0ffee00c0ffee00c0ffee00"
        val missing = "deadbeefdeadbeefdeadbeefdeadbeefdeadbeef"

        val resolved = resolveTorboxAliasMatches(
            cached = mapOf("abc123" to exact, canonical to aliased),
            requestedHashes = listOf("abc123", requested, failing, missing),
        ) { hash ->
            when (hash) {
                requested -> mapOf(canonical to aliased)
                failing -> error("HTTP 429")
                missing -> emptyMap()
                else -> error("unexpected re-ask for $hash")
            }
        }

        assertEquals(StreamDebridCacheState.CACHED, resolved.stateFor("abc123"))
        assertEquals(StreamDebridCacheState.CACHED, resolved.stateFor(requested))
        assertEquals(aliased, resolved.cached[requested])
        assertEquals(StreamDebridCacheState.UNKNOWN, resolved.stateFor(failing))
        assertEquals(StreamDebridCacheState.NOT_CACHED, resolved.stateFor(missing))
        assertEquals(false, resolved.isCached(missing))
        assertEquals(setOf(failing), resolved.unknown)
    }

    @Test
    fun `cancellation of a re-ask still propagates`() = runTest {
        assertFailsWith<CancellationException> {
            resolveTorboxAliasMatches(
                cached = mapOf(canonical to LocalDebridCachedItem(name = "aliased.mkv", size = 2L)),
                requestedHashes = listOf("abc123", requested),
            ) { throw CancellationException("cancelled") }
        }
    }

    @Test
    fun `a plain answer maps every requested hash to cached or not cached`() {
        val check = LocalDebridCacheCheck(mapOf("abc123" to LocalDebridCachedItem(name = null, size = null)))

        assertEquals(StreamDebridCacheState.CACHED, check.stateFor("abc123"))
        assertEquals(StreamDebridCacheState.NOT_CACHED, check.stateFor(requested))
        assertEquals(true, check.isCached("abc123"))
        assertEquals(false, check.isCached(requested))
    }
}
