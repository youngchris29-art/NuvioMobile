package com.nuvio.app.features.addons

import com.nuvio.app.core.auth.AuthRepository
import com.nuvio.app.core.auth.AuthState
import com.nuvio.app.core.coroutines.uncaughtCoroutineLogger
import co.touchlab.kermit.Logger
import com.nuvio.app.core.i18n.StringKey
import com.nuvio.app.core.i18n.resourceString
import com.nuvio.app.core.network.SupabaseProvider
import com.nuvio.app.core.network.urlIdentityKey
import com.nuvio.app.core.sync.putSyncOriginClientId
import io.github.jan.supabase.postgrest.postgrest
import io.github.jan.supabase.postgrest.query.Order
import io.github.jan.supabase.postgrest.rpc
import kotlinx.atomicfu.locks.SynchronizedObject
import kotlinx.atomicfu.locks.synchronized
import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.CoroutineStart
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.Job
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.delay
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asStateFlow
import kotlinx.coroutines.flow.first
import kotlinx.coroutines.flow.update
import kotlinx.coroutines.flow.updateAndGet
import kotlinx.coroutines.launch
import kotlinx.coroutines.withContext
import kotlinx.serialization.SerialName
import kotlinx.serialization.Serializable
import kotlinx.serialization.json.Json
import kotlinx.serialization.json.buildJsonObject
import kotlinx.serialization.json.encodeToJsonElement
import kotlinx.serialization.json.put

@Serializable
private data class AddonRow(
    val url: String,
    val name: String? = null,
    val enabled: Boolean = true,
    @SerialName("sort_order") val sortOrder: Int = 0,
)

@Serializable
private data class AddonPushItem(
    val url: String,
    val name: String = "",
    val enabled: Boolean = true,
    @SerialName("sort_order") val sortOrder: Int = 0,
)

private const val ADDON_PUSH_DEBOUNCE_MS = 500L

object AddonRepository {
    private val scope = CoroutineScope(SupervisorJob() + Dispatchers.Default + uncaughtCoroutineLogger("AddonRepository"))
    private val log = Logger.withTag("AddonRepository")
    private val json = Json { ignoreUnknownKeys = true; encodeDefaults = true }
    private val _uiState = MutableStateFlow(AddonsUiState())
    val uiState: StateFlow<AddonsUiState> = _uiState.asStateFlow()

    private val bootstrap = AddonBootstrapState()
    private var pulledFromServer = false
    private var currentProfileId: Int = 1
    private val activeRefreshJobs = mutableMapOf<String, Job>()
    /**
     * Add-ons hub v2 review r7: guards every read and write of [activeRefreshJobs] (the active-job
     * check plus registration in [refreshAddon], the replacement in [restartRefresh], a job's
     * identity-checked removal, [resetRefreshesAndState]), so a cancelled job's cleanup can never
     * remove its replacement's entry and leave that request untracked.
     */
    private val refreshJobsLock = SynchronizedObject()
    /**
     * Add-ons hub v2 review r6: refresh generations are unique ids from one process-wide counter,
     * never reused, so a job that outlived a reset (`clearLocalState`) can never match the id of a
     * later refresh of the same URL.
     */
    private val refreshIdCounter = MutableStateFlow(0L)
    private val pushJobsByProfile = mutableMapOf<Int, Job>()
    /**
     * Races item 5: guards every read and write of [pushJobsByProfile] (written on the main thread
     * by `pushToServer` and on Default by a push job's `finally` and by `clearLocalState`).
     */
    private val pushJobsLock = SynchronizedObject()
    /**
     * Races item 3, review r1: one profile transition at a time; an install's epoch check, append,
     * persist and push scheduling happen inside it as one step. Order: `profileLock` first, then
     * [refreshJobsLock] or [pushJobsLock]; holders of those two never take this one. Never held
     * across a suspension point or a network call.
     */
    private val profileLock = SynchronizedObject()

    /**
     * Races item 3: bumped whenever the repository's profile changes (`onProfileChanged`,
     * `clearLocalState`), BEFORE the state is reset. An install captures it before its manifest
     * fetch and refuses to append when it moved, so an install that started under one profile can
     * never write into another's list.
     */
    private val profileEpoch = MutableStateFlow(0L)

    // Observable mirror of the bootstrap guard so consumers that can outrun bootstrap (the player's
    // subtitle fetch) can wait for the local addon list instead of snapshotting an empty state.
    // Both live in [AddonBootstrapState] so no completion path can set one without the other.
    val initializedState: StateFlow<Boolean> = bootstrap.initializedState

    // Flips true when a server pull has SETTLED (applied, found-nothing, or failed with a real
    // error — not cancelled). The default-addon seed and the push guard below both key off the
    // distinction between "the server said" and "we never asked": seeding or full-replace-pushing
    // before the first settle is what wiped a tester's account addons (see
    // docs/addon-wipe-investigation-2026-08-28.md).
    private val _serverPullSettled = MutableStateFlow(false)
    val serverPullSettled: StateFlow<Boolean> = _serverPullSettled.asStateFlow()

    fun initialize() {
        val effectiveProfileId = resolveEffectiveProfileId(AddonProfileProvider.context.activeProfileId)
        if (bootstrap.initialized) return
        bootstrap.begin()
        currentProfileId = effectiveProfileId
        log.d { "initialize() — loading local addons for profile $currentProfileId" }

        val storedUrls = dedupeManifestUrls(AddonStorage.loadInstalledAddonUrls(currentProfileId))
        val enabledByUrl = loadLocalEnabledStates()
        log.d { "initialize() — local addon count: ${storedUrls.size}" }
        if (storedUrls.isEmpty()) {
            // Nothing stored locally, but bootstrap HAS run: publish that fact so watchers can tell
            // this settled empty state from the initial one they saw before initialize().
            _uiState.update { it.copy(isInitialized = true) }
            bootstrap.complete()
            return
        }

        val existingByUrl = _uiState.value.addons.associateBy(ManagedAddon::manifestUrl)
        // Add-ons hub v2 review r5: a same-profile replacement keeps the refresh generations, so a
        // refresh superseded before it carries over can still be told apart.
        updateListDetachingDeparted { current ->
            val rebuilt = keepingLiveRefresh(
                storedUrls.map { manifestUrl ->
                    existingByUrl[manifestUrl].toPendingAddon(
                        manifestUrl = manifestUrl,
                        enabled = enabledByUrl[manifestUrl],
                    )
                },
                current,
            )
            AddonsUiState(
                refreshGenerations = generationsForList(current.refreshGenerations, rebuilt),
                addons = rebuilt,
                isInitialized = true,
            )
        }

        storedUrls.forEach { manifestUrl ->
            val existing = existingByUrl[manifestUrl]
            val addon = _uiState.value.addons.firstOrNull { it.manifestUrl == manifestUrl }
            if (addon?.enabled == true && (existing == null || (addon.manifest == null && !addon.isRefreshing))) {
                refreshAddon(manifestUrl)
            }
        }
        bootstrap.complete()
    }

