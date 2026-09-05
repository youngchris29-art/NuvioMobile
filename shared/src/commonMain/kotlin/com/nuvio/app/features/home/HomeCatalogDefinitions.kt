package com.nuvio.app.features.home

import com.nuvio.app.core.i18n.localizedMediaTypeLabel
import com.nuvio.app.features.addons.AddonCatalog
import com.nuvio.app.features.addons.AddonManifest
import com.nuvio.app.features.addons.ManagedAddon
import com.nuvio.app.features.addons.enabledAddons
import com.nuvio.app.features.catalog.supportsPagination
import com.nuvio.app.core.i18n.StringKey
import com.nuvio.app.core.i18n.resourceString

data class HomeCatalogDefinition(
    val key: String,
    val defaultTitle: String,
    val catalogName: String,
    val addonName: String,
    val manifestUrl: String,
    val type: String,
    val catalogId: String,
    val supportsPagination: Boolean,
    val descriptorSignature: String,
) {
    val cacheKey: String
        get() = "$key|$descriptorSignature"

    fun titleFor(showCatalogType: Boolean): String =
        if (showCatalogType) defaultTitle else catalogName
}

fun buildHomeCatalogRefreshSignature(addons: List<ManagedAddon>): List<String> =
    addons.enabledAddons().mapNotNull { addon ->
        val manifest = addon.manifest ?: return@mapNotNull null
        addon to manifest
    }.flatMap { (addon, manifest) ->
        manifest.catalogs.map { catalog ->
            buildHomeCatalogDescriptorSignature(addon, manifest, catalog)
        }
    }.sorted()

fun buildHomeCatalogDefinitions(addons: List<ManagedAddon>): List<HomeCatalogDefinition> =
    addons.enabledAddons().mapNotNull { addon ->
        val manifest = addon.manifest ?: return@mapNotNull null
        addon to manifest
    }.flatMap { (addon, manifest) ->
        manifest.catalogs
            .filter { catalog -> catalog.extra.none { it.isRequired } }
            .map { catalog ->
                HomeCatalogDefinition(
                    key = "${manifest.id}:${catalog.type}:${catalog.id}",
                    defaultTitle = resourceString(
                        "${catalog.name} - ${localizedMediaTypeLabel(catalog.type)}",
                        StringKey.home_catalog_default_title,
                        catalog.name,
                        localizedMediaTypeLabel(catalog.type),
                    ),
                    catalogName = catalog.name,
                    addonName = addon.displayTitle,
                    manifestUrl = addon.manifestUrl,
                    type = catalog.type,
                    catalogId = catalog.id,
                    supportsPagination = catalog.supportsPagination(),
                    descriptorSignature = buildHomeCatalogDescriptorSignature(addon, manifest, catalog),
                )
            }
    }.distinctBy(HomeCatalogDefinition::key)

private fun buildHomeCatalogDescriptorSignature(
    addon: ManagedAddon,
    manifest: AddonManifest,
    catalog: AddonCatalog,
): String {
    val signature = CatalogDescriptorSignature()
    // Hole E (BUG-86, Wave H): VOLATILE addon state is deliberately NOT part of this signature.
    // `displayTitle` moves whenever the cloud pull lands a server-supplied user set name,
    // `enabled` flips on every settings sync, and `isRefreshing`/`errorMessage` flip twice per
    // manifest fetch. Each flip changed the cache key of every one of that addon's sections, which
    // pruned them all out of HomeRepository's cache and forced a full network re-fetch: the grey
    // skeleton rebuild 1.1 s after first paint in the tester's cold-launch video, independent of
    // any ordering change. The signature now describes only what the catalog IS (its transport and
    // its shape), so a cosmetic rename or a refresh flag no longer invalidates fetched content.
    signature.add(addon.manifestUrl)
    signature.add(manifest.id)
    signature.add(manifest.name)
    signature.add(manifest.version)
    signature.add(manifest.description)
    signature.add(manifest.logoUrl)
    signature.add(manifest.transportUrl)
    // Each collection is size-prefixed: without the boundary, types=["movie"] + idPrefixes=["tt"]
    // would hash identically to types=["movie","tt"] + idPrefixes=[] (fork hardening over
    // upstream 191be42a, which flattens collections without boundaries).
    signature.add(manifest.types.size)
    manifest.types.forEach(signature::add)
    signature.add(manifest.idPrefixes.size)
    manifest.idPrefixes.forEach(signature::add)
    signature.add(manifest.resources.size)
    manifest.resources.forEach { resource ->
        signature.add(resource.name)
        signature.add(resource.types.size)
        resource.types.forEach(signature::add)
        signature.add(resource.idPrefixes.size)
        resource.idPrefixes.forEach(signature::add)
    }
    signature.add(manifest.behaviorHints.configurable)
    signature.add(manifest.behaviorHints.configurationRequired)
    signature.add(manifest.behaviorHints.adult)
    signature.add(manifest.behaviorHints.p2p)
    signature.add(catalog.type)
    signature.add(catalog.id)
    signature.add(catalog.name)
    signature.add(catalog.supportsPagination())
    signature.add(catalog.extra.size)
    catalog.extra.forEach { extra ->
        signature.add(extra.name)
        signature.add(extra.isRequired)
        signature.add(extra.options.size)
        extra.options.forEach(signature::add)
        signature.add(extra.optionsLimit)
    }
    return signature.value()
}

private class CatalogDescriptorSignature {
    private var hash = -3750763034362895579L

    fun add(value: String?) {
        val text = value.orEmpty()
        mix(text.length)
        text.forEach { character -> mix(character.code) }
    }

    fun add(value: Boolean) {
        mix(if (value) 1 else 0)
    }

    fun add(value: Int?) {
        mix(value ?: Int.MIN_VALUE)
    }

    fun value(): String = hash.toULong().toString(16)

    private fun mix(value: Int) {
        hash = (hash xor value.toLong()) * 1099511628211L
    }
}

fun String.displayLabel(): String = localizedMediaTypeLabel(this)
