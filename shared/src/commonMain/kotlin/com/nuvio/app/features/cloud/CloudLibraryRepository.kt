package com.nuvio.app.features.cloud

import co.touchlab.kermit.Logger
import com.nuvio.app.core.coroutines.uncaughtCoroutineLogger
import com.nuvio.app.core.identity.CommitKind
import com.nuvio.app.core.identity.CommitResult
import com.nuvio.app.core.identity.IdentityGate
import com.nuvio.app.core.identity.IdentityPhase
import com.nuvio.app.core.identity.IdentityScope
import com.nuvio.app.core.identity.IdentityToken
import com.nuvio.app.core.identity.IdentityWork
import com.nuvio.app.features.debrid.DebridProvider
import com.nuvio.app.features.debrid.DebridProviderCapability
import com.nuvio.app.features.debrid.DebridProviders
import com.nuvio.app.features.debrid.DebridServiceCredential
import com.nuvio.app.features.debrid.DebridSettingsRepository
import com.nuvio.app.features.debrid.supports
import com.nuvio.app.core.i18n.StringKey
import com.nuvio.app.core.i18n.resourceString
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.NonCancellable
import kotlinx.coroutines.delay
import kotlinx.coroutines.withContext
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.asStateFlow
import kotlinx.coroutines.flow.first
import kotlinx.coroutines.flow.update
import kotlinx.coroutines.launch

class CloudLibraryStore(
    private val credentialsProvider: suspend () -> List<DebridServiceCredential>,
    private val providerApis: List<CloudLibraryProviderApi>,
) {
    /**
     * Fork (scope identity W3b, 9.1.2): CloudLibraryRepository passes the call's [credentials]; null
     * (composeApp's store test, other callers) reads the provider as before. (A suspend call cannot
     * be a default parameter value, so the spec's `= credentialsProvider()` default is `null` here.)
     */
    suspend fun refresh(credentials: List<DebridServiceCredential>? = null): CloudLibraryUiState {
        val credentials = (credentials ?: credentialsProvider())
            .filter { credential -> credential.provider.supports(DebridProviderCapability.CloudLibrary) }

        val providerStates = credentials.map { credential ->
            val api = providerApis.firstOrNull { it.provider.id == credential.provider.id }
            if (api == null) {
                return@map CloudLibraryProviderState(
                    provider = credential.provider,
                    errorMessage = resourceString(
                        "Cloud library is not available for ${credential.provider.displayName}.",
                        StringKey.cloud_library_provider_unavailable,
                        credential.provider.displayName,
                    ),
                )
            }

            api.listItems(credential.apiKey)
                .fold(
                    onSuccess = { items ->
                        CloudLibraryProviderState(
                            provider = credential.provider,
                            items = items,
                        )
                    },
                    onFailure = { error ->
                        CloudLibraryProviderState(
                            provider = credential.provider,
                            errorMessage = error.message,
                        )
                    },
                )
        }

        return CloudLibraryUiState(
            isLoaded = true,
            isRefreshing = false,
            providers = providerStates,
        )
    }

    /** Fork (scope identity W3b, 9.1.2): [credentials] is passed by CloudLibraryRepository (read once, on the call). */
    suspend fun resolvePlayback(
        item: CloudLibraryItem,
        file: CloudLibraryFile,
        credentials: List<DebridServiceCredential>? = null,
    ): CloudLibraryPlaybackResult {
        if (!file.playable) return CloudLibraryPlaybackResult.NotPlayable
        val credential = (credentials ?: credentialsProvider())
            .firstOrNull { credential -> credential.provider.id == item.providerId }
            ?: return CloudLibraryPlaybackResult.MissingCredentials
        val api = providerApis.firstOrNull { it.provider.id == item.providerId }
            ?: return CloudLibraryPlaybackResult.Failed()
        file.playbackUrl?.takeIf { it.isNotBlank() }?.let { url ->
            return CloudLibraryPlaybackResult.Success(
                url = url,
                filename = file.name.takeIf { it.isNotBlank() },
                videoSizeBytes = file.sizeBytes,
            )
        }
        return api.resolvePlayback(
            apiKey = credential.apiKey,
            item = item,
            file = file,
        )
    }
}

/**
 * Fork (scope identity W3b, spec 9.1). Every public entry point that reads or writes
 * identity-dependent state captures the call as its FIRST statement (`beginCall`); every setting,
 * credential and cache read after it belongs to that call, and every write and every returned value
 * derived from them goes through `IdentityGate.commit(call.token, Publish, site)`. A refusal at the
 * start or at the final commit returns the function's explicit refused value and writes nothing.
 * `clear()` is the one exception (the profile fan-out and the account wipe, gate closed).
 */
