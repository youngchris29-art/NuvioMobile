package com.nuvio.app.core.poster

import com.nuvio.app.features.home.PosterShape
import kotlin.test.AfterTest
import kotlin.test.BeforeTest
import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertNull

class CustomPosterUrlsTest {
    @BeforeTest
    fun reset() {
        CustomPosterUrlStorage.savePattern(null)
        CustomPosterUrlStorage.saveEnabledScreens(null)
        CustomPosterUrlRepository.clearLocalState()
    }

    @AfterTest
    fun cleanup() = reset()

    @Test
    fun `pattern applies to a bare imdb id`() {
        assertEquals(
            "https://p.example/tt0137523/poster.jpg",
            CustomPosterUrls.resolveWithPattern(
                "https://p.example/{imdb_id}/{shape}.jpg", "tt0137523", "movie", PosterShape.Poster,
            ),
        )
    }

    @Test
    fun `landscape shape resolves only when pattern has shape placeholder`() {
        assertEquals(
            "https://p.example/tmdb/landscape/1396",
            CustomPosterUrls.resolveWithPattern(
                "https://p.example/{id_type}/{shape}/{tmdb_id}", "tmdb:1396", "tv", PosterShape.Landscape,
            ),
        )
        assertNull(
            CustomPosterUrls.resolveWithPattern(
                "https://p.example/{imdb_id}.jpg", "tt1", "movie", PosterShape.Landscape,
            ),
        )
    }

    @Test
    fun `no pattern yields null`() {
        assertNull(CustomPosterUrls.resolveWithPattern("", "tt1", "movie", PosterShape.Poster))
        assertNull(CustomPosterUrls.resolveWithPattern("  ", "tt1", "movie", PosterShape.Poster))
    }

    @Test
    fun `unsupported id type yields null`() {
        assertNull(
            CustomPosterUrls.resolveWithPattern(
                "https://p.example/{imdb_id}.jpg", "kitsu:7442", "series", PosterShape.Poster,
            ),
        )
    }

    @Test
    fun `repository backed resolve honours enabled screens`() {
        CustomPosterUrlRepository.clearLocalState()
        CustomPosterUrlRepository.setPattern("https://p.example/{imdb_id}.jpg")
        assertEquals(
            "https://p.example/tt9.jpg",
            CustomPosterUrls.resolve("tt9", "movie", PosterShape.Poster, CustomPosterScreen.CONTINUE_WATCHING),
        )
        CustomPosterUrlRepository.setScreenEnabled(CustomPosterScreen.CONTINUE_WATCHING, false)
        assertNull(
            CustomPosterUrls.resolve("tt9", "movie", PosterShape.Poster, CustomPosterScreen.CONTINUE_WATCHING),
        )
        assertEquals(
            "https://p.example/tt9.jpg",
            CustomPosterUrls.resolve("tt9", "movie", PosterShape.Poster, CustomPosterScreen.HOME),
        )
    }

    @Test
    fun `screen keys round trip`() {
        val keys = CustomPosterScreen.toKeys(setOf(CustomPosterScreen.HOME, CustomPosterScreen.SEARCH))
        assertEquals(setOf("home", "search"), keys)
        assertEquals(setOf(CustomPosterScreen.HOME, CustomPosterScreen.SEARCH), CustomPosterScreen.fromKeys(keys))
        assertEquals(CustomPosterScreen.ALL, CustomPosterScreen.fromKeys(null))
        assertEquals(CustomPosterScreen.ALL, CustomPosterScreen.fromKeys(emptySet()))
    }
}
