package com.nuvio.app.features.collection

import com.nuvio.app.features.catalog.CatalogPage
import com.nuvio.app.features.catalog.catalogPageAddedVisibleItems
import com.nuvio.app.features.catalog.catalogPageNeedsAutoAdvance
import com.nuvio.app.features.catalog.nextCatalogPaginationState
import com.nuvio.app.features.home.MetaPreview
import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertFalse
import kotlin.test.assertNull
import kotlin.test.assertTrue

/**
 * #20 (review r2): a page that adds no visible item is followed up by the repository itself
 * (the grids only ask for more when a new cell appears), bounded by the duplicate-page limit.
 */
class FolderTabPaginationTest {

    private fun page(vararg ids: String, rawItemCount: Int = ids.size, nextSkip: Int?) = CatalogPage(
        items = ids.map { MetaPreview(id = it, type = "movie", name = it) },
        rawItemCount = rawItemCount,
        nextSkip = nextSkip,
    )

    @Test
    fun `a page with no new visible item and a next skip is followed up`() {
        assertTrue(catalogPageNeedsAutoAdvance(loadedNewItems = false, nextSkip = 40))
        assertFalse(catalogPageNeedsAutoAdvance(loadedNewItems = true, nextSkip = 40), "a new cell asks itself")
        assertFalse(catalogPageNeedsAutoAdvance(loadedNewItems = false, nextSkip = null), "the list ended")
    }

    @Test
    fun `an intermediate page the unreleased filter emptied is skipped and the next one still loads`() {
        // Page 2 had 20 upcoming titles (all filtered out); the skip still advances to page 3.
        val filtered = nextCatalogPaginationState(
            supportsPagination = true, requestedSkip = 20,
            page = page(rawItemCount = 20, nextSkip = 40), loadedNewItems = false, consecutiveDuplicatePages = 0,
        )
        assertEquals(40, filtered.nextSkip)
        assertTrue(catalogPageNeedsAutoAdvance(loadedNewItems = false, nextSkip = filtered.nextSkip))
        // Page 3 has a released title: a new cell, the counter resets, the grid takes over again.
        val released = nextCatalogPaginationState(
            supportsPagination = true, requestedSkip = 40,
            page = page("released", rawItemCount = 20, nextSkip = 60), loadedNewItems = true,
            consecutiveDuplicatePages = filtered.consecutiveDuplicatePages,
        )
        assertEquals(60, released.nextSkip)
        assertEquals(0, released.consecutiveDuplicatePages)
        assertFalse(catalogPageNeedsAutoAdvance(loadedNewItems = true, nextSkip = released.nextSkip))
    }

    @Test
    fun `a first page with every item filtered out is followed up too`() {
        // Review r3: on a reset only a page with a visible item counts as having loaded one.
        assertFalse(catalogPageAddedVisibleItems(reset = true, previousCount = 0, mergedCount = 0))
        assertTrue(catalogPageAddedVisibleItems(reset = true, previousCount = 0, mergedCount = 1))
        assertFalse(catalogPageAddedVisibleItems(reset = false, previousCount = 20, mergedCount = 20))
        assertTrue(catalogPageAddedVisibleItems(reset = false, previousCount = 20, mergedCount = 21))
        val first = nextCatalogPaginationState(
            supportsPagination = true, requestedSkip = 0,
            page = page(rawItemCount = 20, nextSkip = 20), loadedNewItems = false, consecutiveDuplicatePages = 0,
        )
        assertEquals(20, first.nextSkip)
        assertTrue(catalogPageNeedsAutoAdvance(loadedNewItems = false, nextSkip = first.nextSkip))
    }

    @Test
    fun `an unlisted catalog whose server ignores skip is asked at most three more times`() {
        // Unlisted: treated as paginated; the server returns the same two items for every skip.
        var state = nextCatalogPaginationState(
            supportsPagination = true, requestedSkip = 0,
            page = page("a", "b", nextSkip = 2), loadedNewItems = true, consecutiveDuplicatePages = 0,
        )
        assertEquals(2, state.nextSkip)
        var followUps = 0
        while (catalogPageNeedsAutoAdvance(loadedNewItems = false, nextSkip = state.nextSkip)) {
            followUps += 1
            state = nextCatalogPaginationState(
                supportsPagination = true, requestedSkip = state.nextSkip!!,
                page = page("a", "b", nextSkip = state.nextSkip!! + 2), loadedNewItems = false,
                consecutiveDuplicatePages = state.consecutiveDuplicatePages,
            )
            check(followUps < 10) { "unbounded" }
        }
        assertNull(state.nextSkip, "the list ends")
        assertEquals(3, followUps)
    }

    @Test
    fun `an empty page ends an unlisted catalog at once`() {
        val state = nextCatalogPaginationState(
            supportsPagination = true, requestedSkip = 2,
            page = page(nextSkip = null), loadedNewItems = false, consecutiveDuplicatePages = 0,
        )
        assertNull(state.nextSkip)
        assertFalse(catalogPageNeedsAutoAdvance(loadedNewItems = false, nextSkip = state.nextSkip))
    }
}
