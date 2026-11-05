package com.nuvio.app.features.mdblist

import com.nuvio.app.features.tracking.TrackingHistoryItem
import com.nuvio.app.features.tracking.TrackingHistoryWriter
import com.nuvio.app.features.tracking.TrackingMediaReference
import com.nuvio.app.features.tracking.TrackingProviderId
import com.nuvio.app.features.tracking.TrackingScrobbleAction
import com.nuvio.app.features.tracking.TrackingScrobbleEvent
import com.nuvio.app.features.tracking.TrackingScrobbler
import com.nuvio.app.features.tracking.TrackingSeekScrobblePolicy
import kotlinx.coroutines.CancellationException

/**
 * MDBList's history writer and scrobbler. Every episode goes out in TMDB's numbering (upstream
 * facf25ec3): the player and the watched list speak the add-on's, which can split an anime into
 * seasons differently, so [episodeMappings] translates each reference first.
 */
class MdbListTrackingWrites internal constructor(
    private val sync: MdbListSyncRepository,
    private val history: MdbListHistoryService,
    private val scrobble: MdbListScrobbleService,
    private val episodeMappings: MdbListEpisodeMappingService,
) : TrackingHistoryWriter, TrackingScrobbler {
    override val providerId = TrackingProviderId.MDBLIST
    override val seekScrobblePolicy = TrackingSeekScrobblePolicy.STOP_AND_RESTART

    override suspend fun addToHistory(profileId: Int, items: Collection<TrackingHistoryItem>) =
        history.add(scope(profileId), items.map { item -> item.copy(media = item.media.inMdbListNumbering()) })

    override suspend fun removeFromHistory(profileId: Int, items: Collection<TrackingMediaReference>) =
        history.remove(scope(profileId), items.map { it.inMdbListNumbering() })

    override suspend fun scrobble(profileId: Int, action: TrackingScrobbleAction, event: TrackingScrobbleEvent) =
        scrobble.scrobble(scope(profileId), action, event.copy(media = event.media.inMdbListNumbering()))

    private suspend fun TrackingMediaReference.inMdbListNumbering(): TrackingMediaReference {
        if (episode == null) return this
        sync.ensureLoaded()
        return episodeMappings.toMdbListNumbering(this, sync.currentProjection().mediaIndex)
    }

    private fun scope(profileId: Int): MdbListAuthScope = sync.currentScope().also {
        if (it.profileId != profileId) throw CancellationException("MDBList profile changed")
    }
}
