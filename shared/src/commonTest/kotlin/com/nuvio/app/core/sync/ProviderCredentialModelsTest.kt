package com.nuvio.app.core.sync

import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertFalse
import kotlin.test.assertTrue
import kotlinx.serialization.json.buildJsonObject
import kotlinx.serialization.json.put

class ProviderCredentialModelsTest {
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
}