object CloudLibraryRepository {
    private val log = Logger.withTag("CloudLib")
    private val defaultScope = CoroutineScope(SupervisorJob() + Dispatchers.Default + uncaughtCoroutineLogger("CloudLibraryRepository"))
    /** Review r4 B: the one permanent auto-load observer (installed on first use). */
    private val observerScope = CoroutineScope(SupervisorJob() + Dispatchers.Default + uncaughtCoroutineLogger("CloudLibraryObserver"))
    /** Where refresh jobs run (tests use a paused dispatcher to cancel a job before its body). */
    internal var scope: CoroutineScope = defaultScope
    private val store = CloudLibraryStore(
        credentialsProvider = {
            DebridSettingsRepository.ensureLoaded()
            DebridProviders.configuredServices(DebridSettingsRepository.snapshot())
        },
        providerApis = CloudLibraryProviderApis.all(),
    )
    private val _uiState = MutableStateFlow(CloudLibraryUiState())
    private var loadedConnectionKeys: List<CloudConnectionKey> = emptyList()
    val uiState = _uiState.asStateFlow()

    /**
     * Review r1 #3: the profile the listing in memory was published for. A resolve acts only on an
     * item and file found in that listing while the call's identity is that profile; the item and
     * file a caller passes are keys, never trusted values. Written with the listing; under the
     * commit lock.
     */
    private var listingScope: IdentityScope? = null

    /**
     * Review r2 #1/#2: the refreshing marker (CloudRefreshMarker) and the `_uiState` writes it
     * drives, under [stateLock], a LEAF lock: taken inside identity commits, and alone (never the
     * commit lock) from a refresh job's completion handler. So a job that ends without publishing,
     * even one cancelled before its body ran, clears its own marker without entering the gate; it
     * can only clear the marker it owns, never write a listing.
     */
    private val marker = CloudRefreshMarker()

    /**
     * The repository's leaf lock. `_uiState` is assigned while holding it, which cannot run a
     * collector re-entrantly here: a StateFlow assignment only resumes a suspended collector through
     * that collector's dispatcher, and runs it inline only for an undispatched one (Unconfined, or
     * Main.immediate when the assignment itself is on the main thread). The production collectors
     * (tvOS FlowWatcher on Dispatchers.Main, composeApp's collectAsStateWithLifecycle on the
     * composition's dispatcher) always dispatch, and nothing collects this flow Unconfined. Keeping
     * the assignment under the lock is what orders the publications.
     */
    private val stateLock = kotlinx.atomicfu.locks.SynchronizedObject()

    /**
     * Focused check #1-#3: the repository generation, bumped by clear(), by the disabled-state write,
     * by a disabled setting observed in a final section, and by every observed change of the
     * connection keys (ensureLoaded's comparison with the loaded keys, or a final section finding
     * the keys differ from the ones its operation fetched with). Every operation captures it with its
     * token and keys in its start section; its final section publishes, records and returns only if
     * all three still hold. Under [stateLock].
     */
    private var generation = 0L
    private var listingGeneration = -1L

    /**
     * Focused check #4: the targets a resolve may accept for ([trustedScope], [trustedGeneration]):
     * every item and file of every listing published in this generation plus every lookup target
     * found in it. It accumulates, so a row a newer listing dropped stays resolvable within the same
     * profile and settings; it is emptied when the generation bumps or the scope changes. Its size is
     * the union of one generation's listings (a listing is a few hundred items with a handful of
     * files each in practice: tens to hundreds of kilobytes). Under [stateLock].
     */
    private var trustedScope: IdentityScope? = null
    private var trustedGeneration = -1L
    private val trusted = HashMap<String, CloudLibraryPlaybackTarget>()

    /**
     * Review r4 B: a listing was asked for (ensureLoaded/refresh) since the last clear. With
     * [endedTicks] and the gate's state flow it drives the auto-load observer. Under [stateLock].
     */
    private var wanted = false
    private var observerInstalled = false

    /** Review r4 B: bumped when a refresh ends without publishing (an identity-driven end). */
    private val endedTicks = MutableStateFlow(0L)

    private fun targetKey(item: CloudLibraryItem, file: CloudLibraryFile) = "${item.stableKey}|${file.stableKey}"

    private fun bumpGenerationLocked() {
        generation++
        trusted.clear()
        trustedScope = null
    }

