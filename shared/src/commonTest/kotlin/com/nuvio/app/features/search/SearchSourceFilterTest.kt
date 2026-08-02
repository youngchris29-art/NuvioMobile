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
 *
 * BUG-33 defect 1 hardening (bottom half of the file): `manifestId:type:catalogId` is not
 * unique on its own, so duplicate installs and same-type+id catalogs get a `#2`/`#3` suffix
 * while first occurrences keep the legacy key byte-for-byte.
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

    private fun addon(
        manifestId: String,
        catalogs: List<AddonCatalog>,
        manifestUrl: String = "https://example.test/$manifestId/manifest.json",
    ) = ManagedAddon(
        manifestUrl = manifestUrl,
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

    /// BUG-33: the same manifest.id installed a second time under a different URL — a real
    /// tester setup (official addon + community mirror) that used to mint a duplicate key.
    private val marvelMirror = addon(
        "com.test.marvel",
        listOf(searchCatalog("movie", "mcu")),
        manifestUrl = "https://mirror.test/marvel/manifest.json",
    )

    /// BUG-33: one manifest declaring several catalogs that share type+id — the other
    /// collision source. Names differ so tests can tell the entries apart.
    private val twins = addon(
        "com.test.twins",
        listOf(
            searchCatalog("movie", "popular", name = "Popular"),
            searchCatalog("movie", "popular", name = "Popular Mirror"),
            searchCatalog("movie", "popular", name = "Popular Backup"),
        ),
    )

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

    // ---- BUG-33 defect 1 hardening: collision-proof keys ----

    @Test
    fun `duplicate addon installs get unique keys and the first occurrence is unchanged`() {
        val keys = SearchRepository.searchCatalogOptions(listOf(marvel, marvelMirror)).map { it.key }
        assertEquals(
            listOf(
                // Byte-identical to the legacy format — persisted disabled keys keep matching.
                "com.test.marvel:movie:mcu",
                "com.test.marvel:movie:mcu#2",
            ),
            keys,
        )
        assertEquals(keys.size, keys.toSet().size, "duplicate installs must not share a key")
    }

    @Test
    fun `catalogs sharing type and id inside one manifest get unique keys`() {
        val options = SearchRepository.searchCatalogOptions(listOf(twins))
        assertEquals(
            listOf(
                "com.test.twins:movie:popular",
                "com.test.twins:movie:popular#2",
                "com.test.twins:movie:popular#3",
            ),
            options.map { it.key },
        )
        assertEquals(listOf("Popular", "Popular Mirror", "Popular Backup"), options.map { it.catalogName })
    }

    @Test
    fun `disabling a suffixed duplicate drops exactly that catalog`() {
        val suffixDisabled = SearchRepository.buildSearchRequests(
            addons = listOf(twins),
            query = "dune",
            disabledCatalogKeys = setOf("com.test.twins:movie:popular#2"),
        )
        assertEquals(listOf("Popular", "Popular Backup"), suffixDisabled.map { it.catalogName })

        // The legacy (unsuffixed) key must still govern the FIRST occurrence and nothing else —
        // this is the regression that made one toggle silence several fan-out entries.
        val firstDisabled = SearchRepository.buildSearchRequests(
            addons = listOf(twins),
            query = "dune",
            disabledCatalogKeys = setOf("com.test.twins:movie:popular"),
        )
        assertEquals(listOf("Popular Mirror", "Popular Backup"), firstDisabled.map { it.catalogName })
    }

    @Test
    fun `key derivation is deterministic across repeated enumeration`() {
        val addons = listOf(cinemeta, twins, marvel, marvelMirror)
        val first = SearchRepository.searchCatalogOptions(addons).map { it.key }
        val second = SearchRepository.searchCatalogOptions(addons).map { it.key }
        // Same input ordering ⇒ same keys; no counter state survives between enumerations.
        assertEquals(first, second)
        assertEquals(
            listOf(
                "com.test.cinemeta:movie:top",
                "com.test.cinemeta:series:top",
                "com.test.twins:movie:popular",
                "com.test.twins:movie:popular#2",
                "com.test.twins:movie:popular#3",
                "com.test.marvel:movie:mcu",
                "com.test.marvel:movie:mcu#2",
            ),
            first,
        )
    }

    @Test
    fun `options and requests agree on the key universe under collisions`() {
        val addons = listOf(cinemeta, twins, marvel, marvelMirror)
        val optionKeys = SearchRepository.searchCatalogOptions(addons).map { it.key }
        assertEquals(
            optionKeys.size,
            optionKeys.toSet().size,
            "every enumerated key must be unique — SwiftUI ForEach(id: \\.key) identity depends on it",
        )

        // Disabling everything the settings pane can show silences the whole fan-out.
        assertTrue(
            SearchRepository.buildSearchRequests(addons, "iron man", optionKeys.toSet()).isEmpty(),
        )

        // And each single toggle governs exactly ONE fan-out entry — the tester-visible bug
        // ("I select only two catalogs but it searches all of them") stated as an invariant.
        optionKeys.forEach { key ->
            val remaining = SearchRepository.buildSearchRequests(addons, "iron man", setOf(key))
            assertEquals(optionKeys.size - 1, remaining.size, "disabling $key must drop exactly one catalog")
        }
    }
}
