package com.nuvio.app.features.streams

import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertFalse
import kotlin.test.assertNotEquals
import kotlin.test.assertTrue

class StreamItemDebridResolvedTest {
    @Test
    fun debridResolvedDefaultsToFalse() {
        assertFalse(StreamItem(addonName = "A", addonId = "a").debridResolved)
    }

    @Test
    fun debridResolvedTakesPartInEquality() {
        val original = StreamItem(addonName = "A", addonId = "a")
        val resolved = original.copy(debridResolved = true)
        assertTrue(resolved.debridResolved)
        assertNotEquals(original, resolved)
        assertEquals(original, resolved.copy(debridResolved = false))
    }
}
