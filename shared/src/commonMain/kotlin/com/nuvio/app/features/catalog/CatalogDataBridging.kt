package com.nuvio.app.features.catalog

/*
 * Search & Discover batch 2026-10-06 (O3 Stage Discover): fork-only Swift bridging for
 * [fetchCatalogPage] (same pattern as `features/details/MetaDetailsRepositoryBridging.kt`).
 *
 * A Kotlin exception crossing into Swift from a suspend function WITHOUT `@Throws` aborts the
 * process: the plain export only converts `CancellationException`, and [fetchCatalogPage] throws on
 * any HTTP or parse failure (a dead add-on, a 404 genre, no network). The tvOS stage Discover page
 * fetches one page per genre row straight from Swift, so it goes through this twin and gets a
 * catchable error (`try await CatalogDataBridgingKt.fetchCatalogPageChecked(...)`). The ObjC export
 * drops default arguments, so every parameter is explicit. Behaviour is exactly [fetchCatalogPage]'s.
 */

/** [fetchCatalogPage], callable from Swift with `try await`. */
@Throws(Throwable::class)
suspend fun fetchCatalogPageChecked(
    manifestUrl: String,
    type: String,
    catalogId: String,
    genre: String?,
    maxItems: Int,
    forceRefresh: Boolean,
): CatalogPage = fetchCatalogPage(
    manifestUrl = manifestUrl,
    type = type,
    catalogId = catalogId,
    genre = genre,
    search = null,
    skip = null,
    maxItems = maxItems,
    forceRefresh = forceRefresh,
)
