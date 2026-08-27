package com.nuvio.app.core.sync

import com.nuvio.app.core.coroutines.uncaughtCoroutineLogger
import co.touchlab.kermit.Logger
import com.nuvio.app.core.auth.AuthRepository
import com.nuvio.app.core.auth.AuthState
import com.nuvio.app.core.build.FeaturePolicyProvider
import com.nuvio.app.features.addons.AddonRepository
import com.nuvio.app.features.collection.CollectionSyncService
import com.nuvio.app.features.home.HomeCatalogSettingsSyncService
import com.nuvio.app.features.library.LibrarySourceMode
import com.nuvio.app.features.library.LibraryRepository
import com.nuvio.app.features.plugins.PluginSyncProvider
import com.nuvio.app.features.profiles.ProfileRepository
import com.nuvio.app.core.tracking.ensureTrackingProvidersRegistered
import com.nuvio.app.features.tracking.TrackingProviderRegistry
import com.nuvio.app.features.tracking.TrackingSettingsRepository
import com.nuvio.app.features.tracking.TrackingSourceSettingsSyncService
import com.nuvio.app.features.tracking.WatchProgressSource
import com.nuvio.app.features.tracking.effectiveLibrarySourceMode
import com.nuvio.app.features.tracking.effectiveWatchProgressSource
import com.nuvio.app.features.trakt.TraktPlatformClock
import com.nuvio.app.features.watchprogress.WatchProgressSourceCoordinator
import kotlinx.atomicfu.locks.SynchronizedObject
import kotlinx.atomicfu.locks.synchronized
import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.CoroutineStart
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.Job
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.coroutineScope
import kotlinx.coroutines.delay
import kotlinx.coroutines.isActive
import kotlinx.coroutines.launch

private const val FOREGROUND_PULL_DELAY_MS = 2500L
private const val FOREGROUND_ACTIVITY_PULL_MIN_INTERVAL_MS = 2 * 60_000L
private const val FULL_PULL_MIN_INTERVAL_MS = 10_000L
private const val PERIODIC_NUVIO_SYNC_PULL_INTERVAL_MS = 15 * 60_000L

// Fork: the sync primitives below are public (upstream: internal) — composeApp tests consume them cross-module.
enum class ProfileSyncStep {
    Addons,
    Plugins,
    ProfileSettings,
    // Must stay immediately after ProfileSettings: the shared-namespace tracking sources override
    // whatever the platform-scoped settings blob just applied, and the watch-source refresh below
    // has to see the winner (BUG-75).
    TrackingSourceSettings,
    // Must stay between ProfileSettings and Library: the library/watch-source steps can read
    // provider credentials, so those have to be resolved first.
    ProviderCredentials,
    Library,
    ActiveWatchSource,
    Collections,
    HomeCatalogSettings,
}

data class ProfileSyncOperations(
    val pullAddons: suspend (Int) -> Unit,
    val pullPlugins: suspend (Int) -> Unit,
    val pullProfileSettings: suspend (Int) -> Unit,
    // Defaulted so existing constructions (composeApp's cross-module tests included) still compile.
    val pullTrackingSourceSettings: suspend (Int) -> Unit = {},
    val syncProviderCredentials: suspend (Int) -> Unit,
    val pullLibrary: suspend (Int) -> Unit,
    val refreshActiveWatchSource: suspend (Int) -> Unit,
    val pullCollections: suspend (Int) -> Unit,
    val pullHomeCatalogSettings: suspend (Int) -> Unit,
)

data class ProfileActivitySyncOperations(
    val pullLibrary: suspend (Int) -> Unit,
    val pullWatchActivity: suspend (Int) -> Unit,
)

data class ProfileSyncResult(
    val failedSteps: Set<ProfileSyncStep>,
) {
    val succeeded: Boolean
        get() = failedSteps.isEmpty()
}

