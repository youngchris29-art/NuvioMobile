package com.nuvio.app.features.home

import kotlinx.serialization.json.buildJsonObject
import kotlinx.serialization.json.jsonPrimitive
import kotlinx.serialization.json.put
import kotlinx.serialization.json.putJsonArray
import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertNull

/**
 * Ported from upstream `f9c13a9b` ("perf(home): remove legacy catalog sync reads"): exercises
 * the pure [mergeHomeCatalogSettingsJson] helper that backs the cached-remote push merge, and
 * the presence-gated [decodeHomeCatalogPayloadPreservingLocalDefaults] whose null return
 * pullFromServer turns into a failed (and therefore retried) sync step.
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

    @Test
    fun `malformed remote blob decodes to null so the sync step can fail`() {
        // Not this payload's shape at all: `items` must be an array.
        val malformed = buildJsonObject {
            put("show_catalog_type", true)
            put("items", "not-a-list")
        }

        assertNull(decodeHomeCatalogPayloadPreservingLocalDefaults(malformed, SyncHomeCatalogPayload()))
    }

    @Test
    fun `absent toggle keys preserve the local values instead of resetting to defaults`() {
        // Every local toggle differs from its shipped default so "preserved local" and "fell
        // back to the default" cannot be confused.
        val local = SyncHomeCatalogPayload(
            showCatalogType = false,
            hideUnreleasedContent = true,
            hideCatalogUnderline = true,
            hideDiscover = true,
        )
        val remote = buildJsonObject {
            put("show_catalog_type", true)
            putJsonArray("items") { }
        }

        val decoded = decodeHomeCatalogPayloadPreservingLocalDefaults(remote, local)

        assertEquals(true, decoded?.showCatalogType)
        assertEquals(true, decoded?.hideUnreleasedContent)
        assertEquals(true, decoded?.hideCatalogUnderline)
        assertEquals(true, decoded?.hideDiscover)
    }

    @Test
    fun `present toggle keys override the local values`() {
        val local = SyncHomeCatalogPayload(hideUnreleasedContent = true, hideDiscover = true)
        val remote = buildJsonObject {
            put("hide_unreleased_content", false)
            put("hide_discover", false)
        }

        val decoded = decodeHomeCatalogPayloadPreservingLocalDefaults(remote, local)

        assertEquals(false, decoded?.hideUnreleasedContent)
        assertEquals(false, decoded?.hideDiscover)
    }
}
