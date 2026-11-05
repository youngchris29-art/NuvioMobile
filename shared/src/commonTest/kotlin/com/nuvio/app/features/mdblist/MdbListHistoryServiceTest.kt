package com.nuvio.app.features.mdblist

import com.nuvio.app.features.tracking.TrackingEpisode
import com.nuvio.app.features.tracking.TrackingHistoryItem
import com.nuvio.app.features.tracking.TrackingExternalIds
import com.nuvio.app.features.tracking.TrackingMediaKind
import com.nuvio.app.features.tracking.TrackingMediaReference
import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.test.runTest
import kotlin.test.assertEquals
import kotlin.test.assertFalse
import kotlin.test.assertTrue
import kotlin.test.Test

class MdbListHistoryServiceTest {
    @Test
    fun `confirmed history is saved without refreshing unrelated buckets`() = runTest {
        val harness = MdbListSyncTestHarness(backgroundScope)
        harness.http.reply(body = """{"updated":{"movies":1},"plays":[{"type":"movie","ids":{"imdb":"tt1","tmdb":1,"mdblist":"public"},"watched_at":"2026-09-06T00:00:00Z","added":true}]}""")

        val result = service(harness).add(harness.repository.currentScope(), listOf(item(1)))

        assertTrue(result.isComplete)
        assertEquals("public", harness.repository.currentSnapshot()?.watched?.single()?.media?.ids?.mdblist)
        assertEquals(1, harness.http.engine.requests.size)
        assertEquals(mapOf("report_added" to "true"), harness.http.engine.requests.single().query)
        assertTrue(harness.repository.currentSnapshot()?.invalidatedBuckets?.isEmpty() == true)
        assertTrue(harness.remote.calls.isEmpty())
    }

    @Test
    fun `large history batches respect receipt and show entry limits`() = runTest {
        val harness = MdbListSyncTestHarness(backgroundScope)
        harness.http.reply(body = """{"updated":{"movies":100}}""")
        harness.http.reply(body = """{"updated":{"movies":100}}""")
        harness.http.reply(body = """{"updated":{"movies":1}}""")

        val result = service(harness).add(harness.repository.currentScope(), (1L..201L).map(::item))

        assertTrue(result.isComplete)
        assertEquals(201, harness.repository.currentSnapshot()?.watched?.size)
        assertEquals(listOf(100, 100, 1), harness.http.engine.requests.map { mdbListResponseElement(it.body).objectValue().arrayValue("movies").size })
    }

    @Test
    fun `duplicate history input does not produce duplicate writes or false failures`() = runTest {
        val harness = MdbListSyncTestHarness(backgroundScope)
        harness.http.reply(body = """{"updated":{"movies":1}}""")
        val result = service(harness).add(harness.repository.currentScope(), listOf(item(1), item(1)))
        assertTrue(result.isComplete)
        assertEquals(1, harness.repository.currentSnapshot()?.watched?.size)
        assertEquals(1, mdbListResponseElement(harness.http.engine.requests.single().body).objectValue().arrayValue("movies").size)
    }

    @Test
    fun `partial results only project confirmed items and request reconciliation`() = runTest {
        val harness = MdbListSyncTestHarness(backgroundScope)
        harness.http.reply(body = """{"updated":{"movies":1},"not_found":{"movies":[{"ids":{"imdb":"tt2"}}]},"plays":[{"type":"movie","ids":{"imdb":"tt1"},"watched_at":"2026-09-06T00:00:00Z","added":false}]}""")

        val result = service(harness).add(harness.repository.currentScope(), listOf(item(1), item(2)))

        assertFalse(result.isComplete)
        assertEquals(1, result.notFoundCount)
        assertEquals(listOf("tt1"), harness.repository.currentSnapshot()?.watched?.map { it.media.ids.imdb })
        assertTrue(MdbListSyncBucket.WATCHED in harness.repository.currentSnapshot()!!.invalidatedBuckets)
    }

    @Test
    fun `removing history keeps paused playback and never calls clear or list endpoints`() = runTest {
        val harness = MdbListSyncTestHarness(backgroundScope)
        harness.seed(harness.snapshot().copy(playback = listOf(mdbListTestPlayback(timestamp = "2026-09-06T01:00:00Z"))))
        harness.http.reply(body = """{"deleted":{"movies":1},"not_found":{}}""")

        val result = service(harness).remove(harness.repository.currentScope(), listOf(item(1).media))

        assertTrue(result.isComplete)
        assertTrue(harness.repository.currentSnapshot()?.watched?.isEmpty() == true)
        assertEquals(1, harness.repository.currentSnapshot()?.playback?.size)
        assertEquals(listOf("/sync/watched/remove"), harness.http.engine.requests.map { it.path })
    }

