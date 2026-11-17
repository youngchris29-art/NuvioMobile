package com.nuvio.app.features.player

import com.nuvio.app.core.account.AccountDataStores
import com.nuvio.app.core.account.AppleKeySpec
import com.nuvio.app.core.profile.ActiveProfileIdProvider
import com.nuvio.app.core.profile.ActiveProfileProvider
import com.nuvio.app.core.sync.decodeSyncBoolean
import com.nuvio.app.core.sync.decodeSyncInt
import com.nuvio.app.core.sync.encodeSyncInt
import com.nuvio.app.features.streams.StreamAutoPlayMode
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
 * The three source-fallback settings (upstream 8fba6c71e, W4): `streamAutoPlayFallbackOnFailure`
 * (fork default On), `streamAutoPlayFallbackMaxSources` (1..10, 3) and
 * `streamAutoPlayFallbackStartupTimeoutSeconds` (5..45 in steps of 5, 15). All synced and
 * profile scoped; out-of-range values are clamped on load, on set and on sync decode. Same harness
 * as [ChapterTitleSettingsTest].
 */
class SourceFallbackSettingsTest {
    private val maxKey = "stream_auto_play_fallback_max_sources"
    private val timeoutKey = "stream_auto_play_fallback_startup_timeout_seconds"
    private val switchKey = "stream_auto_play_fallback_on_failure"

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
    fun defaultsAreOnThreeSourcesAndFifteenSeconds() {
        PlayerSettingsRepository.ensureLoaded()
        val state = PlayerSettingsRepository.uiState.value
        assertTrue(state.streamAutoPlayFallbackOnFailure)
        assertEquals(3, state.streamAutoPlayFallbackMaxSources)
        assertEquals(15, state.streamAutoPlayFallbackStartupTimeoutSeconds)
        assertNull(PlayerSettingsStorage.loadStreamAutoPlayFallbackOnFailure())
        assertNull(PlayerSettingsStorage.loadStreamAutoPlayFallbackMaxSources())
        assertNull(PlayerSettingsStorage.loadStreamAutoPlayFallbackStartupTimeoutSeconds())
    }

    @Test
    fun savedChoicesSurviveReloadAndAStoredOffIsNeverOverriddenByTheDefault() {
        PlayerSettingsRepository.setStreamAutoPlayFallbackOnFailure(false)
        PlayerSettingsRepository.setStreamAutoPlayFallbackMaxSources(7)
        PlayerSettingsRepository.setStreamAutoPlayFallbackStartupTimeoutSeconds(30)
        PlayerSettingsRepository.onProfileChanged()

        val state = PlayerSettingsRepository.uiState.value
        assertFalse(state.streamAutoPlayFallbackOnFailure)
        assertEquals(7, state.streamAutoPlayFallbackMaxSources)
        assertEquals(30, state.streamAutoPlayFallbackStartupTimeoutSeconds)
        assertEquals(false, PlayerSettingsStorage.loadStreamAutoPlayFallbackOnFailure())
        assertEquals(7, PlayerSettingsStorage.loadStreamAutoPlayFallbackMaxSources())
        assertEquals(30, PlayerSettingsStorage.loadStreamAutoPlayFallbackStartupTimeoutSeconds())
    }

    @Test
    fun settingTheSameValueAgainDoesNotChangeStateAndAFlipIsVisibleInTheDataClass() {
        PlayerSettingsRepository.setStreamAutoPlayFallbackMaxSources(5)
        val before = PlayerSettingsRepository.uiState.value
        PlayerSettingsRepository.setStreamAutoPlayFallbackMaxSources(5)
        assertEquals(before, PlayerSettingsRepository.uiState.value)

        // ProfileSettingsSync's observed-state signature embeds `uiState.value.toString()`.
        PlayerSettingsRepository.setStreamAutoPlayFallbackMaxSources(6)
        PlayerSettingsRepository.setStreamAutoPlayFallbackStartupTimeoutSeconds(20)
        PlayerSettingsRepository.setStreamAutoPlayFallbackOnFailure(false)
        val after = PlayerSettingsRepository.uiState.value
        assertNotEquals(before, after)
        assertNotEquals(before.toString(), after.toString())
        assertEquals(6, after.streamAutoPlayFallbackMaxSources)
        assertEquals(20, after.streamAutoPlayFallbackStartupTimeoutSeconds)
        assertFalse(after.streamAutoPlayFallbackOnFailure)
    }

