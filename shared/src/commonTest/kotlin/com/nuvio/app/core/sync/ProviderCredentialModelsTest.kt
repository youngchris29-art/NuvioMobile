package com.nuvio.app.core.sync

import com.nuvio.app.features.debrid.DebridSettings
import com.nuvio.app.features.mdblist.MdbListSettings
import com.nuvio.app.features.player.PlayerSettingsUiState
import com.nuvio.app.features.tmdb.TmdbSettings
import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertFalse
import kotlin.test.assertTrue
import kotlinx.serialization.json.buildJsonObject
import kotlinx.serialization.json.put

class ProviderCredentialModelsTest {
    // Upstream df589078 (ported from composeApp's ProviderCredentialModelsTest).
    @Test
    fun `TMDB credential snapshot contains the personal override`() {
        val snapshot = credentialSnapshot(TmdbSettings(apiKey = " personal-key "))
        val credential = snapshot.values.single { it.provider == ProviderCredentialIds.TMDB }

        assertEquals(1, snapshot.profileId)
        assertEquals(buildJsonObject { put("api_key", "personal-key") }, credential.credentialJson())
    }

    @Test
    fun `empty TMDB override syncs a clear tombstone instead of the bundled key`() {
        val snapshot = credentialSnapshot(TmdbSettings())
        val credential = snapshot.values.single { it.provider == ProviderCredentialIds.TMDB }

        assertEquals(buildJsonObject { put("api_key", "") }, credential.credentialJson())
    }

    @Test
    fun `remote TMDB override can be replaced and cleared`() {
        val local = credentialSnapshot(TmdbSettings(apiKey = "local-key"))
        val remote = listOf(
            SupabaseProviderCredential("tmdb", buildJsonObject { put("api_key", "remote-key") }),
        )
        val merged = local.mergeRemote(remote)

        assertEquals("remote-key", merged.values.single { it.provider == ProviderCredentialIds.TMDB }.value)
        assertEquals("", merged.mergeRemote(emptyList()).values.single { it.provider == ProviderCredentialIds.TMDB }.value)
    }

    /**
     * Fork: a TMDB key held locally with NO remote row (the first sync after upgrading, or a key
     * set on a build that predates the "tmdb" provider) must be pushed, not blanked by
     * upstream 1854dfc3's clear-when-absent rule. `syncFromRemote` does this through the
     * insert-if-absent SEED plus the `voidFill` refill; this composes the same pure steps
     * (the singleton talks straight to Supabase, so the round trip itself is not unit-testable —
     * see the pending-edit tests below for the same approach).
     */
    @Test
    fun `a local TMDB key with no remote row is seeded and survives the pull`() {
        val local = credentialSnapshot(TmdbSettings(apiKey = "local-key"))
        val rows = listOf(
            SupabaseProviderCredential("mdblist", buildJsonObject { put("api_key", "") }),
        )

        // Seed payload = non-blank local values; it is sent because a provider is missing.
        val seedPayload = local.copy(values = local.values.filter { it.value.isNotBlank() })
        assertTrue(shouldSeedProviderCredentials(seedPayload, rows))
        assertEquals(
            listOf(ProviderCredentialIds.TMDB),
            seedPayload.values.map { it.provider },
        )
        val remoteProviders = rows.mapTo(mutableSetOf()) { it.provider.lowercase() }
        val seeded = seedPayload.values
            .filter { it.provider.lowercase() !in remoteProviders }
            .associate { it.provider to it.value }

        // The merge alone blanks it (no row) ...
        val merged = local.mergeRemote(rows)
        assertEquals("", merged.values.single { it.provider == ProviderCredentialIds.TMDB }.value)
        // ... and the seeded void-fill puts it back, so nothing is applied over the local key.
        val final = merged.copy(
            values = merged.values.map { slot ->
                val fill = seeded[slot.provider]
                if (!fill.isNullOrBlank() && slot.value.isBlank()) slot.copy(value = fill) else slot
            },
        )
        assertEquals("local-key", final.values.single { it.provider == ProviderCredentialIds.TMDB }.value)
        assertEquals(local, final)
    }

