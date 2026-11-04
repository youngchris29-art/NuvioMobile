package com.nuvio.app.features.catalog

import com.nuvio.app.core.coroutines.uncaughtCoroutineLogger
import com.nuvio.app.features.addons.AddonCatalog
import com.nuvio.app.features.addons.buildAddonResourceUrl
import com.nuvio.app.features.addons.fetchAddonResponseText
import com.nuvio.app.features.home.HomeCatalogParser
import com.nuvio.app.features.home.MetaPreview
import com.nuvio.app.features.home.stableKey
import kotlinx.atomicfu.atomic
import kotlinx.coroutines.CompletableDeferred
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.Job
import kotlinx.coroutines.NonCancellable
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.launch
import kotlinx.coroutines.sync.Mutex
import kotlinx.coroutines.sync.withLock
import kotlinx.coroutines.withContext

const val CATALOG_PAGE_SIZE = 100
private const val DUPLICATE_CATALOG_PAGE_ADVANCE_LIMIT = 3

data class CatalogPage(
    val items: List<MetaPreview>,
    val rawItemCount: Int,
    val nextSkip: Int?,
)

data class CatalogPaginationState(
    val nextSkip: Int?,
    val consecutiveDuplicatePages: Int = 0,
)

/**
 * BUG-155 (P2; Steven, beta.19-rc3 follow-ups 2026-10-14: search-as-you-type lags, results "take a
 * while to land"). Catalog GETs are shared between callers asking for the same URL at once (Home,
 * Discover and Search can all want the same page), and each shared fetch runs in its own scope so
 * one caller's cancellation cannot fail the others. Before this fix that also meant NOBODY could
 * cancel it: a search superseded by the next keystroke cancelled its awaiting coroutine, but the
 * HTTP request itself ran on to its 60 s timeout, one per search-capable catalog, letter after
 * letter, and the live query's requests queued behind the dead ones.
 *
 * Now every shared fetch counts its waiters. A waiter that leaves before the result (cancelled)
 * drops the count, and when the LAST waiter leaves the fetch is cancelled and forgotten, all under
 * one mutex, so a caller joining in between either keeps the old fetch alive (it joined first) or
 * starts a fresh one (it joined after the removal). A search that is cancelled while Home still
 * waits on the same URL never kills Home's request.
 */
internal class CatalogInflightRequests<K : Any>(
    private val scope: CoroutineScope,
    private val fetch: suspend (K) -> String,
    /** DEBUG A/B (`-debug.searchLegacy YES` on tvOS): false restores the pre-BUG-155 behaviour. */
    private val cancelAbandoned: () -> Boolean = { true },
) {
    private class Entry(val deferred: CompletableDeferred<String>) {
        var waiters = 0
        var job: Job? = null
    }

    private val mutex = Mutex()
    private val entries = mutableMapOf<K, Entry>()
    private val inflight = atomic(0)
    private val cancelled = atomic(0)

    /** Shared fetches currently running (entries in the map). */
    val inflightCount: Int get() = inflight.value

    /** Fetches cancelled because their last waiter left, since launch. */
    val cancelledCount: Int get() = cancelled.value

    suspend fun get(key: K): String {
        val entry = mutex.withLock {
            val existing = entries[key] ?: Entry(CompletableDeferred()).also { created ->
                entries[key] = created
                inflight.incrementAndGet()
                created.job = scope.launch {
                    try {
                        created.deferred.complete(fetch(key))
                    } catch (error: Throwable) {
                        created.deferred.completeExceptionally(error)
                    } finally {
                        // A cancelled fetch was already removed below; NonCancellable so a
                        // contended lock cannot skip the removal of a finished one.
                        withContext(NonCancellable) {
                            mutex.withLock { removeIfCurrent(key, created) }
                        }
                    }
                }
            }
            existing.waiters += 1
            existing
        }
        try {
            return entry.deferred.await()
        } finally {
            // Runs on success, failure and cancellation alike. Only a waiter that leaves while the
            // result is still pending can make the fetch abandoned.
            withContext(NonCancellable) {
                mutex.withLock {
                    entry.waiters -= 1
                    if (entry.waiters <= 0 && !entry.deferred.isCompleted && cancelAbandoned()) {
                        removeIfCurrent(key, entry)
                        entry.job?.cancel()
                        cancelled.incrementAndGet()
                    }
                }
            }
        }
    }

    /** Call with [mutex] held. */
    private fun removeIfCurrent(key: K, entry: Entry) {
        if (entries[key] === entry) {
            entries.remove(key)
            inflight.decrementAndGet()
        }
    }
}