    private fun trustLocked(scope: IdentityScope, target: CloudLibraryPlaybackTarget) {
        if (trustedScope != scope || trustedGeneration != generation) {
            trusted.clear()
            trustedScope = scope
            trustedGeneration = generation
        }
        trusted[targetKey(target.item, target.file)] = target
    }

    private fun trustListingLocked(scope: IdentityScope, listing: CloudLibraryUiState) {
        for (item in listing.items) for (file in item.files) trustLocked(scope, CloudLibraryPlaybackTarget(item, file))
    }

    /** The profile's Debrid settings, read on a call (a seam: tests flip them at the switch). */
    internal interface Settings {
        fun load()
        fun enabled(): Boolean
        /** The Cloud-capable credentials of the profile, empty when the Cloud library is off. */
        fun credentials(): List<DebridServiceCredential>
    }

    /** The provider calls (a seam: tests gate them). Credentials are always passed, never read here. */
    internal interface Backend {
        suspend fun refresh(credentials: List<DebridServiceCredential>): CloudLibraryUiState
        suspend fun resolvePlayback(
            item: CloudLibraryItem,
            file: CloudLibraryFile,
            credentials: List<DebridServiceCredential>,
        ): CloudLibraryPlaybackResult
    }

    private object DebridCloudSettings : Settings {
        override fun load() = DebridSettingsRepository.ensureLoaded()
        override fun enabled(): Boolean = DebridSettingsRepository.snapshot().cloudLibraryEnabled
        override fun credentials(): List<DebridServiceCredential> =
            DebridSettingsRepository.snapshot()
                .takeIf { settings -> settings.cloudLibraryEnabled }
                ?.let(DebridProviders::configuredServices)
                .orEmpty()
                .filter { credential -> credential.provider.supports(DebridProviderCapability.CloudLibrary) }
    }

    private val storeBackend = object : Backend {
        override suspend fun refresh(credentials: List<DebridServiceCredential>) = store.refresh(credentials)
        override suspend fun resolvePlayback(
            item: CloudLibraryItem,
            file: CloudLibraryFile,
            credentials: List<DebridServiceCredential>,
        ) = store.resolvePlayback(item, file, credentials)
    }

    internal var settings: Settings = DebridCloudSettings
    internal var backend: Backend = storeBackend

    /** DEBUG knob (8.5, `-debug.cloudRefreshHoldMs`): set by TvOsProviderInstaller in DEBUG builds only. */
    internal var debugHoldMs: Long? = null

    /** Where the `[CloudLib]` lines go (tests read them). */
    internal var logSink: (String) -> Unit = { line -> log.i { line } }

    /** Tests only: runs in the auto-load observer right before its token capture. */
    internal var beforeAutoCaptureForTest: () -> Unit = {}

    /** Tests only: runs right before every provider call, after its credentials were read. */
    internal var beforeStoreCallForTest: () -> Unit = {}

    /** Tests only: restores the real seams and an empty state. */
    internal fun resetForTest() {
        settings = DebridCloudSettings
        backend = storeBackend
        debugHoldMs = null
        logSink = { line -> log.i { line } }
        beforeStoreCallForTest = {}
        beforeAutoCaptureForTest = {}
        scope.coroutineContext[kotlinx.coroutines.Job]?.children?.forEach { it.cancel() }
        scope = defaultScope
        clear()
    }

    /** Tests only: a state in memory, published for [scope] (null: nobody's). */
    internal fun setStateForTest(state: CloudLibraryUiState, scope: IdentityScope? = null) {
        kotlinx.atomicfu.locks.synchronized(stateLock) {
            listingScope = scope
            listingGeneration = if (scope != null) generation else -1L
            if (scope != null) trustListingLocked(scope, state)
            _uiState.value = state
        }
    }

    /** Tests only: cancels the refresh jobs (what a drain does to a profile job). */
    internal fun cancelJobsForTest() {
        scope.coroutineContext[kotlinx.coroutines.Job]?.children?.forEach { it.cancel() }
    }

    /** One call: the token captured as its first statement, and the credentials read once on it. */
    private class CloudCall(val token: IdentityToken) {
        var credentials: List<DebridServiceCredential>? = null
    }

    private fun beginCall(site: String): CloudCall? {
        val call = IdentityGate.currentToken()?.let { CloudCall(it) }
        if (call == null) logSink("[CloudLib] refused site=$site stage=start epoch=none")
        return call
    }

