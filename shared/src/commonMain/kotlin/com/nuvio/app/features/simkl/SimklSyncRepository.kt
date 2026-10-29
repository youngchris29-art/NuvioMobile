package com.nuvio.app.features.simkl

import co.touchlab.kermit.Logger
import com.nuvio.app.features.profiles.ProfileRepository
import com.nuvio.app.features.tracking.TrackingProfileStore
import com.nuvio.app.features.tracking.TrackingProviderId
import com.nuvio.app.features.tracking.TrackingProviderRegistry
import com.nuvio.app.features.tracking.TrackingRefreshIntent
import kotlinx.atomicfu.atomic
import kotlinx.atomicfu.locks.SynchronizedObject
import kotlinx.atomicfu.locks.synchronized
import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.CoroutineDispatcher
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asStateFlow
import kotlinx.coroutines.flow.update
import kotlinx.coroutines.launch
import kotlinx.coroutines.sync.Mutex
import kotlinx.coroutines.sync.withLock
import kotlinx.coroutines.withContext
import kotlinx.serialization.decodeFromString
import kotlinx.serialization.encodeToString
import kotlinx.serialization.json.Json

object SimklSyncRepository : TrackingProfileStore {
    override val providerId: TrackingProviderId = TrackingProviderId.SIMKL

    private val log = Logger.withTag("SimklSync")
    private val json = Json {
        ignoreUnknownKeys = true
        encodeDefaults = true
        explicitNulls = false
    }
    private val scope = CoroutineScope(SupervisorJob() + Dispatchers.Default)
    private val refreshGate = SimklRefreshGate()
    private val snapshotMutex = Mutex()
    private val refreshRequestSequence = atomic(0L)
    private val engine = SimklSyncEngine(
        remote = SimklApiSyncRemote(),
        nowEpochMs = SimklPlatformClock::nowEpochMs,
    )

    private val _state = MutableStateFlow(SimklSyncUiState())
    val state: StateFlow<SimklSyncUiState> = _state.asStateFlow()

    /**
     * Where the commit functions run their snapshot work (reconcile, JSON-encode, file write). A
     * commit is called from the player's scrobble completion, so without this hop that work would
     * run on whichever thread resumed the network call. Fork-only; tests swap it to observe the hop.
     */
    internal var commitDispatcher: CoroutineDispatcher = Dispatchers.Default

    /** Test seam: runs on the writing thread after a snapshot is encoded, before the final currency check. */
    internal var beforeSaveHook: () -> Unit = {}

    /** Test seam: runs on the writing thread after the file is written, before the snapshot is published. */
    internal var afterSaveHook: () -> Unit = {}

    /**
     * Makes "still current, then write" one step against sign-out ("bump the generation, then wipe
     * the file", [clearLocalState]); otherwise a commit that passed its check could land its write
     * after the wipe and re-create signed-out data. Never held while taking [snapshotMutex].
     */
    internal val saveLock = SynchronizedObject()

    /**
     * Makes "still current, then publish" one step against a profile switch or sign-out ("bump the
     * generation, then reset the state"). Held only for those few instructions, never across I/O,
     * so [onProfileChanged] on Main never waits for a file write. Lock order: [saveLock] may enclose
     * this lock ([clearLocalState]); this lock never encloses [saveLock].
     */
    internal val stateLock = SynchronizedObject()

    private var hasLoaded = false
    // Read off the main thread by the commit functions, written by profile switch and sign-out.
    private val profileGeneration = atomic(0L)

    init {
        TrackingProviderRegistry.registerProfileStore(this)
    }

    fun ensureLoaded() {
        if (hasLoaded) return
        hasLoaded = true
        val snapshot = SimklSyncStorage.loadPayload()
            ?.trim()
            ?.takeIf(String::isNotEmpty)
            ?.let { payload ->
                runCatching { json.decodeFromString<SimklSyncSnapshot>(payload) }
                    .onFailure { error -> log.w { "Failed to parse Simkl sync snapshot: ${error.message}" } }
                    .getOrNull()
            }
            ?: SimklSyncSnapshot()
        _state.value = SimklSyncUiState(snapshot = snapshot, hasLoaded = true)
        SimklWatchDiagnostics.logSnapshot(stage = "cache-load", snapshot = snapshot)
    }

    fun refreshAsync(intent: TrackingRefreshIntent) {
        refreshAsync(intent, SimklRefreshOrigin.UNKNOWN)
    }

    internal fun refreshAsync(
        intent: TrackingRefreshIntent,
        origin: SimklRefreshOrigin,
    ) {
        scope.launch { refresh(intent, origin) }
    }

