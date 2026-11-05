package com.nuvio.app.features.mdblist

import com.nuvio.app.features.tracking.TrackingHistoryItem
import com.nuvio.app.features.tracking.TrackingScrobbleAction
import com.nuvio.app.features.tracking.TrackingScrobbleEvent
import com.nuvio.app.features.tracking.buildTrackingMediaReference
import com.nuvio.app.features.watched.WatchedItem
import com.nuvio.app.features.watched.watchedItemKey
import kotlinx.coroutines.flow.first
import kotlinx.coroutines.flow.drop
import kotlinx.coroutines.launch
import kotlinx.coroutines.test.runCurrent
import kotlinx.coroutines.test.runTest
import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertFalse
import kotlin.test.assertTrue

/**
 * Upstream NuvioTV facf25ec3 at the fork's ports: scrobbles and history writes reach MDBList in
 * TMDB numbering, progress and watched reads come back in the add-on's.
 */
@OptIn(kotlinx.coroutines.ExperimentalCoroutinesApi::class)
class MdbListEpisodeRemapAdaptersTest {
    @Test
    fun `a scrobble for the add-on's S2E11 goes out as TMDB's S1E35`() = runTest {
        val h = MdbListSyncTestHarness(backgroundScope)
        val writer = MdbListTrackingWrites(h.repository, MdbListHistoryService(h.http.api, h.repository),
            MdbListScrobbleService(h.http.api, h.repository), splitAnimeMappings())
        h.http.reply(body = """{"action":"pause","progress":50,"paused_at":"$MDBLIST_TEST_TIME"}""")

        writer.scrobble(1, TrackingScrobbleAction.PAUSE, TrackingScrobbleEvent(episodeReference(2, 11), 50.0))

        val show = mdbListResponseElement(h.http.engine.requests.single().body).objectValue().objectValue("show")!!
        assertEquals(1, show.text("season")?.toInt())
        assertEquals(35, show.text("episode")?.toInt())
        // The local playback row holds MDBList's numbering; the snapshot hands it out in the add-on's.
        val session = h.repository.currentSnapshot()!!.playback.single()
        assertEquals(1 to 35, session.season to session.episode)
    }

    @Test
    fun `history writes and removals translate the episode the same way`() = runTest {
        val h = MdbListSyncTestHarness(backgroundScope)
        val writer = MdbListTrackingWrites(h.repository, MdbListHistoryService(h.http.api, h.repository),
            MdbListScrobbleService(h.http.api, h.repository), splitAnimeMappings())
        h.http.reply(body = """{"updated":{"episodes":1}}""")
        writer.addToHistory(1, listOf(TrackingHistoryItem(episodeReference(2, 11), 0L)))
        h.http.reply(body = """{"deleted":{"episodes":1}}""")
        writer.removeFromHistory(1, listOf(episodeReference(2, 11)))

        for (request in h.http.engine.requests) {
            val show = mdbListResponseElement(request.body).objectValue().arrayValue("shows").single().objectValue()
            val episode = show.arrayValue("seasons").single().objectValue().let { season ->
                season.text("number")?.toInt() to season.arrayValue("episodes").single().objectValue().text("number")?.toInt()
            }
            assertEquals(1 to 35, episode, request.path)
        }
    }

    @Test
    fun `the watched port pushes in TMDB numbering and pulls in the add-on's once the show is mapped`() = runTest {
        val h = MdbListSyncTestHarness(backgroundScope)
        h.seed(h.snapshot().copy(watched = listOf(mdbListTestEpisode(1, 34), mdbListTestEpisode(1, 35))))
        h.repository.ensureLoaded()
        val mappings = splitAnimeMappings()
        val watched = MdbListWatchedSyncAdapter(h.repository, MdbListHistoryService(h.http.api, h.repository), mappings, h.http.store, h.activeProfile)

        // Before the show is mapped the pull is MDBList's numbering, as it was.
        assertEquals(listOf(1 to 34, 1 to 35), watched.pull(1, 100).map { it.season!! to it.episode!! })

        h.http.reply(body = """{"updated":{"episodes":1}}""")
        watched.push(1, listOf(WatchedItem("tt1", "series", "Show", season = 2, episode = 12, videoId = "tt1:2:12", markedAtEpochMs = 1L)))
        val show = mdbListResponseElement(h.http.engine.requests.single().body).objectValue().arrayValue("shows").single().objectValue()
        val season = show.arrayValue("seasons").single().objectValue()
        assertEquals(1, season.text("number")?.toInt())
        assertEquals(36, season.arrayValue("episodes").single().objectValue().text("number")?.toInt())

        // The push resolved the mapping, so reads now come back in the add-on's numbering, the
        // confirmed mark included (MDBList's S1E36 is the add-on's S2E12 again).
        val items = watched.pull(1, 100)
        assertEquals(listOf(2 to 10, 2 to 11, 2 to 12), items.map { it.season!! to it.episode!! })
        assertEquals("tt1:2:11", items[1].videoId)
        val keys = watched.pullExtraWatchedKeys(1)
        assertTrue(watchedItemKey("series", "tt1", 2, 11) in keys)
        assertTrue(watchedItemKey("series", "tmdb:1", 2, 10) in keys)
        assertFalse(watchedItemKey("series", "tt1", 1, 35) in keys)
        assertEquals(keys, watched.observeExtraWatchedKeys(1).first())
    }

