package com.nuvio.app.features.shuffle

import com.nuvio.app.features.details.MetaDetails
import com.nuvio.app.features.details.MetaVideo
import com.nuvio.app.features.details.SeriesPrimaryAction
import com.nuvio.app.features.details.playLabel
import com.nuvio.app.features.details.resumeLabel
import com.nuvio.app.features.simkl.SimklAnimeWatchedFallback
import com.nuvio.app.features.watched.watchedItemKeys
import com.nuvio.app.features.watchprogress.WatchProgressEntry

/**
 * Fork: upstream calls `WatchingState.isEpisodeWatched` (composeApp's `watching/application`),
 * which has no counterpart in `shared/`. This reproduces its exact semantics from the pieces
 * that do exist here: any alias key from [watchedItemKeys] present in [watchedKeys], else the
 * Simkl franchise-parent anime fallback keyed by the video id + episode number.
 */
private fun isShuffleEpisodeWatched(
    watchedKeys: Set<String>,
    metaType: String,
    metaId: String,
    episode: MetaVideo,
): Boolean {
    val keys = watchedItemKeys(
        type = metaType,
        id = metaId,
        season = episode.season,
        episode = episode.episode,
    )
    if (keys.any(watchedKeys::contains)) return true
    val episodeNumber = episode.episode ?: return false
    return SimklAnimeWatchedFallback.isWatched(episode.id, episodeNumber)
}

fun watchedShuffleEpisodes(
    contentId: String,
    contentType: String,
    videos: List<MetaVideo>,
    watchedKeys: Set<String>,
): Set<Pair<Int, Int>> = videos.mapNotNull { video ->
    val season = video.season ?: return@mapNotNull null
    val episode = video.episode ?: return@mapNotNull null
    (season to episode).takeIf {
        isShuffleEpisodeWatched(watchedKeys, contentType, contentId, video)
    }
}.toSet()

fun shuffleEpisodeProgress(
    contentId: String,
    entries: Collection<WatchProgressEntry>,
): Map<Pair<Int, Int>, WatchProgressEntry> = entries
    .filter { it.parentMetaId == contentId && it.seasonNumber != null && it.episodeNumber != null }
    .groupBy { it.seasonNumber!! to it.episodeNumber!! }
    .mapValues { (_, progress) -> progress.maxBy { it.lastUpdatedEpochMs } }

fun MetaDetails.shufflePrimaryAction(
    profileId: Int,
    settings: EpisodeShuffleSettings,
    entries: List<WatchProgressEntry>,
    watchedKeys: Set<String>,
    visit: Long,
    shuffle: EpisodeShuffle = EpisodeShuffleRepository.shuffle,
    surface: ShuffleSurface = ShuffleSurface.DETAIL,
): SeriesPrimaryAction? {
    val resume = entries.filter {
        it.parentMetaId == id && it.seasonNumber != null && it.episodeNumber != null &&
            it.videoId.isNotBlank() && !it.isEffectivelyCompleted &&
            (it.lastPositionMs > 0 || it.progressFraction > 0)
    }.maxByOrNull { it.lastUpdatedEpochMs }
    if (resume != null) return SeriesPrimaryAction(
        label = resume.resumeLabel(), videoId = resume.videoId,
        seasonNumber = resume.seasonNumber, episodeNumber = resume.episodeNumber,
        episodeTitle = resume.episodeTitle, episodeThumbnail = resume.episodeThumbnail,
        resumePositionMs = resume.lastPositionMs,
    )
    val selected = shuffle.select(
        profileId, id, videos, settings.includeWatched,
        watchedShuffleEpisodes(id, type, videos, watchedKeys), shuffleEpisodeProgress(id, entries),
        surface, visit = visit,
    ) ?: return null
    return SeriesPrimaryAction(
        label = selected.playLabel(), videoId = selected.id,
        seasonNumber = selected.season, episodeNumber = selected.episode,
        episodeTitle = selected.title, episodeThumbnail = selected.thumbnail,
        resumePositionMs = null,
    )
}
