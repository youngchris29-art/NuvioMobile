package com.nuvio.app.features.streams

import com.nuvio.app.core.account.AccountDataStores
import com.nuvio.app.core.account.AppleKeySpec
import kotlinx.serialization.json.buildJsonObject
import kotlin.test.AfterTest
import kotlin.test.BeforeTest
import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertNull
import kotlin.test.assertTrue

/**
 * "Source Layout" and "Row Text" (GitHub #25): defaults Two-Pane and Nuvio, persist across reloads,
 * unknown stored values fall back, and neither key rides the settings sync (profile-local).
 */
class StreamSourceLayoutRowTextSettingsTest {
    @BeforeTest
    fun initialize() = reset()

    @AfterTest
    fun clearState() = reset()

    private fun reset() {
        StreamBadgeSettingsStorage.clearStreamSourceLayout()
        StreamBadgeSettingsStorage.clearStreamRowText()
        StreamBadgeSettingsStorage.replaceFromSyncPayload(buildJsonObject {})
        StreamBadgeSettingsRepository.clearLocalState()
    }

    @Test
    fun defaultsToTwoPaneAndNuvioWithoutWritingThem() {
        StreamBadgeSettingsRepository.ensureLoaded()
        val state = StreamBadgeSettingsRepository.uiState.value
        assertEquals(StreamSourceLayout.TWO_PANE, state.sourceLayout)
        assertEquals(StreamRowText.NUVIO, state.rowText)
        assertNull(StreamBadgeSettingsStorage.loadStreamSourceLayout())
        assertNull(StreamBadgeSettingsStorage.loadStreamRowText())
    }

    @Test
    fun bothChoicesSurviveReload() {
        StreamBadgeSettingsRepository.setSourceLayout(StreamSourceLayout.FULL_WIDTH)
        StreamBadgeSettingsRepository.setRowText(StreamRowText.ADDON)
        StreamBadgeSettingsRepository.clearLocalState()
        StreamBadgeSettingsRepository.ensureLoaded()
        val state = StreamBadgeSettingsRepository.uiState.value
        assertEquals(StreamSourceLayout.FULL_WIDTH, state.sourceLayout)
        assertEquals(StreamRowText.ADDON, state.rowText)
        assertEquals("full_width", StreamBadgeSettingsStorage.loadStreamSourceLayout())
        assertEquals("addon", StreamBadgeSettingsStorage.loadStreamRowText())
    }

    @Test
    fun theTwoSettingsAreIndependent() {
        StreamBadgeSettingsRepository.setRowText(StreamRowText.ADDON)
        assertEquals(StreamSourceLayout.TWO_PANE, StreamBadgeSettingsRepository.uiState.value.sourceLayout)
        StreamBadgeSettingsRepository.setSourceLayout(StreamSourceLayout.FULL_WIDTH)
        StreamBadgeSettingsRepository.setRowText(StreamRowText.NUVIO)
        assertEquals(StreamSourceLayout.FULL_WIDTH, StreamBadgeSettingsRepository.uiState.value.sourceLayout)
    }

    @Test
    fun unknownStoredValuesFallBackToTheDefaults() {
        listOf("wide", "unknown").forEach { value ->
            StreamBadgeSettingsStorage.saveStreamSourceLayout(value)
            StreamBadgeSettingsStorage.saveStreamRowText(value)
            StreamBadgeSettingsRepository.onProfileChanged()
            assertEquals(StreamSourceLayout.TWO_PANE, StreamBadgeSettingsRepository.uiState.value.sourceLayout)
            assertEquals(StreamRowText.NUVIO, StreamBadgeSettingsRepository.uiState.value.rowText)
        }
    }

    @Test
    fun keysAreAbsentFromTheSyncPayloadExport() {
        StreamBadgeSettingsRepository.setSourceLayout(StreamSourceLayout.FULL_WIDTH)
        StreamBadgeSettingsRepository.setRowText(StreamRowText.ADDON)
        val payload = StreamBadgeSettingsStorage.exportToSyncPayload()
        assertNull(payload["stream_source_layout"])
        assertNull(payload["stream_row_text"])
    }

    @Test
    fun incomingSyncDoesNotResetTheChoices() {
        StreamBadgeSettingsRepository.setSourceLayout(StreamSourceLayout.FULL_WIDTH)
        StreamBadgeSettingsRepository.setRowText(StreamRowText.ADDON)
        StreamBadgeSettingsStorage.replaceFromSyncPayload(buildJsonObject {})
        StreamBadgeSettingsRepository.onProfileChanged()
        assertEquals(StreamSourceLayout.FULL_WIDTH, StreamBadgeSettingsRepository.uiState.value.sourceLayout)
        assertEquals(StreamRowText.ADDON, StreamBadgeSettingsRepository.uiState.value.rowText)
    }

    @Test
    fun keysAreRegisteredForSignOutWipe() {
        val scoped = AccountDataStores.all.flatMap { it.appleKeys }
            .filterIsInstance<AppleKeySpec.ProfileScoped>().map { it.base }
        assertTrue("stream_source_layout" in scoped)
        assertTrue("stream_row_text" in scoped)
    }
}
