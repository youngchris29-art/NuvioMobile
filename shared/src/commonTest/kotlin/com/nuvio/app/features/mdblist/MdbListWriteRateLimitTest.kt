package com.nuvio.app.features.mdblist

import com.nuvio.app.features.tracking.TrackingExternalIds
import com.nuvio.app.features.tracking.TrackingHistoryItem
import com.nuvio.app.features.tracking.TrackingMediaKind
import com.nuvio.app.features.tracking.TrackingMediaReference
import com.nuvio.app.features.tracking.TrackingRefreshIntent
import kotlin.coroutines.ContinuationInterceptor
import kotlinx.coroutines.CoroutineDispatcher
import kotlinx.coroutines.test.runCurrent
import kotlinx.coroutines.test.runTest
import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertTrue

/**
 * Fork: a rate-limited history write must not spend another request inside the rate-limit window.
 * Uses the real HTTP sync remote (the harness's fake remote would bypass MdbListHttpClient's limit
 * block), so the follow-up INVALIDATED refresh the write schedules is observed end to end.
 */
class MdbListWriteRateLimitTest {
    @Test
    fun `rate-limited write records the retry time and makes no refresh request until it`() = runTest {
        val h = MdbListSyncTestHarness(backgroundScope)
        h.seed()
        val repository = MdbListSyncRepository(
            h.storage, h.http.store, h.http.api, h.activeProfile, backgroundScope, { h.http.now },
            backgroundScope.coroutineContext[ContinuationInterceptor] as CoroutineDispatcher
        )
        repository.ensureLoaded()
        h.http.reply(429, "{}", mapOf("Retry-After" to "3600"))
        val item = TrackingHistoryItem(
            TrackingMediaReference(TrackingMediaKind.MOVIE, "Movie 2", ids = TrackingExternalIds(imdb = "tt2")),
            mdbListTimestamp(MDBLIST_TEST_TIME)
        )

        expectMdbListFailure<MdbListApiException> {
            MdbListHistoryService(h.http.api, repository).add(repository.currentScope(), listOf(item))
        }
        runCurrent()

        val retryAt = h.http.now + 3_600_000L
        assertEquals(1, h.http.engine.requests.size, "the scheduled refresh must not reach the network")
        assertEquals(MdbListSyncError.RATE_LIMIT, repository.state.value.error)
        assertEquals(retryAt, repository.state.value.retryAtEpochMs)
        assertTrue(MdbListSyncBucket.WATCHED in repository.currentSnapshot()!!.invalidatedBuckets)

        repository.refresh(TrackingRefreshIntent.USER_INITIATED)
        repository.refresh(TrackingRefreshIntent.AUTOMATIC)
        assertEquals(1, h.http.engine.requests.size, "the recorded retry time gates later refreshes")
    }
}
