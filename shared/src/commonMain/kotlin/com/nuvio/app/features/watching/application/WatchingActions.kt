package com.nuvio.app.features.watching.application

import co.touchlab.kermit.Logger
import com.nuvio.app.core.coroutines.uncaughtCoroutineLogger
import com.nuvio.app.features.cloud.CloudLibraryContentType
import com.nuvio.app.features.details.MetaDetails
import com.nuvio.app.features.details.MetaDetailsRepository
import com.nuvio.app.features.details.MetaVideo
import com.nuvio.app.features.home.MetaPreview
import com.nuvio.app.features.watched.WatchedItem
import com.nuvio.app.features.watched.WatchedRepository
import com.nuvio.app.features.watched.WatchedScopeToken
import com.nuvio.app.features.watched.episodePlaybackId
import com.nuvio.app.features.watched.releasedMainSeasonEpisodes
import com.nuvio.app.features.watched.toEpisodeWatchedItem
import com.nuvio.app.features.watched.toSeriesWatchedItem
import com.nuvio.app.features.watched.toWatchedItem
import com.nuvio.app.features.watchprogress.CurrentDateProvider
import com.nuvio.app.features.watchprogress.WatchProgressEntry
import com.nuvio.app.features.watchprogress.WatchProgressRepository
import com.nuvio.app.features.watchprogress.isContinueWatchingNextUp
import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.launch

object WatchingActions {
    private val actionScope = CoroutineScope(SupervisorJob() + Dispatchers.Default + uncaughtCoroutineLogger("WatchingActions"))
    private val log = Logger.withTag("WatchingActions")

    /**
     * Fork (tvOS): fire-and-forget [togglePosterWatched] for Swift, launched on [actionScope].
     * Failures are logged, never thrown.
     */
    fun togglePosterWatchedAsync(preview: MetaPreview) {
        actionScope.launch {
            try {
                togglePosterWatched(preview)
            } catch (error: CancellationException) {
                throw error
            } catch (error: Exception) {
                log.e(error) { "Toggling watched state for ${preview.type}:${preview.id} failed" }
            }
        }
    }

    suspend fun togglePosterWatched(preview: MetaPreview) {
        if (!preview.type.isSeriesLikeType()) {
            WatchedRepository.toggleWatched(preview.toWatchedItem(markedAtEpochMs = 0L))
            return
        }

        val isCurrentlyWatched = WatchedRepository.isWatched(
            id = preview.id,
            type = preview.type,
        ) || WatchedRepository.isFullyWatchedSeries(
            id = preview.id,
            type = preview.type,
        )
        val meta = MetaDetailsRepository.fetch(type = preview.type, id = preview.id)
        if (meta == null) {
            if (isCurrentlyWatched) {
                WatchedRepository.unmarkWatched(preview.toWatchedItem(markedAtEpochMs = 0L))
                WatchedRepository.updateFullyWatchedSeries(
                    id = preview.id,
                    type = preview.type,
                    isFullyWatched = false,
                )
            }
            return
        }

        val todayIsoDate = CurrentDateProvider.todayIsoDate()
        val releasedMainEpisodes = meta.releasedMainSeasonEpisodes(todayIsoDate)
        if (releasedMainEpisodes.isEmpty()) {
            if (isCurrentlyWatched) {
                WatchedRepository.unmarkWatched(meta.toSeriesWatchedItem())
                WatchedRepository.updateFullyWatchedSeries(
                    id = meta.id,
                    type = meta.type,
                    isFullyWatched = false,
                )
            }
            return
        }
        val seriesItems = buildList {
            add(meta.toSeriesWatchedItem())
            addAll(releasedMainEpisodes.map(meta::toEpisodeWatchedItem))
        }

        if (isCurrentlyWatched) {
            WatchedRepository.unmarkWatched(seriesItems)
            WatchProgressRepository.clearProgress(
                videoIds = releasedMainEpisodes.map(meta::episodePlaybackId),
                parentMetaId = meta.id,
            )
            WatchedRepository.updateFullyWatchedSeries(
                id = meta.id,
                type = meta.type,
                isFullyWatched = false,
            )
        } else {
            WatchedRepository.markWatched(seriesItems)
            WatchedRepository.updateFullyWatchedSeries(
                id = meta.id,
                type = meta.type,
                isFullyWatched = true,
            )
            WatchProgressRepository.clearProgress(
                videoIds = releasedMainEpisodes.map(meta::episodePlaybackId),
                parentMetaId = meta.id,
            )
        }
    }

