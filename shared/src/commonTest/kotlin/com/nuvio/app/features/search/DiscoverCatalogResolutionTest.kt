package com.nuvio.app.features.search

import com.nuvio.app.features.addons.AddonCatalog
import com.nuvio.app.features.addons.AddonExtraProperty
import com.nuvio.app.features.addons.AddonManifest
import com.nuvio.app.features.addons.AddonResource
import com.nuvio.app.features.addons.ManagedAddon
import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertNull

/**
 * Upstream ab57cf1b coverage for [resolveDiscoverCatalog], the pure half of "the Discover tab
 * remembers the last-picked catalog across cold starts": the persisted preference wins while the
 * catalog still exists, the in-memory selection is the next fallback, and the first source is the
 * last resort. Upstream carries the first two cases in its SearchRequestStateTest, which has no
 * counterpart here — the fork replaced `canReuseRequestState`/`DiscoverRequestKey` with
 * `canReuseDiscoverState`.
 */
class DiscoverCatalogResolutionTest {

    @Test
    fun `preferred discover catalog is restored ahead of current fallback`() {
        val fallback = discoverCatalog(key = "fallback", type = "movie")
        val preferred = discoverCatalog(key = "preferred", type = "series")

        val selected = resolveDiscoverCatalog(
            sources = listOf(fallback, preferred),
            preferredCatalogKey = preferred.key,
            currentCatalogKey = fallback.key,
        )

        assertEquals(preferred, selected)
    }

    @Test
    fun `current discover catalog remains when preference is unavailable`() {
        val current = discoverCatalog(key = "current", type = "movie")

        val selected = resolveDiscoverCatalog(
            sources = listOf(discoverCatalog(key = "first", type = "movie"), current),
            preferredCatalogKey = "unavailable",
            currentCatalogKey = current.key,
        )

        assertEquals(current, selected)
    }

    @Test
    fun `first source wins when neither key resolves`() {
        val first = discoverCatalog(key = "first", type = "movie")

        assertEquals(
            first,
            resolveDiscoverCatalog(
                sources = listOf(first, discoverCatalog(key = "second", type = "series")),
                preferredCatalogKey = null,
                currentCatalogKey = "gone",
            ),
        )
        assertNull(
            resolveDiscoverCatalog(
                sources = emptyList(),
                preferredCatalogKey = "preferred",
                currentCatalogKey = "current",
            ),
        )
    }

    // Search & Discover batch 2026-10-06 (C5): DiscoverSources, the read-only catalog list behind
    // the stage Discover page.

    @Test
    fun `options keep discover catalogs of enabled loaded addons only`() {
        val addon = addon(
            id = "cinemeta",
            catalogs = listOf(
                AddonCatalog(type = "movie", id = "top", name = "Popular"),
                AddonCatalog(
                    type = "movie",
                    id = "search",
                    name = "Search",
                    extra = listOf(AddonExtraProperty(name = "search", isRequired = true)),
                ),
                AddonCatalog(
                    type = "series",
                    id = "genres",
                    name = "By Genre",
                    extra = listOf(AddonExtraProperty(name = "genre", isRequired = true, options = listOf("Drama", "Comedy"))),
                ),
                AddonCatalog(
                    type = "series",
                    id = "needs-genre",
                    name = "Needs Genre",
                    extra = listOf(AddonExtraProperty(name = "genre", isRequired = true)),
                ),
                AddonCatalog(
                    type = "movie",
                    id = "optional-search",
                    name = "Browse",
                    extra = listOf(AddonExtraProperty(name = "search"), AddonExtraProperty(name = "skip")),
                ),
            ),
        )
        val disabled = addon(id = "off", catalogs = listOf(AddonCatalog(type = "movie", id = "x", name = "X"))).copy(enabled = false)
        val unloaded = ManagedAddon(manifestUrl = "https://unloaded.example/manifest.json", isRefreshing = true)

        val options = DiscoverSources.options(listOf(addon, disabled, unloaded))

        assertEquals(
            listOf("cinemeta:movie:top", "cinemeta:series:genres", "cinemeta:movie:optional-search"),
            options.map { it.key },
        )
        assertEquals(listOf("Drama", "Comedy"), options[1].genreOptions)
        assertEquals(listOf("movie", "series"), DiscoverSources.types(options))
        assertEquals(emptyList(), DiscoverSources.options(emptyList()))
    }

    @Test
    fun `restore selection prefers the persisted catalog and its genre`() {
        val movies = discoverCatalog(key = "movies", type = "movie")
        val series = discoverCatalog(key = "series", type = "series")
            .copy(genreOptions = listOf("Drama", "Comedy"), genreRequired = true)
        val options = listOf(movies, series)

        assertEquals(
            DiscoverSelection(type = "series", catalogKey = "series", genre = "Comedy"),
            DiscoverSources.restoreSelection(options, preferredCatalogKey = " series ", preferredGenre = "Comedy"),
        )
        // An unknown genre falls back to the catalog's default (first option when required).
        assertEquals(
            DiscoverSelection(type = "series", catalogKey = "series", genre = "Drama"),
            DiscoverSources.restoreSelection(options, preferredCatalogKey = "series", preferredGenre = "Horror"),
        )
        // A key that is gone falls back to the first option.
        assertEquals(
            DiscoverSelection(type = "movie", catalogKey = "movies", genre = null),
            DiscoverSources.restoreSelection(options, preferredCatalogKey = "gone", preferredGenre = null),
        )
    }

    @Test
    fun `restore selection is null without options`() {
        assertNull(DiscoverSources.restoreSelection(emptyList(), preferredCatalogKey = "movies", preferredGenre = null))
        assertNull(DiscoverSources.restoreSelection(emptyList()))
    }

    private fun addon(id: String, catalogs: List<AddonCatalog>): ManagedAddon =
        ManagedAddon(
            manifestUrl = "https://$id.example/manifest.json",
            manifest = AddonManifest(
                id = id,
                name = id,
                description = "",
                version = "1.0.0",
                resources = listOf(AddonResource(name = "catalog", types = listOf("movie", "series"))),
                types = listOf("movie", "series"),
                catalogs = catalogs,
                transportUrl = "https://$id.example/manifest.json",
            ),
        )

    private fun discoverCatalog(key: String, type: String): DiscoverCatalogOption =
        DiscoverCatalogOption(
            key = key,
            addonName = "Addon",
            manifestUrl = "https://example.com/manifest.json",
            type = type,
            catalogId = key,
            catalogName = key,
        )
}