    /**
     * Fork: a `tmdb_api_key` still riding a legacy settings blob is extracted by the policy and
     * staged to the "tmdb" provider (rc13 had no mapping, so it was dropped on the floor).
     */
    @Test
    fun `a legacy TMDB key in a settings blob is staged to the TMDB provider`() {
        val blob = buildJsonObject {
            put("tmdb_enabled", encodeSyncBoolean(true))
            put("tmdb_api_key", encodeSyncString("legacy-key"))
        }

        val extracted = extractLegacyCredentials(PROFILE_TMDB_SETTINGS_FEATURE, blob)
        val staged = extracted.entries.mapNotNull { (storageKey, value) ->
            ProviderCredentialSync.legacyStorageKeyToProvider[storageKey]?.let { it to value }
        }.toMap()

        assertEquals(mapOf(ProviderCredentialIds.TMDB to "legacy-key"), staged)
        // Every provider a legacy key can stage into is a slot the snapshot actually carries, or
        // the staged value would have nowhere to land.
        val slots = credentialSnapshot(TmdbSettings()).values.mapTo(mutableSetOf()) { it.provider }
        assertTrue(ProviderCredentialSync.legacyStorageKeyToProvider.values.all { it in slots })
    }

    @Test
    fun `complete remote snapshot does not require seeding`() {
        val snapshot = ProviderCredentialSnapshot(
            profileId = 1,
            values = listOf(
                ProviderCredentialValue("debrid:torbox", "api_key", "local-torbox"),
                ProviderCredentialValue("animeskip", "client_id", "local-anime"),
            ),
        )
        val rows = listOf(
            SupabaseProviderCredential(
                provider = "DEBRID:TORBOX",
                credentialJson = buildJsonObject { put("api_key", "remote") },
            ),
            SupabaseProviderCredential(
                provider = "animeskip",
                credentialJson = buildJsonObject { put("client_id", "remote") },
            ),
        )

        assertFalse(shouldSeedProviderCredentials(snapshot, rows))
    }

    @Test
    fun `missing remote provider requires seeding`() {
        val snapshot = ProviderCredentialSnapshot(
            profileId = 1,
            values = listOf(
                ProviderCredentialValue("debrid:torbox", "api_key", "local-torbox"),
                ProviderCredentialValue("animeskip", "client_id", "local-anime"),
            ),
        )
        val rows = listOf(
            SupabaseProviderCredential(
                provider = "debrid:torbox",
                credentialJson = buildJsonObject { put("api_key", "remote") },
            ),
        )

        assertTrue(shouldSeedProviderCredentials(snapshot, rows))
    }

    @Test
    fun `remote values replace only supported local providers`() {
        val local = ProviderCredentialSnapshot(
            profileId = 2,
            values = listOf(
                ProviderCredentialValue("debrid:torbox", "api_key", "local-torbox"),
                ProviderCredentialValue("animeskip", "client_id", "local-anime"),
            ),
        )
        val remote = listOf(
            SupabaseProviderCredential(
                provider = "debrid:torbox",
                credentialJson = buildJsonObject { put("api_key", "remote-torbox") },
            ),
            SupabaseProviderCredential(
                provider = "unsupported",
                credentialJson = buildJsonObject { put("api_key", "ignored") },
            ),
        )

        val merged = local.mergeRemote(remote)

        assertEquals("remote-torbox", merged.values[0].value)
        // Upstream 1854dfc3: a provider the server did not return is CLEARED, so an automatic
        // pull propagates a deletion instead of the local copy surviving to be re-pushed.
        assertEquals("", merged.values[1].value)
    }

    @Test
    fun `empty remote snapshot clears all cached credentials`() {
        val local = ProviderCredentialSnapshot(
            profileId = 1,
            values = listOf(
                ProviderCredentialValue("debrid:torbox", "api_key", "local-torbox"),
                ProviderCredentialValue("animeskip", "client_id", "local-anime"),
            ),
        )

        assertEquals(listOf("", ""), local.mergeRemote(emptyList()).values.map { it.value })
    }

    @Test
    fun `absent provider is kept when the caller marks it non-syncable`() {
        // Fork: AllDebrid is filtered out of every outbound payload, so it can never have a
        // remote row — upstream's blank-when-absent rule would erase the key on every pull.
        val local = ProviderCredentialSnapshot(
            profileId = 1,
            values = listOf(
                ProviderCredentialValue("debrid:alldebrid", "api_key", "local-ad"),
                ProviderCredentialValue("debrid:torbox", "api_key", "local-torbox"),
            ),
        )
        val remote = listOf(
            SupabaseProviderCredential(
                provider = "debrid:torbox",
                credentialJson = buildJsonObject { put("api_key", "remote") },
            ),
        )

        val merged = local.mergeRemote(remote) { it != "debrid:alldebrid" }

        assertEquals(listOf("local-ad", "remote"), merged.values.map { it.value })
    }

    @Test
    fun `blank remote value is retained as a clear tombstone`() {
        val local = ProviderCredentialSnapshot(
            profileId = 1,
            values = listOf(ProviderCredentialValue("mdblist", "api_key", "local")),
        )
        val remote = listOf(
            SupabaseProviderCredential(
                provider = "mdblist",
                credentialJson = buildJsonObject { put("api_key", "") },
            ),
        )

        assertEquals("", local.mergeRemote(remote).values.single().value)
    }

