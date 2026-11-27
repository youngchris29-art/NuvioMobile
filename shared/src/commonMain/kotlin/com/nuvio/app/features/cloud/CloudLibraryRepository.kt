package com.nuvio.app.features.cloud

import co.touchlab.kermit.Logger
import com.nuvio.app.core.coroutines.uncaughtCoroutineLogger
import com.nuvio.app.core.identity.CommitKind
import com.nuvio.app.core.identity.CommitResult
import com.nuvio.app.core.identity.IdentityGate
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
    private val scope = CoroutineScope(SupervisorJob() + Dispatchers.Default + uncaughtCoroutineLogger("CloudLibraryRepository"))
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

    /** Tests only: runs right before every provider call, after its credentials were read. */
    internal var beforeStoreCallForTest: () -> Unit = {}

    /** Tests only: restores the real seams and an empty state. */
    internal fun resetForTest() {
        settings = DebridCloudSettings
        backend = storeBackend
        debugHoldMs = null
        logSink = { line -> log.i { line } }
        beforeStoreCallForTest = {}
        scope.coroutineContext[kotlinx.coroutines.Job]?.children?.forEach { it.cancel() }
        clear()
    }

    /** Tests only: a state in memory (another profile's listing). */
    internal fun setStateForTest(state: CloudLibraryUiState) {
        _uiState.value = state
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

    private fun writeDisabled() {
        loadedConnectionKeys = emptyList()
        _uiState.value = CloudLibraryUiState(isLoaded = true, isEnabled = false)
    }

    fun ensureLoaded() {
        val call = beginCall("cloudEnsureLoaded") ?: return
        settings.load()
        if (!settings.enabled()) {
            publish(call, "cloudDisabled") { writeDisabled() }
            return
        }
        val current = _uiState.value
        if (current.isRefreshing) return
        val connectedKeys = keysOf(call.credentials())
        if (!current.isLoaded || connectedKeys != loadedConnectionKeys) {
            refreshWith(call)
        }
    }

    fun refresh() {
        val call = beginCall("cloudRefresh") ?: return
        refreshWith(call)
    }

    private fun refreshWith(call: CloudCall) {
        settings.load()
        if (!settings.enabled()) {
            publish(call, "cloudRefreshDisabled") { writeDisabled() }
            return
        }
        val credentials = call.credentials()
        val started = publish(call, "cloudRefreshStart") {
            _uiState.update { current ->
                current.copy(
                    isEnabled = true,
                    isRefreshing = true,
                    providers = current.providers.map { it.copy(isLoading = true, errorMessage = null) },
                )
            }
        }
        if (started is CommitResult.Rejected) return
        val job = IdentityWork.launch(call.token, "cloudRefresh", scope) {
            beforeStoreCallForTest()
            val refreshed = backend.refresh(credentials)
            debugHold(call, "cloudRefresh") {
                publish(call, "cloudRefresh") {
                    loadedConnectionKeys = keysOf(credentials)
                    _uiState.value = refreshed
                }
            }
        }
        if (job == null) {
            // The launch was refused after the start committed: undo the refreshing state while
            // the call's identity still holds (if it moved, the fan-out's clear() already did).
            publish(call, "cloudRefreshAbort") {
                _uiState.update { current ->
                    current.copy(isRefreshing = false, providers = current.providers.map { it.copy(isLoading = false) })
                }
            }
        }
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
            _uiState.value.findPlaybackTargetForProgress(contentId = contentId, videoId = videoId)
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
        val credentials = call.credentials()
        beforeStoreCallForTest()
        val result = backend.resolvePlayback(item, file, credentials)
        return when (val r = debugHold(call, "cloudResolve") {
            publish(call, "cloudResolve") {
                if (result is CloudLibraryPlaybackResult.Success) {
                    rememberResolvedPlaybackUrl(item = item, file = file, url = result.url)
                }
                result
            }
        }) {
            is CommitResult.Committed -> r.value
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

    /** W3b (9.1.4): the profile fan-out and the account wipe empty the Cloud state (gate closed). */
    fun clear() {
        loadedConnectionKeys = emptyList()
        _uiState.value = CloudLibraryUiState()
    }

    /** Under the call's commit (callers): the resolved URL joins the listing. */
    private fun rememberResolvedPlaybackUrl(
        item: CloudLibraryItem,
        file: CloudLibraryFile,
        url: String,
    ) {
        if (url.isBlank()) return
        _uiState.update { current ->
            current.withResolvedPlaybackUrl(
                item = item,
                file = file,
                url = url,
            )
        }
    }

    private suspend fun refreshNow(call: CloudCall, contentId: String, videoId: String): CloudLookupStep {
        val started = publish(call, "cloudRefreshNowStart") {
            _uiState.update { current ->
                current.copy(
                    isEnabled = true,
                    isRefreshing = true,
                    providers = current.providers.map { it.copy(isLoading = true, errorMessage = null) },
                )
            }
        }
        if (started is CommitResult.Rejected) return CloudLookupStep.Refused(CloudLookupStep.Stage.Start)
        val credentials = call.credentials()
        beforeStoreCallForTest()
        val refreshed = backend.refresh(credentials)
        return when (val r = debugHold(call, "cloudRefreshNow") {
            publish(call, "cloudRefreshNow") {
                loadedConnectionKeys = keysOf(credentials)
                _uiState.value = refreshed
                refreshed.findPlaybackTargetForProgress(contentId = contentId, videoId = videoId)
            }
        }) {
            is CommitResult.Committed -> r.value?.let { CloudLookupStep.Found(it) } ?: CloudLookupStep.NotFound
            is CommitResult.Rejected -> CloudLookupStep.Refused(CloudLookupStep.Stage.Commit)
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