    fun onProfileChanged(profileId: Int) {
        // Races item 3, review r1: the whole transition, early-return check included, is one step
        // against an install's commit (`addAddon`), which takes the same lock.
        synchronized(profileLock) {
            val effectiveProfileId = resolveEffectiveProfileId(profileId)
            if (effectiveProfileId == currentProfileId && bootstrap.initialized) return
            // Races item 3: the bump comes before the reset writes the state.
            profileEpoch.update { it + 1 }
            currentProfileId = effectiveProfileId
            bootstrap.reset()
            pulledFromServer = false
            _serverPullSettled.value = false
            resetRefreshesAndState()
        }
    }

    fun clearLocalState() {
        synchronized(profileLock) {
            synchronized(pushJobsLock) {
                pushJobsByProfile.values.forEach(Job::cancel)
                pushJobsByProfile.clear()
            }
            profileEpoch.update { it + 1 }
            currentProfileId = 1
            bootstrap.reset()
            pulledFromServer = false
            _serverPullSettled.value = false
            resetRefreshesAndState()
        }
    }

    suspend fun pullFromServer(profileId: Int) {
        var settled = true
        try {
            currentProfileId = resolveEffectiveProfileId(profileId)
            log.i { "pullFromServer() — profileId=$profileId, initialized=${bootstrap.initialized}, pulledFromServer=$pulledFromServer" }
            runCatching {
                val rows = SupabaseProvider.client.postgrest
                    .from("addons")
                    .select {
                        filter { eq("profile_id", currentProfileId) }
                        order("sort_order", Order.ASCENDING)
                    }
                    .decodeList<AddonRow>()

                val rowsByUrl = linkedMapOf<String, AddonRow>()
                rows.forEach { row ->
                    val manifestUrl = normalizeServerManifestUrl(row.url)
                    if (!rowsByUrl.containsKey(manifestUrl)) {
                        rowsByUrl[manifestUrl] = row.copy(url = manifestUrl)
                    }
                }

                val urls = rowsByUrl.keys.toList()
                log.i { "pullFromServer() — server returned ${rows.size} addons" }
                urls.forEachIndexed { i, u -> log.d { "  server[$i]: $u" } }

                if (urls.isEmpty() && !pulledFromServer) {
                    val localUrls = dedupeManifestUrls(AddonStorage.loadInstalledAddonUrls(currentProfileId))
                    log.i { "pullFromServer() — server empty, local has ${localUrls.size} addons" }
                    if (localUrls.isNotEmpty()) {
                        log.i { "pullFromServer() — migrating local addons to server for profile $currentProfileId" }
                        initialize()
                        pulledFromServer = true
                        val enabledByUrl = loadLocalEnabledStates()
                        val addons = localUrls.mapIndexed { index, addonUrl ->
                            val manifestUrl = ensureManifestSuffix(addonUrl)
                            AddonPushItem(
                                url = manifestUrl,
                                name = _uiState.value.addons
                                    .find { it.manifestUrl == manifestUrl }?.manifest?.name ?: "",
                                enabled = enabledByUrl[manifestUrl]
                                    ?: _uiState.value.addons.find { it.manifestUrl == manifestUrl }?.enabled
                                    ?: true,
                                sortOrder = index,
                            )
                        }
                        val params = buildJsonObject {
                            put("p_profile_id", currentProfileId)
                            put("p_addons", json.encodeToJsonElement(addons))
                            putSyncOriginClientId()
                        }
                        SupabaseProvider.client.postgrest.rpc("sync_push_addons", params)
                        log.i { "pullFromServer() — migration push done (${addons.size} addons)" }
                        return
                    }
                }

                if (urls.isEmpty()) {
                    val localUrls = dedupeManifestUrls(AddonStorage.loadInstalledAddonUrls(currentProfileId))
                    if (localUrls.isNotEmpty()) {
                        log.w { "pullFromServer() — remote empty while local has ${localUrls.size} addons; preserving local addons" }
                        val enabledByUrl = loadLocalEnabledStates()
                        val existingByUrl = _uiState.value.addons.associateBy(ManagedAddon::manifestUrl)
                        // Add-ons hub v2 review r5: a same-profile replacement keeps the refresh generations, so a
                        // refresh superseded before it carries over can still be told apart.
                        updateListDetachingDeparted { current ->
                            val rebuilt = keepingLiveRefresh(
                                localUrls.map { url ->
                                    existingByUrl[url].toPendingAddon(
                                        manifestUrl = url,
                                        enabled = enabledByUrl[url],
                                    )
                                },
                                current,
                            )
                            AddonsUiState(
                                refreshGenerations = generationsForList(current.refreshGenerations, rebuilt),
                                addons = rebuilt,
                                // This path completes bootstrap below, so the published state
                                // says so too — a pull that wins the race with initialize() must not
                                // leave watchers thinking bootstrap never happened.
                                isInitialized = true,
                            )
                        }
                        persist()
                        localUrls.forEach { url ->
                            val existing = existingByUrl[url]
                            val addon = _uiState.value.addons.firstOrNull { it.manifestUrl == url }
                            if (addon?.enabled == true && (existing == null || (addon.manifest == null && !addon.isRefreshing))) {
                                refreshAddon(url)
                            }
                        }
                        pulledFromServer = true
                        bootstrap.complete()
                        return
                    }
                }

                val existingByUrl = _uiState.value.addons.associateBy(ManagedAddon::manifestUrl)
                // Add-ons hub v2 review r5: a same-profile replacement keeps the refresh generations, so a
                // refresh superseded before it carries over can still be told apart.
                updateListDetachingDeparted { current ->
                    val rebuilt = keepingLiveRefresh(
                        urls.map { url ->
                            val row = rowsByUrl[url]
                            existingByUrl[url].toPendingAddon(
                                manifestUrl = url,
                                userSetName = row?.name?.takeIf { it.isNotBlank() },
                                enabled = row?.enabled,
                            )
                        },
                        current,
                    )
                    AddonsUiState(
                        refreshGenerations = generationsForList(current.refreshGenerations, rebuilt),
                        addons = rebuilt,
                        // As above: the server's list IS a settled bootstrap for this profile.
                        isInitialized = true,
                    )
                }
                persist()
                urls.forEach { url ->
                    val existing = existingByUrl[url]
                    val addon = _uiState.value.addons.firstOrNull { it.manifestUrl == url }
                    if (addon?.enabled == true && (existing == null || (addon.manifest == null && !addon.isRefreshing))) {
                        refreshAddon(url)
                    }
                }
                pulledFromServer = true
                bootstrap.complete()
                log.i { "pullFromServer() — applied ${urls.size} addons to state" }
            }.onFailure { e ->
                // runCatching captures cancellation too; without this rethrow the outer handler
                // below never sees it, and a pull cancelled by a profile switch would mark the
                // NEW profile's gate settled (finally runs after onProfileChanged's reset).
                if (e is CancellationException) throw e
                log.e(e) { "pullFromServer() — FAILED" }
            }
        } catch (error: CancellationException) {
            settled = false
            throw error
        } finally {
            // Signals a settle on every completion path except cancellation — including inside
            // the early `return`s above, which trigger this `finally` like any other. A
            // cancelled pull (e.g. profile switched away mid-flight) must NOT count as settled:
            // the seed/push guards below need to keep waiting for a pull that actually finishes.
            if (settled) _serverPullSettled.value = true
        }
    }

