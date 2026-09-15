package com.nuvio.app.features.search

import com.nuvio.app.core.profile.ActiveProfileIdProvider
import com.nuvio.app.core.profile.ActiveProfileProvider
import kotlin.test.AfterTest
import kotlin.test.BeforeTest
import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertFalse
import kotlin.test.assertTrue

/**
 * Ported from upstream `7c1c6578` (`SearchHistoryPreferencesTest.kt`, originally a Robolectric
 * `androidHostTest`). `SearchHistoryStorage` has no sync-payload seam (unlike
 * `PlayerSettingsStorage`) and `commonTest` has no direct handle to the platform preferences
 * object upstream clears in `@BeforeTest` / reads for another profile in its last case, so this
 * resets known keys through the storage object's own public API and stands in for "another
 * profile" via `ActiveProfileProvider` (the shared `activeProfileId` seam `ProfileScopedKey`
 * reads), the same adaptation used by `PauseOverlaySettingsTest`.
 */
class SearchHistoryPreferencesTest {
    @BeforeTest
    fun initialize() {
        SearchHistoryStorage.savePayload("[]")
        SearchHistoryStorage.saveEnabled(true)
        SearchHistoryRepository.onProfileChanged()
    }

    @AfterTest
    fun tearDown() {
        ActiveProfileProvider.provider = ActiveProfileIdProvider { 1 }
        SearchHistoryStorage.savePayload("[]")
        SearchHistoryStorage.saveEnabled(true)
        SearchHistoryRepository.onProfileChanged()
    }

    @Test
    fun existingHistoryRemainsEnabledWhenNoPreferenceIsSaved() {
        SearchHistoryStorage.savePayload("[\"dune\",\"silo\"]")

        SearchHistoryRepository.onProfileChanged()

        assertTrue(SearchHistoryRepository.enabled.value)
        assertEquals(listOf("dune", "silo"), SearchHistoryRepository.uiState.value)
    }

    @Test
    fun disablingHistorySurvivesReloadAndStopsRecordingUntilReenabled() {
        SearchHistoryRepository.recordSearch("dune")
        SearchHistoryRepository.setEnabled(false)
        assertTrue(SearchHistoryRepository.uiState.value.isEmpty())

        SearchHistoryRepository.onProfileChanged()
        assertFalse(SearchHistoryRepository.enabled.value)
        assertTrue(SearchHistoryRepository.uiState.value.isEmpty())
        SearchHistoryRepository.recordSearch("silo")

        SearchHistoryRepository.setEnabled(true)
        SearchHistoryRepository.onProfileChanged()
        assertTrue(SearchHistoryRepository.enabled.value)
        assertEquals(listOf("dune"), SearchHistoryRepository.uiState.value)

        SearchHistoryRepository.recordSearch("arrival")
        assertEquals(listOf("arrival", "dune"), SearchHistoryRepository.uiState.value)
    }

    @Test
    fun changingPreferenceDoesNotReadOrOverwriteAnotherProfile() {
        val originalProvider = ActiveProfileProvider.provider
        try {
            ActiveProfileProvider.provider = ActiveProfileIdProvider { 99 }
            SearchHistoryStorage.saveEnabled(false)
            ActiveProfileProvider.provider = ActiveProfileIdProvider { 1 }

            SearchHistoryRepository.onProfileChanged()
            assertTrue(SearchHistoryRepository.enabled.value)

            SearchHistoryRepository.setEnabled(false)
            SearchHistoryRepository.setEnabled(true)

            ActiveProfileProvider.provider = ActiveProfileIdProvider { 99 }
            assertFalse(SearchHistoryStorage.loadEnabled() ?: true)
        } finally {
            ActiveProfileProvider.provider = originalProvider
        }
    }
}
