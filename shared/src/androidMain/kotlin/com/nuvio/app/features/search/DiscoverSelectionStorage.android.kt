package com.nuvio.app.features.search

import android.content.Context
import android.content.SharedPreferences
import com.nuvio.app.core.storage.ProfileScopedKey

actual object DiscoverSelectionStorage {
    private const val preferencesName = "nuvio_discover_selection"
    private const val catalogKey = "discover_catalog_key"
    private const val genreByCatalogKey = "discover_genre_by_catalog"

    private var preferences: SharedPreferences? = null

    fun initialize(context: Context) {
        preferences = context.getSharedPreferences(preferencesName, Context.MODE_PRIVATE)
    }

    actual fun loadCatalogKey(): String? =
        preferences?.getString(ProfileScopedKey.of(catalogKey), null)

    actual fun saveCatalogKey(catalogKey: String) {
        preferences
            ?.edit()
            ?.putString(ProfileScopedKey.of(DiscoverSelectionStorage.catalogKey), catalogKey)
            ?.apply()
    }

    actual fun loadGenre(catalogKey: String): String? =
        DiscoverGenreMap.decode(
            preferences?.getString(ProfileScopedKey.of(genreByCatalogKey), null),
        )[catalogKey]

    actual fun saveGenre(catalogKey: String, genre: String?) {
        val scopedKey = ProfileScopedKey.of(genreByCatalogKey)
        val prefs = preferences ?: return
        prefs.edit()
            .putString(scopedKey, DiscoverGenreMap.with(prefs.getString(scopedKey, null), catalogKey, genre))
            .apply()
    }
}
