package com.nuvio.app.core.sync

import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertFalse
import kotlinx.serialization.json.JsonPrimitive
import kotlinx.serialization.json.buildJsonObject
import kotlinx.serialization.json.put

class ProfileSettingsCredentialPolicyTest {
    @Test
    fun `credential fields are removed from profile settings payloads`() {
        val payload = buildJsonObject {
            put("debrid_enabled", JsonPrimitive(true))
            put("debrid_torbox_api_key", JsonPrimitive("secret"))
            put("debrid_premiumize_api_key", JsonPrimitive("secret"))
        }

        val sanitized = withoutProfileCredentials(PROFILE_DEBRID_SETTINGS_FEATURE, payload)

        assertFalse("debrid_torbox_api_key" in sanitized)
        assertFalse("debrid_premiumize_api_key" in sanitized)
        assertEquals(JsonPrimitive(true), sanitized["debrid_enabled"])
    }

    /**
     * Fork-only provider: this fork ships AllDebrid on top of upstream's three, and
     * `DebridSettingsStorage.exportToSyncPayload()` emits its key via `DebridProviders.all()`.
     * If the policy ever loses this entry the key silently rejoins the settings blob.
     */
    @Test
    fun `alldebrid credential field is stripped like the other debrid providers`() {
        val payload = buildJsonObject {
            put("debrid_enabled", JsonPrimitive(true))
            put("debrid_alldebrid_api_key", JsonPrimitive("secret"))
            put("debrid_real_debrid_api_key", JsonPrimitive("secret"))
        }

        val sanitized = withoutProfileCredentials(PROFILE_DEBRID_SETTINGS_FEATURE, payload)

        assertFalse("debrid_alldebrid_api_key" in sanitized)
        assertFalse("debrid_real_debrid_api_key" in sanitized)
        assertEquals(JsonPrimitive(true), sanitized["debrid_enabled"])
    }

    @Test
    fun `legacy remote credential fields cannot overwrite local credentials`() {
        // Uses the REAL wire shape (`encodeSyncString`'s typed wrapper): the blank-detection has
        // to unwrap it, or every present local credential reads as blank and remote wins —
        // exactly the inversion Codex round 5 caught.
        val remote = buildJsonObject {
            put("mdblist_enabled", JsonPrimitive(true))
            put("mdblist_api_key", encodeSyncString("remote"))
        }
        val local = buildJsonObject {
            put("mdblist_api_key", encodeSyncString("local"))
        }

        val merged = preservingLocalProfileCredentials(PROFILE_MDBLIST_SETTINGS_FEATURE, remote, local)

        assertEquals(encodeSyncString("local"), merged["mdblist_api_key"])
        assertEquals(JsonPrimitive(true), merged["mdblist_enabled"])
    }

    /**
     * Upstream df589078: the personal TMDB key is an optional credential again, so it follows the
     * MDBList rules — a local key survives a remote blob apply, a remote-only key is stripped and
     * extracted for staging, and the push side never carries it. (rc13 dropped it on both sides.)
     */
    @Test
    fun `TMDB personal key follows the provider credential rules`() {
        val remote = buildJsonObject {
            put("tmdb_enabled", JsonPrimitive(true))
            put("tmdb_api_key", encodeSyncString("remote"))
        }
        val local = buildJsonObject {
            put("tmdb_api_key", encodeSyncString("local"))
        }

        val merged = preservingLocalProfileCredentials(PROFILE_TMDB_SETTINGS_FEATURE, remote, local)
        val remoteOnly = preservingLocalProfileCredentials(PROFILE_TMDB_SETTINGS_FEATURE, remote, buildJsonObject { })
        val sanitized = withoutProfileCredentials(PROFILE_TMDB_SETTINGS_FEATURE, local)

        assertEquals(encodeSyncString("local"), merged["tmdb_api_key"])
        assertEquals(JsonPrimitive(true), merged["tmdb_enabled"])
        assertFalse("tmdb_api_key" in remoteOnly)
        assertFalse("tmdb_api_key" in sanitized)
        assertEquals(
            mapOf("tmdb_api_key" to "remote"),
            extractLegacyCredentials(PROFILE_TMDB_SETTINGS_FEATURE, remote),
        )
    }

    /**
     * The legacy migration contract (Codex rounds 4+7): a credential the pre-split remote blob
     * still carries is STRIPPED from the applied payload (so it never reads as a local edit that
     * pushes over a provider row's clear-tombstone) and surfaced via [extractLegacyCredentials]
     * for ProviderCredentialSync to stage into true voids only.
     */
    @Test
    fun `legacy remote credential is stripped from the applied payload but extracted for staging`() {
        val remote = buildJsonObject {
            put("mdblist_enabled", JsonPrimitive(true))
            put("mdblist_api_key", encodeSyncString("remote"))
        }

        val merged = preservingLocalProfileCredentials(
            PROFILE_MDBLIST_SETTINGS_FEATURE,
            remote,
            buildJsonObject { },
        )

        assertFalse("mdblist_api_key" in merged)
        assertEquals(JsonPrimitive(true), merged["mdblist_enabled"])
        assertEquals(
            mapOf("mdblist_api_key" to "remote"),
            extractLegacyCredentials(PROFILE_MDBLIST_SETTINGS_FEATURE, remote),
        )
    }

    /** A blank local slot counts as "no credential" — strip-and-stage, same as absent. */
    @Test
    fun `blank local credential is treated as absent`() {
        val remote = buildJsonObject {
            put("mdblist_api_key", encodeSyncString("remote"))
        }
        val local = buildJsonObject {
            put("mdblist_api_key", encodeSyncString(""))
        }

        val merged = preservingLocalProfileCredentials(PROFILE_MDBLIST_SETTINGS_FEATURE, remote, local)

        assertFalse("mdblist_api_key" in merged)
        assertEquals(
            mapOf("mdblist_api_key" to "remote"),
            extractLegacyCredentials(PROFILE_MDBLIST_SETTINGS_FEATURE, remote),
        )
    }

    /** Blank values in the legacy blob are noise, not credentials — never staged. */
    @Test
    fun `blank legacy remote values are not extracted`() {
        val remote = buildJsonObject {
            put("mdblist_api_key", encodeSyncString(" "))
        }

        assertEquals(emptyMap(), extractLegacyCredentials(PROFILE_MDBLIST_SETTINGS_FEATURE, remote))
    }
}