    suspend fun refresh(intent: TrackingRefreshIntent): Boolean =
        refresh(intent, SimklRefreshOrigin.MANUAL_SYNC)

    internal suspend fun refresh(
        intent: TrackingRefreshIntent,
        origin: SimklRefreshOrigin,
    ): Boolean {
        ensureLoaded()
        val requestId = refreshRequestSequence.incrementAndGet()
        val requestedGeneration = profileGeneration.value
        val requestedProfileId = ProfileRepository.activeProfileId
        val before = _state.value
        SimklWatchDiagnostics.logRefreshRequest(
            requestId = requestId,
            origin = origin,
            intent = intent,
            profileId = requestedProfileId,
            profileGeneration = requestedGeneration,
            authenticated = SimklAuthRepository.isAuthenticated.value,
            snapshot = before.snapshot,
            errorMessage = before.errorMessage,
        )
        val outcome = refreshGate.runIfNeeded(
            profileGeneration = requestedGeneration,
            shouldRun = {
                val current = _state.value
                val authenticated = SimklAuthRepository.isAuthenticated.value
                val nowEpochMs = SimklPlatformClock.nowEpochMs()
                val eligible = requestedGeneration == profileGeneration.value &&
                    authenticated &&
                    shouldRunSimklRefresh(
                        intent = intent,
                        lastCheckedAtEpochMs = current.snapshot.lastCheckedAtEpochMs,
                        nowEpochMs = nowEpochMs,
                        hasError = current.errorMessage != null,
                    )
                SimklWatchDiagnostics.logRefreshDecision(
                    requestId = requestId,
                    origin = origin,
                    intent = intent,
                    nowEpochMs = nowEpochMs,
                    lastCheckedAtEpochMs = current.snapshot.lastCheckedAtEpochMs,
                    authenticated = authenticated,
                    hasError = current.errorMessage != null,
                    eligible = eligible,
                )
                eligible
            },
        ) {
            refreshSnapshot(requestedGeneration)
        }
        SimklWatchDiagnostics.logRefreshCompletion(
            requestId = requestId,
            origin = origin,
            intent = intent,
            outcome = outcome,
            before = before,
            after = _state.value,
        )
        val completed = _state.value
        return requestedGeneration == profileGeneration.value &&
            requestedProfileId == ProfileRepository.activeProfileId &&
            SimklAuthRepository.isAuthenticated.value &&
            completed.hasLoaded &&
            completed.errorMessage == null
    }

    private suspend fun refreshSnapshot(generation: Long) = snapshotMutex.withLock {
        val profileId = ProfileRepository.activeProfileId
        val previous = _state.value
        _state.value = previous.copy(isLoading = true, errorMessage = null)

        val result = try {
            engine.synchronize(previous.snapshot)
        } catch (error: CancellationException) {
            throw error
        } catch (error: Throwable) {
            log.w { "Simkl sync failed: ${error.message}" }
            publishIfCurrent(generation, profileId) {
                previous.copy(
                    isLoading = false,
                    hasLoaded = true,
                    errorMessage = error.message ?: "Unable to sync Simkl",
                )
            }
            return@withLock
        }

        if (!isCurrent(generation, profileId)) {
            return@withLock
        }
        SimklAuthRepository.synchronizeUserSettings(result.activities?.settings?.all)
        if (!isCurrent(generation, profileId)) {
            return@withLock
        }
        if (!saveIfCurrent(generation, profileId, result)) return@withLock
        if (publishIfCurrent(generation, profileId) { SimklSyncUiState(snapshot = result, hasLoaded = true) }) {
            SimklWatchDiagnostics.logSnapshot(stage = "network-commit", snapshot = result)
        }
    }

    internal suspend fun commitPlaybackRemoval(sessionIds: Set<Long>) {
        if (sessionIds.isEmpty()) return
        ensureLoaded()
        val generation = profileGeneration.value
        val profileId = ProfileRepository.activeProfileId
        withContext(commitDispatcher) {
            snapshotMutex.withLock {
                if (!isCurrent(generation, profileId)) return@withLock
                val current = _state.value
                val updatedPlayback = current.snapshot.playback.filterNot { session -> session.id in sessionIds }
                if (updatedPlayback.size == current.snapshot.playback.size) return@withLock
                val updatedSnapshot = current.snapshot.copy(playback = updatedPlayback)
                if (!saveIfCurrent(generation, profileId, updatedSnapshot)) return@withLock
                if (publishIfCurrent(generation, profileId) { it.copy(snapshot = updatedSnapshot) }) {
                    SimklWatchDiagnostics.logSnapshot(stage = "playback-removal", snapshot = updatedSnapshot)
                }
            }
        }
    }

