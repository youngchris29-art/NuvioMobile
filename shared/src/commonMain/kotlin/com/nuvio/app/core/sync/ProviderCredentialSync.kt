package com.nuvio.app.core.sync

import co.touchlab.kermit.Logger
import com.nuvio.app.core.auth.AuthRepository
import com.nuvio.app.core.auth.AuthState
import com.nuvio.app.core.coroutines.uncaughtCoroutineLogger
import com.nuvio.app.core.network.SupabaseProvider
import com.nuvio.app.features.debrid.DebridProviders
import com.nuvio.app.features.debrid.DebridSettings
import com.nuvio.app.features.debrid.DebridSettingsRepository
import com.nuvio.app.features.mdblist.MdbListSettings
import com.nuvio.app.features.mdblist.MdbListSettingsRepository
import com.nuvio.app.features.player.PlayerSettingsRepository
import com.nuvio.app.features.player.PlayerSettingsUiState
import com.nuvio.app.features.profiles.ProfileRepository
import io.github.jan.supabase.postgrest.postgrest
import io.github.jan.supabase.postgrest.rpc
import kotlin.concurrent.Volatile
import kotlinx.atomicfu.locks.SynchronizedObject
import kotlinx.atomicfu.locks.synchronized
import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.FlowPreview
import kotlinx.coroutines.Job
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.flow.combine
import kotlinx.coroutines.flow.debounce
import kotlinx.coroutines.flow.distinctUntilChanged
import kotlinx.coroutines.launch
import kotlinx.coroutines.sync.Mutex
import kotlinx.coroutines.sync.withLock
import kotlinx.serialization.json.add
import kotlinx.serialization.json.buildJsonArray
import kotlinx.serialization.json.buildJsonObject
import kotlinx.serialization.json.put

private const val PROVIDER_CREDENTIAL_PUSH_DEBOUNCE_MS = 500L

private data class ProviderCredentialScope(
    val userId: String,
    val profileId: Int,
)

/**
 * Cross-client sync for provider API-key credentials (MDBList, every debrid provider,
 * AnimeSkip client id, IntroDB API key).
 *
 * These used to ride the general [ProfileSettingsSync] blob, which does a whole-blob
 * signature diff: a device with an empty key set could blank a good key set on another device.
 * This object owns them instead, keyed per provider, so a remote row only ever replaces the one
 * credential it carries. [ProfileSettingsCredentialPolicy] keeps the same keys out of the
 * settings blob on both the push and the apply side.
 *
 * Persists nothing of its own — the snapshot maps below are in-memory bookkeeping, and the
 * credentials themselves live in the existing per-feature storages (already covered by
 * `core.account.AccountDataStores`).
 */
object ProviderCredentialSync {
    // Fork: uncaughtCoroutineLogger — an exception escaping this scope on Kotlin/Native reaches
    // the unhandled-exception hook and aborts the process.
    private val scope = CoroutineScope(
        SupervisorJob() + Dispatchers.Default + uncaughtCoroutineLogger("ProviderCredentialSync"),
    )
    private val log = Logger.withTag("ProviderCredentialSync")
    private val syncMutex = Mutex()
    private val stateLock = SynchronizedObject()
    private val observedSnapshots = mutableMapOf<Int, ProviderCredentialSnapshot>()
    private val baselineSnapshots = mutableMapOf<ProviderCredentialScope, ProviderCredentialSnapshot>()

    /**
     * Fork: credential edits whose observer push FAILED, per scope, provider id → value ("" is a
     * pending clear). Upstream 1854dfc3 dropped the whole-snapshot push-before-pull retry (and its
     * `pendingScopes` arming set) because that push rewrote EVERY provider row from one possibly
     * stale device. Dropping the retry outright regressed the other way: an edit made offline is
     * restored to the server's old value by the next [mergeRemote] and baselined, so the edit is
     * lost with no further local change to ride out on — and an unsuccessful CLEAR is resurrected.
     *
     * This keeps upstream's rule (no whole-snapshot push) while closing that hole: only providers
     * that actually changed against the baseline are remembered, they are overlaid onto the merged
     * snapshot on the next [syncFromRemote], and only THEY are pushed. Keyed by scope, i.e. per
     * (user, profile): a profile switch must not lose the outgoing profile's unpushed edit, and
     * must not apply it to the incoming profile's rows.
     *
     * [syncFromRemote] also WRITES here: an edit the user makes while a pull is in flight, or a
     * replay push that fails again, is (re)held at the value that was attempted, so the entry
     * survives until the server actually has it.
     */
    private val pendingEdits = mutableMapOf<ProviderCredentialScope, MutableMap<String, String>>()