    @Test
    fun settersClampToTheRanges() {
        PlayerSettingsRepository.setStreamAutoPlayFallbackMaxSources(0)
        assertEquals(1, PlayerSettingsRepository.uiState.value.streamAutoPlayFallbackMaxSources)
        assertEquals(1, PlayerSettingsStorage.loadStreamAutoPlayFallbackMaxSources())
        PlayerSettingsRepository.setStreamAutoPlayFallbackMaxSources(99)
        assertEquals(10, PlayerSettingsRepository.uiState.value.streamAutoPlayFallbackMaxSources)
        assertEquals(10, PlayerSettingsStorage.loadStreamAutoPlayFallbackMaxSources())

        PlayerSettingsRepository.setStreamAutoPlayFallbackStartupTimeoutSeconds(1)
        assertEquals(5, PlayerSettingsRepository.uiState.value.streamAutoPlayFallbackStartupTimeoutSeconds)
        PlayerSettingsRepository.setStreamAutoPlayFallbackStartupTimeoutSeconds(600)
        assertEquals(45, PlayerSettingsRepository.uiState.value.streamAutoPlayFallbackStartupTimeoutSeconds)
        assertEquals(45, PlayerSettingsStorage.loadStreamAutoPlayFallbackStartupTimeoutSeconds())
    }

    @Test
    fun startupLimitRoundsToTheNearestFiveSecondStep() {
        val cases = mapOf(7 to 5, 8 to 10, 12 to 10, 13 to 15, 17 to 15, 18 to 20, 44 to 45, 46 to 45, -3 to 5)
        for ((input, expected) in cases) {
            assertEquals(expected, normalizeSourceStartupTimeoutSeconds(input), "input $input")
        }
        PlayerSettingsRepository.setStreamAutoPlayFallbackStartupTimeoutSeconds(18)
        assertEquals(20, PlayerSettingsRepository.uiState.value.streamAutoPlayFallbackStartupTimeoutSeconds)
        assertEquals(20, PlayerSettingsStorage.loadStreamAutoPlayFallbackStartupTimeoutSeconds())
    }

    @Test
    fun outOfRangeStoredValuesAreClampedOnLoad() {
        PlayerSettingsStorage.saveStreamAutoPlayFallbackMaxSources(99)
        PlayerSettingsStorage.saveStreamAutoPlayFallbackStartupTimeoutSeconds(17)
        PlayerSettingsRepository.onProfileChanged()
        assertEquals(10, PlayerSettingsRepository.uiState.value.streamAutoPlayFallbackMaxSources)
        assertEquals(15, PlayerSettingsRepository.uiState.value.streamAutoPlayFallbackStartupTimeoutSeconds)

        PlayerSettingsStorage.saveStreamAutoPlayFallbackMaxSources(-4)
        PlayerSettingsStorage.saveStreamAutoPlayFallbackStartupTimeoutSeconds(300)
        PlayerSettingsRepository.onProfileChanged()
        assertEquals(1, PlayerSettingsRepository.uiState.value.streamAutoPlayFallbackMaxSources)
        assertEquals(45, PlayerSettingsRepository.uiState.value.streamAutoPlayFallbackStartupTimeoutSeconds)
    }

    @Test
    fun settingsRoundTripThroughSyncAndOlderPayloadsRestoreTheDefaults() {
        PlayerSettingsRepository.setStreamAutoPlayFallbackOnFailure(false)
        PlayerSettingsRepository.setStreamAutoPlayFallbackMaxSources(8)
        PlayerSettingsRepository.setStreamAutoPlayFallbackStartupTimeoutSeconds(25)
        val payload = PlayerSettingsStorage.exportToSyncPayload()
        assertEquals(false, payload.decodeSyncBoolean(switchKey))
        assertEquals(8, payload.decodeSyncInt(maxKey))
        assertEquals(25, payload.decodeSyncInt(timeoutKey))

        PlayerSettingsRepository.setStreamAutoPlayFallbackOnFailure(true)
        PlayerSettingsRepository.setStreamAutoPlayFallbackMaxSources(2)
        PlayerSettingsRepository.setStreamAutoPlayFallbackStartupTimeoutSeconds(5)
        PlayerSettingsStorage.replaceFromSyncPayload(payload)
        PlayerSettingsRepository.onProfileChanged()
        val restored = PlayerSettingsRepository.uiState.value
        assertFalse(restored.streamAutoPlayFallbackOnFailure)
        assertEquals(8, restored.streamAutoPlayFallbackMaxSources)
        assertEquals(25, restored.streamAutoPlayFallbackStartupTimeoutSeconds)

        // A payload from a phone that never touched the settings carries nothing: the rows are
        // cleared and the TV's own defaults come back.
        PlayerSettingsStorage.replaceFromSyncPayload(buildJsonObject {})
        PlayerSettingsRepository.onProfileChanged()
        assertNull(PlayerSettingsStorage.loadStreamAutoPlayFallbackOnFailure())
        assertNull(PlayerSettingsStorage.loadStreamAutoPlayFallbackMaxSources())
        assertNull(PlayerSettingsStorage.loadStreamAutoPlayFallbackStartupTimeoutSeconds())
        val defaults = PlayerSettingsRepository.uiState.value
        assertTrue(defaults.streamAutoPlayFallbackOnFailure)
        assertEquals(3, defaults.streamAutoPlayFallbackMaxSources)
        assertEquals(15, defaults.streamAutoPlayFallbackStartupTimeoutSeconds)
    }