    suspend fun awaitManifestsLoaded() {
        if (_uiState.value.addons.isEmpty()) return
        uiState.first { state ->
            state.addons.isEmpty() ||
                state.addons.any { it.manifest != null } ||
                state.addons.none { it.isRefreshing }
        }
    }

    /**
     * [enabled] (hub v2 C3 review r4): the new add-on's initial flag, set in the same state update
     * that appends it, so it applies only to the instance this call inserted.
     */
    suspend fun addAddon(rawUrl: String): AddAddonResult = addAddon(rawUrl, enabled = true)

    suspend fun addAddon(rawUrl: String, enabled: Boolean): AddAddonResult {
        if (isUsingPrimaryAddonsFromSecondaryProfile()) {
            return AddAddonResult.Error(resourceString("This profile uses primary addons.", StringKey.profile_primary_addons_required))
        }
        // Races item 3: the profile this install belongs to; checked again inside the append.
        val installEpoch = profileEpoch.value
        log.i { "addAddon() — rawUrl=$rawUrl" }
        val manifestUrl = try {
            normalizeManifestUrl(rawUrl)
        } catch (error: IllegalArgumentException) {
            return AddAddonResult.Error(error.message ?: resourceString("Enter a valid addon URL", StringKey.addon_invalid_url))
        }

        if (_uiState.value.addons.any { isSameManifestUrl(it.manifestUrl, manifestUrl) }) {
            return AddAddonResult.Error(resourceString("That addon is already installed.", StringKey.addon_already_installed))
        }

        val manifest = try {
            withContext(Dispatchers.Default) {
                val payload = fetchAddonResponseText(manifestUrl)
                AddonManifestParser.parse(
                    manifestUrl = manifestUrl,
                    payload = payload,
                )
            }
        } catch (error: Throwable) {
            // The same rule as the refresh path: a transport error carries the keyed URL (AddonFailureMessages.kt).
            return AddAddonResult.Error(manifestFailureMessage(error))
        }

        // C1 review r9: the duplicate check above runs before the (slow) fetch, so two installs of
        // one URL can both pass it; the append re-checks inside the update and only one lands.
        // Races item 3: the same update also refuses when the profile changed during the fetch (the
        // reducer decides; see `appendInstalled`), so nothing is written into another profile.
        // Review r1: the epoch check, append, persist and push scheduling are one step under
        // `profileLock`, so a profile switch cannot land between them. The manifest fetch above is
        // outside it; nothing in here suspends or waits on the network (`pushToServer` only
        // snapshots and launches).
        var outcome: InstallAppend = InstallAppend.Duplicate
        synchronized(profileLock) {
            // `update` can retry its block (a concurrent refresh publish does not take the lock);
            // every attempt decides afresh, and the epoch cannot move while the lock is held.
            _uiState.update { current ->
                val result = appendInstalled(
                    current = current,
                    addon = ManagedAddon(
                        manifestUrl = manifestUrl,
                        manifest = manifest,
                        enabled = enabled,
                        isRefreshing = false,
                        errorMessage = null,
                    ),
                    sameProfile = profileEpoch.value == installEpoch,
                )
                outcome = result
                if (result is InstallAppend.Appended) result.state else current
            }
            if (outcome is InstallAppend.Appended) {
                persist()
                pushToServer()
            }
        }
        when (outcome) {
            InstallAppend.Duplicate ->
                return AddAddonResult.Error(resourceString("That addon is already installed.", StringKey.addon_already_installed))
            // No new copy for this rare case (decision B): the existing install-failure message.
            InstallAppend.ProfileChanged -> {
                log.w { "addAddon() — refused: the profile changed during the install of $manifestUrl" }
                return AddAddonResult.Error(resourceString("Unable to load manifest", StringKey.addon_load_manifest_failed))
            }
            is InstallAppend.Appended -> Unit
        }
        return AddAddonResult.Success(manifest)
    }

    /**
     * Review whole-stage r1 P2: every path that REPLACES the list (`initialize`, the three pull
     * applies, a Remote Setup edit) detaches the departed URLs' refresh jobs and health in the same
     * step as the list change, under [refreshJobsLock], exactly as [removeAddon] does. Without it a
     * pull that removes U and a pull that restores it before the asynchronous watcher runs would
     * leave the old job registered: `refreshAddon` refuses to start a new one and the old one
     * cannot publish (its generation is gone). The detached jobs are cancelled after the lock;
     * nothing is awaited. [transform] may run more than once (a state update retries), so it must
     * be free of side effects other than the ones the callers already reset per attempt. No other
     * lock is taken inside; callers do not hold [refreshJobsLock] (it is not re-entered).
     */
    private fun updateListDetachingDeparted(transform: (AddonsUiState) -> AddonsUiState) {
        var before = emptyList<ManagedAddon>()
        var after = emptyList<ManagedAddon>()
        val cancelled = synchronized(refreshJobsLock) {
            _uiState.update { current ->
                val next = transform(current)
                before = current.addons
                after = next.addons
                next
            }
            val detach = detachedByListChange(before, after, activeRefreshJobs.keys)
            detach.healthUrls.forEach(AddonHealthTracker::forget)
            detach.jobUrls.mapNotNull { activeRefreshJobs.remove(it) }
        }
        cancelled.forEach(Job::cancel)
    }

