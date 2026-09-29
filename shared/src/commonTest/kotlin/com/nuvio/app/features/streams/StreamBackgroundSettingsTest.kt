package com.nuvio.app.features.streams

import com.nuvio.app.core.sync.decodeSyncString
import kotlinx.serialization.json.buildJsonObject
import kotlin.test.AfterTest
import kotlin.test.BeforeTest
import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertNull

/**
 * Port of upstream `50d39823`'s `StreamBackgroundSettingsTest` (Robolectric + Compose
 * `androidHostTest`) to a platform-neutral `commonTest`. Kept: default, reload + sync round trip,
 * older-settings restore, removed/unknown modes. Dropped: the Compose picker, tablet-hiding and
 * settings-search cases (composeApp UI, no shared/ seam) and the other-profile SharedPreferences
 * assertion (needs the Android handle). The store is reset through `replaceFromSyncPayload`, which
 * clears every synced key for the current profile.
 */
class StreamBackgroundSettingsTest {
    @BeforeTest
    fun initialize() {
        StreamBadgeSettingsStorage.replaceFromSyncPayload(buildJsonObject {})
        StreamBadgeSettingsRepository.clearLocalState()
    }

    @AfterTest
    fun clearState() {
        StreamBadgeSettingsStorage.replaceFromSyncPayload(buildJsonObject {})
        StreamBadgeSettingsRepository.clearLocalState()
    }

    @Test
    fun existingProfilesUseTheAppBackgroundByDefault() {
        StreamBadgeSettingsRepository.ensureLoaded()
        assertEquals(StreamBackgroundMode.Normal, StreamBadgeSettingsRepository.uiState.value.backgroundMode)
    }

    @Test
    fun cinematicBackgroundSurvivesReloadAndSettingsSync() {
        StreamBadgeSettingsRepository.setBackgroundMode(StreamBackgroundMode.Cinematic)
        StreamBadgeSettingsRepository.clearLocalState()
        StreamBadgeSettingsRepository.ensureLoaded()
        assertEquals(StreamBackgroundMode.Cinematic, StreamBadgeSettingsRepository.uiState.value.backgroundMode)

        val payload = StreamBadgeSettingsStorage.exportToSyncPayload()
        assertEquals("cinematic", payload.decodeSyncString("stream_background_mode"))
        StreamBadgeSettingsRepository.setBackgroundMode(StreamBackgroundMode.Normal)
        StreamBadgeSettingsStorage.replaceFromSyncPayload(payload)
        StreamBadgeSettingsRepository.onProfileChanged()
        assertEquals(StreamBackgroundMode.Cinematic, StreamBadgeSettingsRepository.uiState.value.backgroundMode)
    }

    @Test
    fun olderSettingsRestoreTheDefault() {
        StreamBadgeSettingsRepository.setBackgroundMode(StreamBackgroundMode.Cinematic)

        StreamBadgeSettingsStorage.replaceFromSyncPayload(buildJsonObject {})
        StreamBadgeSettingsRepository.onProfileChanged()

        assertEquals(StreamBackgroundMode.Normal, StreamBadgeSettingsRepository.uiState.value.backgroundMode)
        assertNull(StreamBadgeSettingsStorage.loadStreamBackgroundMode())
    }

    @Test
    fun removedAndUnknownBackgroundModesFallBackToNormal() {
        listOf("dominantcolor", "unknown").forEach { mode ->
            StreamBadgeSettingsStorage.saveStreamBackgroundMode(mode)
            StreamBadgeSettingsRepository.onProfileChanged()
            assertEquals(StreamBackgroundMode.Normal, StreamBadgeSettingsRepository.uiState.value.backgroundMode)
        }
    }
}