    /**
     * Legacy-blob migration stash (Codex rounds 4+7): credential values found in a pre-split
     * remote settings blob, keyed profileId → storage key. Staged by ProfileSettingsSync during
     * blob apply and consumed by [syncFromRemote], which applies a staged value ONLY where the
     * provider has no remote row and the local slot is blank — so provider rows (including
     * clear-tombstones) always beat the blob, and a staged value can never masquerade as a
     * local edit that pushes over another device's state.
     */
    private val legacyBlobCredentials = mutableMapOf<Int, Map<String, String>>()
    private var observeJob: Job? = null

    /**
     * Storage key (as it appears in a legacy settings blob) → snapshot provider id. The debrid
     * spellings are NOT mechanical ("debrid_real_debrid_api_key" ↔ "realdebrid"), so this map is
     * explicit and mirrors `ProfileSettingsCredentialPolicy.profileCredentialKeys`.
     */
    /**
     * Providers the Nuvio backend refuses in `sync_push_provider_credentials` /
     * `sync_seed_provider_credentials` payloads. The RPC validates the WHOLE snapshot and rejects
     * the entire call over one unknown provider (Postgres 22023 "Unsupported provider credential:
     * debrid:alldebrid", observed live 2026-08-08 on the beta.11 device pass — every push from a
     * device holding an AllDebrid key failed, so nothing synced at all). AllDebrid is a fork-only
     * provider (FEAT-6); until the backend learns it, its credential stays device-local. Filtered
     * at the serialization boundary only: local snapshots still carry it, so change detection and
     * `applySnapshot` are untouched (a remote snapshot can never contain it, and apply only writes
     * providers present in the payload, so the local key is never blanked). Since upstream
     * 1854dfc3 a provider missing from a pull is BLANKED, so this set is also the
     * `clearWhenAbsent` exemption passed to [ProviderCredentialSnapshot.mergeRemote] — an
     * AllDebrid row can never exist remotely, and blanking on every pull would wipe the key.
     */
    private val BACKEND_UNSUPPORTED_PROVIDERS = setOf(
        ProviderCredentialIds.debrid(DebridProviders.ALLDEBRID_ID),
    )

    private val legacyStorageKeyToProvider = mapOf(
        // Fork: no "tmdb_api_key" entry — upstream 60ee0160 bundles the TMDB key at compile
        // time, so a legacy blob's personal TMDB key has nowhere to migrate to. It is still
        // EXTRACTED by ProfileSettingsSync, which keeps `rewriteLegacyBlobSanitized` firing so
        // the dead key is stripped from the remote blob.
        "mdblist_api_key" to ProviderCredentialIds.MDBLIST,
        "animeskip_client_id" to ProviderCredentialIds.ANIMESKIP,
        "introdb_api_key" to ProviderCredentialIds.INTRODB,
        "debrid_torbox_api_key" to ProviderCredentialIds.debrid(DebridProviders.TORBOX_ID),
        "debrid_premiumize_api_key" to ProviderCredentialIds.debrid(DebridProviders.PREMIUMIZE_ID),
        "debrid_real_debrid_api_key" to ProviderCredentialIds.debrid(DebridProviders.REAL_DEBRID_ID),
        "debrid_alldebrid_api_key" to ProviderCredentialIds.debrid(DebridProviders.ALLDEBRID_ID),
    )

    fun stageLegacyBlobCredentials(profileId: Int, values: Map<String, String>) {
        val nonBlank = values.filterValues(String::isNotBlank)
        if (nonBlank.isEmpty()) return
        synchronized(stateLock) {
            legacyBlobCredentials[profileId] = legacyBlobCredentials[profileId].orEmpty() + nonBlank
        }
        log.d { "Staged ${nonBlank.size} legacy blob credential(s) for profile $profileId" }
    }

    // Fork: @Volatile — read from the observer coroutine while the sync coroutine writes it.
    @Volatile
    private var isApplyingRemote = false