    fun removeAddon(manifestUrl: String) {
        if (isUsingPrimaryAddonsFromSecondaryProfile()) return
        log.i { "removeAddon() — $manifestUrl" }
        var changed = false
        var cancelled: Job? = null
        // Races item 1/4: the removal ends the URL's refresh generation, drops its health and takes
        // its job out in the same step as the list change, under the lock refresh registration
        // uses. A reinstall that lands before the (asynchronous) removal watcher runs therefore
        // starts clean: the removed instance's request fails its generation check. The job is
        // cancelled after the lock, as `resetRefreshesAndState` does.
        synchronized(refreshJobsLock) {
            _uiState.update { current ->
                val updatedAddons = current.addons.filterNot { it.manifestUrl == manifestUrl }
                changed = updatedAddons.size != current.addons.size
                if (changed) {
                    current.copy(
                        addons = updatedAddons,
                        refreshGenerations = generationsForList(current.refreshGenerations, updatedAddons),
                    )
                } else {
                    current
                }
            }
            if (changed) {
                cancelled = activeRefreshJobs.remove(manifestUrl)
                AddonHealthTracker.forget(manifestUrl)
            }
        }
        cancelled?.cancel()
        if (!changed) return
        persist()
        pushToServer()
    }

    fun moveAddon(fromIndex: Int, toIndex: Int) {
        if (isUsingPrimaryAddonsFromSecondaryProfile()) return
        var changed = false
        _uiState.update { current ->
            val addons = current.addons
            if (
                fromIndex !in addons.indices ||
                toIndex !in addons.indices ||
                fromIndex == toIndex
            ) {
                return@update current
            }

            val reordered = addons.toMutableList()
            val movingAddon = reordered.removeAt(fromIndex)
            reordered.add(toIndex, movingAddon)
            changed = true
            current.copy(addons = reordered)
        }
        if (!changed) return
        persist()
        pushToServer()
    }

    /**
     * Add-ons hub v2 A4 (review r3): moves [manifestUrl] one place by [delta] (±1). The add-on and
     * its destination are resolved INSIDE the state update, so a list replaced by a sync between
     * a caller's read and this call can never move a different add-on. Returns whether it moved.
     */
    fun moveAddonStep(manifestUrl: String, delta: Int): Boolean =
        reorderAtomically { steppedOrder(it, manifestUrl, delta) }

    /**
     * Add-ons hub v2 A4 (review r3): puts [manifestUrl] right after the last add-on of
     * [predecessors] still listed (first when none), resolved inside the state update. The Move
     * mode's cancel uses it to restore the position relative to the survivors.
     */
    fun moveAddonAfter(manifestUrl: String, predecessors: Set<String>): Boolean =
        reorderAtomically(pushWhenUnchanged = true) { restoredOrder(it, manifestUrl, predecessors) }

    /**
     * [pushWhenUnchanged] (review A4-r4): a cancel whose restored order is already in place (a
     * pull applied it meanwhile) still schedules a push of the CURRENT list, which replaces a
     * step's pending debounced push (`pushToServer` snapshots the list and cancels the previous
     * job), so the cancelled order can never reach the server afterwards.
     */
    private fun reorderAtomically(
        pushWhenUnchanged: Boolean = false,
        reorder: (List<ManagedAddon>) -> List<ManagedAddon>?,
    ): Boolean {
        if (isUsingPrimaryAddonsFromSecondaryProfile()) return false
        var changed = false
        _uiState.update { current ->
            val reordered = reorder(current.addons)
            changed = reordered != null && reordered != current.addons
            if (changed) current.copy(addons = reordered!!) else current
        }
        if (!changed) {
            if (pushWhenUnchanged) pushToServer()
            return false
        }
        persist()
        pushToServer()
        return true
    }

    /**
     * Add-ons hub v2 C1 (review r3): applies a list edited on the Remote Setup phone page in ONE
     * state update, and only if the list is still exactly [expectedUrls] (the list the page
     * edited). The result is [desiredUrls] in that order (add-ons left out are removed), with
     * [enabled] overriding each add-on's flag. Changes nothing and returns STALE when the list
     * moved under the page (a sync or another screen) or an add-on's flag no longer matches
     * [expectedEnabled] (the state the confirm dialog showed), or READ_ONLY when the active profile's
     * add-ons are inherited and the edit would change them or [addsNew] (the caller installs new
     * add-ons only after APPLIED); APPLIED otherwise, including when nothing needed to change. Add-ons newly enabled without a manifest are refreshed, as
     * [setAddonEnabled] does.
     */
    fun applyEditedListIfUnchanged(
        expectedUrls: List<String>,
        desiredUrls: List<String>,
        enabled: Map<String, Boolean>,
        addsNew: Boolean,
        expectedEnabled: Map<String, Boolean> = emptyMap(),
    ): RemoteListEditResult {
        val readOnly = isUsingPrimaryAddonsFromSecondaryProfile()
        var matched = false
        var changed = false
        var refusal: EditedListOutcome? = null
        var toRefresh = emptyList<String>()
        updateListDetachingDeparted { current ->
            // `update` can retry its block; every attempt starts from a clean slate.
            matched = false
            changed = false
            refusal = null
            toRefresh = emptyList()
            when (val outcome = editedListOutcome(current.addons, expectedUrls, desiredUrls, enabled, readOnly, addsNew, expectedEnabled)) {
                EditedListOutcome.Stale, EditedListOutcome.ReadOnly -> {
                    refusal = outcome
                    current
                }
                EditedListOutcome.Unchanged -> {
                    matched = true
                    current
                }
                is EditedListOutcome.Edited -> {
                    matched = true
                    changed = true
                    toRefresh = outcome.addons.filter { addon ->
                        addon.enabled && addon.manifest == null && !addon.isRefreshing &&
                            current.addons.firstOrNull { it.manifestUrl == addon.manifestUrl }?.enabled == false
                    }.map { it.manifestUrl }
                    current.copy(
                        addons = outcome.addons,
                        refreshGenerations = generationsForList(current.refreshGenerations, outcome.addons),
                    )
                }
            }
        }
        if (!matched) {
            return if (refusal == EditedListOutcome.ReadOnly) RemoteListEditResult.READ_ONLY else RemoteListEditResult.STALE
        }
        if (changed) {
            persist()
            pushToServer()
        }
        toRefresh.forEach { refreshAddon(it) }
        return RemoteListEditResult.APPLIED
    }

    fun setAddonEnabled(manifestUrl: String, enabled: Boolean) {
        if (isUsingPrimaryAddonsFromSecondaryProfile()) return
        var shouldRefresh = false
        var changed = false
        _uiState.update { current ->
            current.copy(
                addons = current.addons.map { addon ->
                    if (addon.manifestUrl != manifestUrl || addon.enabled == enabled) {
                        addon
                    } else {
                        changed = true
                        shouldRefresh = enabled && addon.manifest == null && !addon.isRefreshing
                        addon.copy(enabled = enabled)
                    }
                },
            )
        }
        if (!changed) return
        persist()
        pushToServer()
        if (shouldRefresh) {
            refreshAddon(manifestUrl)
        }
    }

