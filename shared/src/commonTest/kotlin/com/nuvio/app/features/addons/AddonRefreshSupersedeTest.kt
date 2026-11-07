package com.nuvio.app.features.addons

import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertFalse
import kotlin.test.assertSame
import kotlin.test.assertTrue

/** Add-ons hub v2 reviews r3–r6: the refresh generation rules behind `restartRefresh`. */
class AddonRefreshSupersedeTest {
    @Test
    fun aRefreshRecordsItsIdForItsAddonOnly() {
        val first = withRefreshGeneration(emptyMap(), "a", 7L)
        assertEquals(mapOf("a" to 7L), first)
        assertEquals(mapOf("a" to 7L, "b" to 8L), withRefreshGeneration(first, "b", 8L))
    }

    @Test
    fun onlyTheNewestRefreshMayPublish() {
        val afterRetry = withRefreshGeneration(withRefreshGeneration(emptyMap(), "a", 1L), "a", 2L)
        assertFalse(isCurrentRefreshGeneration(afterRetry, "a", 1L), "the stuck request was superseded")
        assertTrue(isCurrentRefreshGeneration(afterRetry, "a", 2L), "the retry publishes")
    }

    @Test
    fun anotherAddonsRetryDoesNotSupersedeThisOne() {
        val generations = withRefreshGeneration(withRefreshGeneration(emptyMap(), "a", 1L), "b", 2L)
        assertTrue(isCurrentRefreshGeneration(withRefreshGeneration(generations, "b", 3L), "a", 1L))
    }

    /** Review r5: after a reset (generations cleared) an earlier refresh must not publish. */
    @Test
    fun aRefreshFromBeforeAResetDoesNotPublish() {
        assertFalse(isCurrentRefreshGeneration(emptyMap(), "a", 3L))
    }

    /** Review r6: ids are unique, so a refresh after a reset never reuses an old job's id. */
    @Test
    fun aRefreshAfterAResetHasADifferentId() {
        val afterReset = withRefreshGeneration(emptyMap(), "a", 2L)
        assertFalse(isCurrentRefreshGeneration(afterReset, "a", 1L), "the pre-reset job (id 1) stays superseded")
    }

    /** Review r6: a same-profile rebuild keeps an add-on that is still refreshing marked so. */
    @Test
    fun aRebuildKeepsTheLiveRefreshFlag() {
        val current = AddonsUiState(
            addons = listOf(
                ManagedAddon(manifestUrl = "a", isRefreshing = true),
                ManagedAddon(manifestUrl = "b"),
            ),
        )
        val rebuilt = listOf(ManagedAddon(manifestUrl = "a"), ManagedAddon(manifestUrl = "b"), ManagedAddon(manifestUrl = "c"))
        val kept = keepingLiveRefresh(rebuilt, current)
        assertEquals(listOf(true, false, false), kept.map { it.isRefreshing })
    }

    @Test
    fun aRebuildWithNothingRefreshingIsUntouched() {
        val rebuilt = listOf(ManagedAddon(manifestUrl = "a"))
        assertSame(rebuilt, keepingLiveRefresh(rebuilt, AddonsUiState(addons = rebuilt)))
    }
}
