package com.nuvio.app.features.watchprogress

import com.nuvio.app.features.tracking.WatchProgressSource
import com.nuvio.app.features.upcoming.collectUpcomingShowRefs
import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertTrue

/**
 * BUG-76: the Upcoming row seeds from progress ∪ library and must not change when the user flips
 * the watch-progress SOURCE — that row is an air-date calendar keyed off shows the user follows,
 * not off whichever provider currently owns Continue Watching.
 */
class FollowedShowEntriesTest {
    private fun episode(showId: String, lastUpdatedEpochMs: Long): WatchProgressEntry =
        WatchProgressEntry(
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
    fun union_keeps_local_entries_when_the_provider_has_no_history() {
        val local = listOf(episode("tt-local", 1_000L))

        val followed = unionFollowedShowEntries(nuvioEntries = local, providerEntries = emptyList())

        assertEquals(local, followed)
    }

    @Test
    fun union_prefers_the_provider_row_for_a_show_both_know() {
        val shared = "tt-shared"
        val local = listOf(episode(shared, 1_000L))
        val provider = listOf(episode(shared, 9_000L))

        val followed = unionFollowedShowEntries(nuvioEntries = local, providerEntries = provider)

        assertEquals(1, followed.size)
        assertEquals(9_000L, followed.single().lastUpdatedEpochMs)
    }

    @Test
    fun union_carries_local_only_shows_alongside_provider_rows() {
        val local = listOf(episode("tt-local", 1_000L))
        val provider = listOf(episode("tt-provider", 2_000L))

        val followed = unionFollowedShowEntries(nuvioEntries = local, providerEntries = provider)

        assertEquals(
            setOf("tt-local", "tt-provider"),
            followed.mapTo(mutableSetOf()) { it.parentMetaId },
        )
    }

    /**
     * The regression itself, stated as the contrast that caused it: the SOURCE projection empties
     * when a provider owns the source and has no history (correct for Continue Watching), while
     * the followed set — and therefore the Upcoming seed — must not.
     */
    @Test
    fun a_source_flip_to_an_empty_provider_empties_continue_watching_but_not_the_upcoming_seed() {
        val local = listOf(episode("tt-followed", 1_000L))
        val emptySimkl = emptyList<WatchProgressEntry>()

        val continueWatchingEntries = projectWatchProgressSourceEntries(
            source = WatchProgressSource.SIMKL,
            nuvioEntries = local,
            providerEntries = emptySimkl,
        )
        val followed = unionFollowedShowEntries(nuvioEntries = local, providerEntries = emptySimkl)

        assertTrue(continueWatchingEntries.isEmpty(), "the source projection is expected to empty")
        assertEquals(local, followed, "the followed set must survive the flip")

        // And the seed the Upcoming sweep actually builds survives with it.
        val refsBefore = collectUpcomingShowRefs(
            progressEntries = local,
            libraryItems = emptyList(),
        )
        val refsAfter = collectUpcomingShowRefs(
            progressEntries = followed,
            libraryItems = emptyList(),
        )
        assertEquals(refsBefore.map { it.key }, refsAfter.map { it.key })
        assertTrue(refsAfter.isNotEmpty(), "the Upcoming seed must not go empty on a source flip")
    }
}