    /**
     * Cancels a refresh still running for [manifestUrl] (a stuck request: [refreshAddon] is a no-op
     * while one is registered and not completed) and starts a fresh, cache-bypassing one. The cancelled job's cleanup
     * only removes its own map entry, so the new job stays tracked.
     */
    fun restartRefresh(manifestUrl: String) {
        startRefresh(manifestUrl = manifestUrl, forceRefresh = true, replaceExisting = true)
    }

    /**
     * C4 review r2: the hub's Check now. Every enabled add-on gets a fresh, cache-bypassing
     * fetch, replacing a refresh that is still running (a stalled one would otherwise block it).
     */
    fun checkAll() {
        _uiState.value.addons.filter { it.enabled }.distinctBy { it.manifestUrl }.forEach { addon ->
            restartRefresh(addon.manifestUrl)
        }
    }

    fun refreshAll() {
        _uiState.value.addons.filter { it.enabled }.distinctBy { it.manifestUrl }.forEach { addon ->
            refreshAddon(
                manifestUrl = addon.manifestUrl,
                forceRefresh = true,
            )
        }
    }

    fun refreshAddon(
        manifestUrl: String,
        forceRefresh: Boolean = false,
    ) {
        startRefresh(manifestUrl = manifestUrl, forceRefresh = forceRefresh, replaceExisting = false)
    }

    /**
     * Review r7/r11: the active-job check (or, for [replaceExisting], taking the old job out), the
     * generation bump and the new job's registration are ONE step under the job lock, so a stuck
     * job that is still parsing when a retry arrives is superseded before it can publish. The job
     * is created LAZY; the old one is cancelled and the new one started after the lock.
     */
    private fun startRefresh(manifestUrl: String, forceRefresh: Boolean, replaceExisting: Boolean) {
        var started: Job? = null
        var replaced: Job? = null
        synchronized(refreshJobsLock) {
            // C4 review r7: a URL that left the list (a sync, a removal) between a caller's
            // snapshot and here gets no job, so nothing orphaned can publish onto a reinstall.
            if (_uiState.value.addons.none { it.manifestUrl == manifestUrl }) return
            val existing = activeRefreshJobs[manifestUrl]
            // Review r8: `isCompleted`, not `isActive`: a LAZY job reads inactive between its
            // registration and `start()`, and must already hold the URL then.
            if (existing?.isCompleted == false && !replaceExisting) return
            replaced = existing
            // Review r4: the generation bump and the refreshing mark are ONE update of the state
            // the publication below compares against (`AddonsUiState.refreshGenerations`).
            val generation = refreshIdCounter.updateAndGet { it + 1 }
            _uiState.update { current ->
                markedRefreshing(current, manifestUrl)
                    .copy(refreshGenerations = withRefreshGeneration(current.refreshGenerations, manifestUrl, generation))
            }
            val job = launchRefresh(manifestUrl, forceRefresh, generation)
            activeRefreshJobs[manifestUrl] = job
            started = job
        }
        replaced?.cancel()
        started?.start()
    }

    /** The refresh job itself (LAZY: [refreshAddon] starts it after registering it). */
    private fun launchRefresh(
        manifestUrl: String,
        forceRefresh: Boolean,
        generation: Long,
    ): Job =
        scope.launch(start = CoroutineStart.LAZY) {
            try {
                val startMark = kotlin.time.TimeSource.Monotonic.markNow()
                val result = runCatching {
                    val payload = fetchAddonResponseText(
                        url = manifestUrl,
                        forceRefresh = forceRefresh,
                    )
                    AddonManifestParser.parse(
                        manifestUrl = manifestUrl,
                        payload = payload,
                    )
                }
                // Add-ons hub v2 review r2: a cancelled job (restartRefresh) must not publish a
                // failure over its replacement, and a job that finished after being superseded
                // must not overwrite the newer one's state.
                result.exceptionOrNull()?.let { if (it is CancellationException) throw it }
                val elapsedMs = startMark.elapsedNow().inWholeMilliseconds

                _uiState.update { current ->
                    if (!isCurrentRefreshGeneration(current.refreshGenerations, manifestUrl, generation)) {
                        return@update current
                    }
                    current.copy(
                        addons = current.addons.map { addon ->
                            if (addon.manifestUrl != manifestUrl) {
                                addon
                            } else {
                                result.fold(
                                    onSuccess = { manifest ->
                                        addon.copy(
                                            manifest = manifest,
                                            isRefreshing = false,
                                            errorMessage = null,
                                        )
                                    },
                                    onFailure = { error ->
                                        addon.copy(
                                            isRefreshing = false,
                                            // Transport errors carry the (possibly keyed) manifest URL; see AddonFailureMessages.kt.
                                            errorMessage = manifestFailureMessage(error),
                                        )
                                    },
                                )
                            }
                        },
                    )
                }
                // C4 review r1/r2: health is published under the lock that refresh replacement and
                // reset use, and only while this job is still the add-on's current refresh and the
                // add-on is still installed, so a superseded job or one cut off by a reset never
                // publishes it. Only forced refreshes count: a cached manifest says nothing about
                // the server.
                if (forceRefresh) {
                    synchronized(refreshJobsLock) {
                        val now = _uiState.value
                        if (isCurrentRefreshGeneration(now.refreshGenerations, manifestUrl, generation) &&
                            now.addons.any { it.manifestUrl == manifestUrl }
                        ) {
                            AddonHealthTracker.record(
                                manifestUrl = manifestUrl,
                                latencyMs = elapsedMs,
                                failed = result.isFailure,
                            )
                        }
                    }
                }
            } finally {
                val self = coroutineContext[Job]
                synchronized(refreshJobsLock) {
                    if (activeRefreshJobs[manifestUrl] === self) {
                        activeRefreshJobs.remove(manifestUrl)
                    }
                }
            }
        }

    /// Whether the default-addon seed may run right now. Guests/signed-out sessions seed
    /// immediately (nothing to pull); a signed-in account must wait until the first server pull
    /// settles, so the seed can never race the pull and full-replace-push a nearly-empty list
    /// over the account (docs/addon-wipe-investigation-2026-08-28.md).
    fun seedingAllowed(): Boolean =
        defaultAddonSeedingAllowed(AuthRepository.state.value, _serverPullSettled.value)

