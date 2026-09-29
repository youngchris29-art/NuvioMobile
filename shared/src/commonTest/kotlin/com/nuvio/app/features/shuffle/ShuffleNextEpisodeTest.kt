package com.nuvio.app.features.shuffle

import com.nuvio.app.features.details.MetaVideo
import com.nuvio.app.features.watched.watchedItemKey
import com.nuvio.app.features.watchprogress.WatchProgressEntry
import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertNotEquals
import kotlin.test.assertNotNull
import kotlin.test.assertNull
import kotlin.test.assertTrue

// Fork-local tests for `ShuffleNextEpisode` (tvOS next-episode choice while shuffle is on).
class ShuffleNextEpisodeTest {
    private val videos = (1..5).map { MetaVideo("show:1:$it", "Episode $it", season = 1, episode = it) }

    private fun next(
        current: Int? = 1,
        includeWatched: Boolean = false,
        watchedKeys: Set<String> = emptySet(),
        entries: List<WatchProgressEntry> = emptyList(),
        shuffle: EpisodeShuffle = EpisodeShuffle(),
        currentSeason: Int? = 1,
    ) = ShuffleNextEpisode.selectNext(
        profileId = 1, contentId = "show", contentType = "series", videos = videos,
        includeWatched = includeWatched, watchedKeys = watchedKeys, entries = entries,
        currentSeason = currentSeason, currentEpisode = current, shuffle = shuffle,
    )

    @Test
    fun shuffleOffForShowReportsDisabledAndReturnsNull() {
        val offProfile = EpisodeShuffleProfile(available = true, shows = mapOf("show" to EpisodeShuffleSettings(enabled = false)))
        assertTrue(!offProfile.settings("show", "series").enabled)
        assertTrue(!EpisodeShuffleProfile(available = false, shows = mapOf("show" to EpisodeShuffleSettings(enabled = true)))
            .settings("show", "series").enabled)
        assertNull(ShuffleNextEpisode.nextPlaybackEpisode("not-configured-show", "series", videos, 1, 1))
        assertTrue(!ShuffleNextEpisode.isEnabled("not-configured-show", "series"))
    }

    @Test
    fun unwatchedEpisodesYieldPickThatIsNeverTheEpisodeJustPlayed() {
        val shuffle = EpisodeShuffle()
        var current = 1
        repeat(20) {
            val pick = next(current = current, shuffle = shuffle)
            assertNotNull(pick)
            assertNotEquals(current, pick.episode)
            current = pick.episode!!
        }
    }

    @Test
    fun caughtUpWithIncludeWatchedOffReturnsNull() {
        val watched = (1..5).map { watchedItemKey("series", "show", 1, it) }.toSet()
        assertNull(next(current = 5, watchedKeys = watched))
        val completed = (1..5).map { completedProgress(it) }
        assertNull(next(current = 5, entries = completed))
    }

    @Test
    fun includeWatchedPicksAmongWatchedEpisodesExcludingCurrent() {
        val watched = (1..5).map { watchedItemKey("series", "show", 1, it) }.toSet()
        val shuffle = EpisodeShuffle()
        repeat(10) {
            val pick = next(current = 3, includeWatched = true, watchedKeys = watched, shuffle = shuffle)
            assertNotNull(pick)
            assertNotEquals(3, pick.episode)
            assertTrue(pick.episode in 1..5)
        }
    }

    @Test
    fun unknownCurrentEpisodeReturnsNull() {
        assertNull(next(current = null))
        assertNull(next(currentSeason = null))
        assertEquals(null, next(current = null, includeWatched = true))
    }

    private fun completedProgress(number: Int) = WatchProgressEntry(
        contentType = "series", parentMetaId = "show", parentMetaType = "series",
        title = "Show", videoId = "show:1:$number", seasonNumber = 1, episodeNumber = number,
        lastPositionMs = 100L, durationMs = 100L, lastUpdatedEpochMs = 0,
        progressPercent = 100f,
    )
}
