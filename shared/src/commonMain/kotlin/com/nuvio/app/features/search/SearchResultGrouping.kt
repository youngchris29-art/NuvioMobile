package com.nuvio.app.features.search

import com.nuvio.app.core.i18n.localizedMediaTypeLabel
import com.nuvio.app.features.addons.isStreamOnly
import com.nuvio.app.features.addons.providesMeta
import com.nuvio.app.features.catalog.CatalogTarget
import com.nuvio.app.features.home.HomeCatalogSection
import com.nuvio.app.features.home.MetaPreview
import com.nuvio.app.features.home.stableKey

// Search & Discover batch 2026-10-06 (C2): grouped search results. Pure — everything here runs on
// the outcomes `SearchRepository.search()` already collected, so the grouped rows, the per-add-on
// sections and the suggestion chips always describe the same results.

/// What one search catalog returned. A page with no items is [Empty], not an error: before C2 the
/// fetch threw on an empty page, so a search where every catalog came back empty read as
/// `RequestFailed` instead of `NoResults`.
internal sealed interface SearchCatalogOutcome {
    val request: SearchCatalogRequest

    data class Success(
        override val request: SearchCatalogRequest,
        val items: List<MetaPreview>,
        val section: HomeCatalogSection,
    ) : SearchCatalogOutcome {
        val isMetadataAddon: Boolean
            get() = request.addon.manifest?.providesMeta() == true

        val isStreamOnlyAddon: Boolean
            get() = request.addon.manifest?.isStreamOnly() == true
    }

    data class Empty(
        override val request: SearchCatalogRequest,
    ) : SearchCatalogOutcome

    data class Failed(
        override val request: SearchCatalogRequest,
        val error: Throwable,
    ) : SearchCatalogOutcome
}

/// Everything one publish needs, built from one outcome list.
internal data class SearchResultsSnapshot(
    val sections: List<HomeCatalogSection>,
    val groups: List<SearchResultGroup>,
    val suggestions: List<String>,
)

/// [outcomes] in fan-out order (index order, nulls already dropped).
internal fun buildSearchResultsSnapshot(
    query: String,
    outcomes: List<SearchCatalogOutcome>,
    policy: SearchGroupingPolicy = SearchGroupingPolicy(),
): SearchResultsSnapshot {
    val groups = groupSearchResults(query, outcomes, policy)
    return SearchResultsSnapshot(
        sections = outcomes.mapNotNull { outcome -> (outcome as? SearchCatalogOutcome.Success)?.section },
        groups = groups,
        suggestions = suggestionTitles(query, groups),
    )
}

internal const val SEARCH_TOP_RESULT_GROUP_KEY = "top"

/// The Top result row's title. Plain English like the fan-out caption: a new `StringKey` needs a
/// composeApp provider mapping, and tvOS titles the row from its own string catalog anyway.
internal const val SEARCH_TOP_RESULT_TITLE = "Top Result"

private class MergedSearchHit(
    val item: MetaPreview,
    val foundIn: MutableList<String>,
    val firstSeen: Int,
    val target: CatalogTarget,
) {
    fun toHit(): SearchHit = SearchHit(item = item, foundIn = foundIn.toList())
}

