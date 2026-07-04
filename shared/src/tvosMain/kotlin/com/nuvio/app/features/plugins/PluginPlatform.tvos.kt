package com.nuvio.app.features.plugins

import platform.Foundation.NSUserDefaults
import platform.Foundation.timeIntervalSince1970

internal object PluginStorage {
    private const val pluginsStateKey = "plugins_state"

    fun loadState(profileId: Int): String? =
        NSUserDefaults.standardUserDefaults.stringForKey("${pluginsStateKey}_$profileId")

    fun saveState(profileId: Int, payload: String) {
        NSUserDefaults.standardUserDefaults.setObject(
            payload,
            forKey = "${pluginsStateKey}_$profileId",
        )
    }

    fun loadScraperSettings(scraperId: String): String? =
        NSUserDefaults.standardUserDefaults.stringForKey("settings_${scraperId}")

    fun saveScraperSettings(scraperId: String, payload: String) {
        NSUserDefaults.standardUserDefaults.setObject(
            payload,
            forKey = "settings_${scraperId}",
        )
    }
}

// Deliberately "ios", not "tvos": plugin manifests gate scrapers via supportedPlatforms /
// disabledPlatforms lists that only know "android"/"ios" — reporting "tvos" would filter out
// every scraper. The tvOS runtime is API-identical to the iOS one (QuickJS + same bridges).
internal fun currentPluginPlatform(): String = "ios"

internal fun currentEpochMillis(): Long =
    (platform.Foundation.NSDate().timeIntervalSince1970 * 1000.0).toLong()
