package com.nuvio.app.features.shuffle

import com.nuvio.app.features.details.MetaDetails
import com.nuvio.app.features.details.MetaVideo
import com.nuvio.app.features.watched.watchedItemKey
import com.nuvio.app.features.watchprogress.WatchProgressEntry
import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertFalse
import kotlin.test.assertNull
import kotlin.test.assertTrue

// Fork: only the `shufflePrimaryAction` / profile tests from upstream's ShuffleProjectionTest;
// the `home*` tests exercise `applyHomeShuffle` (Home Up Next), which tvOS does not port.
class ShuffleProjectionTest {
    private val videos = (1..4).map { MetaVideo("show:1:$it", "Episode $it", season = 1, episode = it) }
    private val meta = MetaDetails("show", "series", "Show", videos = videos)
    private val settings = EpisodeShuffleSettings(enabled = true)
    private val profile = EpisodeShuffleProfile(available = true, shows = mapOf("show" to settings))

    @Test
    fun latestPartialEpisodeTakesPrecedenceOverShuffleAndFurthestProgress() {
        val action = meta.shufflePrimaryAction(1, settings,
            listOf(progress(4, 20f, 1), progress(1, 30f, 2)), emptySet(), 0, EpisodeShuffle())
        assertEquals(1, action?.episodeNumber)
        assertEquals(30L, action?.resumePositionMs)
    }

    @Test
    fun completedProgressAndWatchedMarkersLeaveOnlyEligibleEpisode() {
        val action = meta.shufflePrimaryAction(1, settings,
            listOf(progress(1, 95f), progress(2, 100f)),
            setOf(watchedItemKey("series", "show", 1, 3)), 0, EpisodeShuffle())
        assertEquals(4, action?.episodeNumber)
        assertNull(action?.resumePositionMs)
    }

    @Test
    fun caughtUpUnwatchedHasNoSequentialFallback() {
        assertNull(meta.shufflePrimaryAction(1, settings,
            (1..4).map { progress(it, 100f) }, emptySet(), 0, EpisodeShuffle()))
    }

    @Test
    fun globalTogglePausesSavedSettingsAndNonSeriesNeverShuffle() {
        assertFalse(profile.copy(available = false).settings("show", "series").enabled)
        assertTrue(profile.settings("show", "tv").enabled)
        assertFalse(profile.settings("show", "movie").enabled)
        assertTrue(profile.copy(available = false).shows.getValue("show").enabled)
    }

    private fun progress(number: Int, percent: Float, updated: Long = 0) = WatchProgressEntry(
        contentType = "series", parentMetaId = "show", parentMetaType = "series",
        title = "Show", videoId = "show:1:$number", seasonNumber = 1, episodeNumber = number,
        lastPositionMs = percent.toLong(), durationMs = 100L, lastUpdatedEpochMs = updated,
        progressPercent = percent,
    )
}
