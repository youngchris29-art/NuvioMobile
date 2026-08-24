package com.nuvio.app.core.sync

import co.touchlab.kermit.Logger
import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertFalse
import kotlin.test.assertTrue
import kotlinx.serialization.json.JsonPrimitive
import kotlinx.serialization.json.buildJsonObject

/**
 * H-1B-i: [applyFeatureUnlessUnchanged] is the shared no-op suppression the theme/poster/card-depth
 * blocks in `ProfileSettingsSync.applyRemoteBlob()` route through. `applyRemoteBlob()` itself isn't
 * exercised here — it needs a live remote pull (Supabase RPC + ProfileRepository state) to reach,
 * which is heavy scaffolding for what is really a pure comparison — so this tests the helper
 * directly: identical payloads must skip both `apply` and `notifyChanged`, and anything that
 * differs at the raw serialized level (including a payload that merely has a different shape, not
 * just different values) must still run both, exactly like today.
 */
class ProfileSettingsSyncNoOpSuppressionTest {
    private val log = Logger.withTag("ProfileSettingsSyncNoOpSuppressionTest")

    @Test
    fun `identical JsonObject payloads skip apply and notify`() {
        val current = buildJsonObject { put("selected_theme", JsonPrimitive("crimson")) }
        val incoming = buildJsonObject { put("selected_theme", JsonPrimitive("crimson")) }
        var applied = false
        var notified = false

        applyFeatureUnlessUnchanged(
            log = log,
            featureName = "theme_settings",
            current = current,
            incoming = incoming,
            apply = { applied = true },
            notifyChanged = { notified = true },
        )

        assertFalse(applied, "apply() must not run for a byte-identical payload")
        assertFalse(notified, "notifyChanged() must not fan out for a byte-identical payload")
    }

    @Test
    fun `different JsonObject payloads still apply and notify`() {
        val current = buildJsonObject { put("selected_theme", JsonPrimitive("crimson")) }
        val incoming = buildJsonObject { put("selected_theme", JsonPrimitive("ocean")) }
        var applied = false
        var notified = false

        applyFeatureUnlessUnchanged(
            log = log,
            featureName = "theme_settings",
            current = current,
            incoming = incoming,
            apply = { applied = true },
            notifyChanged = { notified = true },
        )

        assertTrue(applied, "a genuinely different remote payload must still apply")
        assertTrue(notified, "a genuinely different remote payload must still fan out")
    }

    /**
     * A payload that only has a DIFFERENT SHAPE (extra/missing key), not different values on the
     * shared keys, must still read as "changed" — this is the guard against comparing
     * decoded/parsed fields instead of the raw exported representation. A writing client on a
     * different schema (e.g. one that doesn't model `nav_bar_style`) must never be mistaken for a
     * no-op.
     */
    @Test
    fun `payloads that differ only in shape still apply and notify`() {
        val current = buildJsonObject { put("selected_theme", JsonPrimitive("crimson")) }
        val incoming = buildJsonObject {
            put("selected_theme", JsonPrimitive("crimson"))
            put("nav_bar_style", JsonPrimitive("floating"))
        }
        var applied = false
        var notified = false

        applyFeatureUnlessUnchanged(
            log = log,
            featureName = "theme_settings",
            current = current,
            incoming = incoming,
            apply = { applied = true },
            notifyChanged = { notified = true },
        )

        assertTrue(applied, "a schema difference must never read as unchanged")
        assertTrue(notified, "a schema difference must never read as unchanged")
    }

    @Test
    fun `identical string payloads skip apply and notify`() {
        var applied = false
        var notified = false

        applyFeatureUnlessUnchanged(
            log = log,
            featureName = "poster_card_style_settings_payload",
            current = "v2:rounded",
            incoming = "v2:rounded",
            apply = { applied = true },
            notifyChanged = { notified = true },
        )

        assertFalse(applied)
        assertFalse(notified)
    }

    @Test
    fun `different string payloads still apply and notify`() {
        var applied = false
        var notified = false

        applyFeatureUnlessUnchanged(
            log = log,
            featureName = "card_depth_style_settings_payload",
            current = "v1:flat",
            incoming = "v1:elevated",
            apply = { applied = true },
            notifyChanged = { notified = true },
        )

        assertTrue(applied)
        assertTrue(notified)
    }

    @Test
    fun `apply and notify each run exactly once for a changed payload`() {
        var applyCount = 0
        var notifyCount = 0

        applyFeatureUnlessUnchanged(
            log = log,
            featureName = "theme_settings",
            current = "a",
            incoming = "b",
            apply = { applyCount++ },
            notifyChanged = { notifyCount++ },
        )

        assertEquals(1, applyCount)
        assertEquals(1, notifyCount)
    }
}