    @OptIn(FlowPreview::class)
    fun startObserving() {
        if (observeJob?.isActive == true) return
        ensureRepositoriesLoaded()
        observeJob = scope.launch {
            observeCredentialSnapshots()
                .distinctUntilChanged()
                .debounce(PROVIDER_CREDENTIAL_PUSH_DEBOUNCE_MS)
                .collect(::handleLocalSnapshot)
        }
    }

    fun clearAccountState() {
        observeJob?.cancel()
        observeJob = null
        synchronized(stateLock) {
            observedSnapshots.clear()
            baselineSnapshots.clear()
            // Fork: pending edits belong to the signed-out account's scopes — never replay them
            // against whoever signs in next.
            pendingEdits.clear()
            legacyBlobCredentials.clear()
        }
    }

    /**
     * Re-baselines the observer against the profile that is active RIGHT NOW (upstream
     * 1854dfc3). The profile fan-out reloads every credential repository, so the observer sees a
     * burst of "changes" that are really just the new profile's values; without this re-baseline
     * the first of them reads as a local edit and pushes the outgoing profile's snapshot over the
     * incoming one's rows. Called from the tvOS profile installer after the repositories reload.
     *
     * Fork: [pendingEdits] is deliberately NOT cleared here. It is keyed by scope, so the outgoing
     * profile's unpushed edit is neither lost nor applied to the incoming profile — it is replayed
     * the next time that profile syncs. Re-baselining the incoming scope is enough to stop the
     * fan-out's reload burst reading as a local edit.
     */
    internal fun onProfileChanged() {
        if (observeJob?.isActive != true) return
        ensureRepositoriesLoaded()
        val profileId = ProfileRepository.activeProfileId
        val snapshot = currentSnapshot(profileId)
        val credentialScope = currentScope(profileId)
        synchronized(stateLock) {
            observedSnapshots[profileId] = snapshot
            if (credentialScope != null) {
                baselineSnapshots[credentialScope] = snapshot
            }
        }
    }

