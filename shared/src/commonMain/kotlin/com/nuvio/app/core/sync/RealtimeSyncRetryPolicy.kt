package com.nuvio.app.core.sync

import kotlin.random.Random

/**
 * Retry pacing for [RealtimeSyncInvalidationService]: exponential backoff with ±20% jitter,
 * from [BASE_DELAY_MS] up to [MAX_DELAY_MS]. Realtime invalidations are best-effort (periodic
 * and foreground pulls cover sync correctness), so a long tail cap is safe — during a backend
 * outage this settles at one cheap probe every ~10 minutes instead of hammering the endpoint.
 */
object RealtimeSyncRetryPolicy {
    const val BASE_DELAY_MS = 5_000L
    const val MAX_DELAY_MS = 600_000L
    private const val JITTER_FRACTION = 0.2
    private const val MAX_SHIFTS = 30

    fun delayMs(consecutiveFailures: Int, random: Random = Random.Default): Long {
        val failures = consecutiveFailures.coerceAtLeast(1)
        val shifts = (failures - 1).coerceAtMost(MAX_SHIFTS)
        val base = (BASE_DELAY_MS shl shifts).coerceIn(BASE_DELAY_MS, MAX_DELAY_MS)
        val jitterRange = (base * JITTER_FRACTION).toLong()
        return base + random.nextLong(-jitterRange, jitterRange + 1)
    }
}
