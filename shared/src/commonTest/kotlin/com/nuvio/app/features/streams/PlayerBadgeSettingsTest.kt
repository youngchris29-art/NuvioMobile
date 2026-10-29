package com.nuvio.app.features.streams

import com.nuvio.app.core.sync.decodeSyncBoolean
import com.nuvio.app.core.sync.decodeSyncString
import kotlinx.serialization.json.buildJsonObject
import kotlin.test.AfterTest
import kotlin.test.BeforeTest
import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertFalse
import kotlin.test.assertNull
import kotlin.test.assertTrue

/**
 * Player badges (upstream `344117e73` + `83e528f00`): `showInPlayer` defaults to off and
 * `playerBadgeSource` to blank ("same pack as the stream list"); both persist through the
 * repository, reload from storage and ride the settings sync like upstream's.
 */
class PlayerBadgeSettingsTest {
    @BeforeTest
    fun initialize() = reset()

    @AfterTest
    fun clearState() = reset()

    private fun reset() {
        StreamBadgeSettingsStorage.replaceFromSyncPayload(buildJsonObject {})
        StreamBadgeSettingsRepository.clearLocalState()
    }

    @Test
    fun defaultsAreOffAndSameAsStreamsWithoutWritingThem() {
        StreamBadgeSettingsRepository.ensureLoaded()
        val state = StreamBadgeSettingsRepository.uiState.value
        assertFalse(state.showInPlayer)
        assertEquals("", state.playerBadgeSource)
        assertNull(StreamBadgeSettingsStorage.loadShowInPlayer())
        assertNull(StreamBadgeSettingsStorage.loadPlayerBadgeSource())
    }

    @Test
    fun bothFieldsPersistAndReload() {
        StreamBadgeSettingsRepository.setShowInPlayer(true)
        StreamBadgeSettingsRepository.setPlayerBadgeSource("https://example.com/player.json")
        assertTrue(StreamBadgeSettingsRepository.uiState.value.showInPlayer)
        assertEquals("https://example.com/player.json", StreamBadgeSettingsRepository.uiState.value.playerBadgeSource)

        StreamBadgeSettingsRepository.clearLocalState()
        StreamBadgeSettingsRepository.ensureLoaded()
        val state = StreamBadgeSettingsRepository.uiState.value
        assertTrue(state.showInPlayer)
        assertEquals("https://example.com/player.json", state.playerBadgeSource)
        assertEquals(true, StreamBadgeSettingsStorage.loadShowInPlayer())
        assertEquals("https://example.com/player.json", StreamBadgeSettingsStorage.loadPlayerBadgeSource())
    }

    @Test
    fun clearingTheSourceGoesBackToSameAsStreams() {
        StreamBadgeSettingsRepository.setPlayerBadgeSource("https://example.com/player.json")
        StreamBadgeSettingsRepository.setPlayerBadgeSource("")
        StreamBadgeSettingsRepository.clearLocalState()
        StreamBadgeSettingsRepository.ensureLoaded()
        assertEquals("", StreamBadgeSettingsRepository.uiState.value.playerBadgeSource)
    }

    @Test
    fun bothFieldsRideTheSettingsSync() {
        StreamBadgeSettingsRepository.setShowInPlayer(true)
        StreamBadgeSettingsRepository.setPlayerBadgeSource("https://example.com/player.json")

        val payload = StreamBadgeSettingsStorage.exportToSyncPayload()
        assertEquals(true, payload.decodeSyncBoolean("show_badges_in_player"))
        assertEquals("https://example.com/player.json", payload.decodeSyncString("player_badge_source"))

        StreamBadgeSettingsRepository.setShowInPlayer(false)
        StreamBadgeSettingsRepository.setPlayerBadgeSource("")
        StreamBadgeSettingsStorage.replaceFromSyncPayload(payload)
        StreamBadgeSettingsRepository.onProfileChanged()
        assertTrue(StreamBadgeSettingsRepository.uiState.value.showInPlayer)
        assertEquals("https://example.com/player.json", StreamBadgeSettingsRepository.uiState.value.playerBadgeSource)

        // Older settings (no keys) restore the defaults.
        StreamBadgeSettingsStorage.replaceFromSyncPayload(buildJsonObject {})
        StreamBadgeSettingsRepository.onProfileChanged()
        assertFalse(StreamBadgeSettingsRepository.uiState.value.showInPlayer)
        assertEquals("", StreamBadgeSettingsRepository.uiState.value.playerBadgeSource)
    }
}