data class ProfilePullFreshness(
    val profileId: Int? = null,
    val completedAtEpochMs: Long = 0L,
) {
    fun isRecent(profileId: Int, nowEpochMs: Long, minIntervalMs: Long): Boolean {
        // Fork (Codex 2026-08-24): a backwards wall-clock correction makes elapsed negative, which
        // upstream's `elapsed < minIntervalMs` reads as "recent" — suppressing pulls until the
        // clock catches back up. Treat it as stale instead (same rule d0c7bff7's write dedup uses).
        val elapsedMs = nowEpochMs - completedAtEpochMs
        return this.profileId == profileId && elapsedMs >= 0L && elapsedMs < minIntervalMs
    }

    fun recordIfSuccessful(
        profileId: Int,
        completedAtEpochMs: Long,
        result: ProfileSyncResult,
    ): ProfilePullFreshness =
        if (result.succeeded) {
            ProfilePullFreshness(
                profileId = profileId,
                completedAtEpochMs = completedAtEpochMs,
            )
        } else {
            this
        }
}

suspend fun runOrderedProfileSync(
    profileId: Int,
    pluginsEnabled: Boolean,
    operations: ProfileSyncOperations,
    onFailure: (ProfileSyncStep, Throwable) -> Unit = { _, _ -> },
): ProfileSyncResult {
    val failureLock = SynchronizedObject()
    val failedSteps = mutableSetOf<ProfileSyncStep>()

    suspend fun runStep(
        step: ProfileSyncStep,
        operation: suspend (Int) -> Unit,
    ) {
        try {
            operation(profileId)
        } catch (error: CancellationException) {
            throw error
        } catch (error: Throwable) {
            synchronized(failureLock) {
                failedSteps += step
            }
            onFailure(step, error)
        }
    }

    runStep(ProfileSyncStep.ProfileSettings, operations.pullProfileSettings)
    runStep(ProfileSyncStep.TrackingSourceSettings, operations.pullTrackingSourceSettings)
    runStep(ProfileSyncStep.ProviderCredentials, operations.syncProviderCredentials)
    runStep(ProfileSyncStep.Addons, operations.pullAddons)
    if (pluginsEnabled) {
        runStep(ProfileSyncStep.Plugins, operations.pullPlugins)
    }

    coroutineScope {
        launch {
            runStep(ProfileSyncStep.Library, operations.pullLibrary)
        }
        launch {
            runStep(ProfileSyncStep.ActiveWatchSource, operations.refreshActiveWatchSource)
        }
        launch {
            runStep(ProfileSyncStep.Collections, operations.pullCollections)
        }
        launch {
            runStep(ProfileSyncStep.HomeCatalogSettings, operations.pullHomeCatalogSettings)
        }
    }
    return ProfileSyncResult(
        failedSteps = synchronized(failureLock) { failedSteps.toSet() },
    )
}

// Fork: public (upstream: internal)
suspend fun runActivityProfileSync(
    profileId: Int,
    pullLibrary: Boolean = true,
    pullWatchActivity: Boolean = true,
    operations: ProfileActivitySyncOperations,
    onFailure: (ProfileSyncStep, Throwable) -> Unit = { _, _ -> },
): ProfileSyncResult {
    val failureLock = SynchronizedObject()
    val failedSteps = mutableSetOf<ProfileSyncStep>()

    suspend fun runStep(
        step: ProfileSyncStep,
        operation: suspend (Int) -> Unit,
    ) {
        try {
            operation(profileId)
        } catch (error: CancellationException) {
            throw error
        } catch (error: Throwable) {
            synchronized(failureLock) {
                failedSteps += step
            }
            onFailure(step, error)
        }
    }

    coroutineScope {
        if (pullLibrary) {
            launch {
                runStep(ProfileSyncStep.Library, operations.pullLibrary)
            }
        }
        if (pullWatchActivity) {
            launch {
                runStep(ProfileSyncStep.ActiveWatchSource, operations.pullWatchActivity)
            }
        }
    }
    return ProfileSyncResult(
        failedSteps = synchronized(failureLock) { failedSteps.toSet() },
    )
}

enum class ProfileSyncRequestResult {
    Started,
    Coalesced,
    Replaced,
}

// Fork: public (upstream: internal)
enum class ProfileSyncRequestKind {
    Activity,
    Full,
}

// Fork: public (upstream: internal)
class ProfileSyncRequestGate {
    private data class PendingRequest(
        val scope: CoroutineScope,
        val profileId: Int,
        val kind: ProfileSyncRequestKind,
        val block: suspend () -> Unit,
    )

