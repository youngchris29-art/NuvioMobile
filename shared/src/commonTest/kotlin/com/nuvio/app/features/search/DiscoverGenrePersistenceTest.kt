package com.nuvio.app.features.search

import com.nuvio.app.core.profile.ActiveProfileIdProvider
import com.nuvio.app.core.profile.ActiveProfileProvider
import kotlin.test.AfterTest
import kotlin.test.BeforeTest
import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertNull

/** C4: the Discover genre is remembered per catalog, per profile. */
class DiscoverGenrePersistenceTest {
    private val keys = listOf("a:movie:top", "a:movie:new", "a:series:top")

    @BeforeTest
    fun reset() = clearAll()

    @AfterTest
    fun tearDown() {
        ActiveProfileProvider.provider = ActiveProfileIdProvider { 1 }
        clearAll()
    }

    private fun clearAll() {
        for (profile in listOf(1, 78)) {
            ActiveProfileProvider.provider = ActiveProfileIdProvider { profile }
            keys.forEach { DiscoverSelectionStorage.saveGenre(it, null) }
            DiscoverSelectionStorage.saveCatalogKey("")
        }
        ActiveProfileProvider.provider = ActiveProfileIdProvider { 1 }
    }

    @Test
    fun roundTripKeepsEachCatalogsOwnGenre() {
        DiscoverSelectionStorage.saveGenre("a:movie:top", "Drama")
        DiscoverSelectionStorage.saveGenre("a:movie:new", "Comedy")
        assertEquals("Drama", DiscoverSelectionStorage.loadGenre("a:movie:top"))
        assertEquals("Comedy", DiscoverSelectionStorage.loadGenre("a:movie:new"))
        assertNull(DiscoverSelectionStorage.loadGenre("a:series:top"))
    }

    @Test
    fun nullRemovesOnlyThatEntry() {
        DiscoverSelectionStorage.saveGenre("a:movie:top", "Drama")
        DiscoverSelectionStorage.saveGenre("a:movie:new", "Comedy")
        DiscoverSelectionStorage.saveGenre("a:movie:top", null)
        assertNull(DiscoverSelectionStorage.loadGenre("a:movie:top"))
        assertEquals("Comedy", DiscoverSelectionStorage.loadGenre("a:movie:new"))
    }

    @Test
    fun genreIsProfileScoped() {
        DiscoverSelectionStorage.saveGenre("a:movie:top", "Drama")
        ActiveProfileProvider.provider = ActiveProfileIdProvider { 78 }
        assertNull(DiscoverSelectionStorage.loadGenre("a:movie:top"))
        DiscoverSelectionStorage.saveGenre("a:movie:top", "Horror")
        ActiveProfileProvider.provider = ActiveProfileIdProvider { 1 }
        assertEquals("Drama", DiscoverSelectionStorage.loadGenre("a:movie:top"))
    }

    @Test
    fun corruptPayloadReadsAsEmpty() {
        assertEquals(emptyMap(), DiscoverGenreMap.decode("not json"))
        assertEquals(emptyMap(), DiscoverGenreMap.decode(null))
    }

    @Test
    fun unknownPersistedGenreResolvesToCatalogDefault() {
        val required = option("a:movie:top", genres = listOf("Drama", "Comedy"), required = true)
        val optional = option("a:movie:new", genres = listOf("Drama"), required = false)
        assertEquals("Drama", required.resolveGenreSelection("Removed Genre"))
        assertNull(optional.resolveGenreSelection("Removed Genre"))
        assertEquals("Comedy", required.resolveGenreSelection("Comedy"))
    }

    @Test
    fun restoreSelectionBringsBackThePersistedGenre() {
        val options = listOf(
            option("a:movie:top", genres = listOf("Drama", "Comedy"), required = true),
            option("a:movie:new", genres = listOf("Drama", "Comedy"), required = true),
        )
        DiscoverSources.saveSelection("a:movie:new", "Comedy")
        val restored = DiscoverSources.restoreSelection(options)
        assertEquals(DiscoverSelection("movie", "a:movie:new", "Comedy"), restored)

        // A genre the add-on dropped falls back to the catalog's default.
        DiscoverSelectionStorage.saveGenre("a:movie:new", "Gone")
        assertEquals("Drama", DiscoverSources.restoreSelection(options)?.genre)
    }

    private fun option(key: String, genres: List<String>, required: Boolean) = DiscoverCatalogOption(
        key = key,
        addonName = "Addon",
        manifestUrl = "https://example.com/manifest.json",
        type = key.split(":")[1],
        catalogId = key,
        catalogName = key,
        genreOptions = genres,
        genreRequired = required,
    )
}
