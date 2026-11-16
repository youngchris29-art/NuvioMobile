package com.nuvio.app.features.player

import kotlinx.serialization.json.buildJsonObject
import kotlin.test.AfterTest
import kotlin.test.BeforeTest
import kotlin.test.Test
import kotlin.test.assertEquals

/** Upstream b8bbd700f (clamp part): stored and saved outline widths stay inside 1..5. */
class SubtitleOutlineWidthTest {
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
    fun defaultWidthIsTheDefaultConstant() {
        PlayerSettingsRepository.ensureLoaded()
        assertEquals(SUBTITLE_OUTLINE_WIDTH_DEFAULT, PlayerSettingsRepository.uiState.value.subtitleStyle.outlineWidth)
    }

    @Test
    fun storedWidthsOutsideTheRangeAreClampedOnLoad() {
        PlayerSettingsStorage.saveSubtitleOutlineWidth(9)
        PlayerSettingsRepository.onProfileChanged()
        assertEquals(5, PlayerSettingsRepository.uiState.value.subtitleStyle.outlineWidth)

        PlayerSettingsStorage.saveSubtitleOutlineWidth(0)
        PlayerSettingsRepository.onProfileChanged()
        assertEquals(1, PlayerSettingsRepository.uiState.value.subtitleStyle.outlineWidth)
    }

    @Test
    fun savedWidthsAreClampedBeforeTheyArePublishedOrStored() {
        PlayerSettingsRepository.ensureLoaded()
        val style = PlayerSettingsRepository.uiState.value.subtitleStyle

        PlayerSettingsRepository.setSubtitleStyle(style.copy(outlineWidth = 12))
        assertEquals(5, PlayerSettingsRepository.uiState.value.subtitleStyle.outlineWidth)
        assertEquals(5, PlayerSettingsStorage.loadSubtitleOutlineWidth())

        PlayerSettingsRepository.setSubtitleStyle(style.copy(outlineWidth = -3))
        assertEquals(1, PlayerSettingsRepository.uiState.value.subtitleStyle.outlineWidth)
        assertEquals(1, PlayerSettingsStorage.loadSubtitleOutlineWidth())
    }
}
