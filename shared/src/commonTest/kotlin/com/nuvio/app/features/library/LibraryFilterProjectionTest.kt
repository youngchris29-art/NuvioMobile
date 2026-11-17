package com.nuvio.app.features.library

import kotlin.test.AfterTest
import kotlin.test.BeforeTest
import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertNull
import kotlin.test.assertTrue

class LibraryFilterProjectionTest {
    @BeforeTest
    fun resetStore() {
        LibraryDisplaySettingsStorage.savePayload("")
        LibraryDisplaySettingsRepository.clearLocalState()
    }

    @AfterTest
    fun cleanStore() {
        LibraryDisplaySettingsStorage.savePayload("")
        LibraryDisplaySettingsRepository.clearLocalState()
    }

    @Test
    fun `genres that differ only in case are one option keyed by the first spelling`() {
        val section = localSection(
            item("a", genres = listOf("Drama")),
            item("b", genres = listOf("drama")),
            item("c", genres = listOf("DRAMA", "Drama")),
        )

        val all = project(section)
        assertEquals(listOf("Drama" to 3), all.availableGenres.map { it.key to it.count })

        val picked = project(section, genre = "dRaMa")
        assertEquals("Drama", picked.selectedGenre)
        assertEquals(listOf("a", "b", "c"), picked.entries.map { it.item.id }.sorted())
    }

    @Test
    fun `an item counts once per genre`() {
        val section = localSection(item("a", genres = listOf("Drama", "drama")))

        assertEquals(listOf("Drama" to 1), project(section).availableGenres.map { it.key to it.count })
    }

    @Test
    fun `type order puts movies and series before anime and unknown types`() {
        val section = localSection(
            item("a", type = "anime"),
            item("b", type = "series"),
            item("c", type = "movie"),
            item("d", type = "special"),
        )

        assertEquals(listOf("movie", "series", "anime", "special"), project(section).availableTypes)
    }

    @Test
    fun `remote source filters genre and year inside the selected list only`() {
        val watchlist = LibrarySection(
            type = "watchlist",
            displayTitle = "Watchlist",
            items = listOf(item("h", genres = listOf("Horror"), releaseInfo = "2020")),
        )
        val list2 = LibrarySection(
            type = "list-2",
            displayTitle = "List 2",
            items = listOf(item("s", type = "series", genres = listOf("Comedy"), releaseInfo = "2019")),
        )

        val projection = buildLibraryVerticalProjection(
            sections = listOf(watchlist, list2),
            sourceMode = LibrarySourceMode.TRAKT,
            selectedSectionKey = "list-2",
            selectedType = null,
            sortOption = LibrarySortOption.TITLE_ASC,
            selectedGenre = "Horror",
        )

        assertEquals(listOf("Comedy"), projection.availableGenres.map { it.key })
        assertEquals(listOf("2019"), projection.availableYears.map { it.key })
        assertNull(projection.selectedGenre)
        assertEquals(listOf("s"), projection.entries.map { it.item.id })
    }

    @Test
    fun `simkl items without genres offer years but no genres`() {
        val section = LibrarySection(
            type = "watchlist",
            displayTitle = "Watchlist",
            items = listOf(
                item("a", releaseInfo = "2021"),
                item("b", releaseInfo = "2018"),
            ),
        )

        val projection = buildLibraryVerticalProjection(
            sections = listOf(section),
            sourceMode = LibrarySourceMode.SIMKL,
            selectedSectionKey = null,
            selectedType = null,
            sortOption = LibrarySortOption.DEFAULT,
        )

        assertTrue(projection.availableGenres.isEmpty())
        assertTrue(projection.availableYears.isNotEmpty())
    }

    @Test
    fun `mdblist mixed case genres merge`() {
        val section = LibrarySection(
            type = "list-1",
            displayTitle = "List",
            items = listOf(
                item("a", genres = listOf("crime")),
                item("b", genres = listOf("Drama")),
                item("c", genres = listOf("Crime", "drama")),
            ),
        )
        fun projectionFor(genre: String?) = buildLibraryVerticalProjection(
            sections = listOf(section),
            sourceMode = LibrarySourceMode.MDBLIST,
            selectedSectionKey = null,
            selectedType = null,
            sortOption = LibrarySortOption.TITLE_ASC,
            selectedGenre = genre,
        )

        assertEquals(
            listOf("crime" to 2, "Drama" to 2),
            projectionFor(null).availableGenres.map { it.key to it.count },
        )
        assertEquals("crime", projectionFor("Crime").selectedGenre)
    }

    @Test
    fun `a stored type the list no longer has falls back to all types`() {
        val section = localSection(item("a"), item("b"))

        val projection = project(section, type = "anime")

        assertNull(projection.selectedType)
        assertEquals(2, projection.entries.size)
    }

