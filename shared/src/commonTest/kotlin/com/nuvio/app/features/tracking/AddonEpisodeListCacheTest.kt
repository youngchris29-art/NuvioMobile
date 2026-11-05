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
        val cache = AddonEpisodeListCache(fetch = { _, _, _ -> fetches++; gate.await(); list }, generation = { 0 })
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
        val cache = AddonEpisodeListCache(fetch = { _, _, _ -> fetches++; gate.await(); list }, generation = { 0 })
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
        val cache = AddonEpisodeListCache(fetch = { _, _, _ -> fetches++; answer }, generation = { 0 }, emptyResultTtl = 5.minutes, timeSource = clock)
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
        val cache = AddonEpisodeListCache(fetch = { _, _, _ -> fetches++; if (fetches == 1) { gate.await(); old } else list }, generation = { generation })
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
        val cache = AddonEpisodeListCache(fetch = { _, _, _ -> fetches++; list }, generation = { 0 }, listTtl = 6.hours, timeSource = clock)
        cache.episodes("tt1", "series")
        clock += 5.hours
        cache.episodes("tt1", "series")
        assertEquals(1, fetches)
        clock += 1.hours
        cache.episodes("tt1", "series")
        assertEquals(2, fetches)
    }

    @Test
    fun `an aged list is fetched again with refresh so the source does not answer from its own cache`() = runTest {
        // r3 #3
        val clock = TestTimeSource()
        val refreshes = mutableListOf<Boolean>()
        val cache = AddonEpisodeListCache(fetch = { _, _, refresh -> refreshes += refresh; list }, generation = { 0 }, listTtl = 6.hours, timeSource = clock)
        cache.episodes("tt1", "series")
        clock += 6.hours
        cache.episodes("tt1", "series")
        assertEquals(listOf(false, true), refreshes)
        // An empty list that aged out is a plain fetch: there is nothing stale to bypass.
        var answer = emptyList<EpisodeMappingEntry>()
        val empties = mutableListOf<Boolean>()
        val cache2 = AddonEpisodeListCache(fetch = { _, _, refresh -> empties += refresh; answer }, generation = { 0 }, emptyResultTtl = 5.minutes, timeSource = clock)
        cache2.episodes("tt1", "series")
        clock += 5.minutes
        answer = list
        cache2.episodes("tt1", "series")
        // r4 #4: an aged empty list is fetched with refresh too, past a source that memoised the empty answer.
        assertEquals(listOf(false, true), empties)
    }

    @Test
    fun `an empty answer a source memoised is bypassed once the empty list ages out`() = runTest {
        // r4 #4: the source (MetaDetailsRepository in production) caches a meta with no videos.
        val clock = TestTimeSource()
        var upstream = emptyList<EpisodeMappingEntry>()
        var memo: List<EpisodeMappingEntry>? = null
        val cache = AddonEpisodeListCache(
            fetch = { _, _, refresh -> if (refresh || memo == null) memo = upstream; memo!! },
            generation = { 0 }, emptyResultTtl = 5.minutes, timeSource = clock,
        )
        assertTrue(cache.episodes("tt1", "series").isEmpty())
        upstream = list
        clock += 5.minutes
        assertEquals(list, cache.episodes("tt1", "series"))
    }

    @Test
    fun `a generation change that lands as the fetch returns is not published`() = runTest {
        // r3 #5: the change happens after the fetch body and before publication.
        var generation = 0
        var fetches = 0
        val old = listOf(EpisodeMappingEntry(1, 1, videoId = "old"))
        val cache = AddonEpisodeListCache(fetch = { _, _, _ -> fetches++; if (fetches == 1) { generation = 1; old } else list }, generation = { generation })
        assertEquals(list, cache.episodes("tt1", "series"))
        assertEquals(2, fetches)
        assertEquals(list, cache.episodes("tt1", "series"))
        assertEquals(2, fetches)
    }

    @Test
    fun `a forced refresh fetches past a current list and replaces it`() = runTest {
        // r7 #2
        var answer = list
        val refreshes = mutableListOf<Boolean>()
        val cache = AddonEpisodeListCache(fetch = { _, _, refresh -> refreshes += refresh; answer }, generation = { 0 })
        assertEquals(list, cache.episodes("tt1", "series"))
        answer = list + EpisodeMappingEntry(1, 2, videoId = "tt1:1:2")
        assertEquals(list, cache.episodes("tt1", "series"))
        assertEquals(answer, cache.episodes("tt1", "series", refresh = true))
        assertEquals(answer, cache.episodes("tt1", "series"))
        assertEquals(listOf(false, true), refreshes)
    }

    @Test
    fun `a list from an older add-on set is fetched again`() = runTest {
        var generation = 0
        var fetches = 0
        val cache = AddonEpisodeListCache(fetch = { _, _, _ -> fetches++; list }, generation = { generation })
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
