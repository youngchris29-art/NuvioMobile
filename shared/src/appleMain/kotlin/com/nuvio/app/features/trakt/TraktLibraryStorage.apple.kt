@file:OptIn(kotlinx.cinterop.ExperimentalForeignApi::class)

package com.nuvio.app.features.trakt

import com.nuvio.app.core.storage.ProfileScopedKey
import kotlinx.cinterop.BetaInteropApi
import platform.Foundation.NSApplicationSupportDirectory
import platform.Foundation.NSFileManager
import platform.Foundation.NSSearchPathForDirectoriesInDomains
import platform.Foundation.NSString
import platform.Foundation.NSUTF8StringEncoding
import platform.Foundation.NSUserDefaults
import platform.Foundation.NSUserDomainMask
import platform.Foundation.create
import platform.Foundation.stringWithContentsOfFile
import platform.Foundation.writeToFile

/**
 * File-backed storage for the Trakt library snapshot (same defect class and fix as BUG-11's
 * PluginStateFiles): the snapshot serializes EVERY entry of every Trakt list into one string,
 * and CFPreferences aborts the process outright on an oversized defaults write
 * (`__CFPREFERENCES_HAS_DETECTED_THIS_APP_TRYING_TO_STORE_TOO_MUCH_DATA__`) — a large Trakt
 * library crossed that cap on the Living Room device the first time the tracking-registry
 * refresh persisted a full snapshot (2026-08-01). This data must never go through
 * NSUserDefaults. One-time migration drains any legacy defaults value on first read and
 * removes the legacy key on every save so the plist shrinks back.
 */
actual object TraktLibraryStorage {
    private const val payloadKey = "trakt_library_payload"

    private fun directory(): String? {
        val base = NSSearchPathForDirectoriesInDomains(
            NSApplicationSupportDirectory,
            NSUserDomainMask,
            true,
        ).firstOrNull() as? String ?: return null
        val dir = "$base/TraktLibrary"
        NSFileManager.defaultManager.createDirectoryAtPath(
            dir,
            withIntermediateDirectories = true,
            attributes = null,
            error = null,
        )
        return dir
    }

    // ProfileScopedKey.of resolves the active profile, so the filename stays per-profile the
    // same way the old defaults key did (e.g. "trakt_library_payload_2.json").
    private fun path(): String? = directory()?.let { "$it/${ProfileScopedKey.of(payloadKey)}.json" }

    actual fun loadPayload(): String? {
        val path = path() ?: return legacyDefaultsValue()
        NSString.stringWithContentsOfFile(path, encoding = NSUTF8StringEncoding, error = null)
            ?.let { return it }
        // Migration: drain the legacy defaults value into the file store, then drop the key.
        val legacy = legacyDefaultsValue() ?: return null
        writeFile(path, legacy)
        removeLegacyDefaultsValue()
        return legacy
    }

    actual fun savePayload(payload: String) {
        val path = path() ?: return
        writeFile(path, payload)
        // Keep shrinking the defaults plist even for profiles that never call loadPayload.
        removeLegacyDefaultsValue()
    }

    /** Sign-out cleanup — mirrors PluginStateFiles.deleteAll (called by TvOsAccountDataCleaner). */
    fun deleteAll() {
        directory()?.let { NSFileManager.defaultManager.removeItemAtPath(it, error = null) }
    }

    private fun legacyDefaultsValue(): String? =
        NSUserDefaults.standardUserDefaults.stringForKey(ProfileScopedKey.of(payloadKey))

    private fun removeLegacyDefaultsValue() {
        NSUserDefaults.standardUserDefaults.removeObjectForKey(ProfileScopedKey.of(payloadKey))
    }

    @OptIn(BetaInteropApi::class)
    private fun writeFile(path: String, payload: String) {
        NSString.create(string = payload).writeToFile(
            path,
            atomically = true,
            encoding = NSUTF8StringEncoding,
            error = null,
        )
    }
}
