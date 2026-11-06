package com.nuvio.app.features.streams

/**
 * In-memory LRU of format badges per probe key (see [TitleFormatProbeEngine.cacheKey]). Nothing is
 * persisted: a stale "4K" across launches would mislead more than a short re-probe costs.
 *
 * A non-empty entry lives [positiveTtlMs] (6 h), an empty one [emptyTtlMs] (30 min). Recording into
 * a live entry merges (badges only grow); its TTL restarts only when the new answer holds every
 * merged badge, so an answer that lacks a badge never keeps that badge alive. Not thread-safe: the probe engine
 * calls it under its own lock.
 */
internal class TitleFormatProbeCache(
    private val clock: () -> Long,
    private val capacity: Int = DEFAULT_CAPACITY,
    private val positiveTtlMs: Long = POSITIVE_TTL_MS,
    private val emptyTtlMs: Long = EMPTY_TTL_MS,
) {
    data class Entry(
        val badges: List<TitleFormatBadge>,
        val source: TitleFormatSource,
        val expiresAtMs: Long,
    )

    /** Insertion order is recency order: a hit is removed and re-inserted at the end. */
    private val entries = LinkedHashMap<String, Entry>()

    /** The live entry for [key], or null when absent or expired (an expired entry is dropped). */
    fun get(key: String): Entry? {
        val entry = entries.remove(key) ?: return null
        if (clock() >= entry.expiresAtMs) return null
        entries[key] = entry
        return entry
    }

    /**
     * Stores [badges] for [key], merged with a live entry. The source becomes [TitleFormatSource.PICKER]
     * once either side came from the picker, since the picker saw the add-ons' full answer.
     */
    fun record(key: String, badges: List<TitleFormatBadge>, source: TitleFormatSource): Entry {
        val previous = get(key)
        val merged = previous?.let { TitleFormatBadges.merge(it.badges, badges) } ?: badges
        val mergedSource = if (previous?.source == TitleFormatSource.PICKER) TitleFormatSource.PICKER else source
        val ttl = if (merged.isEmpty()) emptyTtlMs else positiveTtlMs
        // A fresh TTL only when this answer saw every badge the entry keeps; otherwise a badge it
        // lacks would be renewed by an answer that no longer has it.
        val renew = previous == null || badges.containsAll(merged)
        val expiresAtMs = if (renew) clock() + ttl else previous.expiresAtMs
        val entry = Entry(badges = merged, source = mergedSource, expiresAtMs = expiresAtMs)
        entries.remove(key)
        entries[key] = entry
        while (entries.size > capacity) {
            entries.remove(entries.keys.first())
        }
        return entry
    }

    companion object {
        const val DEFAULT_CAPACITY = 200
        const val POSITIVE_TTL_MS = 6L * 60 * 60 * 1_000
        const val EMPTY_TTL_MS = 30L * 60 * 1_000
    }
}