    suspend fun syncFromRemote(profileId: Int): Boolean = syncMutex.withLock {
        ensureRepositoriesLoaded()
        val credentialScope = currentScope(profileId) ?: return@withLock false
        try {
            val localSnapshot = currentSnapshot(profileId)
            // Upstream 1854dfc3 removed the push-before-pull retry that used to run here (and the
            // `pendingScopes` set that armed it): the push serialized EVERY provider with no
            // client timestamp for the server to arbitrate on, so a device reconnecting with one
            // pending edit rewrote all provider rows with its possibly-stale values — the exact
            // "automatic sync restores deleted data" vector. The fork's own note here declined to
            // fix it unilaterally to keep upstream's distributed-sync semantics; upstream has now
            // made the call. Trade: a push that failed in the observer is retried on the next
            // local edit, not on the next foreground sync.

            // Perf (upstream 67b865a7, "seed only missing provider credentials"): pull FIRST, so
            // the seed below can be skipped entirely when nothing is missing remotely — the
            // seed RPC is insert-if-absent, so calling it when every seedable provider already
            // has a remote row is a wasted round-trip.
            val rows = pullRows(profileId)

            // Fork: the legacy-blob seed below is RETAINED (upstream 1854dfc3 deleted its seed
            // RPC outright). Consequence to know about: for a credential this device still holds
            // locally, upstream's new absent-provider blanking is inert here — pull returns no
            // row, the seed re-creates one from the staged legacy value, and `voidFill`/the next
            // merge refills the slot. The real protection against a stale device resurrecting
            // deleted data is [onProfileChanged] plus the two `handleLocalSnapshot` guards, not
            // the blanking. Follow-up (product call, NOT this batch): narrow the seed to
            // `stagedByProvider` only, so a plain local value never re-seeds a row the user
            // deleted elsewhere.

            // Legacy-blob migration (see [legacyBlobCredentials]): fill only true voids. The
            // staged values ride the SEED, whose RPC is insert-if-absent (it must be — it runs
            // with the plain local snapshot on every sync, and an upserting seed would clobber
            // remote rows before every pull, defeating mergeRemote entirely). So a provider that
            // already has a row — including a blank clear-tombstone — is untouched, while a
            // provider with no row gets created carrying the legacy value; mergeRemote below
            // applies it locally like any other remote credential once a later sync pulls it.
            // Fork: never merged into localSnapshot itself — the observer's push path compares
            // against the REAL local state (handleLocalSnapshot), so a staged value must not
            // appear there or it would read as a local edit and be pushed (Codex rounds 7–9).
            // Stash keys are STORAGE keys ("debrid_torbox_api_key"), snapshot providers are ids
            // ("debrid:torbox") — translated via [legacyStorageKeyToProvider].
            // PEEK, don't consume: the stash may be these credentials' only surviving copy (the
            // legacy blob rewrite waits on us), so it must outlive a failed/cancelled seed —
            // consumed only in the success bookkeeping below (Codex round 10).
            val staged = synchronized(stateLock) { legacyBlobCredentials[profileId] }.orEmpty()
            val stagedByProvider = staged.entries.mapNotNull { (storageKey, value) ->
                legacyStorageKeyToProvider[storageKey]?.let { it to value }
            }.toMap()
            val seedSnapshotWithLegacy = if (stagedByProvider.isEmpty()) localSnapshot else localSnapshot.copy(
                values = localSnapshot.values.map { slot ->
                    val legacy = stagedByProvider[slot.provider]
                    if (legacy != null && slot.value.isBlank()) slot.copy(value = legacy) else slot
                },
            )
            // Seed only NON-BLANK values: an uninitialized client seeding blank rows for every
            // provider would mint authoritative tombstones out of nothing — the next device with
            // real local credentials baselines from local (no push), its seed can't replace the
            // existing blank rows, and the pull then erases its credentials (Codex round 14).
            // Blanks still travel on the explicit PUSH path, so an intentional clear remains a
            // tombstone.
            val seedPayload = seedSnapshotWithLegacy.copy(
                values = seedSnapshotWithLegacy.values.filter { it.value.isNotBlank() },
            )
            // shouldSeedProviderCredentials gates on the payload that would actually be sent
            // (post legacy-fill, post blank-filter), not the raw local snapshot — a provider
            // already present remotely never needs re-seeding even if other local slots are blank.
            // Because the pull now precedes the seed, values the seed just created are NOT in
            // `rows` — capture them so the merge below can apply them locally this round (the
            // success bookkeeping consumes the stash, so waiting for the next pull would leave a
            // freshly migrated credential inert for a whole sync round). Only providers with NO
            // remote row qualify: a provider that has a row — including a blank tombstone — was
            // untouched by the insert-if-absent seed, and the tombstone must keep winning.
            val remoteProviders = rows.mapTo(mutableSetOf()) { it.provider.lowercase() }
            var seededByProvider = emptyMap<String, String>()
            if (seedPayload.values.isNotEmpty() && shouldSeedProviderCredentials(seedPayload, rows)) {
                if (stagedByProvider.isNotEmpty()) {
                    log.i { "Seeding ${stagedByProvider.size} legacy blob credential(s) for profile $profileId (insert-if-absent)" }
                }
                seedSnapshot(seedPayload)
                seededByProvider = seedPayload.values
                    .filter { it.provider.lowercase() !in remoteProviders }
                    .associate { it.provider to it.value }
            }
            requireCurrentScope(credentialScope)
            // Fork: the clear-when-absent predicate exempts BACKEND_UNSUPPORTED_PROVIDERS.
            // Upstream 1854dfc3 blanks any provider the server did not return; AllDebrid is
            // filtered out of every outbound payload (see [credentialParams]), so it can NEVER
            // have a remote row and upstream's rule would erase the key on every single pull.
            val remoteSnapshot = localSnapshot.mergeRemote(rows) { it !in BACKEND_UNSUPPORTED_PROVIDERS }
            // Staged credentials for BACKEND_UNSUPPORTED_PROVIDERS never ride the seed (filtered
            // from every outbound payload), so no provider row exists for the pull to return —
            // yet the success bookkeeping below consumes the stash and sanitizes the legacy blob,
            // which held the only copy. Apply them LOCALLY instead, folded into the snapshot
            // `applySnapshot` writes (so the write happens under `isApplyingRemote` and the
            // baselines below include the value — no spurious follow-up push). Void-fill only,
            // mirroring the seed's insert-if-absent semantics: a real local credential wins over
            // a staged legacy one (Codex review, 2026-08-08 device-pass session).
            val unsupportedStaged = stagedByProvider.filterKeys { it in BACKEND_UNSUPPORTED_PROVIDERS }
            // Both maps void-fill only: just-seeded values (rows pulled pre-seed can't contain
            // them) and unsupported-provider staged values (no row will ever exist). Unsupported
            // wins on overlap — its value never rode the seed, so the stash is its only copy.
            val voidFill = seededByProvider + unsupportedStaged
            val mergedSnapshot = if (voidFill.isEmpty()) remoteSnapshot else remoteSnapshot.copy(
                values = remoteSnapshot.values.map { slot ->
                    val fill = voidFill[slot.provider]
                    if (!fill.isNullOrBlank() && slot.value.isBlank()) slot.copy(value = fill) else slot
                },
            )
            // Fork: replay credential edits whose observer push failed (see [pendingEdits]), and
            // protect edits the user made WHILE this pull was in flight.
            //
            // `localSnapshot` was captured BEFORE the pull suspended, so it is stale by the time
            // the rows come back: the user can change a credential in Settings across those
            // round-trips (the repositories write through immediately, while the observer's push
            // is debounced and then blocks on `syncMutex`, which this pull holds). Re-read the
            // live state here and reconcile against BOTH snapshots:
            //   * a provider with a HELD pending edit takes the value this device holds RIGHT NOW,
            //     not the one recorded at failure time — the map marks which providers have an
            //     unpushed local opinion, and the recorded value can be stale (the user edits the
            //     same provider again through a path that does not push; the observer's apply and
            //     profile guards all return early). Reasserting the live value keeps "the local
            //     edit wins" true without ever writing a value the user has already replaced.
            //   * a provider whose value CHANGED DURING THE PULL joins the replay for this round:
            //     the live local value wins over the row the pull returned, and is pushed on its
            //     own. Without this, `applySnapshot` writes the server's value (or a held edit's)
            //     over a change seconds old, the baselines make it permanent, and the observer
            //     emission still queued for it fails its own current-snapshot guard — the edit is
            //     gone with nothing left to retry it.
            // Deliberately coarse: "differs from the pre-pull snapshot" is the whole test, no
            // per-field revisions. The overlay covers BACKEND_UNSUPPORTED_PROVIDERS too (their
            // slot must keep the live local value); the push set below cannot carry them.
            requireCurrentScope(credentialScope)
            val postPullSnapshot = currentSnapshot(profileId)
            val localByProvider = postPullSnapshot.values.associate { it.provider to it.value }
            val concurrentEdits = postPullSnapshot.providersDifferingFrom(localSnapshot)
            val heldProviders = synchronized(stateLock) { pendingEdits[credentialScope]?.keys?.toSet() }.orEmpty()
            val overlay = (heldProviders + concurrentEdits)
                .mapNotNull { provider -> localByProvider[provider]?.let { provider to it } }
                .toMap()
            val finalSnapshot = mergedSnapshot.overlayingPendingEdits(overlay)
            // Never let an unsupported provider into the push set: it has no remote row to
            // reconcile against and its slot is already exempt from blanking.
            val pending = overlay.filterKeys { it !in BACKEND_UNSUPPORTED_PROVIDERS }
            // An entry the server already agrees with is settled, whatever made it so (our push
            // did land and only the response was lost, or another device wrote the same value) —
            // retire it instead of spending a round-trip on it.
            val mergedByProvider = mergedSnapshot.values.associate { it.provider to it.value }
            val settledPending = pending.filter { (provider, value) -> mergedByProvider[provider] == value }
            val outstandingPending = pending - settledPending.keys
            // Against the POST-pull local state: the overlay re-asserts values the repositories
            // already hold, so comparing with the pre-pull snapshot would report an apply (and
            // run a no-op write burst under `isApplyingRemote`) for a pull that changed nothing.
            val applied = finalSnapshot != postPullSnapshot
            if (applied) {
                isApplyingRemote = true
                try {
                    applySnapshot(finalSnapshot, credentialScope)
                } finally {
                    isApplyingRemote = false
                }
            }
            requireCurrentScope(credentialScope)
            // Push ONLY the pending providers — upstream 1854dfc3's whole point is that a
            // reconnecting device must not rewrite rows it has no fresh opinion about. A failure
            // here is not fatal to the pull: keep the entry and retry on the next sync.
            // Fork: `restrictedTo` assumes `sync_push_provider_credentials` UPSERTS the rows it is
            // given per provider and leaves omitted providers untouched — i.e. that a partial
            // payload is a partial write, not a replace-all. That is the contract the fork infers
            // from the RPC's design (the seed RPC is its insert-if-absent sibling, and the pull is
            // row-wise); there is no contract test for it here, and no schema to check from this
            // repo. If the RPC ever deletes omitted rows, this replay becomes a credential wipe —
            // verify against the backend before widening the payload rules.
            var failedReplay = emptySet<String>()
            if (outstandingPending.isNotEmpty()) {
                try {
                    pushSnapshot(finalSnapshot.restrictedTo(outstandingPending.keys))
                    log.i { "Replayed ${outstandingPending.size} pending credential edit(s) for profile $profileId" }
                } catch (error: CancellationException) {
                    throw error
                } catch (error: Throwable) {
                    failedReplay = outstandingPending.keys
                    log.e(error) { "Failed to replay pending credential edits for profile $profileId" }
                }
            }
            requireCurrentScope(credentialScope)
            // Fork: the baseline is what the SERVER is believed to hold, and a failed replay means
            // that is NOT what was just applied locally. Baselining the local value there buries
            // the edit: the observer diffs against the baseline, so a later B -> C -> B matches it,
            // returns without pushing (dropping the held entries on the way), and the next pull
            // restores the server's A. Pin the failed providers to the value the pull returned
            // instead — `observedSnapshots` still records what the repositories actually hold.
            val baselineSnapshot = finalSnapshot.replacingValues(from = mergedSnapshot, providers = failedReplay)
            synchronized(stateLock) {
                observedSnapshots[profileId] = finalSnapshot
                baselineSnapshots[credentialScope] = baselineSnapshot
                // Everything considered this round is cleared and then the failures are re-held,
                // at the value that was actually attempted — including an edit that only appeared
                // during this pull, which has no other way back to the server. Nothing can have
                // touched the map since it was read above: every writer holds `syncMutex`. Dropped
                // entirely when empty, so a scope that never fails does not accumulate a husk. A
                // provider filtered out as BACKEND_UNSUPPORTED is deliberately left: it should
                // never have been recorded, and dropping it here would hide that.
                val scoped = pendingEdits.getOrPut(credentialScope) { mutableMapOf() }
                (settledPending.keys + outstandingPending.keys).forEach { provider -> scoped.remove(provider) }
                failedReplay.forEach { provider -> overlay[provider]?.let { scoped[provider] = it } }
                if (scoped.isEmpty()) pendingEdits.remove(credentialScope)
                // Migration round-trip succeeded (seed-if-missing + pull, unsupported providers
                // applied locally above) — every staged value now lives in a provider row
                // (whether just seeded or already present remotely) or the local store, so the
                // stash can go and the legacy blob may be sanitized.
                legacyBlobCredentials.remove(profileId)
            }
            if (staged.isNotEmpty()) {
                ProfileSettingsSync.rewriteLegacyBlobSanitized(profileId)
            }
            log.d {
                "Synchronized ${finalSnapshot.values.size} credentials for profile $profileId " +
                    "applied=$applied pendingReplayed=${outstandingPending.size - failedReplay.size} " +
                    "pendingHeld=${failedReplay.size} concurrentEdits=${concurrentEdits.size}"
            }
            applied
        } catch (error: CancellationException) {
            throw error
        } catch (error: Throwable) {
            AuthRepository.signOutIfSessionInvalid(error, "Provider credential sync")
            log.e(error) { "Provider credential sync failed for profile $profileId" }
            throw error
        }
    }