    @Test
    fun `progress snapshots move to the add-on's numbering once the mapping resolves in the background`() = runTest {
        val h = MdbListSyncTestHarness(backgroundScope)
        h.seed(h.snapshot().copy(
            watched = listOf(mdbListTestEpisode(1, 35)),
            playback = listOf(mdbListTestPlayback().copy(type = MdbListItemType.EPISODE, season = 1, episode = 40)),
        ))
        h.repository.ensureLoaded()
        val mappings = splitAnimeMappings(backgroundScope)
        val provider = MdbListTrackingProgressProvider(h.repository, MdbListScrobbleService(h.http.api, h.repository), mappings, h.http.store, h.activeProfile, {})
        var ticks = 0
        backgroundScope.launch { provider.changes.drop(1).collect { ticks++ } }

        // First read: MDBList's numbering, and the mapping starts resolving on the background scope
        // (runCurrent, not advanceUntilIdle: the latter stops once no foreground task is left).
        val before = provider.snapshot().entries.associate { it.videoId to (it.seasonNumber to it.episodeNumber) }
        assertEquals(mapOf("tt1:1:40" to (1 to 40), "tt1:1:35" to (1 to 35)), before)
        runCurrent()
        assertTrue(mappings.cached("tt1")!!.remaps)
        assertTrue(ticks > 0, "changes ticks once the mapping resolves")

        val after = provider.snapshot().entries.associate { it.videoId to (it.seasonNumber to it.episodeNumber) }
        assertEquals(mapOf("tt1:2:16" to (2 to 16), "tt1:2:11" to (2 to 11)), after)
        assertEquals("mdblist_playback", provider.snapshot().entries.first { it.videoId == "tt1:2:16" }.source)

        // Removing the remapped row clears MDBList's own coordinates.
        h.http.reply(body = """{"action":"clear","deleted":true}""")
        provider.removeProgress(provider.snapshot().entries.filter { it.videoId == "tt1:2:16" })
        val show = mdbListResponseElement(h.http.engine.requests.single().body).objectValue().objectValue("show")!!
        assertEquals(1 to 40, show.text("season")?.toInt() to show.text("episode")?.toInt())
        assertTrue(h.repository.currentSnapshot()!!.playback.isEmpty())
    }

    @Test
    fun `next-up seeds are remapped inline when the show was not mapped yet and left alone when it was`() = runTest {
        val h = MdbListSyncTestHarness(backgroundScope)
        h.seed(h.snapshot().copy(watched = listOf(mdbListTestEpisode(1, 35))))
        h.repository.ensureLoaded()
        val mappings = splitAnimeMappings()
        val provider = MdbListTrackingProgressProvider(h.repository, MdbListScrobbleService(h.http.api, h.repository), mappings, h.http.store, h.activeProfile, {})

        val seeds = provider.snapshot().entries
        assertEquals(1 to 35, seeds.single().let { it.seasonNumber to it.episodeNumber })
        val prepared = provider.prepareNextUpProgressEntries(seeds, "tt1")
        assertEquals(2 to 11, prepared.single().let { it.seasonNumber to it.episodeNumber })
        assertEquals("tt1:2:11", prepared.single().videoId)

        // Now the mapping is cached: the snapshot is already in the add-on's numbering and
        // preparing it again must not move the episode twice.
        val remapped = provider.snapshot().entries
        assertEquals(2 to 11, remapped.single().let { it.seasonNumber to it.episodeNumber })
        assertEquals(remapped, provider.prepareNextUpProgressEntries(remapped, "tt1"))
        assertEquals(seeds, provider.prepareNextUpProgressEntries(seeds, "tt2"))
    }

    @Test
    fun `the detail screen's refresh resolves the show's mapping`() = runTest {
        val h = MdbListSyncTestHarness(backgroundScope)
        h.seed(h.snapshot().copy(watched = listOf(mdbListTestEpisode(1, 35))))
        h.repository.ensureLoaded()
        val mappings = splitAnimeMappings()
        val provider = MdbListTrackingProgressProvider(h.repository, MdbListScrobbleService(h.http.api, h.repository), mappings, h.http.store, h.activeProfile, {})
        provider.refreshEpisodeProgress("tt1", forceRefresh = false)
        assertTrue(mappings.cached("tt1")!!.remaps)
        provider.refreshEpisodeProgress("kitsu:1", forceRefresh = false)
        assertEquals(null, mappings.cached("kitsu:1"))
    }

    private fun episodeReference(season: Int, episode: Int) = buildTrackingMediaReference(
        contentType = "series", parentMetaId = "tt1", videoId = "tt1:$season:$episode",
        seasonNumber = season, episodeNumber = episode,
    )
}
