package com.nuvio.app.features.library

import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertNull

/**
 * Review r5 (device session 2026-10-04): Detail falls back to the preview's rating, and a library
 * row can carry a synced 0 ("0.0") or an "N/A" saved before the parse fix. The preview a library
 * item opens Detail with drops both.
 */
class LibraryPreviewRatingTest {

    private fun preview(rating: String?) =
        LibraryItem(
            id = "tt0000001", type = "movie", name = "Unreleased", imdbRating = rating, savedAtEpochMs = 0L,
        ).toMetaPreview()

    @Test
    fun placeholdersAreDropped() {
        for (raw in listOf("N/A", "0.0", "0", "", null)) {
            assertNull(preview(raw).imdbRating, "raw=$raw")
        }
    }

    @Test
    fun realRatingsAreKept() {
        assertEquals("7.4", preview("7.4").imdbRating)
    }
}