    private suspend fun seedSnapshot(snapshot: ProviderCredentialSnapshot) {
        SupabaseProvider.client.postgrest.rpc(
            function = "sync_seed_provider_credentials",
            parameters = credentialParams(snapshot),
        )
    }

    private suspend fun pushSnapshot(snapshot: ProviderCredentialSnapshot) {
        SupabaseProvider.client.postgrest.rpc(
            function = "sync_push_provider_credentials",
            parameters = credentialParams(snapshot),
        )
        log.d { "Pushed ${snapshot.values.size} credentials for profile ${snapshot.profileId}" }
    }

    private suspend fun pullRows(profileId: Int): List<SupabaseProviderCredential> {
        val params = buildJsonObject {
            put("p_profile_id", profileId)
        }
        return SupabaseProvider.client.postgrest
            .rpc("sync_pull_provider_credentials", params)
            .decodeList()
    }

    private fun credentialParams(snapshot: ProviderCredentialSnapshot) = buildJsonObject {
        put("p_profile_id", snapshot.profileId)
        put("p_credentials", buildJsonArray {
            snapshot.values.forEach { credential ->
                if (credential.provider in BACKEND_UNSUPPORTED_PROVIDERS) return@forEach
                add(buildJsonObject {
                    put("provider", credential.provider)
                    put("credential_json", credential.credentialJson())
                })
            }
        })
        putSyncOriginClientId()
    }