    private val lock = SynchronizedObject()
    private var activeProfileId: Int? = null
    private var activeKind: ProfileSyncRequestKind? = null
    private var activeJob: Job? = null
    private var pendingRequest: PendingRequest? = null

    fun launch(
        scope: CoroutineScope,
        profileId: Int,
        queueIfCoalesced: Boolean = false,
        kind: ProfileSyncRequestKind = ProfileSyncRequestKind.Full,
        block: suspend () -> Unit,
    ): ProfileSyncRequestResult {
        lateinit var newJob: Job
        var previousJob: Job? = null
        val result = synchronized(lock) {
            val active = activeJob?.takeUnless(Job::isCompleted)
            if (active != null && activeProfileId == profileId) {
                // A Full request in flight absorbs everything for this profile; an Activity
                // request only absorbs other Activity requests — an incoming Full cancels and
                // replaces it (falls through below).
                val activeRequestKind = activeKind
                if (activeRequestKind == ProfileSyncRequestKind.Full || kind == ProfileSyncRequestKind.Activity) {
                    if (queueIfCoalesced) {
                        pendingRequest = PendingRequest(scope = scope, profileId = profileId, kind = kind, block = block)
                    }
                    return ProfileSyncRequestResult.Coalesced
                }
            }

            previousJob = active
            pendingRequest = null
            val requestResult = if (active == null) {
                ProfileSyncRequestResult.Started
            } else {
                ProfileSyncRequestResult.Replaced
            }

            newJob = scope.launch(start = CoroutineStart.LAZY) {
                block()
            }
            activeProfileId = profileId
            activeKind = kind
            activeJob = newJob
            newJob.invokeOnCompletion {
                var pending: PendingRequest? = null
                synchronized(lock) {
                    if (activeJob === newJob) {
                        activeJob = null
                        activeProfileId = null
                        activeKind = null
                        pending = pendingRequest
                        pendingRequest = null
                    }
                }
                pending?.let { request ->
                    launch(
                        scope = request.scope,
                        profileId = request.profileId,
                        queueIfCoalesced = false,
                        kind = request.kind,
                        block = request.block,
                    )
                }
            }
            requestResult
        }

        previousJob?.cancel()
        newJob.start()
        return result
    }

    fun cancel() {
        val job = synchronized(lock) {
            activeJob.also {
                activeJob = null
                activeProfileId = null
                activeKind = null
                pendingRequest = null
            }
        }
        job?.cancel()
    }
}

object SyncManager {
    private val log = Logger.withTag("SyncManager")
    private val syncRequestGate = ProfileSyncRequestGate()
    private val accountScopeLock = SynchronizedObject()
    private var accountScopeJob: Job = SupervisorJob()
    private var accountScope = CoroutineScope(accountScopeJob + Dispatchers.Default + uncaughtCoroutineLogger("SyncManager"))
    private val pullStateLock = SynchronizedObject()
    private var foregroundPullJob: Job? = null
    private var foregroundPullProfileId: Int? = null
    private var periodicNuvioSyncPullJob: Job? = null
    private var periodicNuvioSyncProfileId: Int? = null
    private var activityPullFreshness = ProfilePullFreshness()
    private var fullPullFreshness = ProfilePullFreshness()

    private val profileSyncOperations = ProfileSyncOperations(
        pullAddons = { profileId -> AddonRepository.pullFromServer(profileId) },
        // Fork: plugins pull goes through the PluginSyncProvider seam (PluginRepository is
        // flavor-bound in composeApp), gated on the FeaturePolicy plugins flag.
        pullPlugins = { profileId ->
            if (FeaturePolicyProvider.policy.pluginsEnabled) {
                PluginSyncProvider.controller.pullFromServer(profileId)
            }
        },
        pullProfileSettings = { profileId -> ProfileSettingsSync.pull(profileId) },
        pullTrackingSourceSettings = { profileId -> TrackingSourceSettingsSyncService.pullFromServer(profileId) },
        syncProviderCredentials = { profileId -> ProviderCredentialSync.syncFromRemote(profileId) },
        pullLibrary = { profileId -> LibraryRepository.pullFromServer(profileId) },
        refreshActiveWatchSource = { profileId ->
            val result = WatchProgressSourceCoordinator.refreshActiveSource(profileId = profileId, force = true)
            check(result.succeeded) {
                "Active watch source refresh was incomplete: " +
                    "progress=${result.progressRefreshed} watched=${result.watchedHistoryRefreshed}"
            }
        },
        pullCollections = { profileId -> CollectionSyncService.pullFromServer(profileId) },
        pullHomeCatalogSettings = { profileId -> HomeCatalogSettingsSyncService.pullFromServer(profileId) },
    )
    private val profileActivitySyncOperations = ProfileActivitySyncOperations(
        pullLibrary = { profileId -> LibraryRepository.pullFromServer(profileId) },
        pullWatchActivity = { profileId ->
            val result = WatchProgressSourceCoordinator.refreshActiveSource(profileId = profileId, force = false)
            check(result.succeeded) {
                "Active watch source refresh was incomplete: " +
                    "progress=${result.progressRefreshed} watched=${result.watchedHistoryRefreshed}"
            }
        },
    )

