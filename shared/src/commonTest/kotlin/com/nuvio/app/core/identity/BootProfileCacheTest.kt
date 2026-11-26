package com.nuvio.app.core.identity

import kotlin.test.Test
import kotlin.test.assertEquals

/** Spec 8.1: launch restore applies the cached profiles only for their own trusted owner (P6). */
class BootProfileCacheTest {

    /** The oracle, written independently of the implementation's expression. */
    private fun expected(payload: String?, guest: String?, owner: String?): BootCacheAction = when {
        payload == null -> BootCacheAction.Defer
        guest != null && payload == guest -> BootCacheAction.Apply
        owner != null && payload == owner -> BootCacheAction.Apply
        else -> BootCacheAction.Defer
    }

    @Test
    fun everyCombination() {
        val payloads = listOf(null, "g", "A", "X")
        val guests = listOf(null, "g")
        // Not recorded and recorded "nobody" both reach decide() as null (owner.takeIf { recorded }).
        val owners = listOf("not recorded" to null, "nobody" to null, "A" to "A")
        var cases = 0
        for (payload in payloads) for (guest in guests) for ((label, owner) in owners) {
            cases++
            assertEquals(
                expected(payload, guest, owner),
                BootProfileCache.decide(payload, guest, owner),
                "payload=$payload guest=$guest owner=$label",
            )
        }
        assertEquals(24, cases)
    }

    @Test
    fun foreignCacheIsNeverApplied() {
        assertEquals(BootCacheAction.Defer, BootProfileCache.decide("debug-foreign", null, null))
        assertEquals(BootCacheAction.Defer, BootProfileCache.decide("debug-foreign", "g", "A"))
    }
}
