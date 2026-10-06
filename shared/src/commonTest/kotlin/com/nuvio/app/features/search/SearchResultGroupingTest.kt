package com.nuvio.app.features.search

import com.nuvio.app.features.addons.AddonManifest
import com.nuvio.app.features.addons.AddonResource
import com.nuvio.app.features.addons.ManagedAddon
import com.nuvio.app.features.addons.isStreamOnly
import com.nuvio.app.features.addons.providesMeta
import com.nuvio.app.features.catalog.CatalogTarget
import com.nuvio.app.features.home.MetaPreview
import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertFalse
import kotlin.test.assertNull
import kotlin.test.assertTrue

/// Search & Discover batch 2026-10-06 (C2): the pure grouping behind `SearchUiState.groups`,
/// `suggestions` and the final empty reason. No network: outcomes are built by hand.
class SearchResultGroupingTest {

    private val cinemeta = addon("cinemeta", "Cinemeta", resources = listOf("catalog", "meta"))
    private val tmdb = addon("tmdb", "TMDB", resources = listOf("catalog", "meta"))
    private val scraper = addon("scraper", "Scraper", resources = listOf("catalog", "stream"))
    private val lists = addon("lists", "Lists", resources = listOf("catalog"))

    @Test
    fun `addon classes`() {
        assertTrue(cinemeta.manifest!!.providesMeta())
        assertFalse(cinemeta.manifest!!.isStreamOnly())
        assertTrue(scraper.manifest!!.isStreamOnly())
        assertFalse(lists.manifest!!.providesMeta())
        assertFalse(lists.manifest!!.isStreamOnly())
    }

    @Test
    fun `metadata addons lead the merge and own the record`() {
        val fromScraper = item("tt1", "movie", "Dune", description = "scraper")
        val fromCinemeta = item("tt1", "movie", "Dune", description = "cinemeta")
        val groups = groupSearchResults(
            query = "dune",
            outcomes = listOf(
                success(scraper, "movie", listOf(fromScraper)),
                success(cinemeta, "movie", listOf(fromCinemeta)),
            ),
        )
        val movies = groups.single { it.key == "type:movie" }
        assertEquals("cinemeta", movies.hits.single().item.description)
        assertEquals(listOf("Cinemeta", "Scraper"), movies.hits.single().foundIn)
        // The row's target is the first contributing catalog's search target (Cinemeta's).
        assertEquals("https://cinemeta.example/manifest.json", (movies.representativeTarget as CatalogTarget.Addon).manifestUrl)
    }

    @Test
    fun `stream only addon is capped across its catalogs`() {
        val policy = SearchGroupingPolicy(perStreamOnlyAddonCap = 3, topResult = false)
        val groups = groupSearchResults(
            query = "x",
            outcomes = listOf(
                success(scraper, "movie", (1..2).map { item("m$it", "movie", "Movie $it") }, catalogId = "a"),
                success(scraper, "series", (1..4).map { item("s$it", "series", "Show $it") }, catalogId = "b"),
            ),
            policy = policy,
        )
        assertEquals(2, groups.single { it.key == "type:movie" }.hits.size)
        assertEquals(1, groups.single { it.key == "type:series" }.hits.size)
    }

    @Test
    fun `per catalog cap applies to every addon`() {
        val groups = groupSearchResults(
            query = "x",
            outcomes = listOf(success(lists, "movie", (1..10).map { item("m$it", "movie", "Movie $it") })),
            policy = SearchGroupingPolicy(perCatalogCap = 4, perStreamOnlyAddonCap = 1, topResult = false),
        )
        // Catalog-only add-ons are not stream-only: only the per-catalog cap applies.
        assertEquals(4, groups.single().hits.size)
    }