    fun toggleEpisodeWatched(
        meta: MetaDetails,
        episode: MetaVideo,
        isCurrentlyWatched: Boolean,
    ) {
        val watchedItem = meta.toEpisodeWatchedItem(episode)
        if (isCurrentlyWatched) {
            WatchedRepository.unmarkWatched(watchedItem)
            WatchProgressRepository.clearProgress(
                videoId = meta.episodePlaybackId(episode),
                parentMetaId = meta.id,
            )
        } else {
            WatchedRepository.markWatched(watchedItem)
            WatchProgressRepository.clearProgress(
                videoId = meta.episodePlaybackId(episode),
                parentMetaId = meta.id,
            )
        }
        reconcileSeriesWatchedState(meta)
    }

    fun togglePreviousEpisodesWatched(
        meta: MetaDetails,
        episodes: Collection<MetaVideo>,
        areCurrentlyWatched: Boolean,
    ) {
        toggleEpisodesWatched(
            meta = meta,
            episodes = episodes,
            areCurrentlyWatched = areCurrentlyWatched,
        )
    }

    fun toggleSeasonWatched(
        meta: MetaDetails,
        episodes: Collection<MetaVideo>,
        areCurrentlyWatched: Boolean,
    ) {
        toggleEpisodesWatched(
            meta = meta,
            episodes = episodes,
            areCurrentlyWatched = areCurrentlyWatched,
        )
    }

    fun reconcileSeriesWatchedState(
        meta: MetaDetails,
        todayIsoDate: String = CurrentDateProvider.todayIsoDate(),
    ) {
        if (!meta.type.isSeriesLikeType()) return

        WatchedRepository.reconcileSeriesWatchedState(
            meta = meta,
            todayIsoDate = todayIsoDate,
            isEpisodeCompleted = { episode ->
                WatchProgressRepository.progressForVideo(
                    videoId = meta.episodePlaybackId(episode),
                    parentMetaId = meta.id,
                    seasonNumber = episode.season,
                    episodeNumber = episode.episode,
                )?.isCompleted == true
            },
        )
    }

    fun onProgressEntryUpdated(entry: WatchProgressEntry, syncRemote: Boolean = true) {
        if (!entry.isCompleted) return

        // Seeds the stamp from the entry; WatchedRepository restamps the mark time on write (review r2 #6).
        val watchedItem = watchedItemFromProgress(entry, markedAtEpochMs = entry.lastUpdatedEpochMs)
        WatchedRepository.markWatchedFromPlaybackCompletion(watchedItem, syncRemote = syncRemote)

        if (!syncRemote || !entry.isEpisode) return
        reconcileSeriesAfterMetaFetch(entry)
    }

    /**
     * Review r1 (mark as watched): the series reconcile that follows an episode mark fetches the
     * meta on [actionScope]; the profile or the tracker source can change while that fetch is
     * pending, and the reconcile must then be dropped rather than read and write the other
     * profile's (or source's) watched state. Shared by playback completion and the manual mark.
     */
    private fun reconcileSeriesAfterMetaFetch(entry: WatchProgressEntry) {
        val startedFor = WatchedRepository.scopeToken()
        actionScope.launch {
            val meta = try {
                MetaDetailsRepository.fetch(type = entry.parentMetaType, id = entry.parentMetaId)
            } catch (error: CancellationException) {
                throw error
            } catch (error: Exception) {
                log.e(error) { "Fetching meta to reconcile ${entry.parentMetaType}:${entry.parentMetaId} failed" }
                null
            } ?: return@launch
            if (!reconcileScopeStillCurrent(startedFor, WatchedRepository.scopeToken())) {
                log.w { "Series reconcile for ${entry.parentMetaId} dropped: profile or watched source changed while the meta loaded" }
                return@launch
            }
            reconcileSeriesWatchedState(meta = meta)
        }
    }

