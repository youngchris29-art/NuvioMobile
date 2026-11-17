package com.nuvio.app.features.library

/**
 * W5 (tvOS Library filter bar): a fixed library for the bar mockups, `LibraryFilterBarUITests` and
 * `LibraryViewModelFilterTests`. Ids starting `fx-w-` read as watched and `fx-p-` as in progress
 * on the tvOS side (`LibraryDebugFlags`). Never written to any repository or store.
 */
object LibraryFilterFixture {
    fun uiState(provider: Boolean): LibraryUiState {
        val all = items()
        val sections = if (provider) {
            listOf(
                LibrarySection(type = "watchlist", displayTitle = "Watchlist", items = all),
                LibrarySection(
                    type = "fx-list-weekend",
                    displayTitle = "Weekend Movies With Friends",
                    items = all.filter { it.type == "movie" },
                ),
            )
        } else {
            listOf(LibrarySection(type = "local", displayTitle = "Library", items = all))
        }
        return LibraryUiState(
            sourceMode = if (provider) LibrarySourceMode.TRAKT else LibrarySourceMode.LOCAL,
            items = all,
            sections = sections,
            isLoaded = true,
            isLoading = false,
            errorMessage = null,
        )
    }

    private fun items(): List<LibraryItem> = listOf(
        item("fx-1", "movie", "The Long Kiss Goodnight: Extended Anniversary Edition", "1996", listOf("Action", "Thriller")),
        item("fx-2", "movie", "Arrival", "2016", listOf("Drama", "science-fiction")),
        item("fx-w-3", "movie", "Heat", "1995", listOf("Crime", "Drama")),
        item("fx-4", "movie", "Paddington 2", "2017", listOf("Comedy", "Family")),
        item("fx-p-5", "movie", "Dune", "2021", listOf("Sci-Fi", "Adventure")),
        item("fx-6", "movie", "Knives Out", "2019", listOf("Comedy", "Crime", "Mystery")),
        item("fx-7", "movie", "Nope", "2022", listOf("Horror")),
        item("fx-8", "movie", "Untitled Fixture", null, emptyList()),
        item("fx-p-9", "series", "Severance", "2022", listOf("Drama", "Mystery")),
        item("fx-w-10", "series", "Fleabag", "2016", listOf("comedy")),
        item("fx-11", "series", "Dark", "2017-2020", listOf("Crime", "Drama", "Mystery")),
        item("fx-12", "series", "The Bear", "2022", listOf("Comedy", "Drama")),
        item("fx-13", "series", "Frieren", "2023", listOf("Adventure", "Fantasy"), category = "anime"),
        item("fx-14", "series", "Mob Psycho 100", "2016", listOf("Action", "Comedy"), category = "anime"),
    ).mapIndexed { index, item -> item.copy(savedAtEpochMs = 1_700_000_000_000L - index * 86_400_000L) }

    private fun item(
        id: String,
        type: String,
        name: String,
        releaseInfo: String?,
        genres: List<String>,
        category: String? = null,
    ): LibraryItem = LibraryItem(
        id = id,
        type = type,
        name = name,
        releaseInfo = releaseInfo,
        genres = genres,
        mediaCategory = category,
        savedAtEpochMs = 0L,
    )
}
