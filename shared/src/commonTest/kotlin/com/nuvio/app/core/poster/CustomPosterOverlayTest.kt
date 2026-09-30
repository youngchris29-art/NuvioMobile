package com.nuvio.app.core.poster

import com.nuvio.app.features.home.MetaPreview
import com.nuvio.app.features.home.PosterShape
import com.nuvio.app.features.library.LibraryItem
import com.nuvio.app.features.library.toLibraryItem
import com.nuvio.app.features.library.toMetaPreview
import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertNull

class CustomPosterOverlayTest {

    private val rpdbPattern = "https://api.ratingposterdb.com/key/imdb/poster-default/{imdb_id}.jpg"
    private val universalPattern = "https://example.com/{id_type}/poster-default/{typed_id}.jpg"
    private val shapePattern = "https://example.com/{id_type}/{shape}/{typed_id}.jpg"

    // -- MetaPreview overlay --

    @Test
    fun withCustomPosterUrl_replaces_poster_and_preserves_rawPosterUrl() {
        val item = MetaPreview(
            id = "tt0137523",
            type = "movie",
            name = "Fight Club",
            poster = "https://original.com/poster.jpg",
        )
        val result = item.withCustomPosterUrl(rpdbPattern)
        assertEquals("https://api.ratingposterdb.com/key/imdb/poster-default/tt0137523.jpg", result.poster)
        assertEquals("https://original.com/poster.jpg", result.rawPosterUrl)
    }

    @Test
    fun withCustomPosterUrl_blank_pattern_returns_unchanged() {
        val item = MetaPreview(id = "tt0137523", type = "movie", name = "Test", poster = "https://original.com/poster.jpg")
        val result = item.withCustomPosterUrl("")
        assertEquals("https://original.com/poster.jpg", result.poster)
        assertNull(result.rawPosterUrl)
    }

    @Test
    fun withCustomPosterUrl_unresolvable_id_returns_unchanged() {
        val item = MetaPreview(id = "kitsu:7442", type = "series", name = "Anime", poster = "https://original.com/poster.jpg")
        val result = item.withCustomPosterUrl(rpdbPattern)
        assertEquals("https://original.com/poster.jpg", result.poster)
        assertNull(result.rawPosterUrl)
    }

    @Test
    fun withCustomPosterUrl_shape_pattern_sets_landscapePoster() {
        val item = MetaPreview(id = "tt0137523", type = "movie", name = "Test", poster = "https://original.com/poster.jpg")
        val result = item.withCustomPosterUrl(shapePattern)
        assertEquals("https://example.com/imdb/poster/tt0137523.jpg", result.poster)
        assertEquals("https://example.com/imdb/landscape/tt0137523.jpg", result.landscapePoster)
        assertEquals("https://original.com/poster.jpg", result.rawPosterUrl)
    }

    @Test
    fun withCustomPosterUrl_non_poster_shape_without_shape_placeholder_returns_unchanged() {
        val item = MetaPreview(
            id = "tt0137523", type = "movie", name = "Test",
            poster = "https://original.com/poster.jpg",
            posterShape = PosterShape.Landscape,
        )
        val result = item.withCustomPosterUrl(rpdbPattern)
        assertEquals("https://original.com/poster.jpg", result.poster)
    }

    @Test
    fun withCustomPosterUrl_non_poster_shape_with_shape_placeholder_resolves() {
        val item = MetaPreview(
            id = "tt0137523", type = "movie", name = "Test",
            poster = "https://original.com/poster.jpg",
            posterShape = PosterShape.Landscape,
        )
        val result = item.withCustomPosterUrl(shapePattern)
        assertEquals("https://example.com/imdb/landscape/tt0137523.jpg", result.poster)
    }

    // -- reapplyCustomPosterUrl --

    @Test
    fun reapplyCustomPosterUrl_restores_original_then_applies_new_pattern() {
        val item = MetaPreview(
            id = "tt0137523", type = "movie", name = "Test",
            poster = "https://old-service.com/custom.jpg",
            rawPosterUrl = "https://original.com/poster.jpg",
        )
        val result = item.reapplyCustomPosterUrl(universalPattern)
        assertEquals("https://example.com/imdb/poster-default/tt0137523.jpg", result.poster)
        assertEquals("https://original.com/poster.jpg", result.rawPosterUrl)
    }

