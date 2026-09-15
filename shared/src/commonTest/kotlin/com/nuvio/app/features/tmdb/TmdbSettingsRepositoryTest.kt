package com.nuvio.app.features.tmdb

import com.nuvio.app.core.sync.encodeSyncBoolean
import com.nuvio.app.core.sync.encodeSyncString
import kotlinx.serialization.json.buildJsonObject
import kotlin.test.AfterTest
import kotlin.test.BeforeTest
import kotlin.test.Test
import kotlin.test.assertFalse
import kotlin.test.assertNull
import kotlin.test.assertTrue

/**
 * Ported from upstream `60ee0160` (`TmdbSettingsRepositoryTest.kt`, originally a Robolectric
 * `androidHostTest`). Upstream's cases 1 and 3 are kept; case 2 ("legacy personal keys are
 * ignored") wrote a raw `tmdb_api_key` pref through the Android `SharedPreferences` handle, which
 * `commonTest` has no seam for — case 3 covers the same invariant through the sync payload, which
 * is the path a legacy key actually arrives on.
 *
 * Reset uses `TmdbSettingsStorage.replaceFromSyncPayload({})` (clears every synced key for the
 * current profile, the same effect as clearing the backing store) — the pattern
 * `PauseOverlaySettingsTest` uses. Note `setEnabled` fans out to
 * `HomeRepository.onTmdbSettingsChanged()`; that is deliberate coverage of the real call path, and
 * the fan-out only resets in-memory hero enrichment.
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

        assertTrue(TmdbSettingsRepository.snapshot().enabled)
        assertNull(TmdbSettingsStorage.exportToSyncPayload()["tmdb_api_key"])
    }

    @Test
    fun syncedSettingsIgnoreLegacyPersonalKeys() {
        TmdbSettingsStorage.replaceFromSyncPayload(
            buildJsonObject {
                put("tmdb_enabled", encodeSyncBoolean(true))
                put("tmdb_api_key", encodeSyncString("remote-personal-key"))
            },
        )
        TmdbSettingsRepository.onProfileChanged()

        assertTrue(TmdbSettingsRepository.snapshot().enabled)
        // `apiKeyKey` is still registered in `syncKeys`, so the apply's delete pass purges any
        // orphaned local pref; nothing writes it back, so it never re-enters an export.
        assertNull(TmdbSettingsStorage.exportToSyncPayload()["tmdb_api_key"])

        TmdbSettingsRepository.setEnabled(false)
        TmdbSettingsRepository.onProfileChanged()

        assertFalse(TmdbSettingsRepository.snapshot().enabled)
    }
}