    /**
     * Continue Watching > Mark as Watched (upstream NuvioMobile 7c57f775e, re-expressed on
     * [WatchProgressEntry]). Marks the entry watched, clears its progress unless it is an Up Next
     * card (no progress row), and for a series episode reconciles series watched state the way
     * playback completion does. Safe to call from Swift; the meta fetch runs on [actionScope].
     */
    fun markProgressEntryWatched(entry: WatchProgressEntry, nowEpochMs: Long) {
        val plan = continueWatchingMarkWatchedPlan(entry, nowEpochMs)
        WatchedRepository.markWatched(plan.item)
        if (plan.clearProgress) {
            WatchProgressRepository.clearProgress(videoId = entry.videoId, parentMetaId = entry.parentMetaId)
        }
        if (!plan.reconcileSeries) return
        reconcileSeriesAfterMetaFetch(entry)
    }

    private fun toggleEpisodesWatched(
        meta: MetaDetails,
        episodes: Collection<MetaVideo>,
        areCurrentlyWatched: Boolean,
    ) {
        if (episodes.isEmpty()) return
        val watchedItems = episodes.map(meta::toEpisodeWatchedItem)
        if (areCurrentlyWatched) {
            WatchedRepository.unmarkWatched(watchedItems)
            WatchProgressRepository.clearProgress(
                videoIds = episodes.map(meta::episodePlaybackId),
                parentMetaId = meta.id,
            )
        } else {
            WatchedRepository.markWatched(watchedItems)
            WatchProgressRepository.clearProgress(
                videoIds = episodes.map(meta::episodePlaybackId),
                parentMetaId = meta.id,
            )
        }
        reconcileSeriesWatchedState(meta)
    }
}

/**
 * The watched-history item a progress [entry] stands for (movie, or one episode when the entry
 * carries season/episode), stamped [markedAtEpochMs]. The caller chooses the stamp: playback
 * completion passes the entry's own `lastUpdatedEpochMs`; a manual "Mark Watched" from the
 * Continue Watching menu passes the current time. There is deliberately no default.
 */
fun watchedItemFromProgress(entry: WatchProgressEntry, markedAtEpochMs: Long): WatchedItem =
    WatchedItem(
        id = entry.parentMetaId,
        type = entry.parentMetaType,
        name = entry.title,
        poster = entry.poster,
        season = entry.seasonNumber,
        episode = entry.episodeNumber,
        videoId = entry.videoId,
        markedAtEpochMs = markedAtEpochMs,
    )

/** What a manual Continue Watching mark does; pure so it can be unit-tested without repositories. */
data class ContinueWatchingMarkWatchedPlan(
    val item: WatchedItem,
    val clearProgress: Boolean,
    val reconcileSeries: Boolean,
)

fun continueWatchingMarkWatchedPlan(entry: WatchProgressEntry, nowEpochMs: Long): ContinueWatchingMarkWatchedPlan =
    ContinueWatchingMarkWatchedPlan(
        item = watchedItemFromProgress(entry, markedAtEpochMs = nowEpochMs),
        // An Up Next card has no progress row to clear.
        clearProgress = !entry.isContinueWatchingNextUp,
        reconcileSeries = entry.isEpisode && entry.parentMetaType.isSeriesLikeType(),
    )

/**
 * Whether the Continue Watching menu offers "Mark as Watched" for [entry]: not a cloud-library
 * item, and not an Up Next card whose episode has not aired. [releaseAtEpochMs] is that episode's
 * release instant when known. Under today's `UnairedNextUpPolicy.Drop` no unaired card is ever
 * built, so callers can omit it; it matters once the `LabelAirDate` policy is flipped on.
 */
fun canMarkWatched(entry: WatchProgressEntry, nowEpochMs: Long, releaseAtEpochMs: Long? = null): Boolean {
    if (entry.contentType.equals(CloudLibraryContentType, ignoreCase = true) ||
        entry.parentMetaType.equals(CloudLibraryContentType, ignoreCase = true)
    ) return false
    if (entry.isContinueWatchingNextUp && releaseAtEpochMs != null && releaseAtEpochMs > nowEpochMs) return false
    return true
}

private fun String.isSeriesLikeType(): Boolean =
    trim().lowercase() in setOf("series", "show", "tv", "tvshow")

/** Review r1: a deferred watched write applies only to the profile and source it was started for. */
internal fun reconcileScopeStillCurrent(startedFor: WatchedScopeToken, now: WatchedScopeToken): Boolean =
    startedFor == now