    private fun observeCredentialSnapshots() = combine(
        ProfileRepository.state,
        DebridSettingsRepository.uiState,
        MdbListSettingsRepository.uiState,
        PlayerSettingsRepository.uiState,
    ) { _, debrid, mdbList, player ->
        buildSnapshot(
            profileId = ProfileRepository.activeProfileId,
            debrid = debrid,
            mdbList = mdbList,
            player = player,
        )
    }

    private fun currentSnapshot(profileId: Int): ProviderCredentialSnapshot {
        check(ProfileRepository.activeProfileId == profileId)
        val snapshot = buildSnapshot(
            profileId = profileId,
            debrid = DebridSettingsRepository.snapshot(),
            mdbList = MdbListSettingsRepository.snapshot(),
            player = PlayerSettingsRepository.uiState.value,
        )
        check(ProfileRepository.activeProfileId == profileId)
        return snapshot
    }

    private fun buildSnapshot(
        profileId: Int,
        debrid: DebridSettings,
        mdbList: MdbListSettings,
        player: PlayerSettingsUiState,
    ): ProviderCredentialSnapshot = ProviderCredentialSnapshot(
        profileId = profileId,
        values = buildList {
            DebridProviders.all().forEach { provider ->
                add(
                    ProviderCredentialValue(
                        provider = ProviderCredentialIds.debrid(provider.id),
                        field = PROVIDER_API_KEY_FIELD,
                        value = debrid.apiKeyFor(provider.id).trim(),
                    ),
                )
            }
            add(ProviderCredentialValue(ProviderCredentialIds.MDBLIST, PROVIDER_API_KEY_FIELD, mdbList.apiKey.trim()))
            add(
                ProviderCredentialValue(
                    ProviderCredentialIds.ANIMESKIP,
                    PROVIDER_CLIENT_ID_FIELD,
                    player.animeSkipClientId.trim(),
                ),
            )
            add(
                ProviderCredentialValue(
                    ProviderCredentialIds.INTRODB,
                    PROVIDER_API_KEY_FIELD,
                    player.introDbApiKey.trim(),
                ),
            )
        },
    )

