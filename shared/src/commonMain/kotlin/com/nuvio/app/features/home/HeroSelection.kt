package com.nuvio.app.features.home

import kotlin.random.Random

/**
 * BUG-42 (tvOS beta.12 field report, third re-report): the hero used to be re-drawn from a
 * fresh `shuffled(seed).take(limit)` on EVERY batch publish. The seed was stable, but the pool
 * grew between publishes (catalogs land in batches), so the item at index 0 changed from one
 * publish to the next — on screen, one backdrop painted and another loaded over it a beat later.
 *
 * Stable RANKING instead: whatever was already ranked stays, in its ranked order (minus anything
 * no longer available); newcomers are shuffled in; the caller shows the first [limit]. The head —
 * the item the user is looking at — therefore never changes because a later batch arrived. When
 * newcomers exist, only the first `limit / 2` previously ranked items keep their place ahead of
 * them (never fewer than the head): a first batch can fill all eight slots on its own, and
 * reserving every one of them would keep a later-loading second Hero Source out of the carousel
 * for the whole process (Codex gate 8); the displaced items follow the newcomers, so a small batch
 * never underfills. Positions past the reserved ones may therefore change while a load is in
 * flight; the carousel advances from the head every few seconds and loads finish in a couple, so
 * that is not a visible swap in practice. An empty `previous` reshuffles as before.
 *
 * Returns the FULL ranking, not the carousel slice: feeding the full ranking back as `previous`
 * is what makes an unchanged pool a no-op (a truncated list would re-classify its own displaced
 * tail as newcomers on the next call and churn).
 *
 * Instances come from [pool] (the freshest metadata), not from [previous]; [previous] only fixes
 * identity and order.
 */
internal fun <T> stableHeroSelection(
    previous: List<T>,
    pool: List<T>,
    limit: Int,
    random: Random,
    /**
     * Where a PREVIOUS item may still be found to stay on the hero. Defaults to [pool]. tvOS
     * passes every loaded catalog here: the hero-source set is re-normalized when the profile's
     * synced Home settings land a second or so after first paint, and an item that merely lost
     * hero-SOURCE status (while still sitting in a loaded row) must not be swapped out under the
     * user — an explicit Hero Sources change in Settings resets the selection instead.
     */
    keepFrom: List<T> = pool,
    key: (T) -> String,
): List<T> {
    if (limit <= 0 || (pool.isEmpty() && (previous.isEmpty() || keepFrom.isEmpty()))) return emptyList()
    // (The caller shows `ranking.take(limit)`; the ranking itself is bounded by the pool.)
    val freshByKey = LinkedHashMap<String, T>(pool.size)
    for (item in pool) { val k = key(item); if (k !in freshByKey) freshByKey[k] = item }
    val keepByKey = if (keepFrom === pool) freshByKey else LinkedHashMap<String, T>(keepFrom.size).also { map ->
        for (item in keepFrom) { val k = key(item); if (k !in map) map[k] = item }
    }
    val kept = ArrayList<T>(limit)
    val keptKeys = HashSet<String>()
    for (item in previous) {
        val k = key(item)
        val fresh = freshByKey[k] ?: keepByKey[k] ?: continue
        if (keptKeys.add(k)) kept += fresh
    }
    val newcomers = freshByKey.entries
        .filter { (k, _) -> k !in keptKeys }
        .map { it.value }
        .shuffled(random)
    val keptCap = if (newcomers.isEmpty()) kept.size else maxOf(1, limit / 2)
    // Reserved prefix, then newcomers, then whatever previous items the cap displaced.
    return kept.take(keptCap) + newcomers + kept.drop(keptCap)
}
