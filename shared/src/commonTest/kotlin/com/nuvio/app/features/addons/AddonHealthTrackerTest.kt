package com.nuvio.app.features.addons

import kotlin.test.AfterTest
import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertNull
import kotlin.test.assertTrue

class AddonHealthTrackerTest {
    private val a = "https://a.example.com/manifest.json"
    private val b = "https://b.example.com/manifest.json"

    @AfterTest
    fun reset() = AddonHealthTracker.clear()

    @Test
    fun recordStoresPerUrl() {
        AddonHealthTracker.clear()
        AddonHealthTracker.record(a, 210L, false, nowEpochMs = 100L)
        AddonHealthTracker.record(b, 40L, true, nowEpochMs = 200L)
        val map = AddonHealthTracker.health.value
        assertEquals(AddonHealth(210L, false, 100L), map[a])
        assertEquals(AddonHealth(40L, true, 200L), map[b])
    }

    @Test
    fun aNewResultReplacesTheOldOneForThatUrlOnly() {
        AddonHealthTracker.clear()
        AddonHealthTracker.record(a, 210L, false, nowEpochMs = 100L)
        AddonHealthTracker.record(b, 40L, false, nowEpochMs = 100L)
        AddonHealthTracker.record(a, 3500L, true, nowEpochMs = 300L)
        val map = AddonHealthTracker.health.value
        assertEquals(AddonHealth(3500L, true, 300L), map[a])
        assertEquals(AddonHealth(40L, false, 100L), map[b])
    }

    @Test
    fun clearEmptiesTheMap() {
        AddonHealthTracker.record(a, 1L, false)
        AddonHealthTracker.clear()
        assertTrue(AddonHealthTracker.health.value.isEmpty())
        assertNull(AddonHealthTracker.health.value[a])
    }

    @Test
    fun forgetDropsOneUrl() {
        AddonHealthTracker.clear()
        AddonHealthTracker.record("https://a.example.com/manifest.json", 100, failed = false, nowEpochMs = 1)
        AddonHealthTracker.record("https://b.example.com/manifest.json", 200, failed = true, nowEpochMs = 2)
        AddonHealthTracker.forget("https://a.example.com/manifest.json")
        kotlin.test.assertEquals(setOf("https://b.example.com/manifest.json"), AddonHealthTracker.health.value.keys)
        AddonHealthTracker.clear()
    }
}
