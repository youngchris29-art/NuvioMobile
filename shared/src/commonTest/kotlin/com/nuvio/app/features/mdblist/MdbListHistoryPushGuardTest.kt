package com.nuvio.app.features.mdblist

import com.nuvio.app.features.watched.WatchedItem
import kotlinx.coroutines.test.runTest
import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertTrue

/**
 * Fork: a show-level mark makes MDBList mark every episode of a series watched (add) or wipe the
 * show's whole history (remove), so nothing but a film may leave the app without episode
 * coordinates. Mirrors `SimklHistoryPushGuardTest`, driven through the real adapter.
 */
class MdbListHistoryPushGuardTest {
    private fun mark(
        type: String,
        season: Int? = null,
        episode: Int? = null,
    ) = WatchedItem(
        id = "tt1",
        type = type,
        name = "Rick and Morty",
        season = season,
        episode = episode,
        markedAtEpochMs = 1_700_000_000_000,
    )

    private fun adapter(h: MdbListSyncTestHarness) = MdbListWatchedSyncAdapter(
        h.repository, MdbListHistoryService(h.http.api, h.repository), h.http.store, h.activeProfile
    )

    @Test
    fun `a mark without an episode never reaches MDBList history for a series`() = runTest {
        val h = MdbListSyncTestHarness(backgroundScope)
        val adapter = adapter(h)
        for (type in listOf("series", "show", "tv", "anime", "documentary-series")) {
            adapter.push(1, listOf(mark(type)))
            adapter.delete(1, listOf(mark(type)))
        }
        assertTrue(h.http.engine.requests.isEmpty())
    }

    @Test
    fun `a season-only mark is not collapsed into a whole-show write`() = runTest {
        val h = MdbListSyncTestHarness(backgroundScope)
        val adapter = adapter(h)
        adapter.push(1, listOf(mark("series", season = 1)))
        adapter.delete(1, listOf(mark("series", season = 1)))
        assertTrue(h.http.engine.requests.isEmpty())
    }

    @Test
    fun `episode marks always reach MDBList`() = runTest {
        val h = MdbListSyncTestHarness(backgroundScope)
        h.http.reply(body = """{"updated":{"episodes":1}}""")
        h.http.reply(body = """{"deleted":{"episodes":1}}""")
        val adapter = adapter(h)

        adapter.push(1, listOf(mark("series", season = 1, episode = 1)))
        adapter.delete(1, listOf(mark("series", season = 1, episode = 1)))

        assertEquals(listOf("/sync/watched", "/sync/watched/remove"), h.http.engine.requests.map { it.path })
        h.http.engine.requests.forEach { request ->
            val show = mdbListResponseElement(request.body).objectValue().arrayValue("shows").single().objectValue()
            assertTrue("seasons" in show, "an episode must travel with its season/episode coordinates")
        }
    }

    @Test
    fun `films need no episode`() = runTest {
        val h = MdbListSyncTestHarness(backgroundScope)
        h.http.reply(body = """{"updated":{"movies":1}}""")
        h.http.reply(body = """{"deleted":{"movies":1}}""")
        val adapter = adapter(h)

        adapter.push(1, listOf(mark("Movie")))
        adapter.delete(1, listOf(mark("film")))

        assertEquals(listOf("/sync/watched", "/sync/watched/remove"), h.http.engine.requests.map { it.path })
        h.http.engine.requests.forEach { request ->
            assertEquals(1, mdbListResponseElement(request.body).objectValue().arrayValue("movies").size)
        }
    }

    @Test
    fun `a mixed push keeps the films and the episodes and drops the series mark`() = runTest {
        val h = MdbListSyncTestHarness(backgroundScope)
        h.http.reply(body = """{"updated":{"movies":1,"episodes":1}}""")

        adapter(h).push(
            1,
            listOf(
                mark("movie").copy(id = "tt2"),
                mark("series"),
                mark("series", season = 2, episode = 6),
            ),
        )

        val body = mdbListResponseElement(h.http.engine.requests.single().body).objectValue()
        assertEquals(1, body.arrayValue("movies").size)
        val show = body.arrayValue("shows").single().objectValue()
        assertTrue("seasons" in show)
    }

    @Test
    fun `a mixed removal never sends the series mark`() = runTest {
        val h = MdbListSyncTestHarness(backgroundScope)
        h.http.reply(body = """{"deleted":{"episodes":1}}""")

        adapter(h).delete(1, listOf(mark("series"), mark("series", season = 3, episode = 2)))

        val shows = mdbListResponseElement(h.http.engine.requests.single().body).objectValue().arrayValue("shows")
        assertEquals(1, shows.size)
        assertTrue("seasons" in shows.single().objectValue())
    }
}