    @Test
    fun `a later failed batch preserves already confirmed writes and is not retried`() = runTest {
        val harness = MdbListSyncTestHarness(backgroundScope)
        harness.http.reply(body = """{"updated":{"movies":100}}""")
        harness.http.reply(503)

        expectMdbListFailure<MdbListApiException> {
            service(harness).add(harness.repository.currentScope(), (1L..101L).map(::item))
        }

        assertEquals(100, harness.repository.currentSnapshot()?.watched?.size)
        assertEquals(2, harness.http.engine.requests.size)
        assertTrue(MdbListSyncBucket.WATCHED in harness.repository.currentSnapshot()!!.invalidatedBuckets)
    }

    @Test
    fun `malformed success cannot fabricate watched items`() = runTest {
        val harness = MdbListSyncTestHarness(backgroundScope)
        harness.http.reply(body = "{}")
        expectMdbListFailure<MdbListDecodingException> { service(harness).add(harness.repository.currentScope(), listOf(item(1))) }
        assertTrue(harness.repository.currentSnapshot()?.watched?.isEmpty() == true)
        assertEquals(1, harness.http.engine.requests.size)
    }

    @Test
    fun `unsupported IDs make no requests and report unresolved items`() = runTest {
        val harness = MdbListSyncTestHarness(backgroundScope)
        val unresolved = item(1).copy(media = item(1).media.copy(ids = TrackingExternalIds(mal = 100)))
        val result = service(harness).add(harness.repository.currentScope(), listOf(unresolved))
        assertFalse(result.isComplete)
        assertEquals(1, result.notFoundCount)
        assertTrue(harness.http.engine.requests.isEmpty())
    }

    @Test
    fun `late history response cannot write into another profile`() = runTest {
        val harness = MdbListSyncTestHarness(backgroundScope)
        harness.http.reply(body = """{"updated":{"movies":1}}""")
        harness.http.engine.intercept = { harness.switch(2, 84) }
        val scope = harness.repository.currentScope()
        expectMdbListFailure<CancellationException> { service(harness).add(scope, listOf(item(1))) }
        assertEquals(1, harness.http.engine.requests.size)
        assertEquals(null, harness.storage.profiles[2])
    }

    private fun service(harness: MdbListSyncTestHarness) = MdbListHistoryService(harness.http.api, harness.repository)
    @Test
    fun `an episode echoed in another numbering confirms the write and asks for a snapshot`() = runTest {
        // MDBList accepted the TMDB-numbered S1E59 (counts say so) but echoes the play in its own
        // season numbering; the echo pairs with no requested item and must not fail the mutation.
        val harness = MdbListSyncTestHarness(backgroundScope)
        harness.http.reply(body = """{"updated":{"episodes":1},"plays":[{"type":"episode","show":{"ids":{"imdb":"tt1"}},"season":2,"number":1,"watched_at":"2026-09-06T00:00:00Z","added":true}]}""")

        val result = service(harness).add(harness.repository.currentScope(), listOf(episodeItem(season = 1, number = 59)))

        assertTrue(result.isComplete)
        assertEquals(0, result.notFoundCount)
        val saved = harness.repository.currentSnapshot()?.watched?.single()
        assertEquals(1, saved?.season)
        assertEquals(59, saved?.episode)
        assertTrue(MdbListSyncBucket.WATCHED in harness.repository.currentSnapshot()!!.invalidatedBuckets)
    }

    @Test
    fun `a malformed echoed play is skipped when the counts confirm the write`() = runTest {
        val harness = MdbListSyncTestHarness(backgroundScope)
        harness.http.reply(body = """{"updated":{"movies":1},"plays":[{"type":"bogus","watched_at":"2026-09-06T00:00:00Z"}]}""")

        val result = service(harness).add(harness.repository.currentScope(), listOf(item(1)))

        assertTrue(result.isComplete)
        assertEquals(listOf("tt1"), harness.repository.currentSnapshot()?.watched?.map { it.media.ids.imdb })
        assertTrue(MdbListSyncBucket.WATCHED in harness.repository.currentSnapshot()!!.invalidatedBuckets)
    }

