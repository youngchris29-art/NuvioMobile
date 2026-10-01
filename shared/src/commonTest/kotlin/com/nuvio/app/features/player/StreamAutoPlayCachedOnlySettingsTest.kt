package com.nuvio.app.features.player

import com.nuvio.app.core.account.AccountDataStores
import com.nuvio.app.core.account.AppleKeySpec
import com.nuvio.app.core.profile.ActiveProfileIdProvider
import com.nuvio.app.core.profile.ActiveProfileProvider
import com.nuvio.app.core.sync.decodeSyncBoolean
import kotlinx.serialization.json.buildJsonObject
import kotlin.test.AfterTest
import kotlin.test.BeforeTest
import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertFalse
import kotlin.test.assertNotEquals
import kotlin.test.assertNull
import kotlin.test.assertTrue

/**
 * `streamAutoPlayCachedOnly` mirrors its sibling `streamAutoPlayReuseBingeGroup`: a synced,
 * profile-scoped Boolean that defaults to false. Same harness as [PauseOverlaySettingsTest]:
 * `replaceFromSyncPayload(empty)` clears every synced key for the current profile, and
 * `ActiveProfileProvider` stands in for another profile's row.
 */
class StreamAutoPlayCachedOnlySettingsTest {
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
    fun cachedOnlyDefaultsToOffAndKeepsTheSavedChoiceAfterReload() {
        PlayerSettingsRepository.ensureLoaded()
        assertFalse(PlayerSettingsRepository.uiState.value.streamAutoPlayCachedOnly)
        assertNull(PlayerSettingsStorage.loadStreamAutoPlayCachedOnly())

        PlayerSettingsRepository.setStreamAutoPlayCachedOnly(true)
        assertTrue(PlayerSettingsRepository.uiState.value.streamAutoPlayCachedOnly)
        PlayerSettingsRepository.onProfileChanged()

        assertTrue(PlayerSettingsRepository.uiState.value.streamAutoPlayCachedOnly)
        assertEquals(true, PlayerSettingsStorage.loadStreamAutoPlayCachedOnly())

        PlayerSettingsRepository.setStreamAutoPlayCachedOnly(false)
        PlayerSettingsRepository.onProfileChanged()

        assertFalse(PlayerSettingsRepository.uiState.value.streamAutoPlayCachedOnly)
        assertEquals(false, PlayerSettingsStorage.loadStreamAutoPlayCachedOnly())
    }

    @Test
    fun cachedOnlyIsIndependentOfTheBingeGroupToggles() {
        PlayerSettingsRepository.setStreamAutoPlayReuseBingeGroup(true)
        PlayerSettingsRepository.setStreamAutoPlayCachedOnly(true)
        PlayerSettingsRepository.setStreamAutoPlayReuseBingeGroup(false)
        PlayerSettingsRepository.onProfileChanged()

        assertTrue(PlayerSettingsRepository.uiState.value.streamAutoPlayCachedOnly)
        assertFalse(PlayerSettingsRepository.uiState.value.streamAutoPlayReuseBingeGroup)
        assertTrue(PlayerSettingsRepository.uiState.value.streamAutoPlayPreferBingeGroup)
    }

    @Test
    fun settingTheSameValueAgainDoesNotChangeState() {
        PlayerSettingsRepository.setStreamAutoPlayCachedOnly(true)
        val before = PlayerSettingsRepository.uiState.value
        PlayerSettingsRepository.setStreamAutoPlayCachedOnly(true)
        assertEquals(before, PlayerSettingsRepository.uiState.value)

        // ProfileSettingsSync's observed-state signature embeds `uiState.value.toString()`, so a
        // flip must be visible in the data class or a local edit would never be pushed.
        PlayerSettingsRepository.setStreamAutoPlayCachedOnly(false)
        assertNotEquals(before, PlayerSettingsRepository.uiState.value)
        assertNotEquals(before.toString(), PlayerSettingsRepository.uiState.value.toString())
    }

    @Test
    fun cachedOnlyRoundTripsThroughSyncAndOlderPayloadsRestoreTheDefault() {
        PlayerSettingsRepository.setStreamAutoPlayCachedOnly(true)
        val payload = PlayerSettingsStorage.exportToSyncPayload()
        assertEquals(true, payload.decodeSyncBoolean("stream_auto_play_cached_only"))

        PlayerSettingsRepository.setStreamAutoPlayCachedOnly(false)
        PlayerSettingsStorage.replaceFromSyncPayload(payload)
        PlayerSettingsRepository.onProfileChanged()
        assertTrue(PlayerSettingsRepository.uiState.value.streamAutoPlayCachedOnly)

        // A payload written before the key existed carries no value: the stored row is cleared
        // and the default comes back.
        PlayerSettingsStorage.replaceFromSyncPayload(buildJsonObject {})
        PlayerSettingsRepository.onProfileChanged()
        assertNull(PlayerSettingsStorage.loadStreamAutoPlayCachedOnly())
        assertFalse(PlayerSettingsRepository.uiState.value.streamAutoPlayCachedOnly)
    }

    @Test
    fun cachedOnlyIsStoredPerProfile() {
        PlayerSettingsRepository.setStreamAutoPlayCachedOnly(true)

        val originalProvider = ActiveProfileProvider.provider
        try {
            ActiveProfileProvider.provider = ActiveProfileIdProvider { 99 }
            // Start from a clean row: the JVM preferences file may outlive a previous run.
            PlayerSettingsStorage.replaceFromSyncPayload(buildJsonObject {})
            assertNull(PlayerSettingsStorage.loadStreamAutoPlayCachedOnly())
            PlayerSettingsStorage.saveStreamAutoPlayCachedOnly(false)
            assertEquals(false, PlayerSettingsStorage.loadStreamAutoPlayCachedOnly())
            PlayerSettingsStorage.replaceFromSyncPayload(buildJsonObject {})
        } finally {
            ActiveProfileProvider.provider = originalProvider
        }

        assertEquals(true, PlayerSettingsStorage.loadStreamAutoPlayCachedOnly())
    }

    @Test
    fun newKeysAreRegisteredForSignOutWipe() {
        val scoped = AccountDataStores.all.flatMap { it.appleKeys }
            .filterIsInstance<AppleKeySpec.ProfileScoped>().map { it.base }
        assertTrue("stream_auto_play_cached_only" in scoped)
        // Written by the Apple storage since the fallback toggle shipped, but never registered.
        assertTrue("stream_auto_play_next_episode_fallback_enabled" in scoped)
        assertTrue("debrid_stream_cached_only" in scoped)

        assertTrue("pending_external_playback" in AccountDataStores.applePlainKeys())
        assertTrue("tvos_rejected_stream_links_v1" in AccountDataStores.applePlainKeys())
        assertTrue("nuvio_external_playback" in AccountDataStores.androidPreferenceNames())
    }
}
