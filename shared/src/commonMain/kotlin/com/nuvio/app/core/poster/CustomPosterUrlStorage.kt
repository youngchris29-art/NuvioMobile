package com.nuvio.app.core.poster

/**
 * Per-profile persistence for the custom poster URL pattern and the enabled-screens set.
 * Base keys `custom_poster_url_pattern` / `custom_poster_enabled_screens`
 * (`ProfileScopedKey.of(base)`); both registered in `AccountDataStores`.
 */
expect object CustomPosterUrlStorage {
    fun loadPattern(): String?
    fun savePattern(pattern: String?)
    fun loadEnabledScreens(): Set<String>?
    fun saveEnabledScreens(keys: Set<String>?)
}
