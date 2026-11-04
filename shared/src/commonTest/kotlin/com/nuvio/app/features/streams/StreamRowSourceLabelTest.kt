package com.nuvio.app.features.streams

import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertFalse
import kotlin.test.assertTrue

class StreamRowSourceLabelTest {

    private fun stream(addonId: String, sourceName: String?) = StreamItem(
        name = "Stream",
        sourceName = sourceName,
        addonName = "Repo",
        addonId = addonId,
    )

    @Test
    fun repositoryGroupShowsProvider() {
        val item = stream("${PLUGIN_REPOSITORY_GROUP_ID_PREFIX}https://repo.example/manifest.json", "Provider A")
        assertTrue(item.isPluginRepositoryGroup)
        assertEquals("Provider A", item.rowSourceLabel)
    }

    @Test
    fun repositoryGroupWithoutSourceNameKeepsRepositoryName() {
        assertEquals("Repo", stream("${PLUGIN_REPOSITORY_GROUP_ID_PREFIX}x", null).rowSourceLabel)
        assertEquals("Repo", stream("${PLUGIN_REPOSITORY_GROUP_ID_PREFIX}x", "  ").rowSourceLabel)
    }

    @Test
    fun otherGroupsKeepAddonName() {
        val plugin = stream("plugin:abc", "Provider A")
        assertFalse(plugin.isPluginRepositoryGroup)
        assertEquals("Repo", plugin.rowSourceLabel)
        assertEquals("Repo", stream("com.addon", "Provider A").rowSourceLabel)
    }
}