    internal suspend fun commitScrobble(result: SimklScrobbleResult) {
        ensureLoaded()
        val generation = profileGeneration.value
        val profileId = ProfileRepository.activeProfileId
        withContext(commitDispatcher) {
            snapshotMutex.withLock {
                if (!isCurrent(generation, profileId)) {
                    return@withLock
                }
                val current = _state.value
                val snapshot = current.snapshot.applyScrobbleResult(
                    result = result,
                    committedAtEpochMs = SimklPlatformClock.nowEpochMs(),
                )
                if (snapshot == current.snapshot) return@withLock
                if (!saveIfCurrent(generation, profileId, snapshot)) return@withLock
                if (publishIfCurrent(generation, profileId) { it.copy(snapshot = snapshot) }) {
                    SimklWatchDiagnostics.logSnapshot(stage = "scrobble-commit", snapshot = snapshot)
                }
            }
        }
    }

    internal suspend fun commitMutation(receipt: SimklMutationReceipt) {
        ensureLoaded()
        val generation = profileGeneration.value
        val profileId = ProfileRepository.activeProfileId
        withContext(commitDispatcher) {
            snapshotMutex.withLock {
                if (!isCurrent(generation, profileId)) {
                    return@withLock
                }
                val current = _state.value
                val snapshot = current.snapshot.applyMutationReceipt(
                    receipt = receipt,
                    committedAtEpochMs = SimklPlatformClock.nowEpochMs(),
                )
                if (snapshot == current.snapshot) return@withLock
                if (!saveIfCurrent(generation, profileId, snapshot)) return@withLock
                if (publishIfCurrent(generation, profileId) { it.copy(snapshot = snapshot) }) {
                    SimklWatchDiagnostics.logSnapshot(stage = "mutation-commit", snapshot = snapshot)
                }
            }
        }
    }

    private fun isCurrent(generation: Long, profileId: Int): Boolean =
        generation == profileGeneration.value && profileId == ProfileRepository.activeProfileId

    /**
     * Encodes [snapshot] and writes it to [profileId]'s file, unless a profile switch or sign-out
     * has landed since [generation] was captured. Those run on the main thread and do not take
     * [snapshotMutex], so the check is repeated after the slow encode, right before the write,
     * under [saveLock] (shared with [clearLocalState]), and the write names the captured profile
     * instead of resolving the active one at write time. Returns false (nothing written) when the
     * world moved on. The caller then publishes with [publishIfCurrent].
     */
    private fun saveIfCurrent(generation: Long, profileId: Int, snapshot: SimklSyncSnapshot): Boolean {
        val payload = json.encodeToString(snapshot)
        beforeSaveHook()
        val written = synchronized(saveLock) {
            if (isCurrent(generation, profileId)) {
                SimklSyncStorage.savePayload(profileId, payload)
                true
            } else {
                false
            }
        }
        if (written) afterSaveHook()
        return written
    }

    /**
     * Publishes [transform] of the latest state unless the world moved on. The check and the set
     * run under [stateLock], which [onProfileChanged] / [clearLocalState] also hold for their
     * "bump the generation, reset the state", so a commit can neither publish into a state that
     * was reset after its check nor be fooled by a new state that equals the old one. The update
     * still builds on the latest state, so unlocked writers such as [invalidateProjections] are kept.
     */
    private fun publishIfCurrent(
        generation: Long,
        profileId: Int,
        transform: (SimklSyncUiState) -> SimklSyncUiState,
    ): Boolean {
        return synchronized(stateLock) {
            if (isCurrent(generation, profileId)) {
                _state.update(transform)
                true
            } else {
                false
            }
        }
    }

    override fun onProfileChanged() {
        synchronized(stateLock) {
            profileGeneration.incrementAndGet()
            hasLoaded = false
            _state.value = SimklSyncUiState()
        }
        ensureLoaded()
    }

    override fun clearLocalState() {
        // Bump and wipe as one step against a commit's "still current, then write".
        synchronized(saveLock) {
            synchronized(stateLock) {
                profileGeneration.incrementAndGet()
                hasLoaded = false
                _state.value = SimklSyncUiState()
            }
            SimklSyncStorage.savePayload("")
        }
    }

    /**
     * Bumps the projection version to force downstream collectors (CW, library, watched badges)
     * to recompute their projections without re-fetching from the network.
     * Call this when a setting that affects projection output changes (e.g. anime ID preference).
     */
    fun invalidateProjections() {
        val current = _state.value
        _state.value = current.copy(projectionVersion = current.projectionVersion + 1L)
    }

    override fun removeStoredProfile(profileId: Int) {
        SimklSyncStorage.removeProfile(profileId)
    }
}
