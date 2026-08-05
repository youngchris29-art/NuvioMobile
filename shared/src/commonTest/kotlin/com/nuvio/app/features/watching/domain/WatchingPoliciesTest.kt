package com.nuvio.app.features.watching.domain

import kotlin.test.Test
import kotlin.test.assertTrue

// Ported from upstream 257e8060 (fixes #1684): a dated-but-unavailable episode must
// surface on its release day regardless of showUnairedNextUp, since it's no longer
// "unaired" once daysUntilRelease <= 0.
class WatchingPoliciesTest {
    @Test
    fun shouldSurfaceNextEpisode_keeps_dated_unavailable_episode_visible_on_release_day() {
        assertTrue(
            shouldSurfaceNextEpisode(
                watchedSeasonNumber = 1,
                candidateSeasonNumber = 1,
                todayIsoDate = "2026-07-12",
                releasedDate = "2026-07-12T20:00:00",
                showUnairedNextUp = true,
                available = false,
            ),
        )
    }
}
