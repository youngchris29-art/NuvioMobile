package com.nuvio.app.features.watchprogress

/**
 * What putting one video's local entries back the way they were changes
 * ([WatchProgressRepository.restoreLocalEntriesForVideo]): the captured entries written as they are
 * (own timestamps, own fields), their keys re-dirtied so the next sync replaces the server copy,
 * and every other local entry for the video (one a later write created under another key) removed.
 */
internal data class LocalProgressRestore(
    val upserts: List<WatchProgressEntry>,
    val removals: List<WatchProgressEntry>,
    val dirtyKeys: Set<String>,
)

internal fun planLocalProgressRestore(
    current: Collection<WatchProgressEntry>,
    videoId: String,
    captured: Collection<WatchProgressEntry>,
): LocalProgressRestore {
    val upserts = captured.filter { it.videoId == videoId }.map { it.withResolvedProgressKey() }
    val keys = upserts.mapTo(mutableSetOf()) { it.resolvedProgressKey() }
    val removals = current.filter { it.videoId == videoId && it.resolvedProgressKey() !in keys }
    return LocalProgressRestore(upserts = upserts, removals = removals, dirtyKeys = keys)
}