    @Test
    fun `an unusable echo cannot fabricate a mark the counts do not confirm`() = runTest {
        val harness = MdbListSyncTestHarness(backgroundScope)
        harness.http.reply(body = """{"updated":{"movies":0},"plays":[{"type":"movie","ids":{"imdb":"tt9"},"watched_at":"2026-09-06T00:00:00Z"}]}""")

        val result = service(harness).add(harness.repository.currentScope(), listOf(item(1)))

        assertFalse(result.isComplete)
        assertEquals(1, result.notFoundCount)
        assertTrue(harness.repository.currentSnapshot()?.watched?.isEmpty() == true)
        assertTrue(MdbListSyncBucket.WATCHED in harness.repository.currentSnapshot()!!.invalidatedBuckets)
    }

    @Test
    fun `a batch keeps the echoes that paired and trusts the counts for the rest`() = runTest {
        val harness = MdbListSyncTestHarness(backgroundScope)
        harness.http.reply(body = """{"updated":{"movies":2},"plays":[{"type":"movie","ids":{"imdb":"tt1","mdblist":"m1"},"watched_at":"2026-09-06T00:00:00Z"},{"type":"movie","ids":{"imdb":"tt9"},"watched_at":"2026-09-06T00:00:00Z"}]}""")

        val result = service(harness).add(harness.repository.currentScope(), listOf(item(1), item(2)))

        assertTrue(result.isComplete)
        val watched = harness.repository.currentSnapshot()?.watched.orEmpty()
        assertEquals(setOf("tt1", "tt2"), watched.map { it.media.ids.imdb }.toSet())
        assertEquals("m1", watched.single { it.media.ids.imdb == "tt1" }.media.ids.mdblist)
        assertTrue(MdbListSyncBucket.WATCHED in harness.repository.currentSnapshot()!!.invalidatedBuckets)
    }

    @Test
    fun `incomplete counts project only the echoes that paired`() = runTest {
        val harness = MdbListSyncTestHarness(backgroundScope)
        harness.http.reply(body = """{"updated":{"movies":1},"plays":[{"type":"movie","ids":{"imdb":"tt1"},"watched_at":"2026-09-06T00:00:00Z"},{"type":"movie","ids":{"imdb":"tt9"},"watched_at":"2026-09-06T00:00:00Z"}]}""")

        val result = service(harness).add(harness.repository.currentScope(), listOf(item(1), item(2)))

        assertFalse(result.isComplete)
        assertEquals(1, result.notFoundCount)
        assertEquals(listOf("tt1"), harness.repository.currentSnapshot()?.watched?.map { it.media.ids.imdb })
        assertTrue(MdbListSyncBucket.WATCHED in harness.repository.currentSnapshot()!!.invalidatedBuckets)
    }

    @Test
    fun `an echoed play without usable ids or dates is skipped like any other`() = runTest {
        val harness = MdbListSyncTestHarness(backgroundScope)
        harness.http.reply(body = """{"updated":{"movies":1},"plays":[{"type":"movie","ids":{"imdb":"not-an-id"},"watched_at":"yesterday"},"garbage",{"type":"season","show":"tt1"}]}""")

        val result = service(harness).add(harness.repository.currentScope(), listOf(item(1)))

        assertTrue(result.isComplete)
        assertEquals(listOf("tt1"), harness.repository.currentSnapshot()?.watched?.map { it.media.ids.imdb })
        assertTrue(MdbListSyncBucket.WATCHED in harness.repository.currentSnapshot()!!.invalidatedBuckets)
    }

    private fun item(id: Long) = TrackingHistoryItem(
        TrackingMediaReference(TrackingMediaKind.MOVIE, "Movie $id", ids = TrackingExternalIds(imdb = "tt$id")),
        mdbListTimestamp(MDBLIST_TEST_TIME)
    )

    private fun episodeItem(season: Int, number: Int) = TrackingHistoryItem(
        TrackingMediaReference(TrackingMediaKind.SHOW, "Show", ids = TrackingExternalIds(imdb = "tt1"), episode = TrackingEpisode(season, number)),
        mdbListTimestamp(MDBLIST_TEST_TIME)
    )
}
