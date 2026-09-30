package com.nuvio.app.features.mdblist

import co.touchlab.kermit.Logger
import com.nuvio.app.features.tracking.TrackingHistoryItem
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

class MdbListWatchedSyncAdapter(
    private val sync: MdbListSyncRepository,
    private val history: MdbListHistoryService,
    auth: MdbListAuthStore,
    private val activeProfile: StateFlow<Int>,
) : TrackingWatchedProvider {
    private val log = Logger.withTag("MdbListWatched")
    override val providerId = TrackingProviderId.MDBLIST
    private val changes = combine(sync.state, auth.state, activeProfile) { _, _, _ -> Unit }

    override suspend fun pull(profileId: Int, pageSize: Int): List<WatchedItem> {
        val scope = scope(profileId)
        sync.refresh(TrackingRefreshIntent.AUTOMATIC)
        if (sync.currentScope() != scope) throw CancellationException("MDBList account changed")
        val state = sync.state.value
        if (!state.hasLoaded && state.error != null) throw MdbListApiException(code = "sync_unavailable")
        return sync.currentProjection().watchedItems
    }

    override suspend fun pullExtraWatchedKeys(profileId: Int): Set<String> {
        scope(profileId)
        return sync.currentProjection().watchedKeys
    }

    override fun observeExtraWatchedKeys(profileId: Int) = combine(changes, activeProfile) { _, active ->
        if (profileId == active) sync.currentProjection().watchedKeys else emptySet()
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
        val result = history.add(scope, pushable.map { TrackingHistoryItem(it.reference(), it.markedAtEpochMs) })
        check(result.isComplete) { "MDBList could not match ${result.notFoundCount} watched items" }
    }

    override suspend fun delete(profileId: Int, items: Collection<WatchedItem>) {
        val scope = scope(profileId)
        val removable = items.filter(WatchedItem::isHistoryRemovable)
        if (removable.size != items.size) {
            log.i { "Skipped ${items.size - removable.size} of ${items.size} MDBList history removals: whole-series marks" }
        }
        if (removable.isEmpty()) return
        val result = history.remove(scope, removable.map { it.reference() })
        check(result.isComplete) { "MDBList could not match ${result.notFoundCount} watched items" }
    }

    private fun scope(profileId: Int) = sync.currentScope().also {
        if (it.profileId != profileId) throw CancellationException("MDBList profile changed")
    }

    private fun WatchedItem.reference() = buildTrackingMediaReference(
        contentType = type, parentMetaId = id, videoId = videoId, title = name, releaseInfo = releaseInfo,
        seasonNumber = season, episodeNumber = episode,
    )
}