    @Test
    fun reapplyCustomPosterUrl_blank_pattern_restores_original() {
        val item = MetaPreview(
            id = "tt0137523", type = "movie", name = "Test",
            poster = "https://custom-service.com/custom.jpg",
            rawPosterUrl = "https://original.com/poster.jpg",
        )
        val result = item.reapplyCustomPosterUrl("")
        assertEquals("https://original.com/poster.jpg", result.poster)
    }

    @Test
    fun reapplyCustomPosterUrl_no_rawPosterUrl_applies_normally() {
        val item = MetaPreview(
            id = "tt0137523", type = "movie", name = "Test",
            poster = "https://original.com/poster.jpg",
        )
        val result = item.reapplyCustomPosterUrl(universalPattern)
        assertEquals("https://example.com/imdb/poster-default/tt0137523.jpg", result.poster)
        assertEquals("https://original.com/poster.jpg", result.rawPosterUrl)
    }

    @Test
    fun reapplyCustomPosterUrl_keeps_addon_landscapePoster_without_shape_placeholder() {
        val item = MetaPreview(
            id = "tt0137523", type = "movie", name = "Test",
            poster = "https://original.com/poster.jpg",
            landscapePoster = "https://addon.com/landscape.jpg",
        )
        val result = item.withCustomPosterUrl(rpdbPattern).reapplyCustomPosterUrl(rpdbPattern)
        assertEquals("https://addon.com/landscape.jpg", result.landscapePoster)
    }

    @Test
    fun reapplyCustomPosterUrl_blank_pattern_restores_addon_landscapePoster() {
        val item = MetaPreview(
            id = "tt0137523", type = "movie", name = "Test",
            poster = "https://original.com/poster.jpg",
            landscapePoster = "https://addon.com/landscape.jpg",
        )
        val overlaid = item.withCustomPosterUrl(shapePattern)
        assertEquals("https://example.com/imdb/landscape/tt0137523.jpg", overlaid.landscapePoster)

        val result = overlaid.reapplyCustomPosterUrl("")
        assertEquals("https://original.com/poster.jpg", result.poster)
        assertEquals("https://addon.com/landscape.jpg", result.landscapePoster)
    }

    // -- List overlay --

    @Test
    fun withCustomPosterUrls_applies_to_all_items() {
        val items = listOf(
            MetaPreview(id = "tt0137523", type = "movie", name = "Fight Club", poster = "https://a.com/1.jpg"),
            MetaPreview(id = "tt0903747", type = "series", name = "Breaking Bad", poster = "https://a.com/2.jpg"),
        )
        val result = items.withCustomPosterUrls(rpdbPattern)
        assertEquals("https://api.ratingposterdb.com/key/imdb/poster-default/tt0137523.jpg", result[0].poster)
        assertEquals("https://api.ratingposterdb.com/key/imdb/poster-default/tt0903747.jpg", result[1].poster)
        assertEquals("https://a.com/1.jpg", result[0].rawPosterUrl)
        assertEquals("https://a.com/2.jpg", result[1].rawPosterUrl)
    }

    @Test
    fun withCustomPosterUrls_blank_pattern_returns_same_list() {
        val items = listOf(
            MetaPreview(id = "tt0137523", type = "movie", name = "Test", poster = "https://a.com/1.jpg"),
        )
        val result = items.withCustomPosterUrls("")
        assertEquals(items, result)
    }

    @Test
    fun null_original_poster_is_restored_to_null_after_clearing() {
        val item = MetaPreview(id = "tt1", type = "movie", name = "M", poster = null)
        val overlaid = item.withCustomPosterUrl(universalPattern)
        assertEquals(true, overlaid.customPosterApplied)
        val cleared = overlaid.reapplyCustomPosterUrl("")
        assertNull(cleared.poster)
        assertNull(cleared.rawPosterUrl)
        assertEquals(false, cleared.customPosterApplied)
    }

