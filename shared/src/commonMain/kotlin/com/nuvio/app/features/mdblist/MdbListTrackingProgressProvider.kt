package com.nuvio.app.features.mdblist

import com.nuvio.app.features.tracking.TrackingProgressProvider
import com.nuvio.app.features.tracking.TrackingProgressSnapshot
import com.nuvio.app.features.tracking.TrackingProviderId
import com.nuvio.app.features.tracking.TrackingRefreshIntent
import com.nuvio.app.features.tracking.parseTrackingExternalIds
import com.nuvio.app.features.watchprogress.WatchProgressEntry
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.combine

class MdbListTrackingProgressProvider internal constructor(
    private val sync: MdbListSyncRepository,
    private val scrobble: MdbListScrobbleService,
    private val episodeMappings: MdbListEpisodeMappingService,
    auth: MdbListAuthStore,
    activeProfile: StateFlow<Int>,
    private val ensureAccountLoaded: () -> Unit,
) : TrackingProgressProvider {
    override val providerId = TrackingProviderId.MDBLIST
    override val changes = combine(sync.state, auth.state, activeProfile, episodeMappings.changes) { _, _, _, _ -> Unit }
    override val ownsCompletedHistoryProjection = true
    override fun showIdSiblings() = sync.currentProjection().showIdSiblings

    override fun ensureLoaded() = ensureAccountLoaded()

    override suspend fun refresh(force: Boolean, sourceChanged: Boolean) {
        ensureAccountLoaded()
        sync.refresh(if (force) TrackingRefreshIntent.USER_INITIATED else TrackingRefreshIntent.AUTOMATIC)
    }

    override fun snapshot(): TrackingProgressSnapshot {
        val projection = sync.currentProjection()
        val state = sync.state.value.takeIf { it.scope == runCatching { sync.currentScope() }.getOrNull() }
        return TrackingProgressSnapshot(
            entries = projection.entriesInAddonNumbering { contentId -> cachedMappingOrResolveLater(projection, contentId) },
            hiddenContentIds = projection.hiddenContentIds,
            hasLoadedRemoteProgress = state?.hasLoaded == true,
            errorMessage = state?.error?.localizedMdbListMessage(),
        )
    }

    override suspend fun removeProgress(entries: Collection<WatchProgressEntry>) {
        val scope = sync.currentScope()
        entries.distinctBy { Triple(it.parentMetaId, it.seasonNumber, it.episodeNumber) }.forEach { entry ->
            // MDBList holds TMDB's numbering: the row's tracking key names the episode whichever
            // numbering the row shows; a row without one (built elsewhere) is taken for the add-on's.
            val tmdb = parseMdbListEpisodeKey(entry.trackingEpisodeKey) ?: if (entry.seasonNumber != null && entry.episodeNumber != null) {
                episodeMapping(entry.parentMetaId)?.toTmdb(entry.seasonNumber, entry.episodeNumber, entry.videoId)
                    ?.let { it.season to it.episode }
            } else null
            scrobble.clear(scope, entry.parentMetaId, tmdb?.first ?: entry.seasonNumber, tmdb?.second ?: entry.episodeNumber)
        }
    }

    /**
     * Next-up seeds in the add-on's numbering (what Trakt does in its override). A seed still in
     * TMDB's numbering (handed out before the show's mapping was cached) is moved now; one already
     * in the add-on's is left alone, whichever order the mapping and the snapshot landed in.
     */
    override suspend fun prepareNextUpProgressEntries(
        entries: List<WatchProgressEntry>,
        contentId: String,
    ): List<WatchProgressEntry> {
        if (entries.none { it.parentMetaId == contentId && it.seasonNumber != null && it.episodeNumber != null }) return entries
        val mapping = episodeMapping(contentId)?.takeIf { it.remaps } ?: return entries
        // The dropped seasons are taken from the projection and translated afresh, whether the
        // row came out raw or already remapped: the same answer either way (Codex r6 #4).
        val excluded = mapping.addonExclusionsOf(sync.currentProjection().droppedSeasons(contentId))
        return entries.mapNotNull { entry ->
            if (entry.parentMetaId != contentId) return@mapNotNull entry
            val season = entry.seasonNumber ?: return@mapNotNull entry
            val episode = entry.episodeNumber ?: return@mapNotNull entry
            val tmdb = parseMdbListEpisodeKey(entry.trackingEpisodeKey) ?: (season to episode)
            // A TMDB episode the add-on does not have seeds nothing (Codex r5 #4), as in snapshots.
            val addon = mapping.toAddon(tmdb.first, tmdb.second) ?: return@mapNotNull null
            val moved = if (addon.season == season && addon.episode == episode) entry else entry.withAddonEpisode(addon, mapping)
            if (moved.excludedNextUpSeasons == excluded.seasons && moved.excludedNextUpEpisodeKeys == excluded.episodeKeys) moved
            else moved.copy(excludedNextUpSeasons = excluded.seasons, excludedNextUpEpisodeKeys = excluded.episodeKeys)
        }
    }

    override fun normalizeParentContentId(parentContentId: String, videoId: String?): String =
        sync.currentProjection().canonicalContentId(parentContentId) ?: parentContentId

    override fun isHiddenFromProgress(contentId: String): Boolean = sync.currentProjection().isHidden(contentId)

    // Fork: MDBList only resolves imdb/tmdb/tvdb/trakt/mdblist ids (toMdbListIds), so a local
    // `kitsu:`/`mal:`/`anilist:` continue-watching row can never come back from it. Answering false
    // keeps such rows merged into continue watching while MDBList is the Watch Progress source
    // (projectWatchProgressSourceEntries), mirroring Trakt's override.
    override fun canRepresentContentId(contentId: String): Boolean =
        parseTrackingExternalIds(contentId).toMdbListIds() != null

    /**
     * The detail screen's per-show refresh: also the moment to learn how the add-on numbers this
     * show, so its watched ticks and progress rows land on the add-on's episodes.
     */
    override suspend fun refreshEpisodeProgress(contentId: String, forceRefresh: Boolean) {
        sync.refresh(if (forceRefresh) TrackingRefreshIntent.USER_INITIATED else TrackingRefreshIntent.AUTOMATIC)
        episodeMapping(contentId)
    }

    private suspend fun episodeMapping(contentId: String): MdbListEpisodeMapping? {
        if (parseTrackingExternalIds(contentId).toMdbListIds() == null) return null
        val projection = sync.currentProjection()
        return episodeMappings.resolve(contentId, projection.tmdbShowId(contentId), projection.showAliases(contentId))
    }

    /**
     * The show's cached mapping for this snapshot, scheduling a background resolve for shows that
     * have none or whose mapping has aged (the service's own freshness check keeps that cheap, so an
     * airing show's new season is picked up, Codex r3 #4). [changes] ticks when one lands.
     */
    private fun cachedMappingOrResolveLater(projection: MdbListProgressProjection, contentId: String): MdbListEpisodeMapping? {
        val cached = episodeMappings.cached(contentId)
        if (parseTrackingExternalIds(contentId).toMdbListIds() != null) {
            episodeMappings.resolveInBackground(contentId, projection.tmdbShowId(contentId), projection.showAliases(contentId))
        }
        return cached
    }

}