    /** The call's credentials: read once, after the capture, then passed down explicitly. */
    private fun CloudCall.credentials(): List<DebridServiceCredential> =
        credentials ?: settings.let {
            it.load()
            it.credentials()
        }.also { credentials = it }

    private fun <T> publish(call: CloudCall, site: String, block: () -> T): CommitResult<T> =
        IdentityGate.commit(call.token, CommitKind.Publish, site, block).also {
            if (it is CommitResult.Rejected) logSink("[CloudLib] refused site=$site stage=commit epoch=${call.token.epoch.value}")
        }

    /**
     * Review r1 #2: credentials a provider call may use, only ever built inside an admission. The
     * credentials are read after the capture and then admitted by a commit of the call's token
     * ([admitWork]): the epoch only grows, so a token that still holds at that commit held at the
     * read too, so the settings read were the call's profile's. No provider call takes anything else.
     */
    private class Admitted<T>(
        val credentials: List<DebridServiceCredential>,
        /** Focused check: the connection keys this operation fetches with, compared by value at the end. */
        val keys: List<CloudConnectionKey>,
        /** Focused check: the repository generation at the start. */
        val generation: Long,
        val value: T,
    )

    /**
     * Admits provider work in ONE section under the call's token admission and [stateLock]: the
     * credentials read on the call, the generation, and [block]'s value. [block] returning null
     * refuses (nothing started).
     */
    private fun <T : Any> admitWork(call: CloudCall, site: String, block: () -> T?): Admitted<T>? {
        val credentials = call.credentials()
        val r = publish(call, site) {
            kotlinx.atomicfu.locks.synchronized(stateLock) { block()?.let { generation to it } }
        }
        return when (r) {
            is CommitResult.Committed -> r.value?.let { (gen, value) -> Admitted(credentials, keysOf(credentials), gen, value) }
            is CommitResult.Rejected -> null
        }
    }

    /**
     * The final section of an operation, called inside its token admission: the settings now, then,
     * under [stateLock] and FIRST, the generation, enabled flag and connection keys captured at the
     * start. Only if all hold does [block] run (publish, record, return); otherwise null and nothing
     * is written. An observed key change or disable bumps the generation.
     */
    private fun <T> finalSection(admitted: Admitted<*>, block: () -> T): T? {
        val enabledNow = settings.enabled()
        val keysNow = keysOf(settings.credentials())
        return kotlinx.atomicfu.locks.synchronized(stateLock) {
            when {
                admitted.generation != generation -> null
                !enabledNow || keysNow != admitted.keys -> {
                    bumpGenerationLocked()
                    null
                }
                else -> block()
            }
        }
    }

    /** Inside a start section (stateLock held): a new marker owner (it supersedes any earlier one) and the loading state. */
    private fun markRefreshingLocked(): CloudRefreshMarker.Owner {
        val owner = marker.start()
        _uiState.update { current ->
            current.copy(
                isEnabled = true,
                isRefreshing = true,
                providers = current.providers.map { it.copy(isLoading = true, errorMessage = null) },
            )
        }
        return owner
    }

    /**
     * A refresh that ended without publishing: clears the loading state only if [owner] still holds
     * the marker. Called from a job's completion (any end, body run or not) and after a refused
     * launch; takes only [stateLock], never the identity commit lock.
     */
    private fun abandonRefresh(owner: CloudRefreshMarker.Owner) {
        val ended = kotlinx.atomicfu.locks.synchronized(stateLock) {
            if (!marker.abandon(owner)) return@synchronized false
            _uiState.update { current ->
                current.copy(isRefreshing = false, providers = current.providers.map { it.copy(isLoading = false) })
            }
            true
        }
        // Review r4 B: the observer re-evaluates (a wanted, unloaded listing loads again on the
        // then-current token once the gate is Open). Bumped outside the lock.
        if (ended) endedTicks.update { it + 1 }
    }

    /** Inside a final section (stateLock held, checks passed): the listing, its keys and its trusted targets. */
    private fun writeListingLocked(call: CloudCall, admitted: Admitted<*>, listing: CloudLibraryUiState) {
        loadedConnectionKeys = admitted.keys
        listingScope = call.token.scope
        listingGeneration = generation
        trustListingLocked(call.token.scope, listing)
        _uiState.value = listing
    }

