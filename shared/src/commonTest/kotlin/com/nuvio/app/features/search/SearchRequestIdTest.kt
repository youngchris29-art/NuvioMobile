package com.nuvio.app.features.search

import com.nuvio.app.features.addons.AddonCatalog
import com.nuvio.app.features.addons.AddonExtraProperty
import com.nuvio.app.features.addons.AddonManifest
import com.nuvio.app.features.addons.AddonResource
import com.nuvio.app.features.addons.ManagedAddon
import kotlinx.coroutines.awaitCancellation
import kotlin.test.AfterTest
import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertNull
import kotlin.test.assertTrue

/// Search & Discover batch 2026-10-06 (C1): every `search()`/`clear()`/`reset()` mints a new
/// [SearchUiState.requestId], a same-key dedupe hands back the live id, and a publish carrying a
/// stale id is dropped — the compare-and-set that closes the S1 cancelled-search late-write race.
/// The network fetch is replaced by a seam that never returns, so nothing here leaves the process.
class SearchRequestIdTest {

    @AfterTest
    fun tearDown() {
        SearchRepository.searchPageFetcherForTest = null
        SearchRepository.reset()
    }

    @Test
    fun `search clear and reset each publish a newer id`() {
        SearchRepository.reset()
        val afterReset = SearchRepository.uiState.value.requestId

        val noAddons = SearchRepository.search(query = "dune", addons = emptyList())
        assertTrue(noAddons > afterReset)
        assertEquals(noAddons, SearchRepository.uiState.value.requestId)
        assertEquals("dune", SearchRepository.uiState.value.query)
        assertEquals(SearchEmptyStateReason.NoActiveAddons, SearchRepository.uiState.value.emptyStateReason)

        SearchRepository.clear()
        val afterClear = SearchRepository.uiState.value.requestId
        assertTrue(afterClear > noAddons)
        assertNull(SearchRepository.uiState.value.query)

        val blank = SearchRepository.search(query = "   ", addons = emptyList())
        assertTrue(blank > afterClear)
        assertEquals(blank, SearchRepository.uiState.value.requestId)

        SearchRepository.reset()
        assertTrue(SearchRepository.uiState.value.requestId > blank)
    }

    @Test
    fun `same key search is deduped and keeps the live id`() {
        SearchRepository.searchPageFetcherForTest = { awaitCancellation() }
        SearchRepository.reset()

        val first = SearchRepository.search(query = "Dune", addons = listOf(searchableAddon()))
        assertEquals(first, SearchRepository.uiState.value.requestId)
        assertTrue(SearchRepository.uiState.value.isLoading)
        assertEquals("Dune", SearchRepository.uiState.value.query)

        // Same normalized key (case and padding differ): no new publish, same id back.
        val repeat = SearchRepository.search(query = "  dune ", addons = listOf(searchableAddon()))
        assertEquals(first, repeat)
        assertEquals(first, SearchRepository.uiState.value.requestId)

        // forceRefresh bypasses the dedupe and mints a new id.
        val forced = SearchRepository.search(
            query = "dune",
            addons = listOf(searchableAddon()),
            forceRefresh = true,
        )
        assertTrue(forced > first)
        assertEquals(forced, SearchRepository.uiState.value.requestId)
    }

    @Test
    fun `publish with a stale id is a no-op`() {
        SearchRepository.reset()
        val stale = SearchRepository.search(query = "alien", addons = emptyList())
        val live = SearchRepository.search(query = "aliens", addons = emptyList())

        SearchRepository.publishForTest(stale) {
            SearchUiState(emptyStateReason = SearchEmptyStateReason.NoResults, query = "alien")
        }
        assertEquals(live, SearchRepository.uiState.value.requestId)
        assertEquals("aliens", SearchRepository.uiState.value.query)
        assertEquals(SearchEmptyStateReason.NoActiveAddons, SearchRepository.uiState.value.emptyStateReason)

        SearchRepository.publishForTest(live) { current ->
            current.copy(emptyStateReason = SearchEmptyStateReason.NoResults, requestId = 999L)
        }
        // The live publish lands, and the id it carries is the publisher's, not the transform's.
        assertEquals(live, SearchRepository.uiState.value.requestId)
        assertEquals(SearchEmptyStateReason.NoResults, SearchRepository.uiState.value.emptyStateReason)
    }

    private fun searchableAddon(): ManagedAddon =
        ManagedAddon(
            manifestUrl = "https://search.example/manifest.json",
            manifest = AddonManifest(
                id = "search.example",
                name = "Search Example",
                description = "",
                version = "1.0.0",
                resources = listOf(AddonResource(name = "meta", types = listOf("movie"))),
                types = listOf("movie"),
                catalogs = listOf(
                    AddonCatalog(
                        type = "movie",
                        id = "search",
                        name = "Search",
                        extra = listOf(AddonExtraProperty(name = "search", isRequired = true)),
                    ),
                ),
                transportUrl = "https://search.example/manifest.json",
            ),
        )
}
