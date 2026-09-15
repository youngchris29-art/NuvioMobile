package com.nuvio.app.features.player

import com.nuvio.app.core.profile.ActiveProfileIdProvider
import com.nuvio.app.core.profile.ActiveProfileProvider
import com.nuvio.app.core.sync.decodeSyncBoolean
import kotlinx.serialization.json.buildJsonObject
import kotlin.test.AfterTest
import kotlin.test.BeforeTest
import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertFalse
import kotlin.test.assertNull
import kotlin.test.assertTrue

/**
 * Ported from upstream `ecb69a88` (`PauseOverlaySettingsTest.kt`, originally a Robolectric
 * `androidHostTest`). The fork's `commonTest` has no direct handle to the platform preferences
 * object the upstream test clears in `@BeforeTest`/reads for another profile in its last case, so
 * both are adapted to seams that exist in `commonMain`: `PlayerSettingsStorage.replaceFromSyncPayload`
 * (clears every synced key for the *current* profile, same effect as clearing the backing store)
 * and `ActiveProfileProvider` (the shared `activeProfileId` seam `ProfileScopedKey` reads) to stand
 * in for writing/reading a second profile's row directly.
 */
class PauseOverlaySettingsTest {
    @BeforeTest
    fun initialize() {
        PlayerSettingsStorage.replaceFromSyncPayload(buildJsonObject {})
        PlayerSettingsRepository.clearLocalState()
    }

    @AfterTest
    fun clearState() {
        PlayerSettingsStorage.replaceFromSyncPayload(buildJsonObject {})
        PlayerSettingsRepository.clearLocalState()
    }

    @Test
    fun pauseOverlayDefaultsToEnabledAndKeepsTheSavedChoiceAfterReload() {
        PlayerSettingsRepository.ensureLoaded()
        assertTrue(PlayerSettingsRepository.uiState.value.pauseOverlayEnabled)

        PlayerSettingsRepository.setPauseOverlayEnabled(false)
        PlayerSettingsRepository.onProfileChanged()

        assertFalse(PlayerSettingsRepository.uiState.value.pauseOverlayEnabled)
        assertEquals(false, PlayerSettingsStorage.loadPauseOverlayEnabled())
        assertTrue(PlayerSettingsRepository.uiState.value.showLoadingOverlay)
    }

    @Test
    fun loadingAndPauseOverlaysCanBeToggledIndependently() {
        PlayerSettingsRepository.setShowLoadingOverlay(false)
        PlayerSettingsRepository.setPauseOverlayEnabled(false)
        PlayerSettingsRepository.setShowLoadingOverlay(true)
        PlayerSettingsRepository.onProfileChanged()

        assertTrue(PlayerSettingsRepository.uiState.value.showLoadingOverlay)
        assertFalse(PlayerSettingsRepository.uiState.value.pauseOverlayEnabled)

        PlayerSettingsRepository.setShowLoadingOverlay(false)
        PlayerSettingsRepository.setPauseOverlayEnabled(true)
        PlayerSettingsRepository.onProfileChanged()

        assertFalse(PlayerSettingsRepository.uiState.value.showLoadingOverlay)
        assertTrue(PlayerSettingsRepository.uiState.value.pauseOverlayEnabled)
    }

    @Test
    fun pauseOverlayRoundTripsThroughSyncAndOlderPayloadsRestoreTheDefault() {
        PlayerSettingsRepository.setPauseOverlayEnabled(false)
        val payload = PlayerSettingsStorage.exportToSyncPayload()
        assertEquals(false, payload.decodeSyncBoolean("pause_overlay_enabled"))

        PlayerSettingsRepository.setPauseOverlayEnabled(true)
        PlayerSettingsStorage.replaceFromSyncPayload(payload)
        PlayerSettingsRepository.onProfileChanged()
        assertFalse(PlayerSettingsRepository.uiState.value.pauseOverlayEnabled)

        // Fork adaptation of upstream's "another profile's raw preference row" check: write the
        // other profile's value through the real ProfileScopedKey seam instead of poking a
        // platform SharedPreferences object the commonTest world doesn't have.
        val originalProvider = ActiveProfileProvider.provider
        try {
            ActiveProfileProvider.provider = ActiveProfileIdProvider { 99 }
            PlayerSettingsStorage.savePauseOverlayEnabled(false)
        } finally {
            ActiveProfileProvider.provider = originalProvider
        }

        PlayerSettingsStorage.replaceFromSyncPayload(buildJsonObject {})
        PlayerSettingsRepository.onProfileChanged()

        assertNull(PlayerSettingsStorage.loadPauseOverlayEnabled())
        assertTrue(PlayerSettingsRepository.uiState.value.pauseOverlayEnabled)

        try {
            ActiveProfileProvider.provider = ActiveProfileIdProvider { 99 }
            assertFalse(PlayerSettingsStorage.loadPauseOverlayEnabled() ?: true)
        } finally {
            ActiveProfileProvider.provider = originalProvider
        }
    }
}
