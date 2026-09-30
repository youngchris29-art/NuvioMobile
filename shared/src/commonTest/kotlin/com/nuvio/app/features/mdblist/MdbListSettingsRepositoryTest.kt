package com.nuvio.app.features.mdblist

import kotlinx.serialization.json.JsonObject
import kotlin.test.AfterTest
import kotlin.test.BeforeTest
import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertFalse
import kotlin.test.assertNull
import kotlin.test.assertTrue

/**
 * Upstream 3f0d07be's androidHostTest `MdbListSettingsRepositoryTest`, moved to commonTest: the
 * storage is reset through its own sync-payload replace (clears every settings key) instead of
 * Robolectric SharedPreferences. Fork additions cover the Swift-facing account flags and the
 * settings-sync signature.
 */
class MdbListSettingsRepositoryTest {
    @BeforeTest
    fun initialize() {
        MdbListSettingsStorage.replaceFromSyncPayload(JsonObject(emptyMap()))
        MdbListSettingsRepository.onProfileChanged()
    }

    @AfterTest
    fun clearState() {
        initialize()
    }

    @Test
    fun enabledPreferenceSurvivesReloadWithoutAPersonalKey() {
        MdbListSettingsRepository.setEnabled(true)
        MdbListSettingsRepository.onProfileChanged()

        val settings = MdbListSettingsRepository.snapshot()
        assertTrue(settings.enabled)
        assertEquals("", settings.apiKey)
        assertFalse(settings.hasCredentials)
    }

    @Test
    fun clearingAnOverrideDoesNotDisableRatings() {
        MdbListSettingsRepository.setEnabled(true)
        MdbListSettingsRepository.setApiKey(" separate-key ")
        MdbListSettingsRepository.onProfileChanged()
        assertEquals("separate-key", MdbListSettingsRepository.snapshot().apiKey)

        MdbListSettingsRepository.setApiKey(" ")
        MdbListSettingsRepository.onProfileChanged()

        assertTrue(MdbListSettingsRepository.snapshot().enabled)
        assertEquals("", MdbListSettingsRepository.snapshot().apiKey)
        assertEquals(true, MdbListSettingsStorage.loadEnabled())
        assertEquals("", MdbListSettingsStorage.loadApiKey())
    }

    @Test
    fun settersPublishSynchronously() {
        MdbListSettingsRepository.setEnabled(true)
        assertTrue(MdbListSettingsRepository.uiState.value.enabled)
        MdbListSettingsRepository.setApiKey("key")
        assertEquals("key", MdbListSettingsRepository.uiState.value.apiKey)
        assertTrue(MdbListSettingsRepository.uiState.value.isActive)
    }

    @Test
    fun accountFlagsFollowTheConnectedScopeAndTheOverride() {
        val harness = MdbListTestHarness()
        val profileId = harness.store.scope().profileId
        val base = MdbListSettings(enabled = true)

        val disconnected = base.withAccount(harness.store.state.value, profileId)
        assertNull(disconnected.accountScope)
        assertFalse(disconnected.isAccountConnected)
        assertFalse(disconnected.usingAccount)
        assertFalse(disconnected.isActive)

        harness.connected()
        val connected = base.withAccount(harness.store.state.value, profileId)
        assertTrue(connected.isAccountConnected)
        assertTrue(connected.usingAccount)
        assertFalse(connected.hasPersonalKey)
        assertTrue(connected.isActive)
        assertEquals(MdbListRatingsCredential.Account(harness.store.scope()), connected.credential)

        val overridden = connected.copy(apiKey = " key ")
        assertTrue(overridden.isAccountConnected)
        assertFalse(overridden.usingAccount)
        assertTrue(overridden.hasPersonalKey)
        assertEquals(MdbListRatingsCredential.ApiKey("key"), overridden.credential)

        assertNull(base.withAccount(harness.store.state.value, profileId + 1).accountScope)
    }

    @Test
    fun accountScopeStaysOutOfTheSettingsSignature() {
        val harness = MdbListTestHarness()
        harness.connected()
        val base = MdbListSettings(enabled = true, apiKey = "key")
        val connected = base.withAccount(harness.store.state.value, harness.store.scope().profileId)

        assertTrue(connected.accountScope != null)
        assertEquals(base.toString(), connected.toString())
    }
}