    /**
     * Review r4 B: a provider fetch never throws past here. A throw (other than cancellation) is
     * published as base publishes a failed provider: a loaded provider state carrying the error
     * message, which both apps render with their retry. Not an abandonment.
     */
    private suspend fun fetch(credentials: List<DebridServiceCredential>): CloudLibraryUiState = try {
        backend.refresh(credentials)
    } catch (e: kotlinx.coroutines.CancellationException) {
        throw e
    } catch (e: Throwable) {
        CloudLibraryUiState(
            isLoaded = true,
            providers = credentials
                .filter { it.provider.supports(DebridProviderCapability.CloudLibrary) }
                .map { CloudLibraryProviderState(provider = it.provider, errorMessage = e.message) },
        )
    }

    /**
     * DEBUG hold (9.1.3): with the knob set, waits that long NON-cancellably and then makes the
     * commit attempt anyway, so a drain that cancelled the job still sees the stale attempt refused.
     */
    private suspend fun <T> debugHold(call: CloudCall, site: String, attempt: () -> CommitResult<T>): CommitResult<T> {
        val ms = debugHoldMs ?: return attempt()
        return withContext(NonCancellable) {
            logSink("[CloudLib] hold begin epoch=${call.token.epoch.value}")
            delay(ms)
            logSink("[CloudLib] hold end epoch=${call.token.epoch.value}")
            attempt().also {
                if (it is CommitResult.Rejected) logSink("[CloudLib] stale publish refused site=$site epoch=${call.token.epoch.value}")
            }
        }
    }

    private fun writeDisabled() = kotlinx.atomicfu.locks.synchronized(stateLock) {
        loadedConnectionKeys = emptyList()
        listingScope = null
        listingGeneration = -1L
        bumpGenerationLocked()
        marker.reset()
        _uiState.value = CloudLibraryUiState(isLoaded = true, isEnabled = false)
    }

    fun ensureLoaded() {
        // Review r4 B: wanted is set even when the capture below is refused (the gate closed); the
        // observer serves it on the next Open. Not identity-dependent state.
        want()
        ensureLoadedWith(beginCall("cloudEnsureLoaded") ?: return)
    }

    /**
     * Review r4 B: one permanent, level-triggered observer of the gate's state flow and of
     * [endedTicks]. Whenever the gate is Open and a wanted listing is neither loaded nor being
     * refreshed, it calls the load on the then-current token. Nothing is consumed: a capture the
     * gate refuses (it closed again in between) is served by the next Open emission. It never sets
     * [wanted], so after clear() nothing is loaded until someone asks again.
     */
    private fun want() {
        val install = kotlinx.atomicfu.locks.synchronized(stateLock) {
            wanted = true
            (!observerInstalled).also { observerInstalled = true }
        }
        if (!install) return
        observerScope.launch {
            kotlinx.coroutines.flow.combine(IdentityGate.state, endedTicks) { state, _ -> state }.collect { state ->
                if (state.phase !is IdentityPhase.Open || !autoLoadNeeded()) return@collect
                beforeAutoCaptureForTest()
                // A refused capture means the gate closed after this emission. Its next Open is a new
                // emission: every return to Open bumps the epoch (BarrierModel.settle), so the state
                // differs and the flow cannot conflate it away.
                val call = beginCall("cloudAutoLoad") ?: return@collect
                // The wanted check is repeated in the refresh's start section, with the marker claim
                // (focused check #3): a clear() after this point leaves nothing wanted, nothing starts.
                ensureLoadedWith(call, auto = true)
            }
        }
    }

    private fun autoLoadNeeded(): Boolean =
        kotlinx.atomicfu.locks.synchronized(stateLock) { wanted && !_uiState.value.isLoaded && !marker.isRefreshing }

    private fun ensureLoadedWith(call: CloudCall, auto: Boolean = false) {
        settings.load()
        if (!settings.enabled()) {
            publish(call, "cloudDisabled") { writeDisabled() }
            return
        }
        // Review r2: the marker, not the published flag, says whether a refresh is under way.
        val (current, refreshing) = kotlinx.atomicfu.locks.synchronized(stateLock) { _uiState.value to marker.isRefreshing }
        if (refreshing) return
        val connectedKeys = keysOf(call.credentials())
        val keysChanged = kotlinx.atomicfu.locks.synchronized(stateLock) {
            (current.isLoaded && connectedKeys != loadedConnectionKeys).also { if (it) bumpGenerationLocked() }
        }
        if (!current.isLoaded || keysChanged) {
            refreshWith(call, requireWanted = auto)
        }
    }

    fun refresh() {
        want()
        val call = beginCall("cloudRefresh") ?: return
        refreshWith(call)
    }

