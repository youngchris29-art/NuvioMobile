package com.nuvio.app.features.mdblist

import com.nuvio.app.features.tracking.WatchProgressSource
import com.nuvio.app.features.watchprogress.WatchProgressEntry
import com.nuvio.app.features.watchprogress.projectWatchProgressSourceEntries
import kotlinx.coroutines.test.runTest
import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertFalse
import kotlin.test.assertTrue

/**
 * Fork: MDBList only resolves imdb/tmdb/tvdb/trakt/mdblist ids, so local anime rows keyed by
 * `kitsu:`/`mal:`/`anilist:` must stay in continue watching while MDBList is the source.
 */
class MdbListContentIdRepresentationTest {
    private fun provider(h: MdbListSyncTestHarness) = MdbListTrackingProgressProvider(
        h.repository, MdbListScrobbleService(h.http.api, h.repository), h.http.store, h.activeProfile, {}
    )

    private fun episode(showId: String, lastUpdatedEpochMs: Long) = WatchProgressEntry(
        contentType = "series",
        parentMetaId = showId,
        parentMetaType = "series",
        videoId = "$showId:1:1",
        title = showId,
        seasonNumber = 1,
        episodeNumber = 1,
        lastPositionMs = 10_000L,
        durationMs = 100_000L,
        lastUpdatedEpochMs = lastUpdatedEpochMs,
    )

    @Test
    fun `only ids MDBList can resolve are representable`() = runTest {
        val provider = provider(MdbListSyncTestHarness(backgroundScope))
        for (id in listOf("tt1", "tt1:1:2", "imdb:tt1", "tmdb:5", "tvdb:7", "trakt:9", "mdblist:abc", "12")) {
            assertTrue(provider.canRepresentContentId(id), id)
        }
        for (id in listOf("kitsu:42", "mal:42", "anilist:42", "anidb:42", "simkl:42", "tmdb:0", "custom-addon:x", "")) {
            assertFalse(provider.canRepresentContentId(id), id)
        }
    }

    @Test
    fun `a local kitsu row survives continue watching with MDBList as the source`() = runTest {
        val provider = provider(MdbListSyncTestHarness(backgroundScope))
        val kitsu = episode("kitsu:42", 3_000L)
        val localImdb = episode("tt9", 2_000L)
        val remote = episode("tt1", 1_000L)

        val projected = projectWatchProgressSourceEntries(
            source = WatchProgressSource.MDBLIST,
            nuvioEntries = listOf(kitsu, localImdb),
            providerEntries = listOf(remote),
            canProviderRepresent = provider::canRepresentContentId,
        )

        assertEquals(listOf("tt1", "kitsu:42"), projected.map { it.parentMetaId })
    }
}
