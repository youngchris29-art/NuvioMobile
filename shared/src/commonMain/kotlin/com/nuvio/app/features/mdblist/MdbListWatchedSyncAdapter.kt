package com.nuvio.app.features.mdblist

import co.touchlab.kermit.Logger
import com.nuvio.app.features.tracking.TrackingHistoryItem
import com.nuvio.app.features.tracking.TrackingMediaReference
import com.nuvio.app.features.tracking.TrackingProviderId
import com.nuvio.app.features.tracking.TrackingRefreshIntent
import com.nuvio.app.features.tracking.TrackingWatchedProvider
import com.nuvio.app.features.tracking.buildTrackingMediaReference
import com.nuvio.app.features.tracking.isHistoryRemovable
import com.nuvio.app.features.tracking.trackingHistoryPushItems
import com.nuvio.app.features.watched.WatchedItem
import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.combine
import kotlinx.coroutines.flow.distinctUntilChanged

/**
 * MDBList's watched-history port. Episodes cross it in the add-on's numbering on both sides
 * (upstream facf25ec3): pulls move a remapped show's TMDB season/episode to the add-on's through
 * the mappings [MdbListTrackingProgressProvider.refreshEpisodeProgress] resolves when a detail
 * screen opens, and pushes translate back to TMDB's before the write.
 */
class MdbListWatchedSyncAdapter internal constructor(
    private val sync: MdbListSyncRepository,
    private val history: MdbListHistoryService,
    private val episodeMappings: MdbListEpisodeMappingService,
    auth: MdbListAuthStore,
    private val activeProfile: StateFlow<Int>,
) : TrackingWatchedProvider {
    private val log = Logger.withTag("MdbListWatched")
    override val providerId = TrackingProviderId.MDBLIST
    private val changes = combine(sync.state, auth.state, activeProfile, episodeMappings.changes) { _, _, _, _ -> Unit }

    override suspend fun pull(profileId: Int, pageSize: Int): List<WatchedItem> {
        val scope = scope(profileId)
        sync.refresh(TrackingRefreshIntent.AUTOMATIC)
        if (sync.currentScope() != scope) throw CancellationException("MDBList account changed")
        val state = sync.state.value
        if (!state.hasLoaded && state.error != null) throw MdbListApiException(code = "sync_unavailable")
        return sync.currentProjection().watchedItemsInAddonNumbering(episodeMappings::cached)
    }

    override suspend fun pullExtraWatchedKeys(profileId: Int): Set<String> {
        scope(profileId)
        return sync.currentProjection().watchedKeysInAddonNumbering(episodeMappings::cached)
    }

    override fun observeExtraWatchedKeys(profileId: Int) = combine(changes, activeProfile) { _, active ->
        if (profileId == active) sync.currentProjection().watchedKeysInAddonNumbering(episodeMappings::cached) else emptySet()
    }.distinctUntilChanged()

    // Fork: whole-series guard on both sides (upstream MDBList has none). A mark without episode
    // coordinates becomes a bare `shows` entry (MdbListMutationTarget → SHOW), which MDBList answers
    // by marking EVERY episode watched on add, or by wiping the show's whole history on remove. The
    // app emits such marks itself: reconcileSeriesWatchedState unmarks the series item once a new
    // episode airs, and the delete fans out to every connected provider, active source or not.
    // Push uses the Simkl rule (upstream ba786215) and then the removal allowlist, because MDBList
    // also collapses a season-only mark (episode == null) into a whole-show target.
    override suspend fun push(profileId: Int, items: Collection<WatchedItem>) {
        val scope = scope(profileId)
        val pushable = trackingHistoryPushItems(items).filter(WatchedItem::isHistoryRemovable)
        if (pushable.size != items.size) {
            log.i { "Skipped ${items.size - pushable.size} of ${items.size} MDBList history items: whole-series marks" }
        }
        if (pushable.isEmpty()) return
        val references = pushable.mapNotNull { item -> item.mdbListReference()?.let { TrackingHistoryItem(it, item.markedAtEpochMs) } }
        if (references.isEmpty()) return
        val result = history.add(scope, references)
        check(result.isComplete) { "MDBList could not match ${result.notFoundCount} watched items" }
    }

    override suspend fun delete(profileId: Int, items: Collection<WatchedItem>) {
        val scope = scope(profileId)
        val removable = items.filter(WatchedItem::isHistoryRemovable)
        if (removable.size != items.size) {
            log.i { "Skipped ${items.size - removable.size} of ${items.size} MDBList history removals: whole-series marks" }
        }
        if (removable.isEmpty()) return
        val references = removable.mapNotNull { it.mdbListReference() }
        if (references.isEmpty()) return
        val result = history.remove(scope, references)
        check(result.isComplete) { "MDBList could not match ${result.notFoundCount} watched items" }
    }

    /**
     * The item as MDBList numbers it. An item that came out of [pull] names its TMDB episode in
     * its tracking key, whichever numbering it was handed out in (Codex r2 #1). An MDBList item
     * without a key was pulled by a build before the key existed and persisted as TMDB numbers it
     * (Codex r4 #3), so its own coordinates are the identity. Only an item the app built from the
     * add-on's episode list (no provider id) is translated; null when that episode has no TMDB
     * counterpart, which MDBList cannot hold and the caller skips (Codex r5 #2).
     */
    private suspend fun WatchedItem.mdbListReference(): TrackingMediaReference? {
        val tmdb = parseMdbListEpisodeKey(trackingEpisodeKey)
            ?: (season to episode).takeIf { trackingProviderId == MDBLIST_PROVIDER_STORAGE_ID && season != null && episode != null }
        if (tmdb != null) {
            return buildTrackingMediaReference(
                contentType = type, parentMetaId = id, videoId = videoId, title = name, releaseInfo = releaseInfo,
                seasonNumber = tmdb.first, episodeNumber = tmdb.second,
            )
        }
        val reference = reference()
        if (reference.episode == null) return reference
        sync.ensureLoaded()
        return episodeMappings.toMdbListNumbering(reference, sync.currentProjection().mediaIndex)
            ?: null.also { log.i { "Skipped MDBList history for ${videoId ?: id}: the add-on's episode has no TMDB counterpart" } }
    }

    private fun scope(profileId: Int) = sync.currentScope().also {
        if (it.profileId != profileId) throw CancellationException("MDBList profile changed")
    }

    private companion object {
        /** [WatchedItem.trackingProviderId] of every item the projection builds. */
        const val MDBLIST_PROVIDER_STORAGE_ID = "mdblist"
    }

    private fun WatchedItem.reference() = buildTrackingMediaReference(
        contentType = type, parentMetaId = id, videoId = videoId, title = name, releaseInfo = releaseInfo,
        seasonNumber = season, episodeNumber = episode,
    )
}
