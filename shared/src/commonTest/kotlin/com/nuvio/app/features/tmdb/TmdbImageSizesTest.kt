package com.nuvio.app.features.tmdb

import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertNull

/**
 * I1 (Steven beta.19-rc1 verdict, 2026-10-03; tracker BUG-134): posters are built at w780 so a lifted
 * Large card on a 4K Apple TV is not upscaled from a 500 px file. Title logos deliberately stay at w500 in
 * the data (the Home hero fetches them inside its swap deadline); tvOS asks for `original` at draw time.
 */
class TmdbImageSizesTest {

    @Test
    fun posterSizeIsW780() {
        assertEquals("w780", TmdbImageSizes.POSTER)
    }

    @Test
    fun tmdbImageUrlBuildsPosterUrl() {
        assertEquals(
            "https://image.tmdb.org/t/p/w780/abc123.jpg",
            tmdbImageUrl("/abc123.jpg", TmdbImageSizes.POSTER),
        )
        // Whitespace around the path is trimmed (the metadata service always did this).
        assertEquals(
            "https://image.tmdb.org/t/p/w1280/backdrop.jpg",
            tmdbImageUrl("  /backdrop.jpg  ", TmdbImageSizes.BACKDROP),
        )
    }

    @Test
    fun tmdbImageUrlRejectsBlankPath() {
        assertNull(tmdbImageUrl(null, TmdbImageSizes.POSTER))
        assertNull(tmdbImageUrl("", TmdbImageSizes.POSTER))
        assertNull(tmdbImageUrl("   ", TmdbImageSizes.POSTER))
    }

    @Test
    fun logoStaysW500InData() {
        // Deliberate: a bigger logo in the data would slow the Home hero's deadline-bound fetch.
        assertEquals("w500", TmdbImageSizes.LOGO)
        assertEquals("w500", TmdbImageSizes.PROFILE)
        assertEquals("w1280", TmdbImageSizes.BACKDROP)
    }
}
