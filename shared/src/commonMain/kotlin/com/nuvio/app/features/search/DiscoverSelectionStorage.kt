package com.nuvio.app.features.search

expect object DiscoverSelectionStorage {
    fun loadCatalogKey(): String?
    fun saveCatalogKey(catalogKey: String)

    /// C4: the genre last picked for [catalogKey]; null when none was saved.
    fun loadGenre(catalogKey: String): String?

    /// C4: remembers [genre] for [catalogKey]; null removes that catalog's entry.
    fun saveGenre(catalogKey: String, genre: String?)
}