    /**
     * "A profile was just picked — pull everything for it."
     *
     * tvOS calls this from `ProfilesViewModel.select`, immediately after
     * `ProfileRepository.selectProfile()` and on the same Swift main thread. A Kotlin exception
     * escaping here is not catchable on the Swift side — it reaches the Kotlin/Native
     * unhandled-exception hook and aborts the process, so a single failure turns into "the app
     * force-closes every time I pick my profile". `selectProfile` guards its own persistence and
     * fan-out for exactly this reason; this call sat outside those guards.
     *
     * Note this is the only part of a profile tap that does nothing when signed out, which is why
     * a failure here would look like a crash that only signed-in testers can hit. The sync itself
     * runs on `accountScope` (already covered by `uncaughtCoroutineLogger`) — what is guarded here
     * is the synchronous scheduling that happens on the caller's thread.
     */
    fun pullAllForProfile(profileId: Int) {
        log.i { "Full profile pull requested for profile $profileId" }
        try {
            startFullProfilePull(profileId = profileId, reason = "requested")
        } catch (error: CancellationException) {
            // composeApp calls this from coroutines — never swallow their cancellation.
            throw error
        } catch (error: Throwable) {
            log.e(error) { "Full profile pull request failed for profile $profileId" }
        }
    }

    // Fork: public — composeApp LocalAccountDataCleaner calls this cross-module.
    fun cancelAccountSync() {
        syncRequestGate.cancel()
        val previousAccountJob = synchronized(accountScopeLock) {
            accountScopeJob.also {
                accountScopeJob = SupervisorJob()
                accountScope = CoroutineScope(accountScopeJob + Dispatchers.Default + uncaughtCoroutineLogger("SyncManager"))
            }
        }
        previousAccountJob.cancel()
        val foregroundJob = synchronized(pullStateLock) {
            foregroundPullJob.also {
                foregroundPullJob = null
                foregroundPullProfileId = null
                activityPullFreshness = ProfilePullFreshness()
                fullPullFreshness = ProfilePullFreshness()
            }
        }
        foregroundJob?.cancel()
        stopPeriodicNuvioSyncPull()
    }

    private fun accountScopeSnapshot(): CoroutineScope = synchronized(accountScopeLock) {
        accountScope
    }

    fun requestForegroundPull(profileId: Int, force: Boolean = false) {
        val authState = AuthRepository.state.value
        if (authState !is AuthState.Authenticated || authState.isAnonymous) return

        if (!force && hasRecentActivityPull(profileId)) {
            return
        }
        lateinit var requestJob: Job
        var previousJob: Job? = null
        synchronized(pullStateLock) {
            if (
                !force &&
                foregroundPullJob?.isCompleted == false &&
                foregroundPullProfileId == profileId
            ) {
                return
            }

            previousJob = foregroundPullJob
            requestJob = accountScopeSnapshot().launch(start = CoroutineStart.LAZY) {
                try {
                    if (!force) {
                        delay(FOREGROUND_PULL_DELAY_MS)
                    }
                    if (!force && hasRecentActivityPull(profileId)) return@launch
                    if (ProfileRepository.activeProfileId != profileId) return@launch
                    // Escalate to a full sync when the caller forced (reconnect handlers use
                    // force=true precisely to retry everything) or when this profile has never
                    // completed one — otherwise a full pull that failed offline would only ever
                    // retry library/watch activity until the profile is reselected (Codex
                    // 2026-08-24). startFullProfilePull's own 10s gate bounds the worst case.
                    if (force || !hasCompletedFullPull(profileId)) {
                        startFullProfilePull(profileId = profileId, reason = "foreground")
                    } else {
                        startActivityProfilePull(profileId = profileId, reason = "foreground")
                    }
                } finally {
                    synchronized(pullStateLock) {
                        if (foregroundPullJob === requestJob) {
                            foregroundPullJob = null
                            foregroundPullProfileId = null
                        }
                    }
                }
            }
            foregroundPullProfileId = profileId
            foregroundPullJob = requestJob
        }
        previousJob?.cancel()
        requestJob.start()
    }

