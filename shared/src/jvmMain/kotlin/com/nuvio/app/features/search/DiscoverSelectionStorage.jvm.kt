package com.nuvio.app.features.search

// JVM actual for shared/src/jvmMain (beta.14 Wave 4 / :shared jvm test target, see
// docs/issue-triage-plan-2026-08-21.md §6.1). Ported from the androidMain actual in this
// same relative path: same key layout, JvmSharedPreferences swapped in for
// android.content.SharedPreferences (no Context needed on the JVM).

import com.nuvio.app.core.storage.JvmSharedPreferences
import com.nuvio.app.core.storage.jvmSharedPreferences
import com.nuvio.app.core.storage.ProfileScopedKey

actual object DiscoverSelectionStorage {
    private const val preferencesName = "nuvio_discover_selection"
    private const val catalogKey = "discover_catalog_key"
    private const val genreByCatalogKey = "discover_genre_by_catalog"

    private val preferences: JvmSharedPreferences? = jvmSharedPreferences(preferencesName)

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
