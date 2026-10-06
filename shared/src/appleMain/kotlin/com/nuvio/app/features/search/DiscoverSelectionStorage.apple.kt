package com.nuvio.app.features.search

import com.nuvio.app.core.storage.ProfileScopedKey
import platform.Foundation.NSUserDefaults

actual object DiscoverSelectionStorage {
    private const val catalogKey = "discover_catalog_key"
    private const val genreByCatalogKey = "discover_genre_by_catalog"

    actual fun loadCatalogKey(): String? =
        NSUserDefaults.standardUserDefaults.stringForKey(ProfileScopedKey.of(catalogKey))

    actual fun saveCatalogKey(catalogKey: String) {
        NSUserDefaults.standardUserDefaults.setObject(
            catalogKey,
            forKey = ProfileScopedKey.of(DiscoverSelectionStorage.catalogKey),
        )
    }

    actual fun loadGenre(catalogKey: String): String? =
        DiscoverGenreMap.decode(
            NSUserDefaults.standardUserDefaults.stringForKey(ProfileScopedKey.of(genreByCatalogKey)),
        )[catalogKey]

    actual fun saveGenre(catalogKey: String, genre: String?) {
        val scopedKey = ProfileScopedKey.of(genreByCatalogKey)
        val defaults = NSUserDefaults.standardUserDefaults
        defaults.setObject(
            DiscoverGenreMap.with(defaults.stringForKey(scopedKey), catalogKey, genre),
            forKey = scopedKey,
        )
    }
}