    // Fork: the pending-edit replay (`ProviderCredentialSync.pendingEdits`). `ProviderCredentialSync`
    // itself is a singleton talking straight to Supabase with no injectable adapter, so these cover
    // the pure overlay/restrict helpers the sync path composes rather than the round trip.
    @Test
    fun `a pending edit beats the value the pull returned`() {
        // The regression: edit mdblist A -> B offline, the observer push fails, the next pull
        // returns A and mergeRemote restores it. The overlay puts B back so the sync can push it.
        val local = ProviderCredentialSnapshot(
            profileId = 1,
            values = listOf(
                ProviderCredentialValue("mdblist", "api_key", "B"),
                ProviderCredentialValue("debrid:torbox", "api_key", "torbox-local"),
            ),
        )
        val remote = listOf(
            SupabaseProviderCredential(
                provider = "mdblist",
                credentialJson = buildJsonObject { put("api_key", "A") },
            ),
            SupabaseProviderCredential(
                provider = "debrid:torbox",
                credentialJson = buildJsonObject { put("api_key", "torbox-remote") },
            ),
        )

        val merged = local.mergeRemote(remote)
        assertEquals(listOf("A", "torbox-remote"), merged.values.map { it.value })

        val replayed = merged.overlayingPendingEdits(mapOf("mdblist" to "B"))

        // Only the pending provider is overlaid — a provider with no local edit still takes the
        // server's value, which is the half of upstream 1854dfc3 that must keep working.
        assertEquals(listOf("B", "torbox-remote"), replayed.values.map { it.value })
    }

    @Test
    fun `a pending clear is not resurrected by the pull and narrows the push payload`() {
        val local = ProviderCredentialSnapshot(
            profileId = 1,
            values = listOf(
                ProviderCredentialValue("mdblist", "api_key", ""),
                ProviderCredentialValue("introdb", "api_key", "keep-me"),
            ),
        )
        val remote = listOf(
            SupabaseProviderCredential(
                provider = "mdblist",
                credentialJson = buildJsonObject { put("api_key", "stale") },
            ),
            SupabaseProviderCredential(
                provider = "introdb",
                credentialJson = buildJsonObject { put("api_key", "keep-me") },
            ),
        )

        val replayed = local.mergeRemote(remote).overlayingPendingEdits(mapOf("mdblist" to ""))
        assertEquals(listOf("", "keep-me"), replayed.values.map { it.value })

        // The replay push carries the pending provider ONLY: upstream 1854dfc3's rule is that a
        // reconnecting device must not rewrite rows it has no fresh opinion about.
        val payload = replayed.restrictedTo(setOf("mdblist"))
        assertEquals(listOf("mdblist"), payload.values.map { it.provider })
        assertEquals(1, payload.profileId)
    }

    @Test
    fun `an edit made while the pull was in flight beats the row that came back`() {
        // The pull captures the local state, suspends, and the user retypes mdblist as C while it
        // is out. Composing the apply against the PRE-pull snapshot would write the server's A
        // over C (and baseline it), and the observer emission still queued for C fails its own
        // current-snapshot guard — so C would be gone for good.
        val prePull = ProviderCredentialSnapshot(
            profileId = 1,
            values = listOf(
                ProviderCredentialValue("mdblist", "api_key", "B"),
                ProviderCredentialValue("introdb", "api_key", "introdb-local"),
            ),
        )
        val livePostPull = prePull.copy(
            values = listOf(
                ProviderCredentialValue("mdblist", "api_key", "C"),
                ProviderCredentialValue("introdb", "api_key", "introdb-local"),
            ),
        )
        val remote = listOf(
            SupabaseProviderCredential(
                provider = "mdblist",
                credentialJson = buildJsonObject { put("api_key", "A") },
            ),
            SupabaseProviderCredential(
                provider = "introdb",
                credentialJson = buildJsonObject { put("api_key", "introdb-remote") },
            ),
        )

        // Only the provider the user touched during the pull is flagged.
        assertEquals(setOf("mdblist"), livePostPull.providersDifferingFrom(prePull))

        val liveByProvider = livePostPull.values.associate { it.provider to it.value }
        val overlay = livePostPull.providersDifferingFrom(prePull)
            .mapNotNull { provider -> liveByProvider[provider]?.let { provider to it } }
            .toMap()
        val finalSnapshot = prePull.mergeRemote(remote).overlayingPendingEdits(overlay)

        // C survives and is what gets pushed; a provider nobody touched still takes the server's
        // value, which is the half of upstream 1854dfc3 that must keep working.
        assertEquals(listOf("C", "introdb-remote"), finalSnapshot.values.map { it.value })
        assertEquals(listOf("mdblist"), finalSnapshot.restrictedTo(overlay.keys).values.map { it.provider })
    }

