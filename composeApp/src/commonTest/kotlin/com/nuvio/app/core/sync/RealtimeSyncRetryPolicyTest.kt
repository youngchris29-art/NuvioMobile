package com.nuvio.app.core.sync

import kotlin.random.Random
import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertTrue

class RealtimeSyncRetryPolicyTest {

    private fun boundsFor(baseMs: Long): LongRange {
        val jitter = (baseMs * 0.2).toLong()
        return (baseMs - jitter)..(baseMs + jitter)
    }

    @Test
    fun `delays grow exponentially from the base`() {
        val random = Random(42)
        assertTrue(RealtimeSyncRetryPolicy.delayMs(1, random) in boundsFor(5_000L))
        assertTrue(RealtimeSyncRetryPolicy.delayMs(2, random) in boundsFor(10_000L))
        assertTrue(RealtimeSyncRetryPolicy.delayMs(3, random) in boundsFor(20_000L))
        assertTrue(RealtimeSyncRetryPolicy.delayMs(5, random) in boundsFor(80_000L))
    }

    @Test
    fun `delays cap at the maximum`() {
        val random = Random(7)
        val capBounds = boundsFor(RealtimeSyncRetryPolicy.MAX_DELAY_MS)
        assertTrue(RealtimeSyncRetryPolicy.delayMs(8, random) in capBounds)
        assertTrue(RealtimeSyncRetryPolicy.delayMs(100, random) in capBounds)
        // Far past any shift overflow risk.
        assertTrue(RealtimeSyncRetryPolicy.delayMs(Int.MAX_VALUE, random) in capBounds)
    }

    @Test
    fun `non-positive failure counts behave like the first failure`() {
        val random = Random(3)
        assertTrue(RealtimeSyncRetryPolicy.delayMs(0, random) in boundsFor(5_000L))
        assertTrue(RealtimeSyncRetryPolicy.delayMs(-4, random) in boundsFor(5_000L))
    }

    @Test
    fun `jitter varies between calls`() {
        val random = Random(11)
        val samples = (1..32).map { RealtimeSyncRetryPolicy.delayMs(4, random) }.toSet()
        assertTrue(samples.size > 1, "expected jitter to produce varied delays, got $samples")
        assertEquals(emptyList(), samples.filter { it !in boundsFor(40_000L) })
    }
}
