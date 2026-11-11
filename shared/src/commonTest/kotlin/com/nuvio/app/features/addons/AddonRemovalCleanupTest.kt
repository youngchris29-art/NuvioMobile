package com.nuvio.app.features.addons

import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertFalse
import kotlin.test.assertTrue

/**
 * Races item 1/4: the removal and the install append end the departed URL's refresh generation
 * themselves, so a reinstall that beats the asynchronous removal watcher cannot take the removed
 * instance's result. Pure reductions, in the style of [AddonRefreshSupersedeTest].
 */
class AddonRemovalCleanupTest {
    private val u = "https://u.example/manifest.json"
    private val v = "https://v.example/manifest.json"

    private fun addon(url: String, refreshing: Boolean = false) = ManagedAddon(manifestUrl = url, isRefreshing = refreshing)

    @Test
    fun aRemovalEndsTheRemovedAddonsGeneration() {
        val gens = mapOf(u to 7L, v to 8L)
        val after = generationsForList(gens, listOf(addon(v)))
        assertEquals(mapOf(v to 8L), after)
        assertFalse(isCurrentRefreshGeneration(after, u, 7L))
    }

    @Test
    fun aReinstallBeforeCleanupCannotTakeTheOldResult() {
        // Steps 1-5 of the spec: U refreshing under generation 7, removed, installed again, and the
        // old request returns before the watcher ran.
        val start = AddonsUiState(addons = listOf(addon(u, refreshing = true)), refreshGenerations = mapOf(u to 7L))
        val removed = start.copy(
            addons = emptyList(),
            refreshGenerations = generationsForList(start.refreshGenerations, emptyList()),
        )
        val reinstalled = withInstalledAddon(removed, addon(u))
        assertFalse(isCurrentRefreshGeneration(reinstalled.refreshGenerations, u, 7L))
        assertEquals(listOf(u), reinstalled.addons.map { it.manifestUrl })
    }

    @Test
    fun theAppendEndsAStaleGenerationEvenWhenRemovalDidNotCleanUp() {
        // A route that left the generation behind (a conflated sync): the append drops it.
        val state = AddonsUiState(addons = listOf(addon(v)), refreshGenerations = mapOf(u to 7L, v to 8L))
        val after = withInstalledAddon(state, addon(u))
        assertEquals(mapOf(v to 8L), after.refreshGenerations)
        assertFalse(isCurrentRefreshGeneration(after.refreshGenerations, u, 7L))
        assertTrue(isCurrentRefreshGeneration(after.refreshGenerations, v, 8L))
    }

    @Test
    fun keptAddonsKeepTheirGenerations() {
        val gens = mapOf(u to 7L, v to 8L)
        assertEquals(gens, generationsForList(gens, listOf(addon(v), addon(u))))
        assertEquals(emptyMap(), generationsForList(emptyMap(), listOf(addon(u))))
    }
}
