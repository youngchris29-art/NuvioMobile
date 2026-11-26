package com.nuvio.app.features.mdblist

import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.async
import kotlinx.coroutines.awaitAll
import kotlinx.coroutines.test.runTest
import kotlinx.coroutines.withContext
import kotlin.test.AfterTest
import kotlin.test.Test
import kotlin.test.assertEquals

/**
 * Scope identity W2 fix round: the profile fan-out reloads MDBList settings on Dispatchers.Default
 * while the Settings setters run on another thread. After every round of racing reloads and
 * toggles, what is published, what a snapshot returns and what is stored must agree.
 */
class MdbListSettingsConcurrencyTest {
    @AfterTest
    fun tearDown() {
        MdbListSettingsStorage.saveEnabled(false)
        MdbListSettingsRepository.resetForTest()
    }

    @Test
    fun reloadRacingSetterNeverLeavesPublishedStateBehindStorage() = runTest {
        withContext(Dispatchers.Default) {
            MdbListSettingsRepository.ensureLoaded()
            repeat(10) { round ->
                listOf(
                    async { repeat(200) { MdbListSettingsRepository.onProfileChanged() } },
                    async { repeat(200) { i -> MdbListSettingsRepository.setEnabled((i + round) % 2 == 0) } },
                ).awaitAll()
                val stored = MdbListSettingsStorage.loadEnabled() ?: false
                assertEquals(stored, MdbListSettingsRepository.uiState.value.enabled, "round $round: published vs stored")
                assertEquals(stored, MdbListSettingsRepository.snapshot().enabled, "round $round: snapshot vs stored")
            }
        }
    }
}
