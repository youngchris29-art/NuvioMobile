package com.nuvio.app.features.collection

import com.nuvio.app.features.addons.AddonCatalog
import com.nuvio.app.features.addons.ManagedAddon
import com.nuvio.app.features.addons.enabledAddons

data class ResolvedCollectionCatalog(
    val addon: ManagedAddon,
    val catalog: AddonCatalog,
)

fun List<ManagedAddon>. findCollectionCatalog(
    source: CollectionCatalogSource,
): ResolvedCollectionCatalog? {
    val activeAddons = enabledAddons()
    val declaredAddon = activeAddons.firstOrNull { it.manifest?.id == source.addonId }
    val declaredCatalog = declaredAddon?.manifest?.catalogs?.findSourceCatalog(source)
    if (declaredAddon != null && declaredCatalog != null) {
        return ResolvedCollectionCatalog(addon = declaredAddon, catalog = declaredCatalog)
    }

    return activeAddons.firstNotNullOfOrNull { addon ->
        val catalog = addon.manifest?.catalogs?.find {
            it.id == source.catalogId && it.type == source.type
        } ?: return@firstNotNullOfOrNull null
        ResolvedCollectionCatalog(addon = addon, catalog = catalog)
    }
}

/**
 * The add-on a collection source should be requested from. When the add-on's manifest lists the
 * catalog this is the matched catalog's add-on; otherwise it is the declared add-on
 * (`manifest.id == source.addonId`) as long as it is installed and enabled. Add-ons expose
 * configurable or dynamic catalogs (e.g. FlixPatrol) that their manifest does not list, and those
 * are still served by the add-on. Null only when the add-on is missing or disabled.
 */
fun List<ManagedAddon>.findCollectionAddon(
    source: CollectionCatalogSource,
): ManagedAddon? =
    findCollectionCatalog(source)?.addon
        ?: enabledAddons().firstOrNull { it.manifest?.id == source.addonId }

/**
 * Label for a collection source whose catalog may not be listed in the add-on manifest: the saved
 * title, else a same-id catalog of the declared add-on (any type), else the id humanized
 * (`flixpatrol.netflix.us.movie` -> "Netflix US").
 */
fun List<ManagedAddon>.collectionSourceDisplayName(
    source: CollectionCatalogSource,
    savedTitle: String?,
): String {
    savedTitle?.trim()?.takeIf { it.isNotEmpty() }?.let { return it }
    val sameIdName = enabledAddons()
        .firstOrNull { it.manifest?.id == source.addonId }
        ?.manifest?.catalogs
        ?.firstOrNull { it.id == source.catalogId || it.id == source.catalogId.substringBefore(",") }
        ?.name
        ?.takeIf { it.isNotBlank() }
    return sameIdName ?: humanizeCatalogId(source.catalogId, source.addonId, source.type)
}

private val CATALOG_TYPE_TOKENS = setOf("movie", "movies", "series", "tv", "channel", "anime", "other")

internal fun humanizeCatalogId(catalogId: String, addonId: String, type: String): String {
    val addonTokens = addonId.lowercase().split('.', '-', '_').filter { it.isNotEmpty() }.toSet()
    var tokens = catalogId.substringBefore(",").split('.', '_', '-').filter { it.isNotEmpty() }
    if (tokens.size > 1) {
        val withoutPrefix = tokens.dropWhile { it.lowercase() in addonTokens }
        if (withoutPrefix.isNotEmpty()) tokens = withoutPrefix
    }
    if (tokens.size > 1 && (tokens.last().lowercase() in CATALOG_TYPE_TOKENS || tokens.last().equals(type, ignoreCase = true))) {
        tokens = tokens.dropLast(1)
    }
    if (tokens.isEmpty()) return catalogId
    return tokens.joinToString(" ") { token ->
        if (token.length == 2 && token.all { it.isLetter() }) {
            token.uppercase()
        } else {
            token.lowercase().replaceFirstChar { it.uppercase() }
        }
    }
}

fun List<AvailableCatalog>. findAvailableCatalog(
    source: CollectionCatalogSource,
): AvailableCatalog? {
    val declaredCatalogs = filter { it.addonId == source.addonId }
    return declaredCatalogs.findSourceCatalog(source)
        ?: firstOrNull { it.catalogId == source.catalogId && it.type == source.type }
}

private fun List<AddonCatalog>.findSourceCatalog(source: CollectionCatalogSource): AddonCatalog? =
    find { it.id == source.catalogId && it.type == source.type }
        ?: find { it.id == source.catalogId.substringBefore(",") && it.type == source.type }

private fun List<AvailableCatalog>.findSourceCatalog(source: CollectionCatalogSource): AvailableCatalog? =
    find { it.catalogId == source.catalogId && it.type == source.type }
        ?: find { it.catalogId == source.catalogId.substringBefore(",") && it.type == source.type }
