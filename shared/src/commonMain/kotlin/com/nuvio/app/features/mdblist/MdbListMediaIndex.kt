package com.nuvio.app.features.mdblist

/**
 * Maps movie/show aliases to their merged [MdbListMedia]. Callers that build an index themselves
 * (library projection, sorter, sync engine) fill it with [add]. Once published on a
 * [MdbListProgressProjection] an index is treated as immutable: extend it with [withPlayback],
 * which copies before adding, never with [add].
 */
internal class MdbListMediaIndex private constructor(
    private val byAlias: MutableMap<Pair<Boolean, String>, MdbListMedia>,
) {
    constructor(snapshot: MdbListSyncSnapshot) : this(
        HashMap<Pair<Boolean, String>, MdbListMedia>((snapshot.watched.size + snapshot.playback.size).coerceAtLeast(16)),
    ) {
        snapshot.watched.forEach { add(it.type, it.media) }
        snapshot.playback.forEach { add(it.type, it.media) }
    }

    companion object {
        /** An index over watched history only; [withPlayback] layers a playback list on top. */
        fun watchedOnly(watched: List<MdbListWatchedRecord>): MdbListMediaIndex {
            val index = MdbListMediaIndex(HashMap(watched.size.coerceAtLeast(16)))
            watched.forEach { index.add(it.type, it.media) }
            return index
        }
    }

    fun add(type: MdbListItemType, media: MdbListMedia): MdbListMedia {
        val movie = type == MdbListItemType.MOVIE
        val merged = media.ids.aliases().mapNotNull { byAlias[movie to it] }
            .fold(media, MdbListMedia::merged)
        merged.ids.aliases().forEach { byAlias[movie to it] = merged }
        return merged
    }

    fun resolve(type: MdbListItemType, ids: MdbListIds): MdbListMedia =
        ids.aliases().firstNotNullOfOrNull { byAlias[(type == MdbListItemType.MOVIE) to it] }
            ?.let { it.copy(ids = it.ids.merged(ids)) } ?: MdbListMedia(ids)

    /** [media] merged with everything the index already knows under any of its aliases. */
    fun resolveMedia(type: MdbListItemType, media: MdbListMedia): MdbListMedia {
        val movie = type == MdbListItemType.MOVIE
        return media.ids.aliases().mapNotNull { byAlias[movie to it] }
            .fold(media, MdbListMedia::merged)
    }

    /**
     * This index when every session's media is already represented (the usual scrobble: the same
     * show or movie as the session it replaces), otherwise a copy that has learned the new
     * aliases. Called on a [watchedOnly] base each time, never on an earlier result, so the
     * outcome is exactly what an index built over watched + this playback would hold and aliases
     * taught by a removed session do not linger.
     */
    fun withPlayback(playback: List<MdbListPlayback>): MdbListMediaIndex {
        var extended: MdbListMediaIndex? = null
        for (session in playback) {
            val current = extended ?: this
            if (current.represents(session.type, session.media)) continue
            val copy = extended ?: MdbListMediaIndex(HashMap(byAlias)).also { extended = it }
            copy.add(session.type, session.media)
        }
        return extended ?: this
    }

    private fun represents(type: MdbListItemType, media: MdbListMedia): Boolean {
        val movie = type == MdbListItemType.MOVIE
        val merged = resolveMedia(type, media)
        return merged.ids.aliases().all { byAlias[movie to it] == merged }
    }
}

internal fun MdbListSyncSnapshot.normalizeMedia(): MdbListSyncSnapshot {
    val index = MdbListMediaIndex(this)
    return copy(
        watched = watched.map { it.copy(media = index.resolve(it.type, it.media.ids)) }
            .groupBy(MdbListWatchedRecord::key)
            .map { (_, records) -> records.maxBy { mdbListTimestamp(it.watchedAt) } },
        playback = playback.map { it.copy(media = index.resolve(it.type, it.media.ids)) }
            .groupBy { it.id?.let { id -> "id:$id" } ?: "${it.type}:${it.media.ids.key}:${it.season}:${it.episode}" }
            .map { (_, records) -> records.maxBy { mdbListTimestamp(it.updatedAt) } }
    )
}