    private fun refreshWith(call: CloudCall, requireWanted: Boolean = false) {
        settings.load()
        if (!settings.enabled()) {
            publish(call, "cloudRefreshDisabled") { writeDisabled() }
            return
        }
        val admitted = admitWork(call, "cloudRefreshStart") {
            if (requireWanted && !wanted) null else markRefreshingLocked()
        } ?: return
        val owner = admitted.value
        val job = IdentityWork.launch(call.token, "cloudRefresh", scope) {
            beforeStoreCallForTest()
            val refreshed = fetch(admitted.credentials)
            // The result is not needed: a refused or superseded publish leaves the marker to the
            // job's completion (abandonRefresh), which is a no-op after a publish.
            debugHold(call, "cloudRefresh") {
                publish(call, "cloudRefresh") {
                    finalSection(admitted) { if (marker.publish(owner)) writeListingLocked(call, admitted, refreshed) }
                }
            }
        }
        // Review r2 #1: abandon on job COMPLETION (cancelled before or after its body, refused,
        // thrown or done; a no-op after a publish). A refused launch abandons at once.
        if (job == null) abandonRefresh(owner) else job.invokeOnCompletion { abandonRefresh(owner) }
    }

    suspend fun findPlaybackTargetForProgress(
        contentId: String,
        videoId: String,
    ): CloudLibraryPlaybackTarget? =
        when (val result = findPlaybackTargetForProgressResult(contentId = contentId, videoId = videoId)) {
            is CloudLibraryPlaybackTargetLookupResult.Found -> result.target
            CloudLibraryPlaybackTargetLookupResult.Disabled,
            is CloudLibraryPlaybackTargetLookupResult.NotConnected,
            CloudLibraryPlaybackTargetLookupResult.NotFound,
            -> null
        }

    suspend fun findPlaybackTargetForProgressResult(
        contentId: String,
        videoId: String,
    ): CloudLibraryPlaybackTargetLookupResult {
        val call = beginCall("cloudLookup") ?: return CloudLibraryPlaybackTargetLookupResult.NotFound
        settings.load()
        if (!settings.enabled()) {
            return when (publish(call, "cloudLookupDisabled") { writeDisabled() }) {
                is CommitResult.Committed -> CloudLibraryPlaybackTargetLookupResult.Disabled
                is CommitResult.Rejected -> CloudLibraryPlaybackTargetLookupResult.NotFound
            }
        }

        val providerId = cloudLibraryProviderId(contentId)
            .ifBlank { cloudLibraryProviderId(videoId) }
        val connectedCredentials = call.credentials()
        val notConnected = when {
            connectedCredentials.isEmpty() -> CloudLibraryPlaybackTargetLookupResult.NotConnected(
                providerName = providerId.takeIf { it.isNotBlank() }?.let(DebridProviders::displayName),
            )
            providerId.isNotBlank() &&
                connectedCredentials.none { credential -> credential.provider.id.equals(providerId, ignoreCase = true) } ->
                CloudLibraryPlaybackTargetLookupResult.NotConnected(providerName = DebridProviders.displayName(providerId))
            else -> null
        }
        if (notConnected != null) {
            return when (val r = publish(call, "cloudLookupNotConnected") { notConnected }) {
                is CommitResult.Committed -> r.value
                is CommitResult.Rejected -> CloudLibraryPlaybackTargetLookupResult.NotFound
            }
        }

        when (val cached = publish(call, "cloudCachedFound") {
            // Review r1 #3: only a listing published for the call's profile answers from the cache.
            kotlinx.atomicfu.locks.synchronized(stateLock) {
                // A listing of this generation: its items are already in the trusted set.
                if (listingScope != call.token.scope || listingGeneration != generation) null
                else _uiState.value.findPlaybackTargetForProgress(contentId = contentId, videoId = videoId)
            }
        }) {
            is CommitResult.Rejected -> return CloudLibraryPlaybackTargetLookupResult.NotFound
            is CommitResult.Committed -> cached.value?.let { target -> return CloudLibraryPlaybackTargetLookupResult.Found(target) }
        }

        return when (val step = refreshNow(call, contentId, videoId)) {
            is CloudLookupStep.Found -> CloudLibraryPlaybackTargetLookupResult.Found(step.target)
            CloudLookupStep.NotFound, is CloudLookupStep.Refused -> CloudLibraryPlaybackTargetLookupResult.NotFound
        }
    }

