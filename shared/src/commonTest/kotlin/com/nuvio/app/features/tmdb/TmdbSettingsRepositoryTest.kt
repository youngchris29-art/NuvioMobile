package com.nuvio.app.features.tmdb

import com.nuvio.app.core.sync.PROFILE_TMDB_SETTINGS_FEATURE
import com.nuvio.app.core.sync.encodeSyncBoolean
import com.nuvio.app.core.sync.encodeSyncString
import com.nuvio.app.core.sync.extractLegacyCredentials
import com.nuvio.app.core.sync.preservingLocalProfileCredentials
import com.nuvio.app.core.sync.withoutProfileCredentials
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.buildJsonObject
import kotlin.test.AfterTest
import kotlin.test.BeforeTest
import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertFalse
import kotlin.test.assertNull
import kotlin.test.assertTrue

/**
 * Ported from upstream `60ee0160` and `df589078` (`TmdbSettingsRepositoryTest.kt`, originally a
 * Robolectric `androidHostTest`).
 *
 * Fork differences:
 * - Upstream's legacy-key case wrote a raw `tmdb_api_key` pref through the Android
 *   `SharedPreferences` handle; `commonTest` has no seam for that, so it writes the same pref
 *   through `TmdbSettingsStorage.saveApiKey`.
 * - The fork keeps the personal key in `TmdbSettingsStorage`'s export/import (the MDBList
 *   convention) and strips it at the settings-sync layer instead, so "never rides the settings
 *   blob" is asserted on [pushedSettings] (what `ProfileSettingsSync.exportSettingsBlob` pushes),
 *   and a settings pull is modelled with [applyRemoteSettings] (what `applyRemoteBlob` runs).
 *
 * Reset uses `TmdbSettingsStorage.replaceFromSyncPayload({})` (clears every synced key for the
 * current profile, the personal key included) — the pattern `PauseOverlaySettingsTest` uses.
 * `setEnabled`/`setApiKey` fan out to `HomeRepository.onTmdbSettingsChanged()` and
 * `MetaDetailsRepository.clear()`; that is deliberate coverage of the real call path.
 */
class TmdbSettingsRepositoryTest {
    @BeforeTest
    fun initialize() {
        TmdbSettingsStorage.replaceFromSyncPayload(buildJsonObject {})
        TmdbSettingsRepository.onProfileChanged()
    }

    @AfterTest
    fun clearState() {
        TmdbSettingsStorage.replaceFromSyncPayload(buildJsonObject {})
        TmdbSettingsRepository.onProfileChanged()
    }

    @Test
    fun enrichmentCanBeEnabledAndReloadedWithoutAPersonalKey() {
        assertFalse(TmdbSettingsRepository.snapshot().enabled)

        // Before upstream 60ee0160 this was refused outright (`if (value && apiKey.isBlank())
        // return`) and, even if stored, `loadFromDisk` re-gated it off on the next read.
        TmdbSettingsRepository.setEnabled(true)
        TmdbSettingsRepository.onProfileChanged()

        val settings = TmdbSettingsRepository.snapshot()
        assertTrue(settings.enabled)
        assertEquals("", settings.apiKey)
        assertEquals(TmdbConfig.API_KEY, TmdbSettingsRepository.effectiveApiKey())
        assertNull(pushedSettings()["tmdb_api_key"])
    }

    @Test
    fun savedPersonalKeyOverridesBundledKeyAndSurvivesReload() {
        TmdbSettingsRepository.setApiKey("  personal-key  ")
        TmdbSettingsRepository.onProfileChanged()

        assertEquals("personal-key", TmdbSettingsRepository.snapshot().apiKey)
        assertEquals("personal-key", TmdbSettingsRepository.effectiveApiKey())
        // A personal key does not switch enrichment on by itself.
        assertFalse(TmdbSettingsRepository.snapshot().enabled)
        assertNull(pushedSettings()["tmdb_api_key"])
    }

