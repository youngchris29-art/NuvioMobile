package com.nuvio.app.features.tracking

import com.nuvio.app.features.trakt.EpisodeMappingEntry
import kotlinx.coroutines.CompletableDeferred
import kotlinx.coroutines.async
import kotlinx.coroutines.launch
import kotlinx.coroutines.test.runCurrent
import kotlinx.coroutines.test.runTest
import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertTrue
import kotlin.time.Duration.Companion.hours
import kotlin.time.Duration.Companion.minutes
import kotlin.time.TestTimeSource

/** Codex r1 #3/#5/#6 on the add-on list cache Trakt and MDBList share. */
@OptIn(kotlinx.coroutines.ExperimentalCoroutinesApi::class)
class AddonEpisodeListCacheTest {
    private val list = listOf(EpisodeMappingEntry(1, 1, videoId = "tt1:1:1"))

    @Test
    fun `a tracker waiting on a fetch another tracker cancelled fetches for itself`() = runTest {
        val gate = CompletableDeferred<Unit>()
        var fetches = 0
        val cache = AddonEpisodeListCache(fetch = { _, _ -> fetches++; gate.await(); list }, generation = { 0 })
        val trakt = launch { cache.episodes("tt1", "series") }
        runCurrent()
        val mdblist = async { cache.episodes("tt1", "series") }
        runCurrent()
        trakt.cancel()
        runCurrent()
        gate.complete(Unit)
        assertEquals(list, mdblist.await())
        assertEquals(2, fetches)
        assertEquals(list, cache.episodes("tt1", "series"))
        assertEquals(2, fetches)
    }

    @Test
    fun `a cancelled waiter leaves the owner's fetch alone`() = runTest {
        val gate = CompletableDeferred<Unit>()
        var fetches = 0
        val cache = AddonEpisodeListCache(fetch = { _, _ -> fetches++; gate.await(); list }, generation = { 0 })
        val owner = async { cache.episodes("tt1", "series") }
        runCurrent()
        val waiter = async { cache.episodes("tt1", "series") }
        runCurrent()
        waiter.cancel()
        runCurrent()
        assertTrue(waiter.isCancelled)
        gate.complete(Unit)
        assertEquals(list, owner.await())
        assertEquals(1, fetches)
    }

    @Test
    fun `an empty fetch is retried once its grace period has passed`() = runTest {
        // r1 #6: the metadata providers were still starting; the show must remap later.
        val clock = TestTimeSource()
        var answer = emptyList<EpisodeMappingEntry>()
        var fetches = 0
        val cache = AddonEpisodeListCache(fetch = { _, _ -> fetches++; answer }, generation = { 0 }, emptyResultTtl = 5.minutes, timeSource = clock)
        assertTrue(cache.episodes("tt1", "series").isEmpty())
        answer = list
        assertTrue(cache.episodes("tt1", "series").isEmpty())
        assertEquals(1, fetches)
        clock += 5.minutes
        assertEquals(list, cache.episodes("tt1", "series"))
        assertEquals(2, fetches)
        clock += 60.minutes
        assertEquals(list, cache.episodes("tt1", "series"))
        assertEquals(2, fetches)
    }

    @Test
    fun `a fetch that straddles an add-on change is done again and not joined by the new generation`() = runTest {
        // r2 #3
        val gate = CompletableDeferred<Unit>()
        var generation = 0
        var fetches = 0
        val old = listOf(EpisodeMappingEntry(1, 1, videoId = "old"))
        val cache = AddonEpisodeListCache(fetch = { _, _ -> fetches++; if (fetches == 1) { gate.await(); old } else list }, generation = { generation })
        val owner = async { cache.episodes("tt1", "series") }
        runCurrent()
        generation = 1
        val newcomer = async { cache.episodes("tt1", "series") }
        runCurrent()
        assertEquals(2, fetches) // the newcomer started its own fetch instead of joining the old one
        gate.complete(Unit)
        assertEquals(list, owner.await()) // the owner dropped the old list and fetched again
        assertEquals(list, newcomer.await())
        assertEquals(list, cache.episodes("tt1", "series"))
    }

    @Test
    fun `a successful list is fetched again once it has aged`() = runTest {
        // r2 #8
        val clock = TestTimeSource()
        var fetches = 0
        val cache = AddonEpisodeListCache(fetch = { _, _ -> fetches++; list }, generation = { 0 }, listTtl = 6.hours, timeSource = clock)
        cache.episodes("tt1", "series")
        clock += 5.hours
        cache.episodes("tt1", "series")
        assertEquals(1, fetches)
        clock += 1.hours
        cache.episodes("tt1", "series")
        assertEquals(2, fetches)
    }

    @Test
    fun `a list from an older add-on set is fetched again`() = runTest {
        var generation = 0
        var fetches = 0
        val cache = AddonEpisodeListCache(fetch = { _, _ -> fetches++; list }, generation = { generation })
        cache.episodes("tt1", "series")
        cache.episodes("tt1", "series")
        assertEquals(1, fetches)
        generation = 1
        cache.episodes("tt1", "series")
        assertEquals(2, fetches)
        cache.clear()
        cache.episodes("tt1", "series")
        assertEquals(3, fetches)
    }
}