/// Merges the successful outcomes into a Top result plus one row per media type:
///  1. catalogs ordered metadata add-ons, then catalog-only add-ons, then stream-only add-ons,
///     fan-out order within each tier;
///  2. at most [SearchGroupingPolicy.perCatalogCap] items per catalog, and at most
///     [SearchGroupingPolicy.perStreamOnlyAddonCap] items in total per stream-only add-on;
///  3. deduped by `type:id` ([stableKey], the key `mergeCatalogItems` uses): the first record wins
///     (metadata add-ons come first, so it is the richest), later add-ons are appended to
///     `foundIn`. Id schemes (`tt…` vs `tmdb:…`) are not reconciled — accepted;
///  4. one row per `item.type`, ordered movie, series, anime, then alphabetical; within a row,
///     exact title matches first, then first-seen order;
///  5. the Top result ranks exact title, popularity, vote count, number of add-ons, first seen.
///     The top hit also stays in its type row (the Apple TV app does the same).
internal fun groupSearchResults(
    query: String,
    outcomes: List<SearchCatalogOutcome>,
    policy: SearchGroupingPolicy = SearchGroupingPolicy(),
): List<SearchResultGroup> {
    val successes = outcomes
        .filterIsInstance<SearchCatalogOutcome.Success>()
        .withIndex()
        .sortedWith(compareBy({ (_, success) -> success.addonTier() }, { (index, _) -> index }))
        .map { (_, success) -> success }

    val merged = LinkedHashMap<String, MergedSearchHit>()
    val streamOnlyTaken = mutableMapOf<String, Int>()
    successes.forEach { success ->
        var items = success.items.take(policy.perCatalogCap.coerceAtLeast(0))
        if (success.isStreamOnlyAddon) {
            val manifestUrl = success.request.addon.manifestUrl
            val used = streamOnlyTaken[manifestUrl] ?: 0
            items = items.take((policy.perStreamOnlyAddonCap - used).coerceAtLeast(0))
            streamOnlyTaken[manifestUrl] = used + items.size
        }
        val addonName = success.request.addon.displayTitle
        items.forEach { item ->
            val key = item.stableKey()
            val existing = merged[key]
            if (existing == null) {
                merged[key] = MergedSearchHit(
                    item = item,
                    foundIn = mutableListOf(addonName),
                    firstSeen = merged.size,
                    target = success.section.target,
                )
            } else if (addonName !in existing.foundIn) {
                existing.foundIn += addonName
            }
        }
    }
    if (merged.isEmpty()) return emptyList()

    val normalizedQuery = query.normalizedSearchText()
    val hits = merged.values.toList()

    val typeGroups = hits
        .groupBy { hit -> hit.item.type }
        .entries
        .sortedBy { (type, _) -> type.typeSortKey() }
        .map { (type, typeHits) ->
            val ordered = typeHits.sortedWith(
                compareByDescending<MergedSearchHit> { hit -> hit.isExactTitle(normalizedQuery) }
                    .thenBy { hit -> hit.firstSeen },
            )
            SearchResultGroup(
                key = "type:$type",
                kind = SearchResultGroupKind.Type,
                type = type,
                title = localizedMediaTypeLabel(type),
                hits = ordered.map(MergedSearchHit::toHit),
                representativeTarget = typeHits.minBy { hit -> hit.firstSeen }.target,
            )
        }

    if (!policy.topResult) return typeGroups

    val top = hits.sortedWith(
        compareByDescending<MergedSearchHit> { hit -> hit.isExactTitle(normalizedQuery) }
            .thenByDescending { hit -> hit.item.popularity ?: Double.NEGATIVE_INFINITY }
            .thenByDescending { hit -> hit.item.voteCount ?: -1 }
            .thenByDescending { hit -> hit.foundIn.size }
            .thenBy { hit -> hit.firstSeen },
    ).first()
    val topGroup = SearchResultGroup(
        key = SEARCH_TOP_RESULT_GROUP_KEY,
        kind = SearchResultGroupKind.TopResult,
        type = top.item.type,
        title = SEARCH_TOP_RESULT_TITLE,
        hits = listOf(top.toHit()),
        representativeTarget = top.target,
    )
    return listOf(topGroup) + typeGroups
}

/// Result titles for the suggestion chips: names that start with the query, then names that
/// contain it, distinct ignoring case, never the query itself. No second request: Stremio search
/// catalogs have no completion endpoint, and chips taken from the rows always lead somewhere.
internal fun suggestionTitles(
    query: String,
    groups: List<SearchResultGroup>,
    limit: Int = 8,
): List<String> {
    val normalizedQuery = query.normalizedSearchText()
    if (normalizedQuery.isEmpty() || limit <= 0) return emptyList()

    val seen = mutableSetOf(normalizedQuery)
    val prefix = mutableListOf<String>()
    val contains = mutableListOf<String>()
    groups.forEach { group ->
        group.hits.forEach { hit ->
            val name = hit.item.name.trim()
            val normalizedName = name.normalizedSearchText()
            if (normalizedName.isEmpty() || !seen.add(normalizedName)) return@forEach
            when {
                normalizedName.startsWith(normalizedQuery) -> prefix += name
                normalizedName.contains(normalizedQuery) -> contains += name
            }
        }
    }
    return (prefix + contains).take(limit)
}

/// The final publish's empty reason: null while anything is showing (results or people) or while a
/// manifest is still pending, `RequestFailed` only when every catalog failed, `NoResults` otherwise
/// (including every catalog answering with an empty page).
internal fun resolveEmptyState(
    outcomes: List<SearchCatalogOutcome>,
    pending: Boolean,
    hasPeople: Boolean,
): SearchEmptyStateReason? =
    when {
        outcomes.any { outcome -> outcome is SearchCatalogOutcome.Success } -> null
        hasPeople -> null
        pending -> null
        outcomes.isNotEmpty() && outcomes.all { outcome -> outcome is SearchCatalogOutcome.Failed } ->
            SearchEmptyStateReason.RequestFailed
        else -> SearchEmptyStateReason.NoResults
    }

/// Moved from SearchRepository.kt (C2). Movie, series, anime, then alphabetical.
internal fun String.typeSortKey(): String =
    when (lowercase()) {
        "movie" -> "0_movie"
        "series" -> "1_series"
        "anime" -> "2_anime"
        else -> "9_$this"
    }

private val searchWhitespace = Regex("\\s+")

internal fun String.normalizedSearchText(): String =
    trim().lowercase().replace(searchWhitespace, " ")

private fun MergedSearchHit.isExactTitle(normalizedQuery: String): Boolean =
    normalizedQuery.isNotEmpty() && item.name.normalizedSearchText() == normalizedQuery

private fun SearchCatalogOutcome.Success.addonTier(): Int =
    when {
        isMetadataAddon -> 0
        isStreamOnlyAddon -> 2
        else -> 1
    }
