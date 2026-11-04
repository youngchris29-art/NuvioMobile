package com.nuvio.app.features.collection

import com.nuvio.app.features.catalog.CatalogPage
import com.nuvio.app.features.home.MetaPreview
import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertNull

/** #20 (review r1): an unlisted catalog's pagination ends on a repeated page. */
class FolderTabPaginationTest {

    private fun page(vararg ids: String, nextSkip: Int?) = CatalogPage(
        items = ids.map { MetaPreview(id = it, type = "movie", name = it) },
        rawItemCount = ids.size,
        nextSkip = nextSkip,
    )

    @Test
    fun `an unlisted catalog that ignores skip ends on the first duplicate page`() {
        val state = folderTabPaginationState(
            isUnlistedCatalog = true, supportsPagination = true, requestedSkip = 2,
            page = page("a", "b", nextSkip = 4), loadedNewItems = false, consecutiveDuplicatePages = 0,
        )
        assertNull(state.nextSkip)
        assertEquals(1, state.consecutiveDuplicatePages)
    }

    @Test
    fun `an unlisted catalog keeps paging while pages add items and ends on an empty page`() {
        val more = folderTabPaginationState(
            isUnlistedCatalog = true, supportsPagination = true, requestedSkip = 0,
            page = page("a", "b", nextSkip = 2), loadedNewItems = true, consecutiveDuplicatePages = 0,
        )
        assertEquals(2, more.nextSkip)
        val empty = folderTabPaginationState(
            isUnlistedCatalog = true, supportsPagination = true, requestedSkip = 2,
            page = page(nextSkip = null), loadedNewItems = false, consecutiveDuplicatePages = 0,
        )
        assertNull(empty.nextSkip)
    }

    @Test
    fun `a listed catalog still advances past a duplicate page`() {
        val state = folderTabPaginationState(
            isUnlistedCatalog = false, supportsPagination = true, requestedSkip = 2,
            page = page("a", "b", nextSkip = 4), loadedNewItems = false, consecutiveDuplicatePages = 0,
        )
        assertEquals(4, state.nextSkip)
        assertEquals(1, state.consecutiveDuplicatePages)
    }
}