    @Test
    fun `duplicates keep the first record and accumulate found in once`() {
        val groups = groupSearchResults(
            query = "alien",
            outcomes = listOf(
                success(cinemeta, "movie", listOf(item("tt2", "movie", "Alien"), item("tt3", "movie", "Aliens"))),
                success(tmdb, "movie", listOf(item("tt3", "movie", "Aliens (TMDB)"), item("tt2", "movie", "Alien"))),
                success(tmdb, "movie", listOf(item("tt2", "movie", "Alien")), catalogId = "second"),
            ),
            policy = SearchGroupingPolicy(topResult = false),
        )
        val hits = groups.single().hits
        assertEquals(listOf("tt2", "tt3"), hits.map { it.item.id })
        assertEquals("Aliens", hits[1].item.name)
        assertEquals(listOf("Cinemeta", "TMDB"), hits[0].foundIn)
    }

    @Test
    fun `type rows order movie series anime then alphabetical`() {
        val groups = groupSearchResults(
            query = "x",
            outcomes = listOf(
                success(cinemeta, "tv", listOf(item("c1", "tv", "Channel"))),
                success(cinemeta, "anime", listOf(item("a1", "anime", "Anime"))),
                success(cinemeta, "series", listOf(item("s1", "series", "Show"))),
                success(cinemeta, "documentary", listOf(item("d1", "documentary", "Doc"))),
                success(cinemeta, "movie", listOf(item("m1", "movie", "Film"))),
            ),
            policy = SearchGroupingPolicy(topResult = false),
        )
        assertEquals(
            listOf("type:movie", "type:series", "type:anime", "type:documentary", "type:tv"),
            groups.map { it.key },
        )
        assertTrue(groups.all { it.kind == SearchResultGroupKind.Type })
    }

    @Test
    fun `exact title leads its row and wins the top result over popularity`() {
        val groups = groupSearchResults(
            query = "  The   Thing ",
            outcomes = listOf(
                success(
                    cinemeta,
                    "movie",
                    listOf(
                        item("tt10", "movie", "The Thing Called Love", popularity = 900.0),
                        item("tt11", "movie", "The Thing", popularity = 10.0),
                    ),
                ),
            ),
        )
        assertEquals(SearchResultGroupKind.TopResult, groups.first().kind)
        assertEquals("top", groups.first().key)
        assertEquals("tt11", groups.first().hits.single().item.id)
        assertEquals(listOf("tt11", "tt10"), groups.single { it.key == "type:movie" }.hits.map { it.item.id })
    }

    @Test
    fun `top result falls back to popularity then vote count then addon count`() {
        val byPopularity = groupSearchResults(
            query = "star",
            outcomes = listOf(
                success(cinemeta, "movie", listOf(item("a", "movie", "Star A", popularity = 5.0), item("b", "movie", "Star B", popularity = 50.0))),
            ),
        )
        assertEquals("b", byPopularity.first().hits.single().item.id)

        val byVotes = groupSearchResults(
            query = "star",
            outcomes = listOf(
                success(cinemeta, "movie", listOf(item("a", "movie", "Star A", voteCount = 10), item("b", "movie", "Star B", voteCount = 900))),
            ),
        )
        assertEquals("b", byVotes.first().hits.single().item.id)

        val byAddons = groupSearchResults(
            query = "star",
            outcomes = listOf(
                success(cinemeta, "movie", listOf(item("a", "movie", "Star A"), item("b", "movie", "Star B"))),
                success(tmdb, "movie", listOf(item("b", "movie", "Star B"))),
            ),
        )
        assertEquals("b", byAddons.first().hits.single().item.id)
        // The top hit stays in its type row too.
        assertEquals(listOf("a", "b"), byAddons.single { it.key == "type:movie" }.hits.map { it.item.id })
    }

    @Test
    fun `top result can be switched off`() {
        val groups = groupSearchResults(
            query = "x",
            outcomes = listOf(success(cinemeta, "movie", listOf(item("a", "movie", "X")))),
            policy = SearchGroupingPolicy(topResult = false),
        )
        assertTrue(groups.none { it.kind == SearchResultGroupKind.TopResult })
        assertEquals(emptyList(), groupSearchResults("x", emptyList()))
    }