private val inflightRequestScope = CoroutineScope(SupervisorJob() + Dispatchers.Default + uncaughtCoroutineLogger("CatalogData"))
private val cancelAbandonedCatalogFetches = atomic(true)
private val searchCatalogProbeEnabled = atomic(false)
private val catalogInflightRequests = CatalogInflightRequests<CatalogFetchKey>(
    scope = inflightRequestScope,
    fetch = { key -> fetchAddonResponseText(url = key.url, forceRefresh = key.forceRefresh) },
    cancelAbandoned = { cancelAbandonedCatalogFetches.value },
)

/**
 * BUG-155 counters for the tvOS DEBUG `[SearchPerf]` probe (`SearchPerfProbe.swift`): how many
 * shared catalog fetches are running and how many were cancelled because every caller left. Two
 * atomic reads, no flag. [cancelAbandonedFetches] is the A/B switch the DEBUG launch argument
 * `-debug.searchLegacy YES` flips off; release builds never touch it.
 */
object CatalogInflightStats {
    val inflight: Int get() = catalogInflightRequests.inflightCount
    val cancelled: Int get() = catalogInflightRequests.cancelledCount
    var cancelAbandonedFetches: Boolean
        get() = cancelAbandonedCatalogFetches.value
        set(value) { cancelAbandonedCatalogFetches.value = value }
    /// BUG-208: the DEBUG app turns this on so every search catalog prints one
    /// `[SearchPerf] catalog …` line to stdout (Kermit is invisible on device). Off in release.
    var searchCatalogProbe: Boolean
        get() = searchCatalogProbeEnabled.value
        set(value) { searchCatalogProbeEnabled.value = value }
}

private suspend fun deduplicatedHttpGetText(
    url: String,
    forceRefresh: Boolean,
): String = catalogInflightRequests.get(
    CatalogFetchKey(
        url = url,
        forceRefresh = forceRefresh,
    ),
)

suspend fun fetchCatalogPage(
    manifestUrl: String,
    type: String,
    catalogId: String,
    genre: String? = null,
    search: String? = null,
    skip: Int? = null,
    maxItems: Int? = null,
    forceRefresh: Boolean = false,
): CatalogPage {
    val url = buildCatalogUrl(
        manifestUrl = manifestUrl,
        type = type,
        catalogId = catalogId,
        genre = genre,
        search = search,
        skip = skip,
    )
    val payload = deduplicatedHttpGetText(
        url = url,
        forceRefresh = forceRefresh,
    )
    val parsed = HomeCatalogParser.parseCatalogResponse(
        payload = payload,
        maxItems = maxItems,
    )
    val nextSkip = if (parsed.rawItemCount > 0) {
        (skip ?: 0) + parsed.rawItemCount
    } else {
        null
    }
    return CatalogPage(
        items = parsed.items,
        rawItemCount = parsed.rawItemCount,
        nextSkip = nextSkip,
    )
}

private data class CatalogFetchKey(
    val url: String,
    val forceRefresh: Boolean,
)

fun AddonCatalog.supportsPagination(): Boolean =
    extra.any { property -> property.name.equals("skip", ignoreCase = true) }