    @Test
    fun syncedOutOfRangeValuesAreClampedWhenDecoded() {
        PlayerSettingsStorage.replaceFromSyncPayload(
            buildJsonObject {
                put(maxKey, encodeSyncInt(99))
                put(timeoutKey, encodeSyncInt(17))
            },
        )
        assertEquals(10, PlayerSettingsStorage.loadStreamAutoPlayFallbackMaxSources())
        assertEquals(15, PlayerSettingsStorage.loadStreamAutoPlayFallbackStartupTimeoutSeconds())

        PlayerSettingsStorage.replaceFromSyncPayload(
            buildJsonObject {
                put(maxKey, encodeSyncInt(0))
                put(timeoutKey, encodeSyncInt(2))
            },
        )
        assertEquals(1, PlayerSettingsStorage.loadStreamAutoPlayFallbackMaxSources())
        assertEquals(5, PlayerSettingsStorage.loadStreamAutoPlayFallbackStartupTimeoutSeconds())
    }

    @Test
    fun settingsAreStoredPerProfile() {
        PlayerSettingsRepository.setStreamAutoPlayFallbackMaxSources(9)
        PlayerSettingsRepository.setStreamAutoPlayFallbackOnFailure(false)

        val originalProvider = ActiveProfileProvider.provider
        try {
            ActiveProfileProvider.provider = ActiveProfileIdProvider { 99 }
            PlayerSettingsStorage.replaceFromSyncPayload(buildJsonObject {})
            assertNull(PlayerSettingsStorage.loadStreamAutoPlayFallbackMaxSources())
            assertNull(PlayerSettingsStorage.loadStreamAutoPlayFallbackOnFailure())
            PlayerSettingsStorage.saveStreamAutoPlayFallbackMaxSources(2)
            assertEquals(2, PlayerSettingsStorage.loadStreamAutoPlayFallbackMaxSources())
            PlayerSettingsStorage.replaceFromSyncPayload(buildJsonObject {})
        } finally {
            ActiveProfileProvider.provider = originalProvider
        }

        assertEquals(9, PlayerSettingsStorage.loadStreamAutoPlayFallbackMaxSources())
        assertEquals(false, PlayerSettingsStorage.loadStreamAutoPlayFallbackOnFailure())
    }

    @Test
    fun keysAreRegisteredForSignOutWipe() {
        val scoped = AccountDataStores.all.flatMap { it.appleKeys }
            .filterIsInstance<AppleKeySpec.ProfileScoped>().map { it.base }
        assertTrue(switchKey in scoped)
        assertTrue(maxKey in scoped)
        assertTrue(timeoutKey in scoped)
    }

    @Test
    fun composeParityRuleNeedsAnAutoMode() {
        val on = PlayerSettingsUiState(streamAutoPlayMode = StreamAutoPlayMode.FIRST_STREAM)
        assertTrue(on.streamAutoPlayFallbackActive)
        assertFalse(on.copy(streamAutoPlayMode = StreamAutoPlayMode.MANUAL).streamAutoPlayFallbackActive)
        assertFalse(on.copy(externalPlayerEnabled = true).streamAutoPlayFallbackActive)
        assertFalse(on.copy(streamAutoPlayFallbackOnFailure = false).streamAutoPlayFallbackActive)
    }
}