    suspend fun resolvePlayback(
        item: CloudLibraryItem,
        file: CloudLibraryFile,
    ): CloudLibraryPlaybackResult {
        val call = beginCall("cloudResolve") ?: return CloudLibraryPlaybackResult.Failed()
        settings.load()
        if (!settings.enabled()) {
            val disabled = CloudLibraryPlaybackResult.Failed(
                resourceString("Cloud library is disabled.", StringKey.cloud_library_playback_disabled),
            )
            return when (val r = publish(call, "cloudResolveDisabled") { disabled }) {
                is CommitResult.Committed -> r.value
                is CommitResult.Rejected -> CloudLibraryPlaybackResult.Failed()
            }
        }
        // Review r1 #2/#3: one admission reads the target from the listing published for the
        // call's profile (the passed item and file are only keys) and admits the credentials.
        val admitted = admitWork(call, "cloudResolveAdmit") { trustedTargetLocked(call, item, file) }
            ?: return CloudLibraryPlaybackResult.Failed()
        val target = admitted.value
        // Review r4 A: a target whose provider is no longer configured on this profile (key
        // disconnected after the lookup) gets the existing missing-credentials answer, no request.
        if (admitted.credentials.none { it.provider.id.equals(target.item.providerId, ignoreCase = true) }) {
            return when (val r = publish(call, "cloudResolveMissing") { CloudLibraryPlaybackResult.MissingCredentials }) {
                is CommitResult.Committed -> r.value
                is CommitResult.Rejected -> CloudLibraryPlaybackResult.Failed()
            }
        }
        beforeStoreCallForTest()
        val result = backend.resolvePlayback(target.item, target.file, admitted.credentials)
        return when (val r = debugHold(call, "cloudResolve") {
            publish(call, "cloudResolve") {
                finalSection(admitted) {
                    if (result is CloudLibraryPlaybackResult.Success) {
                        rememberResolvedPlaybackUrlLocked(call, item = target.item, file = target.file, url = result.url)
                    }
                    result
                }
            }
        }) {
            is CommitResult.Committed -> r.value ?: CloudLibraryPlaybackResult.Failed()
            is CommitResult.Rejected -> CloudLibraryPlaybackResult.Failed()
        }
    }

    /** W3b (BUG-257): the profile's Cloud-capable providers, before any listing is published. */
    fun configuredProviders(): List<DebridProvider> {
        val call = beginCall("cloudConfiguredProviders") ?: return emptyList()
        val providers = call.credentials().map { it.provider }
        return when (val r = publish(call, "cloudConfiguredProviders") { providers }) {
            is CommitResult.Committed -> r.value
            is CommitResult.Rejected -> emptyList()
        }
    }

    /**
     * Inside the resolve's start section (stateLock held): the trusted item and file for the call's
     * profile in this generation (stored values, never the caller's), or null.
     *
     * Known limit (review r2 #3, declined: same as base on mobile): composeApp's default profile
     * router switches profiles without moving the identity scope or epoch and does not clear Cloud,
     * so on the mobile app this check (and admitWork) cannot see a profile switch; at 867aba698 the
     * repository had no identity check at all and resolved any passed item with the credentials
     * read at call time. The tvOS barrier advances the token and clears Cloud on every switch.
     */
    private fun trustedTargetLocked(call: CloudCall, item: CloudLibraryItem, file: CloudLibraryFile): CloudLibraryPlaybackTarget? =
        if (trustedScope != call.token.scope || trustedGeneration != generation) null
        else trusted[targetKey(item, file)]

    /** W3b (9.1.4): the profile fan-out and the account wipe empty the Cloud state (gate closed). */
    fun clear() {
        kotlinx.atomicfu.locks.synchronized(stateLock) {
            loadedConnectionKeys = emptyList()
            listingScope = null
            listingGeneration = -1L
            bumpGenerationLocked()
            marker.reset()
            wanted = false
            _uiState.value = CloudLibraryUiState()
        }
    }

    /** Inside the resolve's final section (stateLock held): the resolved URL joins the listing and the trusted target. */
    private fun rememberResolvedPlaybackUrlLocked(
        call: CloudCall,
        item: CloudLibraryItem,
        file: CloudLibraryFile,
        url: String,
    ) {
        if (url.isBlank()) return
        trustLocked(call.token.scope, CloudLibraryPlaybackTarget(item, file.copy(playbackUrl = url.trim())))
        _uiState.update { current ->
            current.withResolvedPlaybackUrl(
                item = item,
                file = file,
                url = url,
            )
        }
    }

