package com.nuvio.app.features.collection

import com.nuvio.app.features.addons.AddonCatalog
import com.nuvio.app.features.addons.AddonManifest
import com.nuvio.app.features.addons.ManagedAddon
import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertNotNull
import kotlin.test.assertNull

class CollectionCatalogResolverTest {

    private fun addon(
        id: String,
        catalogs: List<AddonCatalog>,
        enabled: Boolean = true,
    ) = ManagedAddon(
        manifestUrl = "https://$id.example/manifest.json",
        manifest = AddonManifest(
            id = id,
            name = id,
            description = "",
            version = "1.0.0",
            resources = emptyList(),
            types = listOf("movie", "series"),
            catalogs = catalogs,
            transportUrl = "https://$id.example",
        ),
        enabled = enabled,
    )

    private fun source(addonId: String, catalogId: String, type: String = "movie") =
        CollectionCatalogSource(addonId = addonId, type = type, catalogId = catalogId)

    private val flix = addon("flixpatrol", listOf(AddonCatalog(type = "movie", id = "top10", name = "Top 10")))

    @Test
    fun exactMatchResolvesCatalogAndAddon() {
        val resolved = listOf(flix).findCollectionCatalog(source("flixpatrol", "top10"))
        assertNotNull(resolved)
        assertEquals("Top 10", resolved.catalog.name)
        assertEquals(flix.manifestUrl, listOf(flix).findCollectionAddon(source("flixpatrol", "top10"))?.manifestUrl)
    }

    @Test
    fun commaVariantMatchesBaseCatalog() {
        val resolved = listOf(flix).findCollectionCatalog(source("flixpatrol", "top10,extra"))
        assertEquals("top10", resolved?.catalog?.id)
    }

    @Test
    fun unlistedCatalogResolvesToDeclaredAddon() {
        val src = source("flixpatrol", "flixpatrol.netflix.us.movie")
        assertNull(listOf(flix).findCollectionCatalog(src))
        assertEquals(flix.manifestUrl, listOf(flix).findCollectionAddon(src)?.manifestUrl)
    }

    @Test
    fun disabledOrMissingAddonResolvesToNull() {
        val src = source("flixpatrol", "flixpatrol.netflix.us.movie")
        assertNull(listOf(addon("flixpatrol", emptyList(), enabled = false)).findCollectionAddon(src))
        assertNull(listOf(addon("other", emptyList())).findCollectionAddon(src))
        assertNull(emptyList<ManagedAddon>().findCollectionAddon(src))
    }

    @Test
    fun displayNameSavedTitleWins() {
        val src = source("flixpatrol", "top10")
        assertEquals("My Row", listOf(flix).collectionSourceDisplayName(src, "  My Row "))
    }

    @Test
    fun displayNameUsesSameIdCatalogUnderAnotherType() {
        val src = source("flixpatrol", "top10", type = "series")
        assertEquals("Top 10", listOf(flix).collectionSourceDisplayName(src, null))
    }

    @Test
    fun displayNameHumanizesUnlistedId() {
        val src = source("flixpatrol", "flixpatrol.netflix.us.movie")
        assertEquals("Netflix US", listOf(flix).collectionSourceDisplayName(src, null))
        assertEquals("Netflix US", listOf(flix).collectionSourceDisplayName(src, "  "))
    }

    @Test
    fun displayNameForPlainId() {
        val src = source("flixpatrol", "popular")
        assertEquals("Popular", listOf(flix).collectionSourceDisplayName(src, null))
        assertEquals("Popular", emptyList<ManagedAddon>().collectionSourceDisplayName(src, null))
    }
}