    @Test
    fun null_original_poster_reapply_with_new_pattern_keeps_no_original() {
        val item = MetaPreview(id = "tt1", type = "movie", name = "M", poster = null)
        val again = item.withCustomPosterUrl(universalPattern).reapplyCustomPosterUrl(rpdbPattern)
        assertEquals(rpdbPattern.replace("{imdb_id}", "tt1"), again.poster)
        assertNull(again.rawPosterUrl)
        assertNull(again.reapplyCustomPosterUrl("").poster)
    }

    @Test
    fun shape_pattern_applied_twice_keeps_raw_landscape() {
        val item = MetaPreview(
            id = "tt1", type = "movie", name = "M",
            poster = "https://o/p.jpg", landscapePoster = "https://o/l.jpg",
        )
        val once = item.withCustomPosterUrl(shapePattern)
        val twice = once.withCustomPosterUrl(shapePattern)
        assertEquals("https://o/l.jpg", once.rawLandscapePosterUrl)
        assertEquals("https://o/l.jpg", twice.rawLandscapePosterUrl)
        assertEquals("https://o/p.jpg", twice.rawPosterUrl)
    }

    @Test
    fun overlaid_preview_converts_to_library_item_with_raw_urls() {
        val overlaid = MetaPreview(
            id = "tt1", type = "movie", name = "M",
            poster = "https://o/p.jpg", landscapePoster = "https://o/l.jpg",
        ).withCustomPosterUrl(shapePattern)
        val library = overlaid.toLibraryItem(savedAtEpochMs = 1L)
        assertEquals("https://o/p.jpg", library.poster)
        assertEquals("https://o/l.jpg", library.landscapePoster)
    }

    @Test
    fun overlaid_preview_with_null_original_converts_to_library_item_without_custom_url() {
        val overlaid = MetaPreview(id = "tt1", type = "movie", name = "M", poster = null)
            .withCustomPosterUrl(universalPattern)
        assertEquals(true, overlaid.poster != null)
        val library = overlaid.toLibraryItem(savedAtEpochMs = 1L)
        assertNull(library.poster)
        assertNull(library.landscapePoster)
    }

    @Test
    fun library_item_overlay_records_and_restores_through_meta_preview() {
        val item = LibraryItem(
            id = "tt1", type = "movie", name = "M",
            poster = "https://o/p.jpg", landscapePoster = null, savedAtEpochMs = 1L,
        )
        val overlaid = item.withCustomPosterUrl(shapePattern)
        assertEquals("https://o/p.jpg", overlaid.rawPosterUrl)
        assertNull(overlaid.rawLandscapePosterUrl)
        assertEquals(true, overlaid.customPosterApplied)
        // idempotent
        val twice = overlaid.withCustomPosterUrl(shapePattern)
        assertEquals("https://o/p.jpg", twice.rawPosterUrl)
        assertNull(twice.rawLandscapePosterUrl)

        val preview = overlaid.toMetaPreview()
        assertEquals(true, preview.customPosterApplied)
        val cleared = preview.reapplyCustomPosterUrl("")
        assertEquals("https://o/p.jpg", cleared.poster)
        assertNull(cleared.landscapePoster)
        // and back into a library item: raw art only
        val back = preview.toLibraryItem(savedAtEpochMs = 2L)
        assertEquals("https://o/p.jpg", back.poster)
        assertNull(back.landscapePoster)
    }

    @Test
    fun library_item_with_existing_landscape_keeps_raw_landscape() {
        val item = LibraryItem(
            id = "tt1", type = "movie", name = "M",
            poster = "https://o/p.jpg", landscapePoster = "https://o/l.jpg", savedAtEpochMs = 1L,
        )
        val overlaid = item.withCustomPosterUrl(shapePattern).withCustomPosterUrl(shapePattern)
        assertEquals("https://o/l.jpg", overlaid.rawLandscapePosterUrl)
        assertEquals("https://o/l.jpg", overlaid.toMetaPreview().reapplyCustomPosterUrl("").landscapePoster)
    }
}
