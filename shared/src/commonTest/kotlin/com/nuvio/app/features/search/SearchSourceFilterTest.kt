package com.nuvio.app.features.search

import com.nuvio.app.features.addons.AddonCatalog
import com.nuvio.app.features.addons.AddonExtraProperty
import com.nuvio.app.features.addons.AddonManifest
import com.nuvio.app.features.addons.ManagedAddon
import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertTrue

/**
 * FEAT-10 coverage: the Search Sources setting filters the search fan-out by stable catalog
 * key (`manifestId:type:catalogId`), and [SearchRepository.searchCatalogOptions] enumerates
 * exactly the catalogs the fan-out would hit (same keys, same order).
 */
class SearchSourceFilterTest {

    private fun searchCatalog(type: String, id: String, name: String = id) = AddonCatalog(
        type = type,
        id = id,
        name = name,
        extra = listOf(AddonExtraProperty(name = "search")),
    )

    /// A catalog with a required non-search extra is not search-capable and must never
    /// appear in options or requests.
    private fun nonSearchCatalog(type: String, id: String) = AddonCatalog(
        type = type,
        id = id,
        name = id,
        extra = listOf(AddonExtraProperty(name = "genre", isRequired = true)),
    )

    private fun addon(manifestId: String, catalogs: List<AddonCatalog>) = ManagedAddon(
        manifestUrl = "https://example.test/$manifestId/manifest.json",
        manifest = AddonManifest(
            id = manifestId,
            name = manifestId,
            description = "",
            version = "1.0.0",
            resources = emptyList(),
            types = catalogs.map { it.type }.distinct(),
            catalogs = catalogs,
            transportUrl = "https://example.test/$manifestId",
        ),
    )

    private val cinemeta = addon(
        "com.test.cinemeta",
        listOf(
            searchCatalog("movie", "top"),
            searchCatalog("series", "top"),
            nonSearchCatalog("movie", "genre-only"),
        ),
    )
    private val marvel = addon("com.test.marvel", listOf(searchCatalog("movie", "mcu")))

    @Test
    fun `options enumerate exactly the search-capable catalogs with stable keys`() {
        val options = SearchRepository.searchCatalogOptions(listOf(cinemeta, marvel))
        assertEquals(
            listOf(
                "com.test.cinemeta:movie:top",
                "com.test.cinemeta:series:top",
                "com.test.marvel:movie:mcu",
            ),
            options.map { it.key },
        )
        assertTrue(options.none { it.catalogName == "genre-only" })
    }

    @Test
    fun `empty disabled set keeps the full fan-out`() {
        val requests = SearchRepository.buildSearchRequests(
            addons = listOf(cinemeta, marvel),
            query = "iron man",
        )
        assertEquals(3, requests.size)
    }

    @Test
    fun `disabled keys drop exactly their catalogs`() {
        val requests = SearchRepository.buildSearchRequests(
            addons = listOf(cinemeta, marvel),
            query = "iron man",
            disabledCatalogKeys = setOf(
                "com.test.cinemeta:series:top",
                "com.test.marvel:movie:mcu",
            ),
        )
        assertEquals(1, requests.size)
        assertEquals("top", requests.single().catalogId)
        assertEquals("movie", requests.single().type)
    }

    @Test
    fun `unknown keys are ignored`() {
        val requests = SearchRepository.buildSearchRequests(
            addons = listOf(marvel),
            query = "thor",
            disabledCatalogKeys = setOf("com.gone.addon:movie:old", "not-even-a-key"),
        )
        assertEquals(1, requests.size)
    }

    @Test
    fun `disabling every source empties the fan-out`() {
        val requests = SearchRepository.buildSearchRequests(
            addons = listOf(marvel),
            query = "thor",
            disabledCatalogKeys = setOf("com.test.marvel:movie:mcu"),
        )
        assertTrue(requests.isEmpty(), "search() then reports NoSearchCatalogs — the existing empty state")
    }

    @Test
    fun `options and requests agree on the key universe`() {
        val addons = listOf(cinemeta, marvel)
        val optionKeys = SearchRepository.searchCatalogOptions(addons).map { it.key }.toSet()
        // Disabling every enumerated option must silence the whole fan-out — proves the
        // settings UI's keys and the filter's keys can never drift apart.
        val requests = SearchRepository.buildSearchRequests(
            addons = addons,
            query = "iron man",
            disabledCatalogKeys = optionKeys,
        )
        assertTrue(requests.isEmpty())
    }
}