fun nextCatalogPaginationState(
    supportsPagination: Boolean,
    requestedSkip: Int,
    page: CatalogPage,
    loadedNewItems: Boolean,
    consecutiveDuplicatePages: Int,
): CatalogPaginationState {
    if (!supportsPagination || page.rawItemCount <= 0 || page.nextSkip == null) {
        return CatalogPaginationState(nextSkip = null)
    }
    if (loadedNewItems) {
        return CatalogPaginationState(nextSkip = page.nextSkip)
    }

    val duplicatePages = consecutiveDuplicatePages + 1
    val advancedSkip = if (page.nextSkip > requestedSkip) {
        page.nextSkip
    } else {
        requestedSkip + page.rawItemCount.coerceAtLeast(1)
    }
    return if (duplicatePages < DUPLICATE_CATALOG_PAGE_ADVANCE_LIMIT && advancedSkip > requestedSkip) {
        CatalogPaginationState(
            nextSkip = advancedSkip,
            consecutiveDuplicatePages = duplicatePages,
        )
    } else {
        CatalogPaginationState(
            nextSkip = null,
            consecutiveDuplicatePages = duplicatePages,
        )
    }
}

/**
 * #20 (review r2): whether the repository should ask for the next page itself. The grids ask
 * for more only when a new cell appears, so a page that added no visible item (the unreleased
 * filter emptied it, the server repeated or overlapped a page, or it ignores `skip`) would
 * otherwise leave `canLoadMore` true with nothing to trigger the load. Bounded by
 * [nextCatalogPaginationState]: after [DUPLICATE_CATALOG_PAGE_ADVANCE_LIMIT] such pages in a
 * row `nextSkip` is null and the list ends.
 */
fun catalogPageNeedsAutoAdvance(loadedNewItems: Boolean, nextSkip: Int?): Boolean =
    !loadedNewItems && nextSkip != null

fun mergeCatalogItems(
    existing: List<MetaPreview>,
    incoming: List<MetaPreview>,
): List<MetaPreview> {
    if (incoming.isEmpty()) return existing
    val seen = existing.mapTo(mutableSetOf()) { item -> item.stableKey() }
    return buildList(existing.size + incoming.size) {
        addAll(existing)
        incoming.forEach { item ->
            val key = item.stableKey()
            if (seen.add(key)) {
                add(item)
            }
        }
    }
}

fun dedupeCatalogItems(items: List<MetaPreview>): List<MetaPreview> {
    if (items.size < 2) return items
    val seen = mutableSetOf<String>()
    return buildList(items.size) {
        items.forEach { item ->
            if (seen.add(item.stableKey())) {
                add(item)
            }
        }
    }
}

fun buildCatalogUrl(
    manifestUrl: String,
    type: String,
    catalogId: String,
    genre: String?,
    search: String?,
    skip: Int?,
): String {
    val extraParts = buildList {
        if (!search.isNullOrBlank()) add("search=${search.encodeCatalogExtra()}")
        if (!genre.isNullOrBlank()) add("genre=${genre.encodeCatalogExtra()}")
        if (skip != null && skip > 0) add("skip=$skip")
    }

    return buildAddonResourceUrl(
        manifestUrl = manifestUrl,
        resource = "catalog",
        type = type,
        id = catalogId,
        extraPathSegment = extraParts.joinToString(separator = "&").ifBlank { null },
    )
}

private fun String.encodeCatalogExtra(): String =
    buildString {
        encodeToByteArray().forEach { byte ->
            val value = byte.toInt() and 0xFF
            val char = value.toChar()
            if (
                char in 'a'..'z' ||
                char in 'A'..'Z' ||
                char in '0'..'9' ||
                char == '-' ||
                char == '_' ||
                char == '.' ||
                char == '~'
            ) {
                append(char)
            } else {
                append('%')
                append(HEX[value shr 4])
                append(HEX[value and 0x0F])
            }
        }
    }

private val HEX = "0123456789ABCDEF"
