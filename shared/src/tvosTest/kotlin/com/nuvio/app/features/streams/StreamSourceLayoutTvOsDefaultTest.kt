package com.nuvio.app.features.streams

import kotlinx.serialization.json.buildJsonObject
import kotlin.test.AfterTest
import kotlin.test.BeforeTest
import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertNull

/** GitHub #25: a tvOS profile that never set Source Layout or Row Text gets Two-Pane and Nuvio, and nothing is written. */
class StreamSourceLayoutTvOsDefaultTest {
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
    fun freshProfileLoadsTwoPaneAndNuvioWithoutWritingThem() {
        StreamBadgeSettingsRepository.ensureLoaded()

        assertEquals(StreamSourceLayout.TWO_PANE, StreamBadgeSettingsRepository.uiState.value.sourceLayout)
        assertEquals(StreamRowText.NUVIO, StreamBadgeSettingsRepository.uiState.value.rowText)
        assertNull(StreamBadgeSettingsStorage.loadStreamSourceLayout())
        assertNull(StreamBadgeSettingsStorage.loadStreamRowText())
        assertNull(StreamBadgeSettingsStorage.exportToSyncPayload()["stream_source_layout"])
        assertNull(StreamBadgeSettingsStorage.exportToSyncPayload()["stream_row_text"])
    }

    @Test
    fun fullWidthAndAddonTextAreExplicitChoicesThatPersist() {
        StreamBadgeSettingsRepository.setSourceLayout(StreamSourceLayout.FULL_WIDTH)
        StreamBadgeSettingsRepository.setRowText(StreamRowText.ADDON)
        StreamBadgeSettingsRepository.clearLocalState()
        StreamBadgeSettingsRepository.ensureLoaded()

        assertEquals(StreamSourceLayout.FULL_WIDTH, StreamBadgeSettingsRepository.uiState.value.sourceLayout)
        assertEquals(StreamRowText.ADDON, StreamBadgeSettingsRepository.uiState.value.rowText)
    }
}
