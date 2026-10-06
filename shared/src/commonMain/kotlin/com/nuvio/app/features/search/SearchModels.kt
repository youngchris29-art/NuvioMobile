package com.nuvio.app.features.search

import com.nuvio.app.features.tmdb.PersonPreview
import com.nuvio.app.features.catalog.CatalogTarget
import com.nuvio.app.features.home.MetaPreview
import com.nuvio.app.features.home.HomeCatalogSection

enum class SearchEmptyStateReason {
    NoActiveAddons,
    NoSearchCatalogs,
    NoResults,
    RequestFailed,
}

data class SearchUiState(
    val isLoading: Boolean = false,
    val sections: List<HomeCatalogSection> = emptyList(),
    val emptyStateReason: SearchEmptyStateReason? = null,
    val errorMessage: String? = null,
    /// BUG-33 defect 1 instrumentation: a compact, human-readable line describing the last
    /// `search()` call's fan-out — how many search-capable catalogs were queried vs. filtered
    /// out by Search Sources, and which ones (display names, not keys). Set by `search()`
    /// right after `buildSearchRequests`; null until the first search of this app session (or
    /// after `clear()`/`reset()`). Shown verbatim in Settings → Content Sources → Search
    /// Sources so a tester can screenshot one line instead of a device log capture.
    val lastFanOut: String? = null,
    /// Search & Discover batch 2026-10-06 (C1): the id of the `search()`/`clear()`/`reset()` call
    /// this state answers. Monotonic per repository; every publish of a running search is a
    /// compare-and-set on it, so a cancelled search's late write can never overwrite a newer one
    /// (the S1 late-write race). `search()` returns the id it published or re-used, which is how
    /// tvOS's `SearchRowsHold` tells a stale emission from the active one.
    val requestId: Long = 0L,
    /// The normalized (trimmed) query this state answers; null for the cleared/idle state. Lets the
    /// UI say "No results for '…'" without echoing whatever is in the field right now.
    val query: String? = null,
    /// C2: the same results as [sections], merged across add-ons and grouped (a Top result, then
    /// one row per media type). Built from the same outcomes on every publish, so a UI can switch
    /// between grouped rows and per-add-on [sections] without a refetch.
    val groups: List<SearchResultGroup> = emptyList(),
    /// C2: up to eight result titles that start with (then contain) the query, excluding the query
    /// itself. Derived from the merged results, never from a second request.
    val suggestions: List<String> = emptyList(),
    /// C3: TMDB people matching the query. Filled by a sibling coroutine, so add-on rows are never
    /// delayed by it; empty when TMDB is off or nothing matched.
    val people: List<PersonPreview> = emptyList(),
    /// C3: true from the start of a search until the people lookup answers (TMDB enabled only).
    /// Independent of [isLoading], which stays add-on-only.
    val peopleLoading: Boolean = false,
)

/// Search & Discover batch 2026-10-06 (C2). Swift sees `.topresult` / `.type`.
enum class SearchResultGroupKind {
    TopResult,
    Type,
}

/// One merged search result. [foundIn] lists the add-on display names that returned it, metadata
/// add-ons first, distinct.
data class SearchHit(
    val item: MetaPreview,
    val foundIn: List<String>,
)

/// A grouped search row. [key] is `"top"` for the Top result or `"type:<type>"`; [type] is the
/// media type of the row (for the Top result, the type of its one hit). [representativeTarget] is
/// the search target of the first catalog that contributed to the row, so a UI that needs a
/// `HomeCatalogSection`-shaped row has a target to hand it; grouped rows have no See All.
data class SearchResultGroup(
    val key: String,
    val kind: SearchResultGroupKind,
    val type: String?,
    val title: String,
    val hits: List<SearchHit>,
    val representativeTarget: CatalogTarget,
)

/// Caps applied while merging: [perCatalogCap] items per catalog, [perStreamOnlyAddonCap] items in
/// total per stream-only add-on (by manifest URL), and whether to pick a Top result.
data class SearchGroupingPolicy(
    val perCatalogCap: Int = 40,
    val perStreamOnlyAddonCap: Int = 8,
    val topResult: Boolean = true,
)

enum class DiscoverEmptyStateReason {
    NoActiveAddons,
    NoDiscoverCatalogs,
    NoResults,
    RequestFailed,
}

/// One search-capable catalog, as shown in the tvOS "Search Sources" settings (FEAT-10).
/// [key] is the stable identity persisted when the user disables a source — same
/// `manifestId:type:catalogId` shape as [DiscoverCatalogOption.key].
data class SearchCatalogOption(
    val key: String,
    val addonName: String,
    val catalogName: String,
    val type: String,
    /// Localized media-type label ("Movies", "Series", …) resolved at construction so UI
    /// layers can render it without reaching back into shared string helpers.
    val typeLabel: String,
)

data class DiscoverCatalogOption(
    val key: String,
    val addonName: String,
    val manifestUrl: String,
    val type: String,
    val catalogId: String,
    val catalogName: String,
    val genreOptions: List<String> = emptyList(),
    val genreRequired: Boolean = false,
    val supportsPagination: Boolean = false,
)

data class DiscoverUiState(
    val typeOptions: List<String> = emptyList(),
    val selectedType: String? = null,
    val catalogOptions: List<DiscoverCatalogOption> = emptyList(),
    val selectedCatalogKey: String? = null,
    val selectedGenre: String? = null,
    val items: List<MetaPreview> = emptyList(),
    val isLoading: Boolean = false,
    val nextSkip: Int? = null,
    val consecutiveDuplicatePages: Int = 0,
    val emptyStateReason: DiscoverEmptyStateReason? = null,
    val errorMessage: String? = null,
) {
    val selectedCatalog: DiscoverCatalogOption?
        get() = catalogOptions.firstOrNull { it.key == selectedCatalogKey }

    val genreOptions: List<String>
        get() = selectedCatalog?.genreOptions.orEmpty()

    val canLoadMore: Boolean
        get() = nextSkip != null
}