    private fun pushToServer() {
        if (isUsingPrimaryAddonsFromSecondaryProfile()) return
        if (shouldBlockUnhydratedAddonPush(AuthRepository.state.value, pulledFromServer)) {
            // Deliberate data-direction choice (Codex 2026-08-28 P2, declined): a mutation made
            // before this device has ever seen the account's list is non-authoritative — that is
            // the exact shape that wiped a tester's account (the Cinemeta seed). If the account is
            // genuinely empty, pullFromServer's migration branch still pushes the local list; if
            // the account has addons, the pull's apply wins over the pre-hydration edit.
            log.w { "pushToServer() — BLOCKED: signed-in account but the addon list was never hydrated from the server; a full-replace push composed from this state can wipe the account's addons" }
            return
        }
        val profileId = currentProfileId
        val addons = _uiState.value.addons
            .distinctBy { it.manifestUrl }
            .mapIndexed { index, addon ->
                AddonPushItem(
                    url = addon.manifestUrl,
                    name = addon.userSetName?.takeIf { it.isNotBlank() } ?: addon.manifest?.name ?: "",
                    enabled = addon.enabled,
                    sortOrder = index,
                )
            }
        // Races item 5: cancelling the previous job, launching and registering the new one are one
        // step under the lock; the job's `finally` takes the same lock for its identity-checked removal.
        synchronized(pushJobsLock) {
            pushJobsByProfile[profileId]?.cancel()
            var pushJob: Job? = null
            pushJob = scope.launch {
                try {
                    delay(ADDON_PUSH_DEBOUNCE_MS)
                    log.d { "pushToServer() — profileId=$profileId, pushing ${addons.size} addons" }
                    val params = buildJsonObject {
                        put("p_profile_id", profileId)
                        put("p_addons", json.encodeToJsonElement(addons))
                        putSyncOriginClientId()
                    }
                    SupabaseProvider.client.postgrest.rpc("sync_push_addons", params)
                    log.d { "pushToServer() — success" }
                } catch (error: CancellationException) {
                    throw error
                } catch (error: Throwable) {
                    log.e(error) { "pushToServer() — FAILED" }
                } finally {
                    synchronized(pushJobsLock) {
                        if (pushJobsByProfile[profileId] === pushJob) {
                            pushJobsByProfile.remove(profileId)
                        }
                    }
                }
            }
            pushJobsByProfile[profileId] = pushJob
        }
    }

    private fun markedRefreshing(current: AddonsUiState, manifestUrl: String): AddonsUiState =
        current.copy(
            addons = current.addons.map { addon ->
                if (addon.manifestUrl == manifestUrl) {
                    addon.copy(
                        isRefreshing = true,
                        errorMessage = null,
                    )
                } else {
                    addon
                }
            },
        )

    private fun persist() {
        val addons = _uiState.value.addons
        AddonStorage.saveInstalledAddonUrls(
            currentProfileId,
            dedupeManifestUrls(addons.map { it.manifestUrl }),
        )
        AddonStorage.saveAddonEnabledStates(
            currentProfileId,
            addons.associate { it.manifestUrl to it.enabled },
        )
    }

    private fun loadLocalEnabledStates(): Map<String, Boolean> =
        AddonStorage.loadAddonEnabledStates(currentProfileId)
            .mapKeys { (url, _) -> ensureManifestSuffix(url) }

    /**
     * Review r10: empties the job map AND resets the state under the job lock, so no refresh can
     * register between the two (it would survive the cancellation, lose its generation with the
     * reset, block the new profile's refresh of the same URL and never clear its row). A refresh
     * registered before this is cancelled; one registered after belongs to the new state.
     */
    private fun resetRefreshesAndState() {
        val jobs = synchronized(refreshJobsLock) {
            val running = activeRefreshJobs.values.toList()
            activeRefreshJobs.clear()
            _uiState.value = AddonsUiState()
            AddonHealthTracker.clear()
            running
        }
        jobs.forEach(Job::cancel)
    }

    private fun resolveEffectiveProfileId(profileId: Int): Int {
        val ctx = AddonProfileProvider.context
        return if (ctx.activeProfileIndex != null && ctx.activeProfileIndex != 1 && ctx.usesPrimaryAddons) 1 else profileId
    }

    private fun isUsingPrimaryAddonsFromSecondaryProfile(): Boolean {
        val ctx = AddonProfileProvider.context
        return ctx.activeProfileIndex != null && ctx.activeProfileIndex != 1 && ctx.usesPrimaryAddons
    }

    /** tvOS Add-ons hub: a secondary profile that uses the primary profile's add-ons cannot add, move, enable or remove them; the hub greys its controls. */
    fun isReadOnly(): Boolean = isUsingPrimaryAddonsFromSecondaryProfile()

    /**
     * Add-ons hub v2 C4 review r3: an add-on that leaves the list by ANY route (removal, a sync,
     * a phone edit) has its in-flight refresh cancelled and its health dropped, under the lock
     * refresh registration and health publication use. A synced restore or a quick reinstall of
     * the same URL therefore starts without a result, and a refresh from before the removal can
     * never publish onto the new instance (a cancelled job publishes nothing).
     * Declared last, so every property it uses is initialised first.
     */
    init {
        scope.launch {
            var installed = emptySet<String>()
            _uiState.collect { state ->
                val now = state.addons.mapTo(mutableSetOf()) { it.manifestUrl }
                val left = installed - now
                installed = now
                if (left.isEmpty()) return@collect
                val cancelled = synchronized(refreshJobsLock) {
                    // Review r4: this runs after the transition; a URL that is back in the list
                    // by now (a profile load, a reinstall) belongs to a new instance whose refresh
                    // and health must not be touched.
                    val current = _uiState.value.addons.mapTo(mutableSetOf()) { it.manifestUrl }
                    val gone = left.filterNot(current::contains)
                    gone.forEach(AddonHealthTracker::forget)
                    // Review r6: also end the departed URLs' refresh generations, so a job whose
                    // fetch already returned fails its generation check after a reinstall even
                    // if the cancellation arrives too late to stop it.
                    if (gone.isNotEmpty()) {
                        _uiState.update { state -> state.copy(refreshGenerations = state.refreshGenerations - gone.toSet()) }
                    }
                    gone.mapNotNull { activeRefreshJobs.remove(it) }
                }
                cancelled.forEach(Job::cancel)
            }
        }
    }
}

