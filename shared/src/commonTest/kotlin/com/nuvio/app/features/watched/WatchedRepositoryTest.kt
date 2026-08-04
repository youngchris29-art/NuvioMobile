package com.nuvio.app.features.watched

import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.runBlocking
import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertFailsWith
import kotlin.test.assertFalse
import kotlin.test.assertNull
import kotlin.test.assertTrue

/**
 * Ported from upstream's `WatchedRepositoryTest` additions in `e0cbf447` and `7a491570` only —
 * the fork already has a large, pre-existing `WatchedRepositoryTest` in `composeApp/src/commonTest`
 * that must keep compiling untouched. This file covers just the new [watchedProviderRefreshOrNull]
 * and [extraWatchedKeysChanged] cases; named distinctly so it can never collide with the
 * composeApp class.
 */
class WatchedRepositoryHelpersTest {
    @Test
    fun emptyProviderExtraKeys_doNotTriggerInitialRefresh() {
        assertFalse(extraWatchedKeysChanged(previous = null, current = emptySet()))
    }

    @Test
    fun populatedProviderExtraKeys_triggerRefreshFromEmptyState() {
        assertTrue(extraWatchedKeysChanged(previous = null, current = setOf("series:tt1:-1:-1")))
    }

    @Test
    fun changedProviderExtraKeys_triggerRefresh() {
        assertTrue(
            extraWatchedKeysChanged(
                previous = setOf("series:tt1:-1:-1"),
                current = setOf("series:tt2:-1:-1"),
            ),
        )
    }

    @Test
    fun providerRefreshFailure_isContainedWithoutReplacingState() = runBlocking {
        val failure = IllegalStateException("rate limited")
        var observedFailure: Throwable? = null

        val result = watchedProviderRefreshOrNull(
            refresh = { throw failure },
            onFailure = { observedFailure = it },
        )

        assertNull(result)
        assertEquals(failure, observedFailure)
    }

    @Test
    fun providerRefreshCancellation_isNotContained() = runBlocking {
        assertFailsWith<CancellationException> {
            watchedProviderRefreshOrNull(
                refresh = { throw CancellationException("cancelled") },
                onFailure = {},
            )
        }
        Unit
    }
}
