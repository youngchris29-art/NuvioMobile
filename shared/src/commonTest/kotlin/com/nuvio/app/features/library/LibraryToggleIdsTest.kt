package com.nuvio.app.features.library

import com.nuvio.app.features.details.MetaDetails
import com.nuvio.app.features.home.MetaPreview
import com.nuvio.app.features.tracking.TrackingProviderId
import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertNull

/** Issue #17: the Detail page's library + carries an IMDb/TMDB id whenever either source has one. */
class LibraryToggleIdsTest {

    @Test
    fun `an add-on id takes the meta's parsed IMDb id`() {
        val meta = MetaDetails(id = "kitsu:1376", type = "series", name = "Show", imdbId = "tt0388629")
        val preview = MetaPreview(id = "kitsu:1376", type = "series", name = "Show")
        val item = libraryItemForDetail(meta, preview, savedAtEpochMs = 0L)
        assertEquals("kitsu:1376", item.id)
        assertEquals("tt0388629", item.imdbId)
    }

    @Test
    fun `an IMDb id only the preview has is kept`() {
        val meta = MetaDetails(id = "addon-slug-123", type = "movie", name = "Movie")
        val preview = MetaPreview(id = "tt0111161", type = "movie", name = "Movie")
        assertEquals("tt0111161", libraryItemForDetail(meta, preview, savedAtEpochMs = 0L).imdbId)
    }

    @Test
    fun `a tmdb content id fills the TMDB id`() {
        val preview = MetaPreview(id = "tmdb:550", type = "movie", name = "Fight Club")
        val item = libraryItemForDetail(meta = null, preview = preview, savedAtEpochMs = 0L)
        assertEquals(550, item.tmdbId)
        assertNull(item.imdbId)
    }

    @Test
    fun `an id with no IMDb or TMDB form stays without ids`() {
        val preview = MetaPreview(id = "addon-slug-123", type = "movie", name = "Movie")
        val item = libraryItemForDetail(meta = null, preview = preview, savedAtEpochMs = 0L)
        assertNull(item.imdbId)
        assertNull(item.tmdbId)
    }

    @Test
    fun `the generic failure names the provider and a thrown message wins`() {
        assertEquals("Failed to update Simkl lists",
            libraryToggleFailureMessage(IllegalStateException(), TrackingProviderId.SIMKL))
        assertEquals("Failed to update MDBList lists",
            libraryToggleFailureMessage(IllegalStateException(" "), TrackingProviderId.MDBLIST))
        assertEquals("Trakt sign-in expired",
            libraryToggleFailureMessage(IllegalStateException("Trakt sign-in expired"), TrackingProviderId.TRAKT))
    }
}