    private fun hasRecentActivityPull(profileId: Int): Boolean =
        synchronized(pullStateLock) {
            activityPullFreshness.isRecent(
                profileId = profileId,
                nowEpochMs = TraktPlatformClock.nowEpochMs(),
                minIntervalMs = FOREGROUND_ACTIVITY_PULL_MIN_INTERVAL_MS,
            )
        }

    private fun hasRecentFullPull(profileId: Int): Boolean =
        synchronized(pullStateLock) {
            fullPullFreshness.isRecent(
                profileId = profileId,
                nowEpochMs = TraktPlatformClock.nowEpochMs(),
                minIntervalMs = FULL_PULL_MIN_INTERVAL_MS,
            )
        }

    // "Has ANY full pull ever succeeded for this profile since the account scope began" — the
    // freshness record only ever holds a successful pull's profile, and cancelAccountSync resets it.
    private fun hasCompletedFullPull(profileId: Int): Boolean =
        synchronized(pullStateLock) {
            fullPullFreshness.profileId == profileId
        }

    private fun startActivityProfilePull(
        profileId: Int,
        reason: String,
        pullLibrary: Boolean = true,
        pullWatchActivity: Boolean = true,
    ) {
        val authState = AuthRepository.state.value
        if (authState !is AuthState.Authenticated || authState.isAnonymous) return
        if (ProfileRepository.activeProfileId != profileId) return

        val result = syncRequestGate.launch(
            scope = accountScopeSnapshot(),
            profileId = profileId,
            kind = ProfileSyncRequestKind.Activity,
        ) {
            val currentAuthState = AuthRepository.state.value
            if (currentAuthState !is AuthState.Authenticated || currentAuthState.isAnonymous) return@launch
            if (ProfileRepository.activeProfileId != profileId) return@launch

            log.i { "Activity sync started profile=$profileId reason=$reason" }
            val syncResult = runActivityProfileSync(
                profileId = profileId,
                pullLibrary = pullLibrary,
                pullWatchActivity = pullWatchActivity,
                operations = profileActivitySyncOperations,
                onFailure = { step, error ->
                    log.e(error) { "Activity sync step failed profile=$profileId step=$step" }
                },
            )
            synchronized(pullStateLock) {
                activityPullFreshness = activityPullFreshness.recordIfSuccessful(
                    profileId = profileId,
                    completedAtEpochMs = TraktPlatformClock.nowEpochMs(),
                    result = syncResult,
                )
            }
            if (!syncResult.succeeded) {
                log.w {
                    "Activity sync incomplete profile=$profileId reason=$reason failedSteps=${syncResult.failedSteps}"
                }
            }
            log.i { "Activity sync completed profile=$profileId reason=$reason" }
        }

        if (result == ProfileSyncRequestResult.Coalesced) {
            log.d { "Activity sync coalesced profile=$profileId reason=$reason" }
        }
    }