    @Test
    fun `a failed replay baselines the server value while the local one stays applied`() {
        // The replay push for mdblist failed. `observedSnapshots` keeps B (what the repositories
        // hold), but the BASELINE has to stay at the server's A: baseline B and a later
        // B -> C -> B compares equal to it, the observer returns without pushing, and the next
        // pull restores A with nothing left to correct it.
        val applied = ProviderCredentialSnapshot(
            profileId = 1,
            values = listOf(
                ProviderCredentialValue("mdblist", "api_key", "B"),
                ProviderCredentialValue("introdb", "api_key", "introdb-remote"),
            ),
        )
        val pulled = applied.copy(
            values = listOf(
                ProviderCredentialValue("mdblist", "api_key", "A"),
                ProviderCredentialValue("introdb", "api_key", "introdb-remote"),
            ),
        )

        val baseline = applied.replacingValues(from = pulled, providers = setOf("mdblist"))

        assertEquals(listOf("A", "introdb-remote"), baseline.values.map { it.value })
        // The applied snapshot is untouched — only the baseline is rolled back.
        assertEquals(listOf("B", "introdb-remote"), applied.values.map { it.value })
        // A successful replay rolls nothing back.
        assertEquals(applied, applied.replacingValues(from = pulled, providers = emptySet()))
    }

    @Test
    fun `snapshot diffs and rollbacks ignore providers the other side does not carry`() {
        val local = ProviderCredentialSnapshot(
            profileId = 1,
            values = listOf(
                ProviderCredentialValue("mdblist", "api_key", "A"),
                ProviderCredentialValue("introdb", "api_key", "keep-me"),
            ),
        )
        val partial = ProviderCredentialSnapshot(
            profileId = 1,
            values = listOf(ProviderCredentialValue("mdblist", "api_key", "A")),
        )

        // A provider the other snapshot has no slot for reads as CHANGED — the sync's pre/post
        // pull snapshots always carry the same slot list, so this only bites if that ever stops
        // being true, and erring towards "keep the local value" is the safe direction.
        assertEquals(setOf("introdb"), local.providersDifferingFrom(partial))
        assertEquals(emptySet<String>(), local.providersDifferingFrom(local))
        // ...and a rollback for a provider the source lacks leaves the local value alone.
        assertEquals(local, local.replacingValues(from = partial, providers = setOf("introdb")))
    }

    @Test
    fun `an empty pending map and an unknown pending provider change nothing`() {
        val local = ProviderCredentialSnapshot(
            profileId = 1,
            values = listOf(ProviderCredentialValue("mdblist", "api_key", "A")),
        )

        assertEquals(local, local.overlayingPendingEdits(emptyMap()))
        assertEquals(local, local.overlayingPendingEdits(mapOf("debrid:torbox" to "B")))
        assertTrue(local.restrictedTo(emptySet()).values.isEmpty())
    }

    @Test
    fun connectedMdbListAccountNeverEntersTheCredentialSnapshot() {
        // Upstream 3f0d07be: account-backed ratings. Only the personal key override is a synced
        // credential; the account scope (and its Keychain token) must not change the snapshot.
        fun snapshot(mdbList: MdbListSettings) = ProviderCredentialSync.buildSnapshot(
            profileId = 1,
            debrid = DebridSettings(),
            tmdb = TmdbSettings(),
            mdbList = mdbList,
            player = PlayerSettingsUiState(),
        )
        val scope = com.nuvio.app.features.mdblist.MdbListAuthScope(profileId = 1, generation = 3)

        assertEquals(snapshot(MdbListSettings()), snapshot(MdbListSettings(accountScope = scope)))
        val withKey = snapshot(MdbListSettings(apiKey = "K", accountScope = scope))
        assertEquals(snapshot(MdbListSettings(apiKey = "K")), withKey)
        assertEquals(
            listOf(ProviderCredentialValue("mdblist", "api_key", "K")),
            withKey.values.filter { it.provider == "mdblist" },
        )
    }

    private fun credentialSnapshot(tmdb: TmdbSettings) = ProviderCredentialSync.buildSnapshot(
        profileId = 1,
        debrid = DebridSettings(),
        tmdb = tmdb,
        mdbList = MdbListSettings(),
        player = PlayerSettingsUiState(),
    )
}
