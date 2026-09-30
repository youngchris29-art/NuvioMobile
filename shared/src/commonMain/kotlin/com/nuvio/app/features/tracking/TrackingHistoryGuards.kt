package com.nuvio.app.features.tracking

import com.nuvio.app.features.watched.WatchedItem

/*
 * Fork: history guards shared by every tracker that turns a [WatchedItem] into a history write.
 *
 * Extracted from the Simkl adapter (upstream `ba786215` on the push side, the fork's own allowlist on
 * the remove side) so MDBList, whose history API treats a bare show the same way, applies the exact
 * same rule. The Simkl adapter delegates here with no change in behaviour.
 */

/** Content types that stand on their own and need no episode to be a real mark. */
internal val MOVIE_LIKE_WATCHED_TYPES: Set<String> = setOf("movie", "film")

/**
 * What may travel to a tracker as a watched mark.
 *
 * A mark without episode coordinates describes a whole series. Trackers turn that into a show-level
 * entry and answer by marking every episode of the show watched, including episodes the user never
 * opened, which is how a single ill-timed mark wiped a full series. Only films are allowed through
 * without coordinates; a whole-series action still reports its episodes one by one, which carries the
 * same information and cannot touch anything else. A mark whose type is `anime` is dropped too: the
 * app cannot tell an anime film from an anime series without more metadata.
 */
internal fun trackingHistoryPushItems(items: Collection<WatchedItem>): List<WatchedItem> =
    items.filterNot(WatchedItem::isWholeSeriesMark)

/** A mark with no episode coordinates whose type is not a film: it stands for the whole series. */
internal fun WatchedItem.isWholeSeriesMark(): Boolean =
    season == null && episode == null && type.trim().lowercase() !in MOVIE_LIKE_WATCHED_TYPES

/**
 * Which watched entries may be forwarded to a tracker's history-removal endpoint.
 *
 * Episodes and movies map to a single history entry, so removing them is precise. A series-level
 * marker has no season/episode and would serialize as a bare show, which trackers treat as "remove
 * this show's entire history" — far more destructive than the local marker it mirrors. The app drops
 * such markers on its own (`reconcileSeriesWatchedState` once a new episode airs), so forwarding them
 * would wipe history the user never asked to remove.
 *
 * Deliberately an allowlist: anything whose type is unrecognized (or that carries a partial
 * season/episode pair) is skipped rather than sent, so the failure mode is a stale tracker entry
 * instead of deleted history.
 */
internal fun WatchedItem.isHistoryRemovable(): Boolean {
    val isEpisode = season != null && episode != null
    val isMovie = type.trim().lowercase() in MOVIE_LIKE_WATCHED_TYPES
    return isEpisode || isMovie
}
