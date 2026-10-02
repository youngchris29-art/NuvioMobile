package com.nuvio.app.features.player

import com.nuvio.app.core.account.AccountDataStores
import com.nuvio.app.core.account.AppleKeySpec
import com.nuvio.app.core.profile.ActiveProfileIdProvider
import com.nuvio.app.core.profile.ActiveProfileProvider
import com.nuvio.app.core.sync.decodeSyncBoolean
import com.nuvio.app.features.player.skip.NextEpisodeThresholdMode
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
 * `preloadNextEpisodeSources` (upstream 22c9ab20 / FEAT-49) is a synced, profile-scoped Boolean that
 * defaults to false, placed beside the next-episode threshold settings. Same harness as
 * [StreamAutoPlayCachedOnlySettingsTest].
 */
class PreloadNextEpisodeSourcesSettingsTest {
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
    fun preloadDefaultsToOffAndKeepsTheSavedChoiceAfterReload() {
        PlayerSettingsRepository.ensureLoaded()
        assertFalse(PlayerSettingsRepository.uiState.value.preloadNextEpisodeSources)
        assertNull(PlayerSettingsStorage.loadPreloadNextEpisodeSources())

        PlayerSettingsRepository.setPreloadNextEpisodeSources(true)
        assertTrue(PlayerSettingsRepository.uiState.value.preloadNextEpisodeSources)
        PlayerSettingsRepository.onProfileChanged()

        assertTrue(PlayerSettingsRepository.uiState.value.preloadNextEpisodeSources)
        assertEquals(true, PlayerSettingsStorage.loadPreloadNextEpisodeSources())

        PlayerSettingsRepository.setPreloadNextEpisodeSources(false)
        PlayerSettingsRepository.onProfileChanged()

        assertFalse(PlayerSettingsRepository.uiState.value.preloadNextEpisodeSources)
        assertEquals(false, PlayerSettingsStorage.loadPreloadNextEpisodeSources())
    }

    @Test
    fun preloadIsIndependentOfTheThresholdSettings() {
        PlayerSettingsRepository.setNextEpisodeThresholdMode(NextEpisodeThresholdMode.MINUTES_BEFORE_END)
        PlayerSettingsRepository.setNextEpisodeThresholdMinutesBeforeEnd(3f)
        PlayerSettingsRepository.setPreloadNextEpisodeSources(true)
        PlayerSettingsRepository.onProfileChanged()

        val state = PlayerSettingsRepository.uiState.value
        assertTrue(state.preloadNextEpisodeSources)
        assertEquals(NextEpisodeThresholdMode.MINUTES_BEFORE_END, state.nextEpisodeThresholdMode)
        assertEquals(3f, state.nextEpisodeThresholdMinutesBeforeEnd)

        PlayerSettingsRepository.setPreloadNextEpisodeSources(false)
        PlayerSettingsRepository.onProfileChanged()

        val after = PlayerSettingsRepository.uiState.value
        assertFalse(after.preloadNextEpisodeSources)
        assertEquals(NextEpisodeThresholdMode.MINUTES_BEFORE_END, after.nextEpisodeThresholdMode)
        assertEquals(3f, after.nextEpisodeThresholdMinutesBeforeEnd)
    }

    @Test
    fun settingTheSameValueAgainDoesNotChangeState() {
        PlayerSettingsRepository.setPreloadNextEpisodeSources(true)
        val before = PlayerSettingsRepository.uiState.value
        PlayerSettingsRepository.setPreloadNextEpisodeSources(true)
        assertEquals(before, PlayerSettingsRepository.uiState.value)

        // ProfileSettingsSync's observed-state signature embeds `uiState.value.toString()`, so a
        // flip must be visible in the data class or a local edit would never be pushed.
        PlayerSettingsRepository.setPreloadNextEpisodeSources(false)
        assertNotEquals(before, PlayerSettingsRepository.uiState.value)
        assertNotEquals(before.toString(), PlayerSettingsRepository.uiState.value.toString())
    }

    @Test
    fun preloadRoundTripsThroughSyncAndOlderPayloadsRestoreTheDefault() {
        PlayerSettingsRepository.setPreloadNextEpisodeSources(true)
        val payload = PlayerSettingsStorage.exportToSyncPayload()
        assertEquals(true, payload.decodeSyncBoolean("preload_next_episode_sources"))

        PlayerSettingsRepository.setPreloadNextEpisodeSources(false)
        PlayerSettingsStorage.replaceFromSyncPayload(payload)
        PlayerSettingsRepository.onProfileChanged()
        assertTrue(PlayerSettingsRepository.uiState.value.preloadNextEpisodeSources)

        // A payload written before the key existed carries no value: the stored row is cleared
        // and the default comes back.
        PlayerSettingsStorage.replaceFromSyncPayload(buildJsonObject {})
        PlayerSettingsRepository.onProfileChanged()
        assertNull(PlayerSettingsStorage.loadPreloadNextEpisodeSources())
        assertFalse(PlayerSettingsRepository.uiState.value.preloadNextEpisodeSources)
    }

    @Test
    fun preloadIsStoredPerProfile() {
        PlayerSettingsRepository.setPreloadNextEpisodeSources(true)

        val originalProvider = ActiveProfileProvider.provider
        try {
            ActiveProfileProvider.provider = ActiveProfileIdProvider { 99 }
            // Start from a clean row: the JVM preferences file may outlive a previous run.
            PlayerSettingsStorage.replaceFromSyncPayload(buildJsonObject {})
            assertNull(PlayerSettingsStorage.loadPreloadNextEpisodeSources())
            PlayerSettingsStorage.savePreloadNextEpisodeSources(false)
            assertEquals(false, PlayerSettingsStorage.loadPreloadNextEpisodeSources())
            PlayerSettingsStorage.replaceFromSyncPayload(buildJsonObject {})
        } finally {
            ActiveProfileProvider.provider = originalProvider
        }

        assertEquals(true, PlayerSettingsStorage.loadPreloadNextEpisodeSources())
    }

    @Test
    fun keysAreRegisteredForSignOutWipe() {
        val scoped = AccountDataStores.all.flatMap { it.appleKeys }
            .filterIsInstance<AppleKeySpec.ProfileScoped>().map { it.base }
        assertTrue("preload_next_episode_sources" in scoped)
        assertTrue("debrid_instant_playback_preparation_limit" in scoped)
    }
}
