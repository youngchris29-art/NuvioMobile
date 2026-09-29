package com.nuvio.app.features.shuffle

import com.nuvio.app.features.details.MetaVideo
import com.nuvio.app.features.profiles.ProfileRepository
import com.nuvio.app.features.watched.WatchedRepository
import com.nuvio.app.features.watchprogress.WatchProgressEntry
import com.nuvio.app.features.watchprogress.WatchProgressRepository

/**
 * Fork-local, Swift-facing port of the shuffle branch upstream keeps inside its Compose-only
 * `PlayerScreenRuntimeEffects.kt` (next-episode selection while shuffle is on).
 *
 * Upstream behaviour preserved: when shuffle is enabled for the show there is NO sequential
 * fallback. If nothing is left to pick (caught up with "include watched" off) the answer is
 * null and the caller must not fall back to next-in-order. Callers distinguish "off" from
 * "on but nothing to pick" with [isEnabled].
 *
 * Both functions are synchronous (they read repository state already in memory), so no
 * `@Throws` twins are needed.
 */
object ShuffleNextEpisode {

    /** True when shuffle is available (settings toggle) and enabled for this series. */
    fun isEnabled(contentId: String, contentType: String): Boolean {
        EpisodeShuffleRepository.ensureLoaded()
        return EpisodeShuffleRepository.uiState.value.settings(contentId, contentType).enabled
    }

    /**
     * Shuffled next episode after [currentSeason]/[currentEpisode], or null when shuffle is off
     * for the show, the current episode is unknown, OR there is nothing left to pick. Never returns the episode just played.
     */
    fun nextPlaybackEpisode(
        contentId: String,
        contentType: String,
        videos: List<MetaVideo>,
        currentSeason: Int?,
        currentEpisode: Int?,
    ): MetaVideo? {
        EpisodeShuffleRepository.ensureLoaded()
        val profileId = ProfileRepository.activeProfileId
        val settings = EpisodeShuffleRepository.uiState.value.settings(contentId, contentType)
        if (!settings.enabled) {
            EpisodeShuffleRepository.shuffle.clearSelection(profileId, contentId, ShuffleSurface.PLAYBACK)
            return null
        }
        WatchedRepository.ensureLoaded()
        WatchProgressRepository.ensureLoaded()
        return selectNext(
            profileId = profileId,
            contentId = contentId,
            contentType = contentType,
            videos = videos,
            includeWatched = settings.includeWatched,
            watchedKeys = WatchedRepository.uiState.value.watchedKeys,
            entries = WatchProgressRepository.uiState.value.entries,
            currentSeason = currentSeason,
            currentEpisode = currentEpisode,
            shuffle = EpisodeShuffleRepository.shuffle,
        )
    }

    internal fun selectNext(
        profileId: Int,
        contentId: String,
        contentType: String,
        videos: List<MetaVideo>,
        includeWatched: Boolean,
        watchedKeys: Set<String>,
        entries: Collection<WatchProgressEntry>,
        currentSeason: Int?,
        currentEpisode: Int?,
        shuffle: EpisodeShuffle,
    ): MetaVideo? {
        // Upstream bails out when the current season/episode is unknown.
        val current = (currentSeason ?: return null) to (currentEpisode ?: return null)
        return shuffle.select(
            profileId, contentId, videos, includeWatched,
            watchedShuffleEpisodes(contentId, contentType, videos, watchedKeys),
            shuffleEpisodeProgress(contentId, entries),
            ShuffleSurface.PLAYBACK, current = current,
        )
    }
}
