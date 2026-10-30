package com.nuvio.app.features.plugins

import com.nuvio.app.core.storage.PayloadFileStore

/**
 * File-backed storage for per-profile plugin state. The payload embeds every scraper's JS
 * source, and CFPreferences aborts the process outright once an app's defaults plist crosses
 * ~4 MB (`__CFPREFERENCES_HAS_DETECTED_THIS_APP_TRYING_TO_STORE_TOO_MUCH_DATA__`), so this
 * data must never go through NSUserDefaults.
 *
 * One more [PayloadFileStore] subdirectory (`PluginState`, files `plugins_state_<profileId>.json`,
 * the same layout this object wrote on its own before 2026-10-29): the store resolves the
 * tvOS-safe root, drains the legacy `plugins_state_<profileId>` defaults value on first read,
 * and logs a failed write once per launch instead of dropping it on the floor.
 */
internal object PluginStateFiles {
    private const val subdirectory = "PluginState"

    private fun key(profileId: Int) = "plugins_state_$profileId"

    fun read(profileId: Int): String? = PayloadFileStore.load(subdirectory, key(profileId))

    /** Returns false when the write did not land; the store has already logged why. */
    fun write(profileId: Int, payload: String): Boolean =
        PayloadFileStore.save(subdirectory, key(profileId), payload)

    fun deleteAll() = PayloadFileStore.deleteAll(subdirectory)
}