    private fun startFullProfilePull(
        profileId: Int,
        reason: String,
        queueIfCoalesced: Boolean = false,
    ) {
        val authState = AuthRepository.state.value
        if (authState !is AuthState.Authenticated || authState.isAnonymous) return
        if (ProfileRepository.activeProfileId != profileId) return
        if (hasRecentFullPull(profileId)) return

        val result = syncRequestGate.launch(
            scope = accountScopeSnapshot(),
            profileId = profileId,
            queueIfCoalesced = queueIfCoalesced,
            kind = ProfileSyncRequestKind.Full,
        ) {
            val currentAuthState = AuthRepository.state.value
            if (currentAuthState !is AuthState.Authenticated || currentAuthState.isAnonymous) return@launch
            if (ProfileRepository.activeProfileId != profileId) return@launch

            log.i { "Full profile sync started profile=$profileId reason=$reason" }
            WatchProgressSourceCoordinator.pauseAutomaticTransitions()
            val syncResult = try {
                runOrderedProfileSync(
                    profileId = profileId,
                    pluginsEnabled = FeaturePolicyProvider.policy.pluginsEnabled,
                    operations = profileSyncOperations,
                    onFailure = { step, error ->
                        log.e(error) { "Full profile sync step failed profile=$profileId step=$step" }
                    },
                )
            } finally {
                WatchProgressSourceCoordinator.resumeAutomaticTransitions()
            }
            synchronized(pullStateLock) {
                activityPullFreshness = activityPullFreshness.recordIfSuccessful(
                    profileId = profileId,
                    completedAtEpochMs = TraktPlatformClock.nowEpochMs(),
                    result = syncResult,
                )
                fullPullFreshness = fullPullFreshness.recordIfSuccessful(
                    profileId = profileId,
                    completedAtEpochMs = TraktPlatformClock.nowEpochMs(),
                    result = syncResult,
                )
            }
            if (!syncResult.succeeded) {
                log.w {
                    "Full profile sync incomplete profile=$profileId reason=$reason " +
                        "failedSteps=${syncResult.failedSteps}"
                }
            }
            log.i { "Full profile sync completed profile=$profileId reason=$reason" }
        }

        when (result) {
            ProfileSyncRequestResult.Started -> Unit
            ProfileSyncRequestResult.Coalesced -> {
                log.d { "Full profile sync coalesced profile=$profileId reason=$reason" }
            }
            ProfileSyncRequestResult.Replaced -> {
                log.d { "Full profile sync replaced stale profile request with profile=$profileId reason=$reason" }
            }
        }
    }

    fun startPeriodicNuvioSyncPull(profileId: Int) {
        val authState = AuthRepository.state.value
        if (authState !is AuthState.Authenticated || authState.isAnonymous) {
            stopPeriodicNuvioSyncPull()
            return
        }
        if (periodicNuvioSyncPullJob?.isActive == true && periodicNuvioSyncProfileId == profileId) return

        stopPeriodicNuvioSyncPull()
        periodicNuvioSyncProfileId = profileId
        periodicNuvioSyncPullJob = accountScopeSnapshot().launch {
            while (isActive) {
                delay(PERIODIC_NUVIO_SYNC_PULL_INTERVAL_MS)

                val currentAuthState = AuthRepository.state.value
                if (currentAuthState !is AuthState.Authenticated || currentAuthState.isAnonymous) {
                    continue
                }
                if (ProfileRepository.activeProfileId != profileId) {
                    continue
                }

                // Registry-driven, but still profile-scoped: the `profileId` overload fans out to
                // each provider's per-profile loader, so Trakt keeps loading exactly this
                // profile's credentials the way `TraktAuthRepository.ensureLoaded(profileId)` did.
                ensureTrackingProvidersRegistered()
                TrackingProviderRegistry.ensureLoaded(profileId)
                TrackingSettingsRepository.ensureLoaded()

                val settings = TrackingSettingsRepository.uiState.value
                val shouldPullLibrary = effectiveLibrarySourceMode(
                    requestedSource = settings.librarySourceMode,
                    isProviderAuthenticated = TrackingProviderRegistry::isAuthenticated,
                ) == LibrarySourceMode.LOCAL
                val shouldPullWatchProgress = effectiveWatchProgressSource(
                    requestedSource = settings.watchProgressSource,
                    isProviderAuthenticated = TrackingProviderRegistry::isAuthenticated,
                ) == WatchProgressSource.NUVIO_SYNC

                if (!shouldPullLibrary && !shouldPullWatchProgress) {
                    continue
                }

                startActivityProfilePull(
                    profileId = profileId,
                    reason = "periodic",
                    pullLibrary = shouldPullLibrary,
                    pullWatchActivity = shouldPullWatchProgress,
                )
            }
        }
    }

    fun stopPeriodicNuvioSyncPull() {
        periodicNuvioSyncPullJob?.cancel()
        periodicNuvioSyncPullJob = null
        periodicNuvioSyncProfileId = null
    }
}
