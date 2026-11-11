package com.nuvio.app.features.addons

import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertFalse
import kotlin.test.assertIs
import kotlin.test.assertTrue

/** Races items 1 and 3: the install append is refused after a profile switch and ends stale generations. */
class AddonInstallAppendTest {
    private val u = "https://u.example/manifest.json"
    private val v = "https://v.example/manifest.json"
    private val installed = ManagedAddon(manifestUrl = u, enabled = false)

    @Test
    fun anInstallAfterAProfileSwitchIsRefused() {
        // After the switch the state is the empty reset: the inline append would have produced [U]
        // and persisted it as the new profile's whole stored list.
        assertEquals(InstallAppend.ProfileChanged, appendInstalled(AddonsUiState(), installed, sameProfile = false))
    }

    @Test
    fun aProfileSwitchWinsOverADuplicate() {
        val state = AddonsUiState(addons = listOf(ManagedAddon(manifestUrl = u)))
        assertEquals(InstallAppend.ProfileChanged, appendInstalled(state, installed, sameProfile = false))
    }

    @Test
    fun anInstallAppendsWithItsFlagAndNoStaleGeneration() {
        val state = AddonsUiState(addons = listOf(ManagedAddon(manifestUrl = v)), refreshGenerations = mapOf(u to 7L, v to 8L))
        val result = assertIs<InstallAppend.Appended>(appendInstalled(state, installed, sameProfile = true))
        assertEquals(listOf(v, u), result.state.addons.map { it.manifestUrl })
        assertFalse(result.state.addons.last().enabled, "the new instance carries the flag it was installed with")
        assertFalse(isCurrentRefreshGeneration(result.state.refreshGenerations, u, 7L))
        assertTrue(isCurrentRefreshGeneration(result.state.refreshGenerations, v, 8L))
    }

    @Test
    fun aDuplicateWithHostCaseDifferenceIsRefused() {
        val state = AddonsUiState(addons = listOf(ManagedAddon(manifestUrl = "https://U.example/manifest.json")))
        assertEquals(InstallAppend.Duplicate, appendInstalled(state, installed, sameProfile = true))
    }

    @Test
    fun aPathCaseDifferenceIsAnotherAddon() {
        val state = AddonsUiState(addons = listOf(ManagedAddon(manifestUrl = "https://u.example/Manifest.json")))
        assertIs<InstallAppend.Appended>(appendInstalled(state, installed, sameProfile = true))
    }
}
