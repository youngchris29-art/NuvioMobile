package com.nuvio.app.features.library

import com.nuvio.app.features.details.MetaDetails
import com.nuvio.app.features.home.MetaPreview
import com.nuvio.app.features.tracking.TrackingProviderId
import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertFalse
import kotlin.test.assertNull
import kotlin.test.assertTrue

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

    // Saved-state lookup: a title saved under one id reads as saved when asked by another.

    private fun loadedState(vararg items: LibraryItem): LibraryLocalState {
        val state = LibraryLocalState()
        val token = state.beginProfileLoad(profileId = 1).snapshot.token
        state.completeProfileLoad(token = token, activeProfileId = 1, items = items.toList())
        return state
    }

    @Test
    fun `saved under the IMDb id reads as saved when asked by the add-on id`() {
        val state = loadedState(LibraryItem(id = "tt0388629", type = "series", name = "Show", imdbId = "tt0388629", savedAtEpochMs = 0L))
        assertTrue(state.containsAnyId("kitsu:1376", "series", imdbId = "tt0388629", tmdbId = null))
        assertFalse(state.containsAnyId("kitsu:1376", "series", imdbId = null, tmdbId = null))
        assertFalse(state.containsAnyId("kitsu:1376", "movie", imdbId = "tt0388629", tmdbId = null),
            "a different type is a different title")
    }

    @Test
    fun `saved under the add-on id reads as saved when asked by the IMDb or TMDB id`() {
        val state = loadedState(
            LibraryItem(id = "kitsu:1376", type = "series", name = "Show", imdbId = "tt0388629", tmdbId = 30983, savedAtEpochMs = 0L),
        )
        assertTrue(state.containsAnyId("tt0388629", "series", imdbId = "tt0388629", tmdbId = null))
        assertTrue(state.containsAnyId("tmdb:30983", "series", imdbId = null, tmdbId = 30983))
        assertFalse(state.containsAnyId("tt0000001", "series", imdbId = "tt0000001", tmdbId = null))
    }

    @Test
    fun `toggling from a page with another id removes the stored record instead of adding a second`() {
        // Review r1: saved as tt0388629, toggled from the kitsu:1376 Detail page.
        val state = loadedState(LibraryItem(id = "tt0388629", type = "series", name = "Show", imdbId = "tt0388629", savedAtEpochMs = 0L))
        val fromAddonPage = LibraryItem(id = "kitsu:1376", type = "series", name = "Show", imdbId = "tt0388629", savedAtEpochMs = 0L)
        val target = state.findAnyId(fromAddonPage.id, fromAddonPage.type, fromAddonPage.imdbId, fromAddonPage.tmdbId)
        assertEquals("tt0388629", target?.id)
        val result = state.toggle((target ?: fromAddonPage).copy(savedAtEpochMs = 1L))
        assertFalse(result.isSaved)
        assertTrue(result.snapshot.items.isEmpty(), "no second record under the add-on id")
        assertFalse(state.containsAnyId("kitsu:1376", "series", imdbId = "tt0388629", tmdbId = null))
        // Nothing stored: the toggle saves the page's own item.
        assertNull(state.findAnyId("kitsu:1376", "series", imdbId = "tt0388629", tmdbId = null))
        assertTrue(state.toggle(fromAddonPage.copy(savedAtEpochMs = 2L)).isSaved)
    }

    @Test
    fun `the exact record wins when a title is stored under two ids`() {
        val state = loadedState(
            LibraryItem(id = "tt0388629", type = "series", name = "Show", imdbId = "tt0388629", savedAtEpochMs = 0L),
            LibraryItem(id = "kitsu:1376", type = "series", name = "Show", imdbId = "tt0388629", savedAtEpochMs = 0L),
        )
        assertEquals("kitsu:1376", state.findAnyId("kitsu:1376", "series", imdbId = "tt0388629", tmdbId = null)?.id)
    }

    @Test
    fun `a provider toggle acts on the record the provider holds under another id`() {
        // Review r2: Simkl/Trakt hold the title under tt0388629; the page was opened by kitsu:1376.
        val stored = LibraryItem(id = "tt0388629", type = "series", name = "Show", imdbId = "tt0388629", tmdbId = 30983, savedAtEpochMs = 0L)
        val fromAddonPage = LibraryItem(id = "kitsu:1376", type = "series", name = "Show", imdbId = "tt0388629", savedAtEpochMs = 0L)
        val find: (String) -> LibraryItem? = { id -> stored.takeIf { it.id == id } }
        val target = libraryToggleTarget(fromAddonPage, find) { listOf(stored) }
        assertEquals("tt0388629", target.id)
        assertEquals(30983, target.tmdbId)
        // Nothing held, or held as another type: the page's item is toggled as is.
        assertEquals(fromAddonPage, libraryToggleTarget(fromAddonPage, { null }) { emptyList() })
        val asMovie = stored.copy(type = "movie")
        assertEquals(fromAddonPage, libraryToggleTarget(fromAddonPage, { id -> asMovie.takeIf { it.id == id } }) { listOf(asMovie) })
    }

    @Test
    fun `a record stored under a canonical id the page cannot know matches by its IMDb or TMDB field`() {
        // Review r3: Simkl keeps the anime as kitsu:1376 (with its IMDb id); the page was opened by tt0388629.
        val storedKitsu = LibraryItem(id = "kitsu:1376", type = "series", name = "Show", imdbId = "tt0388629", savedAtEpochMs = 0L)
        val find: (String) -> LibraryItem? = { id -> storedKitsu.takeIf { it.id == id } }
        val record = providerStoredRecord("tt0388629", "series", imdbId = "tt0388629", tmdbId = null, find = find) { listOf(storedKitsu) }
        assertEquals("kitsu:1376", record?.id)
        val target = libraryToggleTarget(
            LibraryItem(id = "tt0388629", type = "series", name = "Show", imdbId = "tt0388629", tmdbId = 30983, savedAtEpochMs = 0L), find,
        ) { listOf(storedKitsu) }
        assertEquals("kitsu:1376", target.id)
        assertEquals(30983, target.tmdbId, "the page's TMDB id rides along")
        // By TMDB field; a different type or no ids to match by finds nothing.
        val storedTmdb = LibraryItem(id = "simkl:9", type = "movie", name = "Film", tmdbId = 550, savedAtEpochMs = 0L)
        assertEquals("simkl:9", providerStoredRecord("addon-1", "movie", null, 550, { null }) { listOf(storedTmdb) }?.id)
        assertNull(providerStoredRecord("addon-1", "series", null, 550, { null }) { listOf(storedTmdb) })
        assertNull(providerStoredRecord("addon-1", "movie", null, null, { null }) { listOf(storedTmdb) })
    }

    @Test
    fun `a hold menu's saved state resolves the same ids its toggle item carries`() {
        // Review r5: isSaved(id, type) derives IMDb/TMDB ids from the content id exactly as
        // MetaPreview.toLibraryItem does, so the label and the action see the same record.
        for (id in listOf("tt0388629", "tmdb:550", "kitsu:1376")) {
            val item = MetaPreview(id = id, type = "series", name = "T").toLibraryItem(savedAtEpochMs = 0L)
            assertEquals(item.imdbId, imdbIdFromContentId(id), id)
            assertEquals(item.tmdbId, tmdbIdFromContentId(id), id)
        }
        // The library holds kitsu:1376 (with its IMDb id); a tt0388629 card reads "Remove", and
        // the toggle target is that Kitsu record, not a second one.
        val state = loadedState(LibraryItem(id = "kitsu:1376", type = "series", name = "Show", imdbId = "tt0388629", savedAtEpochMs = 0L))
        assertTrue(state.containsAnyId("tt0388629", "series", imdbIdFromContentId("tt0388629"), tmdbIdFromContentId("tt0388629")))
        assertEquals("kitsu:1376", state.findAnyId("tt0388629", "series", "tt0388629", null)?.id)
    }

    @Test
    fun `a provider lookup tries the own id then the IMDb and TMDB ids`() {
        assertEquals(listOf("kitsu:1376", "tt0388629", "tmdb:30983"),
            libraryLookupIds("kitsu:1376", imdbId = "tt0388629", tmdbId = 30983))
        assertEquals(listOf("tt0388629"), libraryLookupIds("tt0388629", imdbId = "tt0388629", tmdbId = null))
        // Trakt's content keys: saved under the tt id, asked by the add-on id.
        val traktSaved = setOf("tt0388629")
        assertTrue(libraryLookupIds("kitsu:1376", "tt0388629", null).any(traktSaved::contains))
    }
}
