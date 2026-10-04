package com.nuvio.app.features.details

import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertNull

/**
 * Device session 2026-10-04: an add-on's "N/A" IMDb rating reached the Detail meta line as
 * "★ N/A". [knownImdbRating] drops the placeholders and passes real values through.
 */
class KnownImdbRatingTest {

    @Test
    fun placeholdersMeanNoRating() {
        for (raw in listOf(null, "", "  ", "N/A", "n/a", "NA", "-", "0", "0.0", " 0 ", "-1")) {
            assertNull(knownImdbRating(raw), "raw=$raw")
        }
    }

    @Test
    fun realRatingsPassThroughTrimmed() {
        assertEquals("7.4", knownImdbRating("7.4"))
        assertEquals("7.4", knownImdbRating(" 7.4 "))
        assertEquals("7.4/10", knownImdbRating("7.4/10"))
        assertEquals("10", knownImdbRating("10"))
    }

    @Test
    fun theParserDropsAnNaRating() {
        val payload = """
            {"meta": {"id": "tt0000001", "type": "movie", "name": "Unreleased", "imdbRating": "N/A"}}
        """.trimIndent()
        assertNull(MetaDetailsParser.parse(payload).imdbRating)
    }
}
