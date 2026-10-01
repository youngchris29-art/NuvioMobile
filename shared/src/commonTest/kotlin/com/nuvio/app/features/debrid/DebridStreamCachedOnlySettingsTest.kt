package com.nuvio.app.features.debrid

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
 * `DebridSettings.streamCachedOnly` ("Cached Sources Only", key `debrid_stream_cached_only`): off by
 * default, persisted per profile, and carried through the settings sync payload like the other
 * debrid stream filters.
 */
class DebridStreamCachedOnlySettingsTest {
    @BeforeTest
    fun initialize() {
        DebridSettingsStorage.replaceFromSyncPayload(buildJsonObject {})
        DebridSettingsRepository.onProfileChanged()
    }

    @AfterTest
    fun clearState() {
        DebridSettingsStorage.replaceFromSyncPayload(buildJsonObject {})
        DebridSettingsRepository.onProfileChanged()
    }

    @Test
    fun `cached only defaults to off`() {
        assertFalse(DebridSettings().streamCachedOnly)
        assertFalse(DebridSettingsRepository.snapshot().streamCachedOnly)
        assertNull(DebridSettingsStorage.loadStreamCachedOnly())
    }

    @Test
    fun `cached only round-trips through the repository and storage`() {
        DebridSettingsRepository.setStreamCachedOnly(true)
        assertTrue(DebridSettingsRepository.uiState.value.streamCachedOnly)
        assertEquals(true, DebridSettingsStorage.loadStreamCachedOnly())

        // A fresh load from disk keeps the choice.
        DebridSettingsRepository.onProfileChanged()
        assertTrue(DebridSettingsRepository.uiState.value.streamCachedOnly)

        DebridSettingsRepository.setStreamCachedOnly(false)
        assertFalse(DebridSettingsRepository.uiState.value.streamCachedOnly)
        assertEquals(false, DebridSettingsStorage.loadStreamCachedOnly())

        DebridSettingsRepository.onProfileChanged()
        assertFalse(DebridSettingsRepository.uiState.value.streamCachedOnly)
    }

    @Test
    fun `cached only leaves the other stream filters alone`() {
        DebridSettingsRepository.setStreamHdrFilter(DebridStreamFeatureFilter.ONLY)
        DebridSettingsRepository.setStreamMinimumQuality(DebridStreamMinimumQuality.P1080)
        DebridSettingsRepository.setStreamCachedOnly(true)
        DebridSettingsRepository.onProfileChanged()

        val settings = DebridSettingsRepository.uiState.value
        assertTrue(settings.streamCachedOnly)
        assertEquals(DebridStreamFeatureFilter.ONLY, settings.streamHdrFilter)
        assertEquals(DebridStreamMinimumQuality.P1080, settings.streamMinimumQuality)
    }

    @Test
    fun `cached only round-trips through the sync payload and older payloads restore the default`() {
        DebridSettingsRepository.setStreamCachedOnly(true)
        val payload = DebridSettingsStorage.exportToSyncPayload()
        assertEquals(true, payload.decodeSyncBoolean("debrid_stream_cached_only"))

        DebridSettingsRepository.setStreamCachedOnly(false)
        DebridSettingsStorage.replaceFromSyncPayload(payload)
        DebridSettingsRepository.onProfileChanged()
        assertTrue(DebridSettingsRepository.uiState.value.streamCachedOnly)

        // A payload from before this setting existed carries no key: replace clears the local one.
        DebridSettingsStorage.replaceFromSyncPayload(buildJsonObject {})
        DebridSettingsRepository.onProfileChanged()
        assertFalse(DebridSettingsRepository.uiState.value.streamCachedOnly)
        assertNull(DebridSettingsStorage.loadStreamCachedOnly())
    }
}
