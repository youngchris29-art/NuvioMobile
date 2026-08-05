package com.nuvio.app.features.watching.domain

import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertNotNull

// Ported from upstream 257e8060 (fixes #1684): nextReleasedEpisodeAfter must keep
// surfacing a dated-but-unavailable next episode on its release day, matching the
// shouldSurfaceNextEpisode fix in WatchingPolicies.kt.
class SeriesContinuityTest {
    private val show = WatchingContentRef(type = "series", id = "show")

    @Test
    fun nextReleasedEpisodeAfter_keeps_dated_unavailable_episode_on_release_day() {
        val episodes = listOf(
            WatchingReleasedEpisode(videoId = "s1e1", seasonNumber = 1, episodeNumber = 1, title = "Episode 1", releasedDate = "2026-07-01"),
            WatchingReleasedEpisode(videoId = "s1e2", seasonNumber = 1, episodeNumber = 2, title = "Episode 2", releasedDate = "2026-07-12T20:00:00", available = false),
        )

        val nextEpisode = nextReleasedEpisodeAfter(
            content = show,
            episodes = episodes,
            seasonNumber = 1,
            episodeNumber = 1,
            todayIsoDate = "2026-07-12",
            showUnairedNextUp = true,
        )

        assertNotNull(nextEpisode)
        assertEquals("s1e2", nextEpisode.videoId)
    }
}