private fun ManagedAddon?.toPendingAddon(
    manifestUrl: String,
    userSetName: String? = null,
    enabled: Boolean? = null,
): ManagedAddon =
    when {
        this == null -> ManagedAddon(
            manifestUrl = manifestUrl,
            isRefreshing = enabled ?: true,
            userSetName = userSetName,
            enabled = enabled ?: true,
        )
        manifest != null -> copy(
            manifestUrl = manifestUrl,
            isRefreshing = false,
            userSetName = userSetName ?: this.userSetName,
            enabled = enabled ?: this.enabled,
        )
        isRefreshing -> copy(
            manifestUrl = manifestUrl,
            userSetName = userSetName ?: this.userSetName,
            enabled = enabled ?: this.enabled,
        )
        else -> copy(
            manifestUrl = manifestUrl,
            isRefreshing = enabled ?: this.enabled,
            errorMessage = null,
            userSetName = userSetName ?: this.userSetName,
            enabled = enabled ?: this.enabled,
        )
    }

private fun dedupeManifestUrls(urls: List<String>): List<String> =
    urls.map(::ensureManifestSuffix).distinct()

private fun ensureManifestSuffix(url: String): String {
    val path = url.substringBefore("?").trimEnd('/')
    val query = url.substringAfter("?", "")
    val withSuffix = if (path.endsWith("/manifest.json")) path else "$path/manifest.json"
    return if (query.isEmpty()) withSuffix else "$withSuffix?$query"
}

/// Server rows can carry `stremio://` deep-link URLs (the website stores what the user pasted) —
/// unfetchable by the HTTP client, so the manifest never loads and the addon is silently inert.
/// Map to https and ensure the manifest suffix so server rows dedupe with app-added ones.
private fun normalizeServerManifestUrl(rawUrl: String): String {
    val trimmed = rawUrl.trim()
    val https = if (trimmed.startsWith("stremio://")) {
        "https://${trimmed.removePrefix("stremio://")}"
    } else {
        trimmed
    }
    return ensureManifestSuffix(https)
}

private fun normalizeManifestUrl(rawUrl: String): String {
    val trimmed = rawUrl.trim()
    require(trimmed.isNotEmpty()) { resourceString("Enter an addon URL.", StringKey.addons_error_enter_url) }

    val normalizedScheme = when {
        trimmed.startsWith("http://") || trimmed.startsWith("https://") -> trimmed
        trimmed.startsWith("stremio://") -> "https://${trimmed.removePrefix("stremio://")}"
        else -> "https://$trimmed"
    }

    val withoutFragment = normalizedScheme.substringBefore("#")
    val query = withoutFragment.substringAfter("?", "")
    val path = withoutFragment.substringBefore("?").trimEnd('/')
    val manifestPath = if (path.endsWith("/manifest.json")) {
        path
    } else {
        "$path/manifest.json"
    }

    return if (query.isEmpty()) manifestPath else "$manifestPath?$query"
}

/// A signed-in, non-anonymous account's addon list must never full-replace-push to the server
/// before at least one pull has hydrated `pulledFromServer` — otherwise a locally-seeded or
/// locally-mutated list (e.g. HomeViewModel's default Cinemeta seed on an empty local state) can
/// overwrite the account's real addon rows via `sync_push_addons`'s full-replace semantics. See
/// docs/addon-wipe-investigation-2026-08-28.md.
internal fun shouldBlockUnhydratedAddonPush(authState: AuthState, pulledFromServer: Boolean): Boolean =
    authState is AuthState.Authenticated && !authState.isAnonymous && !pulledFromServer

/// Guests and signed-out sessions have nothing to pull, so the default-addon seed may run as
/// soon as local state is known empty. A signed-in, non-anonymous account must instead wait for
/// the first server pull to settle, so the seed can't race the pull and get full-replace-pushed
/// over the account's real addon list. See docs/addon-wipe-investigation-2026-08-28.md.
internal fun defaultAddonSeedingAllowed(authState: AuthState, serverPullSettled: Boolean): Boolean =
    authState !is AuthState.Authenticated || authState.isAnonymous || serverPullSettled

/** [current] with [generation] (a unique refresh id) as [manifestUrl]'s newest refresh. */
internal fun withRefreshGeneration(current: Map<String, Long>, manifestUrl: String, generation: Long): Map<String, Long> =
    current + (manifestUrl to generation)

/**
 * Races item 1: [current] generations kept only for the URLs still in [addons]. A generation for a
 * URL that is not listed is stale by definition (`startRefresh` refuses absent URLs), so a list
 * change ends the departed URLs' generations while every kept URL carries its own over (review r5).
 */
internal fun generationsForList(current: Map<String, Long>, addons: List<ManagedAddon>): Map<String, Long> {
    if (current.isEmpty()) return current
    val listed = addons.mapTo(HashSet()) { it.manifestUrl }
    return current.filterKeys { it in listed }
}

/** Review whole-stage r1: what a replacement of the list takes with it. */
internal data class ListChangeDetach(
    /** URLs whose health is dropped: listed before, not after. */
    val healthUrls: Set<String>,
    /** URLs whose registered refresh job is detached and cancelled: registered, not listed after. */
    val jobUrls: Set<String>,
)

/**
 * Review whole-stage r1: when the list [before] is replaced by [after], the URLs that left lose
 * their health and any registered refresh job in the same step (the caller applies it under the job
 * lock). A URL that is still listed keeps its job, so a kept add-on's refresh is never disturbed; a
 * URL removed and then restored holds no job by the time the restore arrives, so a new refresh can
 * start. [registeredJobUrls] is the key set of the job map at that moment.
 */
internal fun detachedByListChange(
    before: List<ManagedAddon>,
    after: List<ManagedAddon>,
    registeredJobUrls: Set<String>,
): ListChangeDetach {
    val listedAfter = after.mapTo(HashSet()) { it.manifestUrl }
    return ListChangeDetach(
        healthUrls = before.mapNotNullTo(HashSet()) { it.manifestUrl.takeIf { url -> url !in listedAfter } },
        jobUrls = registeredJobUrls.filterTo(HashSet()) { it !in listedAfter },
    )
}

/** Races item 3: what appending a freshly installed add-on to the state comes to. */
internal sealed interface InstallAppend {
    data class Appended(val state: AddonsUiState) : InstallAppend
    /** The URL (or a host-case variant) is already listed (C1 review r9). */
    data object Duplicate : InstallAppend
    /** The active profile changed since the install started; nothing may be written. */
    data object ProfileChanged : InstallAppend
}

/**
 * Races item 3 (with item 1): the append of an installed [addon] to [current]. Refused when the
 * profile changed during the fetch ([sameProfile] false); re-checks duplicates with
 * [isSameManifestUrl] (the pre-fetch check can pass for two installs of one URL); otherwise appends
 * and ends any stale refresh generation for the URL ([withInstalledAddon]).
 */