    @Test
    fun `suggestions are prefix first then contains without the query`() {
        val groups = groupSearchResults(
            query = "star",
            outcomes = listOf(
                success(
                    cinemeta,
                    "movie",
                    listOf(
                        item("1", "movie", "Lone Star"),
                        item("2", "movie", "Star"),
                        item("3", "movie", "Star Wars"),
                        item("4", "movie", "Unrelated"),
                        item("5", "movie", "star wars"),
                        item("6", "movie", "Starship Troopers"),
                    ),
                ),
            ),
        )
        assertEquals(listOf("Star Wars", "Starship Troopers", "Lone Star"), suggestionTitles("Star", groups))
        assertEquals(listOf("Star Wars"), suggestionTitles("star", groups, limit = 1))
        assertEquals(emptyList(), suggestionTitles("  ", groups))
    }

    @Test
    fun `empty state reasons`() {
        val emptyOutcome = SearchCatalogOutcome.Empty(request(cinemeta, "movie"))
        val failedOutcome = SearchCatalogOutcome.Failed(request(tmdb, "movie"), IllegalStateException("boom"))
        val successOutcome = success(cinemeta, "movie", listOf(item("a", "movie", "A")))

        assertEquals(SearchEmptyStateReason.NoResults, resolveEmptyState(emptyList(), pending = false, hasPeople = false))
        assertEquals(SearchEmptyStateReason.NoResults, resolveEmptyState(listOf(emptyOutcome), pending = false, hasPeople = false))
        assertEquals(SearchEmptyStateReason.NoResults, resolveEmptyState(listOf(emptyOutcome, failedOutcome), pending = false, hasPeople = false))
        assertEquals(SearchEmptyStateReason.RequestFailed, resolveEmptyState(listOf(failedOutcome), pending = false, hasPeople = false))
        assertNull(resolveEmptyState(listOf(failedOutcome), pending = true, hasPeople = false))
        assertNull(resolveEmptyState(listOf(failedOutcome), pending = false, hasPeople = true))
        assertNull(resolveEmptyState(listOf(failedOutcome, successOutcome), pending = false, hasPeople = false))
    }

    @Test
    fun `snapshot keeps per addon sections in fan out order`() {
        val snapshot = buildSearchResultsSnapshot(
            query = "a",
            outcomes = listOf(
                success(scraper, "movie", listOf(item("s", "movie", "A scraper"))),
                SearchCatalogOutcome.Empty(request(lists, "movie")),
                success(cinemeta, "movie", listOf(item("c", "movie", "A cinemeta"))),
            ),
        )
        assertEquals(listOf("Scraper", "Cinemeta"), snapshot.sections.map { it.addonName })
        assertEquals(listOf("top", "type:movie"), snapshot.groups.map { it.key })
        assertEquals(listOf("A cinemeta", "A scraper"), snapshot.suggestions)
    }

    private fun addon(id: String, name: String, resources: List<String>): ManagedAddon =
        ManagedAddon(
            manifestUrl = "https://$id.example/manifest.json",
            manifest = AddonManifest(
                id = id,
                name = name,
                description = "",
                version = "1.0.0",
                resources = resources.map { AddonResource(name = it, types = listOf("movie", "series")) },
                types = listOf("movie", "series"),
                transportUrl = "https://$id.example/manifest.json",
            ),
        )

    private fun request(addon: ManagedAddon, type: String, catalogId: String = "search"): SearchCatalogRequest =
        SearchCatalogRequest(
            addon = addon,
            catalogId = catalogId,
            catalogName = "Search",
            type = type,
            query = "q",
            supportsPagination = false,
            key = "${addon.manifest!!.id}:$type:$catalogId",
        )

    private fun success(
        addon: ManagedAddon,
        type: String,
        items: List<MetaPreview>,
        catalogId: String = "search",
    ): SearchCatalogOutcome.Success {
        val request = request(addon, type, catalogId)
        return SearchCatalogOutcome.Success(
            request = request,
            items = items,
            section = request.toSection(items = items, manifestTransportUrl = addon.manifestUrl),
        )
    }

    private fun item(
        id: String,
        type: String,
        name: String,
        description: String? = null,
        popularity: Double? = null,
        voteCount: Int? = null,
    ): MetaPreview =
        MetaPreview(
            id = id,
            type = type,
            name = name,
            description = description,
            popularity = popularity,
            voteCount = voteCount,
        )
}
