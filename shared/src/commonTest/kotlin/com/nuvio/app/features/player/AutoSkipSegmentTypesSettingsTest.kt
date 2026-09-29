package com.nuvio.app.features.player

import com.nuvio.app.core.account.AccountDataStores
import com.nuvio.app.core.account.AppleKeySpec
import com.nuvio.app.core.sync.decodeSyncStringSet
import com.nuvio.app.features.player.skip.AutoSkipSegmentType
import kotlinx.serialization.json.buildJsonObject
import kotlin.test.AfterTest
import kotlin.test.BeforeTest
import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertNull
import kotlin.test.assertTrue

class AutoSkipSegmentTypesSettingsTest {
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
    fun defaultsToNoAutoSkipAndPersistsAcrossReload() {
        PlayerSettingsRepository.ensureLoaded()
        assertTrue(PlayerSettingsRepository.uiState.value.autoSkipSegmentTypes.isEmpty())

        PlayerSettingsRepository.setAutoSkipSegmentType(AutoSkipSegmentType.INTRO, true)
        PlayerSettingsRepository.setAutoSkipSegmentType(AutoSkipSegmentType.MOVIE_CREDITS, true)
        PlayerSettingsRepository.setAutoSkipSegmentType(AutoSkipSegmentType.INTRO, false)
        PlayerSettingsRepository.onProfileChanged()

        assertEquals(setOf(AutoSkipSegmentType.MOVIE_CREDITS), PlayerSettingsRepository.uiState.value.autoSkipSegmentTypes)
        assertEquals(setOf("movie-credits"), PlayerSettingsStorage.loadAutoSkipSegmentTypes())
    }

    @Test
    fun roundTripsThroughSyncAndUnknownValuesAreDropped() {
        PlayerSettingsRepository.setAutoSkipSegmentType(AutoSkipSegmentType.OUTRO, true)
        val payload = PlayerSettingsStorage.exportToSyncPayload()
        assertEquals(setOf("outro"), payload.decodeSyncStringSet("auto_skip_segment_types"))

        PlayerSettingsRepository.setAutoSkipSegmentType(AutoSkipSegmentType.OUTRO, false)
        PlayerSettingsStorage.replaceFromSyncPayload(payload)
        PlayerSettingsStorage.saveAutoSkipSegmentTypes(setOf("outro", "bogus"))
        PlayerSettingsRepository.onProfileChanged()
        assertEquals(setOf(AutoSkipSegmentType.OUTRO), PlayerSettingsRepository.uiState.value.autoSkipSegmentTypes)

        PlayerSettingsStorage.replaceFromSyncPayload(buildJsonObject {})
        assertNull(PlayerSettingsStorage.loadAutoSkipSegmentTypes())
    }

    @Test
    fun newKeysAreRegisteredForSignOutWipe() {
        val scoped = AccountDataStores.all.flatMap { it.appleKeys }
            .filterIsInstance<AppleKeySpec.ProfileScoped>().map { it.base }
        assertTrue("auto_skip_segment_types" in scoped)
        assertTrue("stream_background_mode" in scoped)
    }
}
