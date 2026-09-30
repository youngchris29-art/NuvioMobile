package com.nuvio.app.features.mdblist

import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.CompletableDeferred
import kotlinx.coroutines.ExperimentalCoroutinesApi
import kotlinx.coroutines.async
import kotlinx.coroutines.test.runCurrent
import kotlinx.coroutines.test.runTest
import kotlinx.coroutines.withTimeoutOrNull
import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertFailsWith
import kotlin.test.assertNull

@OptIn(ExperimentalCoroutinesApi::class)
class MdbListRatingsCancellationTest {
    @Test
    fun accountChangeCancellationIsSwallowedWhileCallerIsActive() = runTest {
        val result = MdbListMetadataService.swallowRepositoryCancellation(listOf("fallback")) {
            throw CancellationException("MDBList account changed")
        }
        assertEquals(listOf("fallback"), result)
    }

    @Test
    fun cancelledInFlightDeferredIsSwallowedWhileCallerIsActive() = runTest {
        val deferred = CompletableDeferred<List<String>>()
        val call = async {
            MdbListMetadataService.swallowRepositoryCancellation(emptyList<String>()) { deferred.await() }
        }
        runCurrent()
        deferred.cancel()
        assertEquals(emptyList(), call.await())
    }

    @Test
    fun realCancellationOfTheCallerStillPropagates() = runTest {
        val gate = CompletableDeferred<Unit>()
        val call = async {
            MdbListMetadataService.swallowRepositoryCancellation("fallback") {
                gate.await()
                "done"
            }
        }
        runCurrent()
        call.cancel()
        assertFailsWith<CancellationException> { call.await() }
    }

    @Test
    fun timeoutStillPropagatesThroughTheHelper() = runTest {
        val result = withTimeoutOrNull(100) {
            MdbListMetadataService.swallowRepositoryCancellation("fallback") {
                kotlinx.coroutines.delay(10_000)
                "late"
            }
        }
        assertNull(result)
    }
}
