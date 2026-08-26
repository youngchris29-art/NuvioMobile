package com.nuvio.app.features.home

import kotlinx.serialization.json.buildJsonObject
import kotlinx.serialization.json.jsonPrimitive
import kotlinx.serialization.json.put
import kotlin.test.Test
import kotlin.test.assertEquals

/**
 * Ported from upstream `f9c13a9b` ("perf(home): remove legacy catalog sync reads"): exercises
 * the pure [mergeHomeCatalogSettingsJson] helper that backs the cached-remote push merge.
 */
class HomeCatalogSettingsSyncServiceTest {
    @Test
    fun `shared settings merge preserves unknown remote fields`() {
        val remote = buildJsonObject {
            put("future_setting", "preserved")
            put("show_catalog_type", false)
        }
        val local = buildJsonObject {
            put("show_catalog_type", true)
            put("hide_unreleased_content", true)
        }

        val merged = mergeHomeCatalogSettingsJson(remoteJson = remote, localJson = local)

        assertEquals("preserved", merged.getValue("future_setting").jsonPrimitive.content)
        assertEquals(true, merged.getValue("show_catalog_type").jsonPrimitive.content.toBoolean())
        assertEquals(true, merged.getValue("hide_unreleased_content").jsonPrimitive.content.toBoolean())
    }

    @Test
    fun `null remote json falls back to local only`() {
        val local = buildJsonObject {
            put("show_catalog_type", true)
        }

        val merged = mergeHomeCatalogSettingsJson(remoteJson = null, localJson = local)

        assertEquals(1, merged.size)
        assertEquals(true, merged.getValue("show_catalog_type").jsonPrimitive.content.toBoolean())
    }
}
