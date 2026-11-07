package com.nuvio.app.features.addons

import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertFalse
import kotlin.test.assertTrue

/** Add-ons hub v2 review r3: the refresh generation rules behind `restartRefresh`. */
class AddonRefreshSupersedeTest {
    @Test
    fun bumpingStartsAtOneAndAdvancesPerAddon() {
        val first = bumpRefreshGeneration(emptyMap(), "a")
        assertEquals(mapOf("a" to 1L), first)
        val second = bumpRefreshGeneration(first, "a")
        assertEquals(2L, second["a"])
        assertEquals(mapOf("a" to 2L, "b" to 1L), bumpRefreshGeneration(second, "b"))
    }

    @Test
    fun onlyTheNewestGenerationMayPublish() {
        val afterRetry = bumpRefreshGeneration(bumpRefreshGeneration(emptyMap(), "a"), "a")
        assertFalse(isCurrentRefreshGeneration(afterRetry, "a", 1L), "the stuck request was superseded")
        assertTrue(isCurrentRefreshGeneration(afterRetry, "a", 2L), "the retry publishes")
    }

    @Test
    fun anotherAddonsRetryDoesNotSupersedeThisOne() {
        val generations = bumpRefreshGeneration(bumpRefreshGeneration(emptyMap(), "a"), "b")
        assertTrue(isCurrentRefreshGeneration(bumpRefreshGeneration(generations, "b"), "a", 1L))
    }

    @Test
    fun aReplacedStateDoesNotBlockPublication() {
        assertTrue(isCurrentRefreshGeneration(emptyMap(), "a", 3L), "a wholesale replacement keeps the old behaviour")
    }
}
