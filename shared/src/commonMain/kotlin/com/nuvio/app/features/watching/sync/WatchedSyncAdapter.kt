package com.nuvio.app.features.watching.sync

import com.nuvio.app.features.watched.WatchedItem

data class WatchedDeltaEvent(
    val eventId: Long,
    val operation: String,
    val contentId: String,
    val contentType: String,
    val title: String,
    val season: Int?,
    val episode: Int?,
    val watchedAt: Long,
)

interface WatchedSyncAdapter {
    suspend fun pull(
        profileId: Int,
        pageSize: Int,
    ): List<WatchedItem>

    /**
     * Fully-watched series keys the provider tracks separately from individual watched items.
     * `null` means "this adapter has no opinion" and leaves the current set untouched — which is
     * every adapter the fork ships today (Nuvio Sync and Trakt both derive the set locally).
     */
    suspend fun pullFullyWatchedSeriesKeys(profileId: Int): Set<String>? = null

    suspend fun getDeltaCursor(profileId: Int): Long? = null

    suspend fun pullDelta(
        profileId: Int,
        sinceEventId: Long,
        limit: Int,
    ): List<WatchedDeltaEvent> = emptyList()

    suspend fun push(
        profileId: Int,
        items: Collection<WatchedItem>,
    )

    suspend fun delete(
        profileId: Int,
        items: Collection<WatchedItem>,
    )
}
