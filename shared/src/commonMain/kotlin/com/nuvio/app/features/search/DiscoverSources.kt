package com.nuvio.app.features.search

import com.nuvio.app.features.addons.AddonCatalog
import com.nuvio.app.features.addons.AddonExtraProperty
import com.nuvio.app.features.addons.ManagedAddon
import com.nuvio.app.features.addons.enabledAddons
import com.nuvio.app.features.catalog.supportsPagination

// Search & Discover batch 2026-10-06 (C5): the Discover catalog list, read-only, for the tvOS stage
// Discover page. The helpers below moved here from SearchRepository.kt unchanged (now `internal`);
// SearchRepository's own Discover feed still calls them, so both surfaces list the same catalogs
// under the same keys and share the persisted selection.

/// One Discover selection: a type, a catalog of that type, and its genre (null = all / none).
data class DiscoverSelection(
    val type: String,
    val catalogKey: String,
    val genre: String?,
)

object DiscoverSources {
    /// Every Discover-capable catalog across the enabled add-ons with a loaded manifest, in add-on
    /// then manifest order. Pure: no state, no network. tvOS recomputes it on each
    /// `AddonRepository.uiState` emission.
    fun options(addons: List<ManagedAddon>): List<DiscoverCatalogOption> =
        buildDiscoverSources(addons.enabledAddons().filter { addon -> addon.manifest != null })

    /// Distinct catalog types, in option order.
    fun types(options: List<DiscoverCatalogOption>): List<String> =
        options.map { option -> option.type }.distinct()

    /// The persisted catalog (the same `discover_catalog_key` Search's Discover uses) when it is
    /// still offered, else the first option; null when there are no options. The genre is the
    /// catalog's resolved default: the per-catalog genre memory (plan C4) plugs in here.
    fun restoreSelection(options: List<DiscoverCatalogOption>): DiscoverSelection? =
        restoreSelection(
            options = options,
            preferredCatalogKey = DiscoverSelectionStorage.loadCatalogKey(),
            preferredGenre = null,
        )

    /// Persists the catalog key (shared with Search's Discover). [genre] is accepted for the C4
    /// per-catalog genre memory and not stored yet.
    fun saveSelection(catalogKey: String, genre: String?) {
        val key = catalogKey.trim()
        if (key.isEmpty()) return
        DiscoverSelectionStorage.saveCatalogKey(key)
    }

    /// Pure half of [restoreSelection], for tests and for the C4 genre hook.
    internal fun restoreSelection(
        options: List<DiscoverCatalogOption>,
        preferredCatalogKey: String?,
        preferredGenre: String?,
    ): DiscoverSelection? {
        val catalog = resolveDiscoverCatalog(
            sources = options,
            preferredCatalogKey = preferredCatalogKey?.trim()?.takeIf { it.isNotEmpty() },
            currentCatalogKey = null,
        ) ?: return null
        return DiscoverSelection(
            type = catalog.type,
            catalogKey = catalog.key,
            genre = catalog.resolveGenreSelection(preferredGenre),
        )
    }
}

internal fun buildDiscoverSources(addons: List<ManagedAddon>): List<DiscoverCatalogOption> =
    addons.mapNotNull { addon ->
        val manifest = addon.manifest ?: return@mapNotNull null
        addon to manifest
    }.flatMap { (addon, manifest) ->
        manifest.catalogs
            .filter { catalog -> catalog.supportsDiscover() }
            .map { catalog ->
                val genreExtra = catalog.genreExtra()
                DiscoverCatalogOption(
                    key = "${manifest.id}:${catalog.type}:${catalog.id}",
                    addonName = addon.displayTitle,
                    manifestUrl = addon.manifestUrl,
                    type = catalog.type,
                    catalogId = catalog.id,
                    catalogName = catalog.name,
                    genreOptions = genreExtra?.options.orEmpty(),
                    genreRequired = genreExtra?.isRequired == true,
                    supportsPagination = catalog.supportsPagination(),
                )
            }
    }

internal fun AddonCatalog.supportsDiscover(): Boolean {
    if (extra.any { property -> property.name == "search" && property.isRequired }) {
        return false
    }

    return extra.none { property ->
        when (property.name) {
            "genre" -> property.isRequired && property.options.isEmpty()
            "skip" -> false
            "search" -> false
            else -> property.isRequired
        }
    }
}

internal fun AddonCatalog.genreExtra(): AddonExtraProperty? =
    extra.firstOrNull { property -> property.name == "genre" }

internal fun DiscoverCatalogOption.resolveGenreSelection(requestedGenre: String?): String? =
    when {
        genreOptions.isEmpty() -> null
        requestedGenre != null && genreOptions.contains(requestedGenre) -> requestedGenre
        genreRequired -> genreOptions.firstOrNull()
        else -> null
    }
