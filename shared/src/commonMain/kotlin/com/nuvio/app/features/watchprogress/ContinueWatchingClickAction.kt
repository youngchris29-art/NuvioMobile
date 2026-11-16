package com.nuvio.app.features.watchprogress

import com.nuvio.app.features.cloud.CloudLibraryContentType

/**
 * Upstream 37e8a5c0e: an Up Next episode that has not aired yet. One rule for the Upcoming split
 * (`splitUpcomingItems` in the phone app) and the click action.
 */
fun ContinueWatchingItem.isUpcoming(nowEpochMs: Long = WatchProgressClock.nowEpochMs()): Boolean =
    isNextUp && parseReleaseDateToEpochMs(released)
        ?.let { releaseEpochMs -> releaseEpochMs > nowEpochMs } == true

/** Upstream 37e8a5c0e: whether selecting [item] opens the details page instead of the stream. */
fun ContinueWatchingClickAction.opensDetails(
    item: ContinueWatchingItem,
    nowEpochMs: Long = WatchProgressClock.nowEpochMs(),
): Boolean = when (this) {
    ContinueWatchingClickAction.STREAM -> false
    ContinueWatchingClickAction.DETAILS -> true
    ContinueWatchingClickAction.DETAILS_FOR_UPCOMING -> item.isUpcoming(nowEpochMs)
}

/**
 * tvOS: the same decision for a Continue Watching card, which is a [WatchProgressEntry]. A cloud
 * library item always keeps playing (upstream checks it before the action). [releaseAtEpochMs] is
 * the episode's release instant when known; tvOS passes null today because unaired Up Next cards
 * are dropped ([ContinueWatchingUnairedNextUpPolicy]), so "details for upcoming" plays every card
 * until that policy is flipped.
 */
object ContinueWatchingSelect {
    fun opensDetails(
        action: ContinueWatchingClickAction,
        entry: WatchProgressEntry,
        releaseAtEpochMs: Long?,
        nowEpochMs: Long,
    ): Boolean {
        if (entry.contentType.equals(CloudLibraryContentType, ignoreCase = true) ||
            entry.parentMetaType.equals(CloudLibraryContentType, ignoreCase = true)
        ) return false
        return when (action) {
            ContinueWatchingClickAction.STREAM -> false
            ContinueWatchingClickAction.DETAILS -> true
            ContinueWatchingClickAction.DETAILS_FOR_UPCOMING ->
                entry.isContinueWatchingNextUp && releaseAtEpochMs != null && releaseAtEpochMs > nowEpochMs
        }
    }
}
