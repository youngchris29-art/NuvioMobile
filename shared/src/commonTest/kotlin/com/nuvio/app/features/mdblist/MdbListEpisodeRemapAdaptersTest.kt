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

    @Test
    fun `rows handed out in TMDB numbering are removed and prepared as such after the mapping lands`() = runTest {
        // r1 #7: add-on 30 + 18 vs TMDB 24 + 24. TMDB S2E5 is the add-on's S1E29, while the add-on's own
        // S2E5 is TMDB S2E11: a row that left in TMDB numbering must not be read as the add-on's.
        val h = MdbListSyncTestHarness(backgroundScope)
        h.seed(h.snapshot().copy(
            watched = listOf(mdbListTestEpisode(2, 6)),
            playback = listOf(
                mdbListTestPlayback().copy(type = MdbListItemType.EPISODE, season = 2, episode = 5),
                mdbListTestPlayback().copy(id = 8, type = MdbListItemType.EPISODE, season = 2, episode = 7),
            ),
        ))
        h.repository.ensureLoaded()
        val mappings = mdbListTestEpisodeMappings(
            MdbListTestAddonEpisodes(seasons = listOf(30, 18)),
            MdbListTestTmdbSeasons(seasons = listOf(24, 24), lookup = mapOf("tt1" to 1)),
        )
        val provider = MdbListTrackingProgressProvider(h.repository, MdbListScrobbleService(h.http.api, h.repository), mappings, h.http.store, h.activeProfile, {})

        val raw = provider.snapshot().entries
        assertEquals(setOf(2 to 5, 2 to 6, 2 to 7), raw.map { it.seasonNumber to it.episodeNumber }.toSet())
        // The mapping lands between that snapshot and the operations on its rows.
        assertTrue(mappings.resolve("tt1", 1)!!.remaps)

        val prepared = provider.prepareNextUpProgressEntries(raw.filter { it.source == "mdblist_history" }, "tt1")
        assertEquals(1 to 30, prepared.single().let { it.seasonNumber to it.episodeNumber })

        h.http.reply(body = """{"action":"clear","deleted":true}""")
        provider.removeProgress(raw.filter { it.episodeNumber == 5 })
        val show = mdbListResponseElement(h.http.engine.requests.single().body).objectValue().objectValue("show")!!
        assertEquals(2 to 5, show.text("season")?.toInt() to show.text("episode")?.toInt())

        // Rows handed out after the mapping landed are in the add-on's numbering and stay there.
        val remapped = provider.snapshot().entries
        assertEquals(setOf(1 to 30, 2 to 1), remapped.map { it.seasonNumber to it.episodeNumber }.toSet()) // TMDB S2E7 is the 31st episode: add-on S2E1
        assertEquals(remapped, provider.prepareNextUpProgressEntries(remapped, "tt1"))
        h.http.reply(body = """{"action":"clear","deleted":true}""")
        provider.removeProgress(remapped.filter { it.source == "mdblist_playback" })
        val again = mdbListResponseElement(h.http.engine.requests.last().body).objectValue().objectValue("show")!!
        assertEquals(2 to 7, again.text("season")?.toInt() to again.text("episode")?.toInt())
        assertTrue(h.repository.currentSnapshot()!!.playback.isEmpty())
    }

    @Test
    fun `a mapping the detail screen resolved under the TMDB id reaches records filed under the IMDb id`() = runTest {
        // r1 #8
        val h = MdbListSyncTestHarness(backgroundScope)
        h.seed(h.snapshot().copy(watched = listOf(mdbListTestEpisode(1, 35))))
        h.repository.ensureLoaded()
        val mappings = splitAnimeMappings()
        val provider = MdbListTrackingProgressProvider(h.repository, MdbListScrobbleService(h.http.api, h.repository), mappings, h.http.store, h.activeProfile, {})
        val watched = MdbListWatchedSyncAdapter(h.repository, MdbListHistoryService(h.http.api, h.repository), mappings, h.http.store, h.activeProfile)

        provider.refreshEpisodeProgress("tmdb:1", forceRefresh = false)
        assertTrue(mappings.cached("tt1")!!.remaps)
        assertEquals(listOf(2 to 11), watched.pull(1, 100).map { it.season!! to it.episode!! })
        assertEquals(setOf(2 to 11), provider.snapshot().entries.map { it.seasonNumber to it.episodeNumber }.toSet())
    }

    @Test
    fun `a watched row pulled before the mapping resolved deletes its own TMDB episode afterwards`() = runTest {
        // r2 #1: add-on 30 + 18 vs TMDB 24 + 24; TMDB S2E5 pulled raw must not become TMDB S2E11 on delete.
        val h = MdbListSyncTestHarness(backgroundScope)
        h.seed(h.snapshot().copy(watched = listOf(mdbListTestEpisode(2, 5))))
        h.repository.ensureLoaded()
        val mappings = mdbListTestEpisodeMappings(
            MdbListTestAddonEpisodes(seasons = listOf(30, 18)),
            MdbListTestTmdbSeasons(seasons = listOf(24, 24), lookup = mapOf("tt1" to 1)),
        )
        val watched = MdbListWatchedSyncAdapter(h.repository, MdbListHistoryService(h.http.api, h.repository), mappings, h.http.store, h.activeProfile)

        val pulled = watched.pull(1, 100).single()
        assertEquals(2 to 5, pulled.season to pulled.episode)
        assertEquals("mdblist:tt1:2:5", pulled.trackingEpisodeKey)
        assertTrue(mappings.resolve("tt1", 1)!!.remaps)

        h.http.reply(body = """{"deleted":{"episodes":1}}""")
        watched.delete(1, listOf(pulled))
        val show = mdbListResponseElement(h.http.engine.requests.single().body).objectValue().arrayValue("shows").single().objectValue()
        val season = show.arrayValue("seasons").single().objectValue()
        assertEquals(2 to 5, season.text("number")?.toInt() to season.arrayValue("episodes").single().objectValue().text("number")?.toInt())

        // A row pulled after the mapping landed shows the add-on's numbers and still names TMDB's episode.
        h.seed(h.snapshot().copy(watched = listOf(mdbListTestEpisode(2, 6))))
        h.repository.refresh(com.nuvio.app.features.tracking.TrackingRefreshIntent.USER_INITIATED)
        val remapped = watched.pull(1, 100).lastOrNull { it.trackingEpisodeKey == "mdblist:tt1:2:6" }
        if (remapped != null) {
            assertEquals(1 to 30, remapped.season to remapped.episode)
            h.http.reply(body = """{"updated":{"episodes":1}}""")
            watched.push(1, listOf(remapped))
            val pushed = mdbListResponseElement(h.http.engine.requests.last().body).objectValue().arrayValue("shows").single().objectValue()
            val pushedSeason = pushed.arrayValue("seasons").single().objectValue()
            assertEquals(2 to 6, pushedSeason.text("number")?.toInt() to pushedSeason.arrayValue("episodes").single().objectValue().text("number")?.toInt())
        }
        // An item the app built from the add-on's episode list is translated as before.
        h.http.reply(body = """{"updated":{"episodes":1}}""")
        watched.push(1, listOf(WatchedItem("tt1", "series", "Show", season = 2, episode = 5, videoId = "tt1:2:5", markedAtEpochMs = 1L)))
        val built = mdbListResponseElement(h.http.engine.requests.last().body).objectValue().arrayValue("shows").single().objectValue()
        val builtSeason = built.arrayValue("seasons").single().objectValue()
        assertEquals(2 to 11, builtSeason.text("number")?.toInt() to builtSeason.arrayValue("episodes").single().objectValue().text("number")?.toInt())
    }

    @Test
    fun `a pulled row still names its TMDB episode after a restart`() = runTest {
        // r3 #1: the key rides the stored payload's compacted entries.
        val h = MdbListSyncTestHarness(backgroundScope)
        h.seed(h.snapshot().copy(watched = listOf(mdbListTestEpisode(2, 5))))
        h.repository.ensureLoaded()
        val mappings = mdbListTestEpisodeMappings(
            MdbListTestAddonEpisodes(seasons = listOf(30, 18)),
            MdbListTestTmdbSeasons(seasons = listOf(24, 24), lookup = mapOf("tt1" to 1)),
        )
        val watched = MdbListWatchedSyncAdapter(h.repository, MdbListHistoryService(h.http.api, h.repository), mappings, h.http.store, h.activeProfile)
        val pulled = watched.pull(1, 100)
        val restored = com.nuvio.app.features.watched.expandProviderWatchedItems(
            com.nuvio.app.features.watched.compactProviderWatchedItems(pulled),
        ).single()
        assertEquals("mdblist:tt1:2:5", restored.trackingEpisodeKey)
        assertTrue(mappings.resolve("tt1", 1)!!.remaps)
        h.http.reply(body = """{"deleted":{"episodes":1}}""")
        watched.delete(1, listOf(restored))
        val show = mdbListResponseElement(h.http.engine.requests.single().body).objectValue().arrayValue("shows").single().objectValue()
        val season = show.arrayValue("seasons").single().objectValue()
        assertEquals(2 to 5, season.text("number")?.toInt() to season.arrayValue("episodes").single().objectValue().text("number")?.toInt())
    }

    @Test
    fun `a snapshot schedules a reload of a mapping that has aged`() = runTest {
        // r3 #4: the old answer is served while the show's new season is picked up in the background.
        val clock = kotlin.time.TestTimeSource()
        val h = MdbListSyncTestHarness(backgroundScope)
        h.seed(h.snapshot().copy(watched = listOf(mdbListTestEpisode(1, 30))))
        h.repository.ensureLoaded()
        val addon = MdbListTestAddonEpisodes(seasons = listOf(34))
        val tmdb = MdbListTestTmdbSeasons(seasons = listOf(34))
        val mappings = mdbListTestEpisodeMappings(addon, tmdb, backgroundScope, clock)
        val provider = MdbListTrackingProgressProvider(h.repository, MdbListScrobbleService(h.http.api, h.repository), mappings, h.http.store, h.activeProfile, {})
        assertFalse(mappings.resolve("tt1", 1)!!.remaps)
        addon.seasons = listOf(24, 10) // the add-on now splits the show
        clock += kotlin.time.Duration.parse("6h")
        assertEquals(1 to 30, provider.snapshot().entries.single().let { it.seasonNumber to it.episodeNumber })
        runCurrent()
        assertTrue(mappings.cached("tt1")!!.remaps)
        assertEquals(2 to 6, provider.snapshot().entries.single().let { it.seasonNumber to it.episodeNumber })
    }

    @Test
    fun `a TMDB episode the add-on does not have is left out rather than shown as another episode`() = runTest {
        // r4 #2: TMDB A, B, Recap, C vs add-on A, B, C; the recap is watched on MDBList.
        val h = MdbListSyncTestHarness(backgroundScope)
        h.seed(h.snapshot().copy(
            watched = listOf(mdbListTestEpisode(1, 3), mdbListTestEpisode(1, 4)),
            playback = listOf(mdbListTestPlayback().copy(type = MdbListItemType.EPISODE, season = 1, episode = 3)),
        ))
        h.repository.ensureLoaded()
        val mappings = mdbListTestEpisodeMappings(
            MdbListTestAddonEpisodes(seasons = listOf(3), titles = mapOf(1 to 1 to "A", 1 to 2 to "B", 1 to 3 to "C")),
            MdbListTestTmdbSeasons(seasons = listOf(4), titles = mapOf(1 to 1 to "A", 1 to 2 to "B", 1 to 3 to "Recap", 1 to 4 to "C"), lookup = mapOf("tt1" to 1)),
        )
        val provider = MdbListTrackingProgressProvider(h.repository, MdbListScrobbleService(h.http.api, h.repository), mappings, h.http.store, h.activeProfile, {})
        val watched = MdbListWatchedSyncAdapter(h.repository, MdbListHistoryService(h.http.api, h.repository), mappings, h.http.store, h.activeProfile)
        assertTrue(mappings.resolve("tt1", 1)!!.remaps)

        val items = watched.pull(1, 100)
        assertEquals(listOf(1 to 3), items.map { it.season!! to it.episode!! }) // TMDB S1E4 "C"; the recap is gone
        assertEquals("mdblist:tt1:1:4", items.single().trackingEpisodeKey)
        val keys = watched.pullExtraWatchedKeys(1)
        assertTrue(watchedItemKey("series", "tt1", 1, 3) in keys)
        assertFalse(watchedItemKey("series", "tt1", 1, 4) in keys)
        // The recap's playback row and its next-up seed are left out too; the "C" seed is S1E3.
        assertEquals(listOf(1 to 3), provider.snapshot().entries.map { it.seasonNumber to it.episodeNumber })
    }

    @Test
    fun `a legacy MDBList row without a key is deleted by its own coordinates`() = runTest {
        // r4 #3: pulled by a build before the key existed, persisted in TMDB numbering, restored, unmarked.
        val h = MdbListSyncTestHarness(backgroundScope)
        h.seed(h.snapshot().copy(watched = listOf(mdbListTestEpisode(2, 5))))
        h.repository.ensureLoaded()
        val mappings = mdbListTestEpisodeMappings(
            MdbListTestAddonEpisodes(seasons = listOf(30, 18)),
            MdbListTestTmdbSeasons(seasons = listOf(24, 24), lookup = mapOf("tt1" to 1)),
        )
        val watched = MdbListWatchedSyncAdapter(h.repository, MdbListHistoryService(h.http.api, h.repository), mappings, h.http.store, h.activeProfile)
        val legacy = com.nuvio.app.features.watched.expandProviderWatchedItems(
            com.nuvio.app.features.watched.compactProviderWatchedItems(listOf(
                WatchedItem("tt1", "series", "Show", season = 2, episode = 5, videoId = "tt1:2:5", trackingProviderId = "mdblist", markedAtEpochMs = 1L),
            )),
        ).single()
        assertEquals(null, legacy.trackingEpisodeKey)
        assertTrue(mappings.resolve("tt1", 1)!!.remaps)
        h.http.reply(body = """{"deleted":{"episodes":1}}""")
        watched.delete(1, listOf(legacy))
        val show = mdbListResponseElement(h.http.engine.requests.single().body).objectValue().arrayValue("shows").single().objectValue()
        val season = show.arrayValue("seasons").single().objectValue()
        assertEquals(2 to 5, season.text("number")?.toInt() to season.arrayValue("episodes").single().objectValue().text("number")?.toInt())
        // A row the app built (no provider id) is still translated.
        h.http.reply(body = """{"deleted":{"episodes":1}}""")
        watched.delete(1, listOf(WatchedItem("tt1", "series", "Show", season = 2, episode = 5, videoId = "tt1:2:5", markedAtEpochMs = 1L)))
        val built = mdbListResponseElement(h.http.engine.requests.last().body).objectValue().arrayValue("shows").single().objectValue()
        val builtSeason = built.arrayValue("seasons").single().objectValue()
        assertEquals(2 to 11, builtSeason.text("number")?.toInt() to builtSeason.arrayValue("episodes").single().objectValue().text("number")?.toInt())
    }

    @Test
    fun `writes for an add-on episode MDBList has no counterpart for are skipped`() = runTest {
        // r5 #2 at the ports: add-on A, B, Recap, C vs TMDB A, B, C.
        val h = MdbListSyncTestHarness(backgroundScope)
        val mappings = mdbListTestEpisodeMappings(
            MdbListTestAddonEpisodes(seasons = listOf(4), titles = mapOf(1 to 1 to "A", 1 to 2 to "B", 1 to 3 to "Recap", 1 to 4 to "C")),
            MdbListTestTmdbSeasons(seasons = listOf(3), titles = mapOf(1 to 1 to "A", 1 to 2 to "B", 1 to 3 to "C"), lookup = mapOf("tt1" to 1)),
        )
        val writer = MdbListTrackingWrites(h.repository, MdbListHistoryService(h.http.api, h.repository), MdbListScrobbleService(h.http.api, h.repository), mappings)
        writer.scrobble(1, TrackingScrobbleAction.PAUSE, TrackingScrobbleEvent(episodeReference(1, 3), 50.0))
        assertTrue(h.http.engine.requests.isEmpty())
        val added = writer.addToHistory(1, listOf(TrackingHistoryItem(episodeReference(1, 3), 0L)))
        assertEquals(1, added.attemptedCount)
        assertEquals(1, added.notFoundCount)
        assertTrue(h.http.engine.requests.isEmpty())
        val watched = MdbListWatchedSyncAdapter(h.repository, MdbListHistoryService(h.http.api, h.repository), mappings, h.http.store, h.activeProfile)
        watched.push(1, listOf(WatchedItem("tt1", "series", "Show", season = 1, episode = 3, videoId = "tt1:1:3", markedAtEpochMs = 1L)))
        assertTrue(h.http.engine.requests.isEmpty())
        // The episode after it is written as TMDB's S1E3.
        h.http.reply(body = """{"action":"pause","progress":50,"paused_at":"$MDBLIST_TEST_TIME"}""")
        writer.scrobble(1, TrackingScrobbleAction.PAUSE, TrackingScrobbleEvent(episodeReference(1, 4), 50.0))
        val show = mdbListResponseElement(h.http.engine.requests.single().body).objectValue().objectValue("show")!!
        assertEquals(1 to 3, show.text("season")?.toInt() to show.text("episode")?.toInt())
    }

    @Test
    fun `a raw seed for a TMDB episode the add-on does not have is dropped when prepared`() = runTest {
        // r5 #4: TMDB A, B, Recap, C vs add-on A, B, C; the recap was watched before the mapping resolved.
        val h = MdbListSyncTestHarness(backgroundScope)
        h.seed(h.snapshot().copy(watched = listOf(mdbListTestEpisode(1, 3), mdbListTestEpisode(1, 4))))
        h.repository.ensureLoaded()
        val mappings = mdbListTestEpisodeMappings(
            MdbListTestAddonEpisodes(seasons = listOf(3), titles = mapOf(1 to 1 to "A", 1 to 2 to "B", 1 to 3 to "C")),
            MdbListTestTmdbSeasons(seasons = listOf(4), titles = mapOf(1 to 1 to "A", 1 to 2 to "B", 1 to 3 to "Recap", 1 to 4 to "C"), lookup = mapOf("tt1" to 1)),
        )
        val provider = MdbListTrackingProgressProvider(h.repository, MdbListScrobbleService(h.http.api, h.repository), mappings, h.http.store, h.activeProfile, {})
        val raw = provider.snapshot().entries
        assertEquals(setOf(1 to 3, 1 to 4), raw.map { it.seasonNumber to it.episodeNumber }.toSet())
        val prepared = provider.prepareNextUpProgressEntries(raw, "tt1")
        assertEquals(listOf(1 to 3), prepared.map { it.seasonNumber to it.episodeNumber })
        assertEquals("mdblist:tt1:1:4", prepared.single().trackingEpisodeKey)
    }

    @Test
    fun `a dropped TMDB season excludes every add-on season it maps into`() = runTest {
        // r5 #5: TMDB's one season of 48 is the add-on's two seasons; dropping it drops both.
        val h = MdbListSyncTestHarness(backgroundScope)
        h.seed(h.snapshot().copy(
            watched = listOf(mdbListTestEpisode(1, 35)),
            dropped = listOf(MdbListDroppedRecord(mdbListTestMovie().media.ids, season = 1)),
        ))
        h.repository.ensureLoaded()
        val mappings = splitAnimeMappings()
        val provider = MdbListTrackingProgressProvider(h.repository, MdbListScrobbleService(h.http.api, h.repository), mappings, h.http.store, h.activeProfile, {})
        assertEquals(setOf(1), provider.snapshot().entries.single().excludedNextUpSeasons)
        assertTrue(mappings.resolve("tt1", 1)!!.remaps)
        val remapped = provider.snapshot().entries.single()
        assertEquals(2 to 11, remapped.seasonNumber to remapped.episodeNumber)
        assertEquals(setOf(1, 2), remapped.excludedNextUpSeasons)
    }

    @Test
    fun `a raw seed that keeps its coordinates still gets its dropped seasons translated`() = runTest {
        // r6 #4: 48 vs 24+24, TMDB season 1 dropped; raw S1E1 stays S1E1 but must exclude add-on seasons 1 and 2.
        val h = MdbListSyncTestHarness(backgroundScope)
        h.seed(h.snapshot().copy(
            watched = listOf(mdbListTestEpisode(1, 1)),
            dropped = listOf(MdbListDroppedRecord(mdbListTestMovie().media.ids, season = 1)),
        ))
        h.repository.ensureLoaded()
        val mappings = splitAnimeMappings()
        val provider = MdbListTrackingProgressProvider(h.repository, MdbListScrobbleService(h.http.api, h.repository), mappings, h.http.store, h.activeProfile, {})
        val raw = provider.snapshot().entries.single()
        assertEquals(setOf(1), raw.excludedNextUpSeasons)
        val prepared = provider.prepareNextUpProgressEntries(listOf(raw), "tt1").single()
        assertEquals(1 to 1, prepared.seasonNumber to prepared.episodeNumber)
        assertEquals(setOf(1, 2), prepared.excludedNextUpSeasons)
        // Preparing an already remapped row gives the same answer.
        val remapped = provider.snapshot().entries.single()
        assertEquals(setOf(1, 2), remapped.excludedNextUpSeasons)
        assertEquals(remapped, provider.prepareNextUpProgressEntries(listOf(remapped), "tt1").single())
    }

    @Test
    fun `a partly covered add-on season keeps its other episodes for next-up`() = runTest {
        // r11: TMDB 24+24 vs add-on 30+18, TMDB season 2 dropped; watched TMDB S1E10 = add-on S1E10.
        val h = MdbListSyncTestHarness(backgroundScope)
        h.seed(h.snapshot().copy(
            watched = listOf(mdbListTestEpisode(1, 10)),
            dropped = listOf(MdbListDroppedRecord(mdbListTestMovie().media.ids, season = 2)),
        ))
        h.repository.ensureLoaded()
        val mappings = mdbListTestEpisodeMappings(
            MdbListTestAddonEpisodes(seasons = listOf(30, 18)),
            MdbListTestTmdbSeasons(seasons = listOf(24, 24), lookup = mapOf("tt1" to 1)),
        )
        val provider = MdbListTrackingProgressProvider(h.repository, MdbListScrobbleService(h.http.api, h.repository), mappings, h.http.store, h.activeProfile, {})
        assertTrue(mappings.resolve("tt1", 1)!!.remaps)
        val seed = provider.snapshot().entries.single()
        assertEquals(1 to 10, seed.seasonNumber to seed.episodeNumber)
        assertEquals(setOf(2), seed.excludedNextUpSeasons)
        assertEquals((25..30).map { "1:$it" }.toSet(), seed.excludedNextUpEpisodeKeys)
        assertEquals(seed, provider.prepareNextUpProgressEntries(listOf(seed), "tt1").single())
        // The resolver still offers S1E11 and leaves out S1E25 and season 2.
        val videos = (1..30).map { com.nuvio.app.features.details.MetaVideo(id = "tt1:1:$it", title = "E$it", season = 1, episode = it) } +
            (1..18).map { com.nuvio.app.features.details.MetaVideo(id = "tt1:2:$it", title = "E$it", season = 2, episode = it) }
        val offered = videos.filterNot { video ->
            video.season in seed.excludedNextUpSeasons ||
                com.nuvio.app.features.watchprogress.nextUpEpisodeKey(video.season!!, video.episode!!) in seed.excludedNextUpEpisodeKeys
        }.map { it.season!! to it.episode!! }
        assertTrue(1 to 11 in offered)
        assertFalse(1 to 25 in offered)
        assertFalse(2 to 1 in offered)
    }

    @Test
    fun `specials of a remapping show keep their rows and marks`() = runTest {
        // r6 #2 at the ports.
        val h = MdbListSyncTestHarness(backgroundScope)
        h.seed(h.snapshot().copy(watched = listOf(mdbListTestEpisode(0, 2), mdbListTestEpisode(1, 35))))
        h.repository.ensureLoaded()
        val mappings = splitAnimeMappings()
        val provider = MdbListTrackingProgressProvider(h.repository, MdbListScrobbleService(h.http.api, h.repository), mappings, h.http.store, h.activeProfile, {})
        val watched = MdbListWatchedSyncAdapter(h.repository, MdbListHistoryService(h.http.api, h.repository), mappings, h.http.store, h.activeProfile)
        assertTrue(mappings.resolve("tt1", 1)!!.remaps)
        assertEquals(setOf(0 to 2, 2 to 11), watched.pull(1, 100).map { it.season!! to it.episode!! }.toSet())
        assertTrue(watchedItemKey("series", "tt1", 0, 2) in watched.pullExtraWatchedKeys(1))
        // Specials never seed next-up (the projection's own rule), so only the remapped S2E11 seed is there.
        assertEquals(setOf(2 to 11), provider.snapshot().entries.map { it.seasonNumber to it.episodeNumber }.toSet())
        h.http.reply(body = """{"action":"pause","progress":50,"paused_at":"$MDBLIST_TEST_TIME"}""")
        MdbListTrackingWrites(h.repository, MdbListHistoryService(h.http.api, h.repository), MdbListScrobbleService(h.http.api, h.repository), mappings)
            .scrobble(1, TrackingScrobbleAction.PAUSE, TrackingScrobbleEvent(episodeReference(0, 2), 50.0))
        val show = mdbListResponseElement(h.http.engine.requests.single().body).objectValue().objectValue("show")!!
        assertEquals(0 to 2, show.text("season")?.toInt() to show.text("episode")?.toInt())
    }

    @Test
    fun `seeds sharing a timestamp keep their own TMDB episode across snapshots`() = runTest {
        // r2 #6: a bulk import marks TMDB S2E1 and S2E7 at the same time; add-on 30 + 18 vs TMDB 24 + 24
        // shows TMDB S2E7 as the add-on's S2E1, the same numbers the raw S2E1 row had.
        val h = MdbListSyncTestHarness(backgroundScope)
        h.seed(h.snapshot().copy(watched = listOf(mdbListTestEpisode(2, 1), mdbListTestEpisode(2, 7))))
        h.repository.ensureLoaded()
        val mappings = mdbListTestEpisodeMappings(
            MdbListTestAddonEpisodes(seasons = listOf(30, 18)),
            MdbListTestTmdbSeasons(seasons = listOf(24, 24), lookup = mapOf("tt1" to 1)),
        )
        val provider = MdbListTrackingProgressProvider(h.repository, MdbListScrobbleService(h.http.api, h.repository), mappings, h.http.store, h.activeProfile, {})
        val raw = provider.snapshot().entries
        assertTrue(mappings.resolve("tt1", 1)!!.remaps)
        val remapped = provider.snapshot().entries
        assertEquals(setOf(1 to 25, 2 to 1), remapped.map { it.seasonNumber to it.episodeNumber }.toSet())

        val rawFirst = raw.single { it.episodeNumber == 1 }
        val prepared = provider.prepareNextUpProgressEntries(listOf(rawFirst), "tt1").single()
        assertEquals(1 to 25, prepared.seasonNumber to prepared.episodeNumber)
        val remappedSeventh = remapped.single { it.trackingEpisodeKey == "mdblist:tt1:2:7" }
        assertEquals(2 to 1, remappedSeventh.seasonNumber to remappedSeventh.episodeNumber)
        assertEquals(listOf(remappedSeventh), provider.prepareNextUpProgressEntries(listOf(remappedSeventh), "tt1"))
    }

    private fun episodeReference(season: Int, episode: Int) = buildTrackingMediaReference(
        contentType = "series", parentMetaId = "tt1", videoId = "tt1:$season:$episode",
        seasonNumber = season, episodeNumber = episode,
    )
}
