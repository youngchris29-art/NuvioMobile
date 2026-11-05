package com.nuvio.app.features.mdblist

import com.nuvio.app.features.tracking.TrackingHistoryItem
import com.nuvio.app.features.tracking.TrackingHistoryWriter
import com.nuvio.app.features.tracking.TrackingMediaReference
import com.nuvio.app.features.tracking.TrackingMutationResult
import com.nuvio.app.features.tracking.TrackingProviderId
import com.nuvio.app.features.tracking.TrackingScrobbleAction
import com.nuvio.app.features.tracking.TrackingScrobbleEvent
import com.nuvio.app.features.tracking.TrackingScrobbler
import com.nuvio.app.features.tracking.TrackingSeekScrobblePolicy
import co.touchlab.kermit.Logger
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
    private val log = Logger.withTag("MdbListWrites")
    override val providerId = TrackingProviderId.MDBLIST
    override val seekScrobblePolicy = TrackingSeekScrobblePolicy.STOP_AND_RESTART

    override suspend fun addToHistory(profileId: Int, items: Collection<TrackingHistoryItem>): TrackingMutationResult {
        val scope = scope(profileId)
        val mapped = items.mapNotNull { item -> item.media.inMdbListNumbering()?.let { item.copy(media = it) } }
        val result = history.add(scope, mapped)
        return result.copy(attemptedCount = items.size, notFoundCount = result.notFoundCount + items.size - mapped.size)
    }

    override suspend fun removeFromHistory(profileId: Int, items: Collection<TrackingMediaReference>): TrackingMutationResult {
        val scope = scope(profileId)
        val mapped = items.mapNotNull { it.inMdbListNumbering() }
        val result = history.remove(scope, mapped)
        return result.copy(attemptedCount = items.size, notFoundCount = result.notFoundCount + items.size - mapped.size)
    }

    override suspend fun scrobble(profileId: Int, action: TrackingScrobbleAction, event: TrackingScrobbleEvent) {
        val scope = scope(profileId)
        val media = event.media.inMdbListNumbering() ?: return
        scrobble.scrobble(scope, action, event.copy(media = media))
    }

    /** Null for an add-on episode MDBList has no counterpart for: not written (Codex r5 #2). */
    private suspend fun TrackingMediaReference.inMdbListNumbering(): TrackingMediaReference? {
        if (episode == null) return this
        sync.ensureLoaded()
        return episodeMappings.toMdbListNumbering(this, sync.currentProjection().mediaIndex)
            ?: null.also { log.i { "Skipped an MDBList write for ${catalog?.videoId ?: stableKey}: the add-on's episode has no TMDB counterpart" } }
    }

    private fun scope(profileId: Int): MdbListAuthScope = sync.currentScope().also {
        if (it.profileId != profileId) throw CancellationException("MDBList profile changed")
    }
}