internal fun appendInstalled(current: AddonsUiState, addon: ManagedAddon, sameProfile: Boolean): InstallAppend = when {
    !sameProfile -> InstallAppend.ProfileChanged
    current.addons.any { isSameManifestUrl(it.manifestUrl, addon.manifestUrl) } -> InstallAppend.Duplicate
    else -> InstallAppend.Appended(withInstalledAddon(current, addon))
}

/** Races item 1: [current] with [addon] appended and any stale refresh generation for its URL ended. */
internal fun withInstalledAddon(current: AddonsUiState, addon: ManagedAddon): AddonsUiState =
    current.copy(
        addons = current.addons + addon,
        refreshGenerations = current.refreshGenerations - addon.manifestUrl,
    )

/**
 * Add-ons hub v2 review r6: a same-profile rebuild of the list (`initialize`, a server pull) builds
 * rows through `toPendingAddon`, which drops `isRefreshing` for an add-on that already has a
 * manifest. A refresh job still running for it would then be invisible (no spinner, no stall
 * ceiling, no retry). Keep the live flag from [current] on the rebuilt rows.
 */
internal fun keepingLiveRefresh(rebuilt: List<ManagedAddon>, current: AddonsUiState): List<ManagedAddon> {
    val refreshing = current.addons.filter { it.isRefreshing }.mapTo(HashSet()) { it.manifestUrl }
    if (refreshing.isEmpty()) return rebuilt
    return rebuilt.map { if (it.manifestUrl in refreshing && !it.isRefreshing) it.copy(isRefreshing = true) else it }
}

/**
 * Whether [generation] is still the newest refresh of [manifestUrl]. Strict (review r5): every
 * refresh bumps its entry before it starts and same-profile replacements carry the map over, so a
 * missing entry only follows a reset (`clearLocalState`), whose refreshes must not publish.
 */
internal fun isCurrentRefreshGeneration(generations: Map<String, Long>, manifestUrl: String, generation: Long): Boolean =
    generations[manifestUrl] == generation

/** [addons] with [manifestUrl] moved one place by [delta] (±1), or null when absent or at the end. */
/** Add-ons hub v2 C1: how a Remote Setup add-on edit ended. */
enum class RemoteListEditResult { APPLIED, STALE, READ_ONLY }

/** Add-ons hub v2 C1 (review r4/r5): what applying a Remote Setup edit to [current] comes to. */
internal sealed interface EditedListOutcome {
    /** The list moved under the page. */
    data object Stale : EditedListOutcome
    /** The list is inherited and the edit would change it or install a new add-on. */
    data object ReadOnly : EditedListOutcome
    data object Unchanged : EditedListOutcome
    data class Edited(val addons: List<ManagedAddon>) : EditedListOutcome
}

internal fun editedListOutcome(
    current: List<ManagedAddon>,
    expectedUrls: List<String>,
    desiredUrls: List<String>,
    enabled: Map<String, Boolean>,
    readOnly: Boolean,
    addsNew: Boolean = false,
    expectedEnabled: Map<String, Boolean> = emptyMap(),
): EditedListOutcome {
    if (current.map { it.manifestUrl } != expectedUrls) return EditedListOutcome.Stale
    // C3 review r2: the flags the confirm dialog was built from must still hold, or what the user
    // approved is not what would apply.
    if (current.any { addon -> expectedEnabled[addon.manifestUrl]?.let { it != addon.enabled } == true }) {
        return EditedListOutcome.Stale
    }
    val edited = editedAddonList(current, desiredUrls, enabled)
    return when {
        readOnly && (addsNew || edited != current) -> EditedListOutcome.ReadOnly
        edited == current -> EditedListOutcome.Unchanged
        else -> EditedListOutcome.Edited(edited)
    }
}

/**
 * Add-ons hub v2 C1: [addons] reduced and reordered to [desiredUrls] (unknown urls ignored, later
 * duplicates dropped), each flag overridden by [enabled] where given.
 */
internal fun editedAddonList(
    addons: List<ManagedAddon>,
    desiredUrls: List<String>,
    enabled: Map<String, Boolean>,
): List<ManagedAddon> {
    val byUrl = addons.associateBy { it.manifestUrl }
    return desiredUrls.distinct().mapNotNull { url ->
        val addon = byUrl[url] ?: return@mapNotNull null
        val flag = enabled[url]
        if (flag == null || flag == addon.enabled) addon else addon.copy(enabled = flag)
    }
}

/**
 * Add-ons hub v2 C1 (review r21): two normalised manifest URLs name the same add-on when they
 * match with the scheme and host compared case-insensitively (the rule the tvOS install field and
 * Remote Setup use); userinfo, path and query keep their case.
 */
internal fun isSameManifestUrl(a: String, b: String): Boolean = manifestComparisonKey(a) == manifestComparisonKey(b)

private fun manifestComparisonKey(raw: String): String {
    // Review r22: a synced URL can be schemeless (`EXAMPLE.com/manifest.json`) or `stremio://`;
    // both mean https, as normalizeManifestUrl reads them. Only a `://` before the first `/` or
    // `?` is a scheme separator.
    val trimmed = raw.trim()
    val firstBreak = trimmed.indexOfFirst { it == '/' || it == '?' }.let { if (it < 0) trimmed.length else it }
    val schemeAt = trimmed.indexOf("://").takeIf { it in 0 until firstBreak }
    val url = when {
        schemeAt == null -> "https://$trimmed"
        trimmed.substring(0, schemeAt).equals("stremio", ignoreCase = true) -> "https://" + trimmed.substring(schemeAt + 3)
        else -> trimmed
    }
    return urlIdentityKey(url)
}

internal fun steppedOrder(addons: List<ManagedAddon>, manifestUrl: String, delta: Int): List<ManagedAddon>? {
    val from = addons.indexOfFirst { it.manifestUrl == manifestUrl }
    if (from < 0 || delta == 0) return null
    val to = from + delta
    if (to !in addons.indices) return null
    return addons.toMutableList().apply { add(to, removeAt(from)) }
}

/**
 * [addons] with [manifestUrl] placed right after the last add-on of [predecessors] still listed
 * (first when none survives), or null when absent.
 */
internal fun restoredOrder(addons: List<ManagedAddon>, manifestUrl: String, predecessors: Set<String>): List<ManagedAddon>? {
    val moving = addons.firstOrNull { it.manifestUrl == manifestUrl } ?: return null
    val others = addons.filter { it.manifestUrl != manifestUrl }
    val insertAt = others.indexOfLast { it.manifestUrl in predecessors } + 1
    return others.toMutableList().apply { add(insertAt, moving) }
}
