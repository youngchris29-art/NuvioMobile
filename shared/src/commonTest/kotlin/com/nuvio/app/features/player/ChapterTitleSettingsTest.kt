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
 * `chapterTitleEnabled` (upstream 637b21aa0) is a synced, profile-scoped Boolean that defaults to
 * true: the chapter name above the scrub preview. Same harness as
 * [PreloadNextEpisodeSourcesSettingsTest] with the default inverted.
 */
class ChapterTitleSettingsTest {
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
    fun chapterTitleDefaultsToOnAndKeepsTheSavedChoiceAfterReload() {
        PlayerSettingsRepository.ensureLoaded()
        assertTrue(PlayerSettingsRepository.uiState.value.chapterTitleEnabled)
        assertNull(PlayerSettingsStorage.loadChapterTitleEnabled())

        PlayerSettingsRepository.setChapterTitleEnabled(false)
        assertFalse(PlayerSettingsRepository.uiState.value.chapterTitleEnabled)
        PlayerSettingsRepository.onProfileChanged()

        assertFalse(PlayerSettingsRepository.uiState.value.chapterTitleEnabled)
        assertEquals(false, PlayerSettingsStorage.loadChapterTitleEnabled())

        PlayerSettingsRepository.setChapterTitleEnabled(true)
        PlayerSettingsRepository.onProfileChanged()

        assertTrue(PlayerSettingsRepository.uiState.value.chapterTitleEnabled)
        assertEquals(true, PlayerSettingsStorage.loadChapterTitleEnabled())
    }

    @Test
    fun settingTheSameValueAgainDoesNotChangeState() {
        PlayerSettingsRepository.setChapterTitleEnabled(false)
        val before = PlayerSettingsRepository.uiState.value
        PlayerSettingsRepository.setChapterTitleEnabled(false)
        assertEquals(before, PlayerSettingsRepository.uiState.value)

        // ProfileSettingsSync's observed-state signature embeds `uiState.value.toString()`, so a
        // flip must be visible in the data class or a local edit would never be pushed.
        PlayerSettingsRepository.setChapterTitleEnabled(true)
        assertNotEquals(before, PlayerSettingsRepository.uiState.value)
        assertNotEquals(before.toString(), PlayerSettingsRepository.uiState.value.toString())
    }

    @Test
    fun chapterTitleRoundTripsThroughSyncAndOlderPayloadsRestoreTheDefault() {
        PlayerSettingsRepository.setChapterTitleEnabled(false)
        val payload = PlayerSettingsStorage.exportToSyncPayload()
        assertEquals(false, payload.decodeSyncBoolean("chapter_title_enabled"))

        PlayerSettingsRepository.setChapterTitleEnabled(true)
        PlayerSettingsStorage.replaceFromSyncPayload(payload)
        PlayerSettingsRepository.onProfileChanged()
        assertFalse(PlayerSettingsRepository.uiState.value.chapterTitleEnabled)

        // A payload written before the key existed carries no value: the stored row is cleared
        // and the default comes back.
        PlayerSettingsStorage.replaceFromSyncPayload(buildJsonObject {})
        PlayerSettingsRepository.onProfileChanged()
        assertNull(PlayerSettingsStorage.loadChapterTitleEnabled())
        assertTrue(PlayerSettingsRepository.uiState.value.chapterTitleEnabled)
    }

    @Test
    fun chapterTitleIsStoredPerProfile() {
        PlayerSettingsRepository.setChapterTitleEnabled(false)

        val originalProvider = ActiveProfileProvider.provider
        try {
            ActiveProfileProvider.provider = ActiveProfileIdProvider { 99 }
            // Start from a clean row: the JVM preferences file may outlive a previous run.
            PlayerSettingsStorage.replaceFromSyncPayload(buildJsonObject {})
            assertNull(PlayerSettingsStorage.loadChapterTitleEnabled())
            PlayerSettingsStorage.saveChapterTitleEnabled(true)
            assertEquals(true, PlayerSettingsStorage.loadChapterTitleEnabled())
            PlayerSettingsStorage.replaceFromSyncPayload(buildJsonObject {})
        } finally {
            ActiveProfileProvider.provider = originalProvider
        }

        assertEquals(false, PlayerSettingsStorage.loadChapterTitleEnabled())
    }

    @Test
    fun keyIsRegisteredForSignOutWipe() {
        val scoped = AccountDataStores.all.flatMap { it.appleKeys }
            .filterIsInstance<AppleKeySpec.ProfileScoped>().map { it.base }
        assertTrue("chapter_title_enabled" in scoped)
    }
}