    private suspend fun refreshNow(call: CloudCall, contentId: String, videoId: String): CloudLookupStep {
        val admitted = admitWork(call, "cloudRefreshNowStart") { markRefreshingLocked() }
            ?: return CloudLookupStep.Refused(CloudLookupStep.Stage.Start)
        val owner = admitted.value
        // Runs in the caller's coroutine (no registered job): the body always runs, so `finally` is
        // its completion.
        try {
            beforeStoreCallForTest()
            val refreshed = fetch(admitted.credentials)
            // Review r4 A: the lookup answers from ITS OWN fetch (as at base), inside its own final
            // admission: its token still holds, so the fetch was made for this profile with the
            // credentials admitted for this call. Publishing stays owner-only (a superseded lookup
            // publishes nothing); the target it found is recorded under the call's scope, so the
            // resolve that follows can accept it.
            return when (val r = debugHold(call, "cloudRefreshNow") {
                publish(call, "cloudRefreshNow") {
                    // Generation, keys and enabled FIRST; then publish (owner only), trust, return.
                    finalSection(admitted) {
                        if (marker.publish(owner)) writeListingLocked(call, admitted, refreshed)
                        refreshed.findPlaybackTargetForProgress(contentId = contentId, videoId = videoId)
                            ?.also { trustLocked(call.token.scope, it) }
                    }
                }
            }) {
                is CommitResult.Committed -> r.value?.let { CloudLookupStep.Found(it) } ?: CloudLookupStep.NotFound
                is CommitResult.Rejected -> CloudLookupStep.Refused(CloudLookupStep.Stage.Commit)
            }
        } finally {
            abandonRefresh(owner)
        }
    }

    private sealed interface CloudLookupStep {
        data class Found(val target: CloudLibraryPlaybackTarget) : CloudLookupStep
        data object NotFound : CloudLookupStep
        data class Refused(val stage: Stage) : CloudLookupStep
        enum class Stage { Start, Commit }
    }

    /** Compared by full value (9.1.3), so two keys with equal hashes still differ; never printed. */
    internal data class CloudConnectionKey(
        val providerId: String,
        val apiKey: String,
    ) {
        override fun toString(): String = "CloudConnectionKey(providerId=$providerId)"
    }

    internal fun keysOf(credentials: List<DebridServiceCredential>): List<CloudConnectionKey> =
        credentials.map { credential ->
            CloudConnectionKey(providerId = credential.provider.id, apiKey = credential.apiKey)
        }.sortedBy { it.providerId }
}

fun CloudLibraryUiState.findPlaybackTargetForProgress(
    contentId: String,
    videoId: String,
): CloudLibraryPlaybackTarget? {
    val normalizedContentId = contentId.trim()
    val normalizedVideoId = videoId.trim()
    if (normalizedContentId.isBlank()) return null

    val matchingItems = items.filter { item -> item.stableKey == normalizedContentId }
    if (matchingItems.isEmpty()) return null

    for (item in matchingItems) {
        val exactFile = item.playableFiles.firstOrNull { file ->
            item.playbackVideoId(file) == normalizedVideoId
        }
        if (exactFile != null) {
            return CloudLibraryPlaybackTarget(item = item, file = exactFile)
        }
    }

    val singleItem = matchingItems.singleOrNull() ?: return null
    val singleFile = singleItem.playableFiles.singleOrNull() ?: return null
    return CloudLibraryPlaybackTarget(item = singleItem, file = singleFile)
}

fun CloudLibraryUiState.withResolvedPlaybackUrl(
    item: CloudLibraryItem,
    file: CloudLibraryFile,
    url: String,
): CloudLibraryUiState {
    val normalizedUrl = url.trim().takeIf { it.isNotBlank() } ?: return this
    val targetItemKey = item.stableKey
    val targetFileKey = file.stableKey
    var didUpdate = false
    val updatedProviders = providers.map { providerState ->
        if (providerState.providerId != item.providerId) return@map providerState
        val updatedItems = providerState.items.map { candidateItem ->
            if (candidateItem.stableKey != targetItemKey) return@map candidateItem
            val updatedFiles = candidateItem.files.map { candidateFile ->
                if (candidateFile.stableKey != targetFileKey) {
                    candidateFile
                } else {
                    didUpdate = true
                    candidateFile.copy(playbackUrl = normalizedUrl)
                }
            }
            candidateItem.copy(files = updatedFiles)
        }
        providerState.copy(items = updatedItems)
    }
    return if (didUpdate) {
        copy(providers = updatedProviders)
    } else {
        this
    }
}