    @Test
    fun clearingPersonalKeyRestoresBundledKeyWithoutDisablingEnrichment() {
        TmdbSettingsRepository.setEnabled(true)
        TmdbSettingsRepository.setApiKey("personal-key")
        TmdbSettingsRepository.setApiKey("  ")
        TmdbSettingsRepository.onProfileChanged()

        assertEquals("", TmdbSettingsRepository.snapshot().apiKey)
        assertEquals(TmdbConfig.API_KEY, TmdbSettingsRepository.effectiveApiKey())
        assertTrue(TmdbSettingsRepository.snapshot().enabled)
    }

    @Test
    fun legacyPersonalKeysAreRestoredAndExcludedFromSync() {
        // rc13 purged this pref on the next settings pull; with df589078 a key left on disk is
        // simply the personal override again.
        TmdbSettingsStorage.saveEnabled(true)
        TmdbSettingsStorage.saveApiKey("legacy-personal-key")
        TmdbSettingsRepository.onProfileChanged()

        assertTrue(TmdbSettingsRepository.snapshot().enabled)
        assertEquals("legacy-personal-key", TmdbSettingsRepository.effectiveApiKey())
        assertNull(pushedSettings()["tmdb_api_key"])
    }

    /**
     * Inverts rc13's `syncedSettingsIgnoreLegacyPersonalKeys` (which asserted the purge): a
     * remote settings blob never writes a personal key locally, a local key survives the apply's
     * delete pass, and the push still strips it.
     */
    @Test
    fun settingsSyncPreservesLocalOverride() {
        TmdbSettingsRepository.setApiKey("local-key")

        applyRemoteSettings(
            buildJsonObject {
                put("tmdb_enabled", encodeSyncBoolean(true))
                put("tmdb_api_key", encodeSyncString("remote-key"))
            },
        )

        assertEquals("local-key", TmdbSettingsRepository.effectiveApiKey())
        assertTrue(TmdbSettingsRepository.snapshot().enabled)
        assertNull(pushedSettings()["tmdb_api_key"])

        // A blob with no key at all (every current client pushes one like this) keeps it too.
        applyRemoteSettings(buildJsonObject {})

        assertEquals("local-key", TmdbSettingsRepository.effectiveApiKey())
    }

    @Test
    fun remoteOnlyPersonalKeyIsStagedNotAppliedBySettingsSync() {
        val remote = buildJsonObject {
            put("tmdb_enabled", encodeSyncBoolean(true))
            put("tmdb_api_key", encodeSyncString("remote-key"))
        }

        applyRemoteSettings(remote)

        // No local key: the blob's key is NOT written here (it would read as a local edit and be
        // pushed over the provider row) — it is extracted for ProviderCredentialSync to stage.
        assertEquals("", TmdbSettingsRepository.snapshot().apiKey)
        assertEquals(TmdbConfig.API_KEY, TmdbSettingsRepository.effectiveApiKey())
        assertTrue(TmdbSettingsRepository.snapshot().enabled)
        assertEquals(
            mapOf("tmdb_api_key" to "remote-key"),
            extractLegacyCredentials(PROFILE_TMDB_SETTINGS_FEATURE, remote),
        )
    }

    /** What `ProfileSettingsSync.exportSettingsBlob` pushes for this feature. */
    private fun pushedSettings(): JsonObject =
        withoutProfileCredentials(PROFILE_TMDB_SETTINGS_FEATURE, TmdbSettingsStorage.exportToSyncPayload())

    /** What `ProfileSettingsSync.applyRemoteBlob` does with an incoming `tmdb_settings` block. */
    private fun applyRemoteSettings(remote: JsonObject) {
        val local = TmdbSettingsStorage.exportToSyncPayload()
        TmdbSettingsStorage.replaceFromSyncPayload(
            preservingLocalProfileCredentials(PROFILE_TMDB_SETTINGS_FEATURE, remote, local),
        )
        TmdbSettingsRepository.onProfileChanged()
    }
}