    @Test
    fun `the eight argument overload matches the full call with every title shown`() {
        val section = localSection(
            item("a", genres = listOf("Drama"), releaseInfo = "2020"),
            item("b", genres = listOf("Comedy"), releaseInfo = "2018"),
            item("c", type = "series", genres = listOf("drama")),
        )
        val orders = mapOf("local" to mapOf("movie:a" to 1))

        val full = buildLibraryVerticalProjection(
            sections = listOf(section),
            sourceMode = LibrarySourceMode.LOCAL,
            selectedSectionKey = null,
            selectedType = null,
            sortOption = LibrarySortOption.TITLE_ASC,
            providerOrders = orders,
            selectedGenre = "drama",
            selectedYear = null,
            watchedFilter = LibraryWatchedFilter.ALL,
            isWatched = { false },
        )
        val eight = buildLibraryVerticalProjection(
            sections = listOf(section),
            sourceMode = LibrarySourceMode.LOCAL,
            selectedSectionKey = null,
            selectedType = null,
            sortOption = LibrarySortOption.TITLE_ASC,
            providerOrders = orders,
            selectedGenre = "drama",
            selectedYear = null,
        )

        assertEquals(full, eight)
    }

    @Test
    fun `an old payload without list and type decodes to nil picks`() {
        val state = decodeLibraryDisplaySettings("""{"layout_mode":"VERTICAL","sort_option":"TITLE_ASC"}""")

        assertEquals(LibraryLayoutMode.VERTICAL, state.layoutMode)
        assertEquals(LibrarySortOption.TITLE_ASC, state.sortOption)
        assertNull(state.selectedSectionKey)
        assertNull(state.selectedType)
    }

    @Test
    fun `picking a list resets the type and repeating a pick is a no-op`() {
        LibraryDisplaySettingsRepository.setSelectedType("series")
        LibraryDisplaySettingsRepository.setSelectedSection("list-2")

        assertEquals("list-2", LibraryDisplaySettingsRepository.uiState.value.selectedSectionKey)
        assertNull(LibraryDisplaySettingsRepository.uiState.value.selectedType)

        LibraryDisplaySettingsRepository.setSelectedType("movie")
        LibraryDisplaySettingsRepository.setSelectedSection("list-2")
        assertNull(LibraryDisplaySettingsRepository.uiState.value.selectedType)

        LibraryDisplaySettingsRepository.setSelectedType("movie")
        val afterFirst = LibraryDisplaySettingsRepository.uiState.value
        LibraryDisplaySettingsRepository.setSelectedType("movie")
        assertEquals(afterFirst, LibraryDisplaySettingsRepository.uiState.value)
        assertEquals("movie", LibraryDisplaySettingsRepository.uiState.value.selectedType)

        LibraryDisplaySettingsRepository.onProfileChanged()
        assertEquals("list-2", LibraryDisplaySettingsRepository.uiState.value.selectedSectionKey)
        assertEquals("movie", LibraryDisplaySettingsRepository.uiState.value.selectedType)
    }

    @Test
    fun `the filter fixture parses into years and genres`() {
        val state = LibraryFilterFixture.uiState(provider = false)
        val projection = buildLibraryVerticalProjection(
            sections = state.sections,
            sourceMode = state.sourceMode,
            selectedSectionKey = null,
            selectedType = null,
            sortOption = LibrarySortOption.TITLE_ASC,
        )

        assertEquals(14, projection.entries.size)
        assertEquals(14, projection.allTypesCount)
        val genres = projection.availableGenres.associate { it.key to it.count }
        assertEquals(5, genres["Comedy"])
        assertTrue("science-fiction" in genres)
        assertTrue("Sci-Fi" in genres)
        assertEquals("2023", projection.availableYears.first().key)
        assertEquals(13, projection.availableYears.sumOf { it.count })
    }

    private fun localSection(vararg items: LibraryItem) =
        LibrarySection(type = "local", displayTitle = "Library", items = items.toList())

    private fun project(
        section: LibrarySection,
        genre: String? = null,
        type: String? = null,
    ) = buildLibraryVerticalProjection(
        sections = listOf(section),
        sourceMode = LibrarySourceMode.LOCAL,
        selectedSectionKey = null,
        selectedType = type,
        sortOption = LibrarySortOption.TITLE_ASC,
        selectedGenre = genre,
    )

    private fun item(
        id: String,
        type: String = "movie",
        name: String = id,
        releaseInfo: String? = null,
        genres: List<String> = emptyList(),
    ): LibraryItem = LibraryItem(
        id = id,
        type = type,
        name = name,
        releaseInfo = releaseInfo,
        genres = genres,
        savedAtEpochMs = 0L,
    )
}
