package com.nuvio.app.features.mdblist

import com.nuvio.app.features.tracking.TrackingRefreshIntent
import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.NonCancellable
import kotlinx.coroutines.withContext

internal suspend fun <T> MdbListSyncRepository.write(
    scope: MdbListAuthScope,
    buckets: Set<MdbListSyncBucket>,
    block: suspend (MdbListSyncSnapshot) -> Pair<MdbListSyncSnapshot, T>
): T = try {
    mutate(scope, block)
} catch (error: CancellationException) {
    withContext(NonCancellable) {
        try {
            invalidate(scope, buckets)
        } catch (_: Exception) {
        }
    }
    throw error
} catch (error: Exception) {
    try {
        invalidate(scope, buckets)
        // Fork: this refresh is safe after a 429. MdbListHttpClient blocks the account's limit key
        // until the reset, so the refresh fails locally without a network request, and that local
        // failure is what records retryAtEpochMs in MdbListSyncState; shouldRefresh then defers
        // every later attempt until the reset. Recording it here instead is not possible: invalidate
        // commits a fresh MdbListSyncState, which drops any retry time set before it.
        // Pinned by MdbListWriteRateLimitTest.
        refreshAsync(TrackingRefreshIntent.INVALIDATED)
    } catch (_: Exception) {
    }
    throw error
}
