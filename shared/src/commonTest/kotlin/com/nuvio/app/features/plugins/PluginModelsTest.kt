package com.nuvio.app.features.plugins

import kotlin.test.Test
import kotlin.test.assertFalse
import kotlin.test.assertTrue

class PluginModelsTest {
    @Test
    fun `repository updated just under the interval is not due for refresh`() {
        val now = 10 * PLUGIN_REPOSITORY_REFRESH_INTERVAL_MS

        assertFalse(
            isPluginRepositoryRefreshDue(
                lastUpdatedEpochMs = now - PLUGIN_REPOSITORY_REFRESH_INTERVAL_MS + 1L,
                nowEpochMs = now,
            ),
        )
    }

    @Test
    fun `repository updated exactly one interval ago is due for refresh`() {
        val now = 10 * PLUGIN_REPOSITORY_REFRESH_INTERVAL_MS

        assertTrue(
            isPluginRepositoryRefreshDue(
                lastUpdatedEpochMs = now - PLUGIN_REPOSITORY_REFRESH_INTERVAL_MS,
                nowEpochMs = now,
            ),
        )
    }

    @Test
    fun `repository that has never been updated is due for refresh`() {
        val now = 10 * PLUGIN_REPOSITORY_REFRESH_INTERVAL_MS

        assertTrue(isPluginRepositoryRefreshDue(lastUpdatedEpochMs = 0L, nowEpochMs = now))
    }

    // Fork-only (Codex 2026-08-24): a future lastUpdated (clock rollback) is due, not frozen.
    @Test
    fun `repository updated in the future is due for refresh`() {
        val now = 10 * PLUGIN_REPOSITORY_REFRESH_INTERVAL_MS

        assertTrue(isPluginRepositoryRefreshDue(lastUpdatedEpochMs = now + 1L, nowEpochMs = now))
    }
}
