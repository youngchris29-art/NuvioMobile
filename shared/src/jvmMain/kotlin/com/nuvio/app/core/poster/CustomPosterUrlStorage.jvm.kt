package com.nuvio.app.core.poster

import com.nuvio.app.core.storage.ProfileScopedKey

// JVM actual (test target): in-memory, same profile-scoped key layout as the Apple/Android actuals.
actual object CustomPosterUrlStorage {
    private const val patternKey = "custom_poster_url_pattern"
    private const val enabledScreensKey = "custom_poster_enabled_screens"

    private val patterns = mutableMapOf<String, String>()
    private val screens = mutableMapOf<String, Set<String>>()

    actual fun loadPattern(): String? = synchronized(patterns) { patterns[ProfileScopedKey.of(patternKey)] }

    actual fun savePattern(pattern: String?) {
        synchronized(patterns) {
            val key = ProfileScopedKey.of(patternKey)
            if (pattern.isNullOrBlank()) patterns.remove(key) else patterns[key] = pattern.trim()
        }
    }

    actual fun loadEnabledScreens(): Set<String>? = synchronized(screens) { screens[ProfileScopedKey.of(enabledScreensKey)] }

    actual fun saveEnabledScreens(keys: Set<String>?) {
        synchronized(screens) {
            val key = ProfileScopedKey.of(enabledScreensKey)
            if (keys == null) screens.remove(key) else screens[key] = keys
        }
    }
}