    private suspend fun applySnapshot(
        snapshot: ProviderCredentialSnapshot,
        expectedScope: ProviderCredentialScope,
    ) {
        snapshot.values.forEach { credential ->
            requireCurrentScope(expectedScope)
            when {
                credential.provider.startsWith("debrid:") -> {
                    DebridSettingsRepository.setProviderApiKey(
                        credential.provider.substringAfter("debrid:"),
                        credential.value,
                    )
                }
                credential.provider == ProviderCredentialIds.MDBLIST -> {
                    MdbListSettingsRepository.setApiKey(credential.value)
                }
                credential.provider == ProviderCredentialIds.ANIMESKIP -> {
                    PlayerSettingsRepository.setAnimeSkipClientId(credential.value)
                }
                credential.provider == ProviderCredentialIds.INTRODB -> {
                    PlayerSettingsRepository.setIntroDbApiKey(credential.value)
                }
            }
        }
    }

    private suspend fun handleLocalSnapshot(snapshot: ProviderCredentialSnapshot) {
        if (isApplyingRemote) return
        syncMutex.withLock {
            // Upstream 1854dfc3: the debounced emission may have been produced under a profile
            // that is no longer active, or superseded by a newer local state while it waited on
            // this mutex — pushing either would write stale values over good remote rows.
            if (ProfileRepository.activeProfileId != snapshot.profileId) return@withLock
            // Fork: runCatching — currentSnapshot() `check`s the active profile, and a switch
            // racing the line above would otherwise throw out of the collector and kill
            // observeJob for the rest of the session (upstream lets it throw).
            val current = runCatching { currentSnapshot(snapshot.profileId) }.getOrNull() ?: return@withLock
            if (snapshot != current) return@withLock
            val previous = synchronized(stateLock) {
                observedSnapshots.put(snapshot.profileId, snapshot)
            }
            val credentialScope = currentScope(snapshot.profileId) ?: return@withLock
            if (previous == null) {
                synchronized(stateLock) {
                    if (credentialScope !in baselineSnapshots) {
                        baselineSnapshots[credentialScope] = snapshot
                    }
                }
                return@withLock
            }
            // Compare only what a push can carry: BACKEND_UNSUPPORTED_PROVIDERS are device-local
            // by construction, so an edit touching ONLY them must not trigger a push — under
            // upstream's push-before-pull, a stale device pushing its whole (unchanged-remote)
            // snapshot over newer remote keys is exactly the overwrite race, widened to fire off
            // a credential that never even syncs (Codex round 2, 2026-08-08 device-pass session).
            if (previous.syncableSubset() == snapshot.syncableSubset()) return@withLock
            val baseline = synchronized(stateLock) {
                baselineSnapshots.getOrPut(credentialScope) { previous }
            }
            if (baseline.syncableSubset() == snapshot.syncableSubset()) {
                // Fork: local is back at the state the server is believed to hold (a failed edit
                // undone by hand, say), so nothing is owed — drop any held edits for this scope
                // before they get replayed over the value the user just restored.
                synchronized(stateLock) { pendingEdits.remove(credentialScope) }
                return@withLock
            }

            try {
                pushSnapshot(snapshot)
                synchronized(stateLock) {
                    baselineSnapshots[credentialScope] = snapshot
                    // Fork: this push carried the WHOLE snapshot, so every edit remembered for
                    // this scope is now on the server — a stale entry left here would later be
                    // overlaid over (and pushed back on top of) a newer value.
                    pendingEdits.remove(credentialScope)
                }
            } catch (error: CancellationException) {
                throw error
            } catch (error: Throwable) {
                // Upstream 1854dfc3: a failed push is NOT remembered as a whole-snapshot retry —
                // that re-push was exactly the stale-device overwrite the commit closes.
                // Fork: remember the CHANGED PROVIDERS only (see [pendingEdits]). Upstream's
                // trade — the edit rides the next local change or is lost to the next pull — is
                // a regression the fork does not take; replaying one provider is not the
                // whole-snapshot push upstream removed.
                val baselineByProvider = baseline.values.associate { it.provider to it.value }
                val edits = snapshot.values
                    .filter { it.provider !in BACKEND_UNSUPPORTED_PROVIDERS }
                    .filter { baselineByProvider[it.provider] != it.value }
                    .associate { it.provider to it.value }
                if (edits.isNotEmpty()) {
                    synchronized(stateLock) {
                        pendingEdits.getOrPut(credentialScope) { mutableMapOf() }.putAll(edits)
                    }
                }
                AuthRepository.signOutIfSessionInvalid(error, "Provider credential push")
                log.e(error) {
                    "Failed to push provider credentials for profile ${snapshot.profileId} " +
                        "— ${edits.size} edit(s) held for the next sync"
                }
            }
        }
    }

    /**
     * The snapshot minus [BACKEND_UNSUPPORTED_PROVIDERS] — i.e. exactly what a push/seed payload
     * can carry after [credentialParams] filtering. Dirty/baseline comparisons use this so a
     * device-local-only edit never fires a network push; the STORED snapshots keep the full value
     * list (the local-only credential still participates in apply/merge bookkeeping).
     */
    private fun ProviderCredentialSnapshot.syncableSubset(): ProviderCredentialSnapshot =
        copy(values = values.filter { it.provider !in BACKEND_UNSUPPORTED_PROVIDERS })

    private fun currentScope(profileId: Int): ProviderCredentialScope? {
        val state = AuthRepository.state.value as? AuthState.Authenticated ?: return null
        if (state.isAnonymous || ProfileRepository.activeProfileId != profileId) return null
        return ProviderCredentialScope(state.userId, profileId)
    }

    private fun requireCurrentScope(expected: ProviderCredentialScope) {
        if (currentScope(expected.profileId) != expected) {
            throw CancellationException("Provider credential sync target changed")
        }
    }

    private fun ensureRepositoriesLoaded() {
        DebridSettingsRepository.ensureLoaded()
        MdbListSettingsRepository.ensureLoaded()
        PlayerSettingsRepository.ensureLoaded()
    }
}
