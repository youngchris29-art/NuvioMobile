package com.nuvio.app.features.debrid

import com.nuvio.app.core.coroutines.uncaughtCoroutineLogger
import com.nuvio.app.features.streams.StreamBehaviorHints
import com.nuvio.app.features.streams.StreamClientResolve
import com.nuvio.app.features.streams.StreamDebridCacheState
import com.nuvio.app.features.streams.StreamItem
import com.nuvio.app.features.streams.epochMs
import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.CoroutineStart
import kotlinx.coroutines.Deferred
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.async
import kotlinx.coroutines.launch
import kotlinx.coroutines.sync.Mutex
import kotlinx.coroutines.sync.withLock
import com.nuvio.app.core.i18n.StringKey
import com.nuvio.app.core.i18n.resourceString

object DirectDebridPlaybackResolver {
    private val localAddonStreamResolver = LocalDebridAddonStreamResolver()
    private val scope = CoroutineScope(SupervisorJob() + Dispatchers.Default + uncaughtCoroutineLogger("DirectDebridResolver"))
    private val resolves = DebridResolveSingleFlight(scope)

    /**
     * [forceRefresh] always requests a new link from the provider: it skips the in-memory
     * resolved link and never joins an older in-flight resolve, and an older resolve that
     * finishes later cannot replace the forced result in the cache.
     */
    suspend fun resolve(
        stream: StreamItem,
        season: Int?,
        episode: Int?,
        forceRefresh: Boolean = false,
    ): DirectDebridResolveResult {
        if (!shouldResolveToPlayableStream(stream)) {
            return DirectDebridResolveResult.Stale
        }
        val cacheKey = stream.debridResolveCacheKey(season, episode)
        if (cacheKey == null) {
            return resolveUncached(stream, season, episode)
        }
        return resolves.resolve(cacheKey, forceRefresh) {
            resolveUncached(stream, season, episode)
        }
    }

    suspend fun cachedPlayableStream(stream: StreamItem, season: Int?, episode: Int?): StreamItem? {
        if (!shouldResolveToPlayableStream(stream)) return null
        val cacheKey = stream.debridResolveCacheKey(season, episode) ?: return null
        return resolves.cached(cacheKey)
            ?.let { result -> stream.withResolvedDebridUrl(result) }
    }

    /**
     * Fork (tvOS): drops the 15-minute resolve-cache entry for [stream] at this season/episode,
     * so the next [resolve] asks the provider again (e.g. after the cached link failed to play).
     * Keyed exactly like [resolve]. An in-flight resolve for the same key is left alone.
     *
     * Non-suspend for Swift. The eviction runs undispatched under the resolver's mutex: it
     * completes before this returns unless the mutex is held, and then it is queued ahead of
     * any later lookup (the mutex is fair), so a [resolve] issued after this call never reads
     * the old entry. Suspend callers can pass `forceRefresh = true` to [resolve] instead.
     */
    fun invalidate(stream: StreamItem, season: Int?, episode: Int?) {
        val cacheKey = stream.debridResolveCacheKey(season, episode) ?: return
        scope.launch(start = CoroutineStart.UNDISPATCHED) {
            resolves.evict(cacheKey)
        }
    }

    fun shouldResolveToPlayableStream(stream: StreamItem): Boolean {
        val settings = DebridSettingsRepository.snapshot()
        if (!settings.canResolvePlayableLinks) return false
        if (stream.needsLocalDebridResolve) {
            return stream.isInstalledAddonStream && localTorrentResolveCredential(settings) != null
        }
        if (!stream.isInstalledAddonStream || !stream.isDirectDebridStream || stream.playableDirectUrl != null) {
            return false
        }
        val providerId = DebridProviders.byId(stream.clientResolve?.service)?.id ?: return false
        return providerId == settings.activeResolverProviderId &&
            settings.apiKeyFor(providerId).isNotBlank() &&
            DebridProviderApis.apiFor(providerId) != null
    }

    private suspend fun resolveUncached(stream: StreamItem, season: Int?, episode: Int?): DirectDebridResolveResult {
        if (stream.needsLocalDebridResolve) {
            return localAddonStreamResolver.resolve(stream, season, episode)
        }
        val providerId = DebridProviders.byId(stream.clientResolve?.service)?.id
            ?: return DirectDebridResolveResult.Error()
        val settings = DebridSettingsRepository.snapshot()
        if (providerId != settings.activeResolverProviderId) {
            return DirectDebridResolveResult.Stale
        }
        val apiKey = settings
            .apiKeyFor(providerId)
            .trim()
            .takeIf { it.isNotBlank() }
            ?: return DirectDebridResolveResult.MissingApiKey
        val api = DebridProviderApis.apiFor(providerId) ?: return DirectDebridResolveResult.Error()
        return api.resolveClientStream(stream, apiKey, season, episode)
    }

    suspend fun resolveToPlayableStream(
        stream: StreamItem,
        season: Int?,
        episode: Int?,
        forceRefresh: Boolean = false,
    ): DirectDebridPlayableResult {
        if (!shouldResolveToPlayableStream(stream)) {
            return DirectDebridPlayableResult.Success(stream)
        }
        return when (val result = resolve(stream, season, episode, forceRefresh)) {
            is DirectDebridResolveResult.Success -> DirectDebridPlayableResult.Success(stream.withResolvedDebridUrl(result))
            DirectDebridResolveResult.MissingApiKey -> DirectDebridPlayableResult.MissingApiKey
            DirectDebridResolveResult.NotCached -> DirectDebridPlayableResult.NotCached
            DirectDebridResolveResult.Stale -> DirectDebridPlayableResult.Stale
            is DirectDebridResolveResult.Error -> DirectDebridPlayableResult.Error(result.message)
        }
    }
}

private const val DEBRID_RESOLVE_CACHE_TTL_MS = 15L * 60L * 1000L

/**
 * One provider request per cache key at a time, plus the 15-minute cache of successful
 * resolves. Internal so DirectDebridResolverForceRefreshTest can drive it with a fake provider
 * call (the real ones have no injection point).
 *
 * A non-forced call returns the cached result, else joins the in-flight resolve for the key
 * (forced or not), else starts one. A forced call never reads the cache and never joins a
 * non-forced in-flight resolve: it evicts the cached entry and registers its own resolve in
 * place of the older one, in one locked step. Concurrent forced calls share that forced
 * resolve. Only the resolve still registered for its key when it finishes may write the
 * cache, so a replaced older resolve finishing late returns its result to its own callers
 * but never overwrites the forced one.
 */
internal class DebridResolveSingleFlight(
    private val scope: CoroutineScope,
    private val now: () -> Long = ::epochMs,
) {
    private class InFlight(
        val deferred: Deferred<DirectDebridResolveResult>,
        val forced: Boolean,
    )

    private val mutex = Mutex()
    private val resolvedCache = mutableMapOf<String, CachedDirectDebridResolve>()
    private val inFlightResolves = mutableMapOf<String, InFlight>()

    suspend fun resolve(
        cacheKey: String,
        forceRefresh: Boolean,
        resolveUncached: suspend () -> DirectDebridResolveResult,
    ): DirectDebridResolveResult {
        if (!forceRefresh) {
            cached(cacheKey)?.let { return it }
        }

        val newResolve = scope.async(start = CoroutineStart.LAZY) { resolveUncached() }
        var owned: InFlight? = null
        val activeResolve = mutex.withLock {
            if (!forceRefresh) {
                getCachedLocked(cacheKey)?.let { cached ->
                    return@withLock null to cached
                }
            }
            val existing = inFlightResolves[cacheKey]
            if (existing != null && (!forceRefresh || existing.forced)) {
                existing.deferred to null
            } else {
                if (forceRefresh) resolvedCache.remove(cacheKey)
                val entry = InFlight(newResolve, forced = forceRefresh)
                inFlightResolves[cacheKey] = entry
                owned = entry
                newResolve to null
            }
        }
        activeResolve.second?.let {
            newResolve.cancel()
            return it
        }
        val deferred = activeResolve.first ?: return DirectDebridResolveResult.Error()
        val ownedEntry = owned
        if (ownedEntry == null) newResolve.cancel() else deferred.start()

        var result: DirectDebridResolveResult? = null
        try {
            result = deferred.await()
            return result
        } finally {
            if (ownedEntry != null) {
                mutex.withLock {
                    if (inFlightResolves[cacheKey] === ownedEntry) {
                        val success = result as? DirectDebridResolveResult.Success
                        if (success != null) {
                            resolvedCache[cacheKey] = CachedDirectDebridResolve(
                                result = success,
                                cachedAtMs = now(),
                            )
                        }
                        inFlightResolves.remove(cacheKey)
                    }
                }
            }
        }
    }

    suspend fun cached(cacheKey: String): DirectDebridResolveResult.Success? =
        mutex.withLock { getCachedLocked(cacheKey) }

    /** Drops the cached result only; an in-flight resolve for [cacheKey] is left alone. */
    suspend fun evict(cacheKey: String) {
        mutex.withLock { resolvedCache.remove(cacheKey) }
    }

    private fun getCachedLocked(cacheKey: String): DirectDebridResolveResult.Success? {
        val cached = resolvedCache[cacheKey] ?: return null
        val age = now() - cached.cachedAtMs
        return if (age in 0..DEBRID_RESOLVE_CACHE_TTL_MS) {
            cached.result
        } else {
            resolvedCache.remove(cacheKey)
            null
        }
    }
}

private data class CachedDirectDebridResolve(
    val result: DirectDebridResolveResult.Success,
    val cachedAtMs: Long,
)

sealed class DirectDebridPlayableResult {
    data class Success(val stream: StreamItem) : DirectDebridPlayableResult()
    data object MissingApiKey : DirectDebridPlayableResult()
    data object NotCached : DirectDebridPlayableResult()
    data object Stale : DirectDebridPlayableResult()

    // [message] is an optional step-specific diagnostic (BUG-21); null falls back to the
    // generic "Could not open this link." toast.
    data class Error(val message: String? = null) : DirectDebridPlayableResult()
}

sealed class DirectDebridResolveResult {
    data class Success(
        val url: String,
        val filename: String?,
        val videoSize: Long?,
    ) : DirectDebridResolveResult()

    data object MissingApiKey : DirectDebridResolveResult()
    data object NotCached : DirectDebridResolveResult()
    data object Stale : DirectDebridResolveResult()

    // [message] names the failing step plus the provider's own error code/detail when known
    // (BUG-21: the generic Error hid which of the four TorBox calls failed). Diagnostic
    // strings are intentionally English-only until the next localization sweep.
    data class Error(val message: String? = null) : DirectDebridResolveResult()
}

fun DirectDebridPlayableResult.toastMessage(): String? =
    when (this) {
        is DirectDebridPlayableResult.Success -> null
        DirectDebridPlayableResult.MissingApiKey ->
            resourceString("Connect an account in Settings.", StringKey.debrid_missing_api_key)
        DirectDebridPlayableResult.NotCached ->
            resourceString("Not cached on Torbox.", StringKey.debrid_not_cached)
        DirectDebridPlayableResult.Stale ->
            resourceString("This link expired. Refreshing results.", StringKey.debrid_stream_stale)
        is DirectDebridPlayableResult.Error ->
            message ?: resourceString("Could not open this link.", StringKey.debrid_resolve_failed)
    }

// Builds the step-specific failure for a TorBox call: which step, the HTTP status when it
// wasn't a 2xx, and TorBox's own `error` code + human `detail` from the response envelope
// (e.g. `BAD_TOKEN: Your token is invalid…`). Shared by both TorBox resolve paths.
internal fun torboxStepFailure(
    step: String,
    status: Int? = null,
    envelope: TorboxEnvelopeDto<*>? = null,
    exception: String? = null,
): DirectDebridResolveResult.Error {
    val parts = listOfNotNull(
        status?.takeIf { it !in 200..299 }?.let { "HTTP $it" },
        listOfNotNull(
            envelope?.error?.takeIf { it.isNotBlank() },
            (envelope?.detail ?: exception)?.takeIf { it.isNotBlank() }?.take(140),
        ).joinToString(": ").takeIf { it.isNotBlank() },
    ).joinToString(" · ")
    val suffix = if (parts.isBlank()) "" else " ($parts)"
    return DirectDebridResolveResult.Error("TorBox: $step failed$suffix")
}

private class LocalDebridAddonStreamResolver(
    private val fileSelector: TorboxFileSelector = TorboxFileSelector(),
    private val premiumizeFileSelector: PremiumizeDirectDownloadFileSelector = PremiumizeDirectDownloadFileSelector(),
    private val allDebridFileSelector: AllDebridFileSelector = AllDebridFileSelector(),
) {
    suspend fun resolve(stream: StreamItem, season: Int?, episode: Int?): DirectDebridResolveResult {
        val account = localTorrentResolveCredential() ?: return DirectDebridResolveResult.MissingApiKey
        val apiKey = account.apiKey.trim()

        val hash = stream.infoHash?.trim()?.lowercase()
        if (stream.debridCacheStatus?.state == StreamDebridCacheState.NOT_CACHED) {
            return DirectDebridResolveResult.NotCached
        }
        if (
            !hash.isNullOrBlank() &&
            stream.debridCacheStatus?.state != StreamDebridCacheState.CACHED &&
            account.provider.supports(DebridProviderCapability.LocalTorrentCacheCheck)
        ) {
            when (LocalDebridService.isCached(account, hash)) {
                false -> return DirectDebridResolveResult.NotCached
                true, null -> Unit
            }
        }

        val magnet = DebridMagnetBuilder.fromStream(stream)
            ?: return DirectDebridResolveResult.Stale
        val resolve = stream.toResolveMetadata(season, episode, account.provider.id)

        return when (account.provider.id) {
            DebridProviders.TORBOX_ID -> resolveTorbox(stream, resolve, apiKey, magnet, season, episode)
            DebridProviders.PREMIUMIZE_ID -> resolvePremiumizeDirectDownload(
                apiKey = apiKey,
                source = magnet,
                resolve = resolve,
                season = season,
                episode = episode,
                fallbackFilename = stream.behaviorHints.filename,
                fallbackSize = stream.behaviorHints.videoSize,
                fileSelector = premiumizeFileSelector,
            )
            DebridProviders.ALLDEBRID_ID -> resolveAllDebridMagnet(
                apiKey = apiKey,
                magnet = magnet,
                resolve = resolve,
                season = season,
                episode = episode,
                fallbackFilename = stream.behaviorHints.filename,
                fallbackSize = stream.behaviorHints.videoSize,
                fileSelector = allDebridFileSelector,
            )
            else -> DirectDebridResolveResult.Error()
        }
    }

    // BUG-21: every non-Success exit names its step — this chain had never been exercised
    // end-to-end, and the old mapping collapsed most failures into Stale ("link expired",
    // which also triggers a pointless result reload) or the bare generic Error.
    private suspend fun resolveTorbox(
        stream: StreamItem,
        resolve: StreamClientResolve,
        apiKey: String,
        magnet: String,
        season: Int?,
        episode: Int?,
    ): DirectDebridResolveResult {
        return try {
            val create = TorboxApiClient.createTorrent(apiKey = apiKey, magnet = magnet)
            DebridCredentialHealth.recordHttpStatus(DebridProviders.TORBOX_ID, create.status)
            val torrentId = create.body?.takeIf { it.success != false }?.data?.resolvedTorrentId()
                ?: return create.toFailureForCreate()

            val torrent = TorboxApiClient.getTorrent(apiKey = apiKey, id = torrentId)
            if (!torrent.isSuccessful) {
                return torboxStepFailure("fetching the file list", torrent.status, torrent.body)
            }
            val files = torrent.body?.data?.files.orEmpty()
            val file = fileSelector.selectFile(files, resolve, season, episode)
                ?: return torboxStepFailure("finding a matching video file (of ${files.size})")
            val fileId = file.id
                ?: return torboxStepFailure("finding the selected file's id")

            val link = TorboxApiClient.requestDownloadLink(
                apiKey = apiKey,
                torrentId = torrentId,
                fileId = fileId,
            )
            if (!link.isSuccessful) {
                return torboxStepFailure("requesting the download link", link.status, link.body)
            }
            val url = link.body?.data?.takeIf { it.isNotBlank() }
                ?: return torboxStepFailure("reading the download link (empty response)")

            DirectDebridResolveResult.Success(
                url = url,
                filename = file.displayName().takeIf { it.isNotBlank() }
                    ?: stream.behaviorHints.filename?.takeIf { it.isNotBlank() },
                videoSize = file.size ?: stream.behaviorHints.videoSize,
            )
        } catch (error: Exception) {
            if (error is CancellationException) throw error
            torboxStepFailure("network request", exception = error.message ?: error::class.simpleName)
        }
    }
}

private fun localTorrentResolveCredential(
    settings: DebridSettings = DebridSettingsRepository.snapshot(),
): DebridServiceCredential? =
    settings.activeResolverCredential
        ?.takeIf { credential -> credential.provider.supports(DebridProviderCapability.LocalTorrentResolve) }

// internal (not private) so DirectDebridResolverInvalidateTest can pin the key [resolve] and
// [DirectDebridPlaybackResolver.invalidate] share: the resolver's cache cannot be seeded without a
// live provider call.
internal fun StreamItem.debridResolveCacheKey(season: Int?, episode: Int?): String? {
    val resolve = clientResolve
    if (resolve == null && needsLocalDebridResolve) {
        val account = localTorrentResolveCredential() ?: return null
        val apiKey = account.apiKey.trim().takeIf { it.isNotBlank() } ?: return null
        val identity = infoHash ?: torrentMagnetUri ?: behaviorHints.filename ?: return null
        return listOf(
            account.provider.id,
            apiKey.stableFingerprint(),
            identity.trim().lowercase(),
            fileIdx?.toString().orEmpty(),
            behaviorHints.filename.orEmpty().trim().lowercase(),
            season?.toString().orEmpty(),
            episode?.toString().orEmpty(),
        ).joinToString("|")
    }
    resolve ?: return null
    val providerId = DebridProviders.byId(resolve.service)?.id ?: return null
    val settings = DebridSettingsRepository.snapshot()
    if (providerId != settings.activeResolverProviderId) return null
    val apiKey = settings
        .apiKeyFor(providerId)
        .trim()
        .takeIf { it.isNotBlank() }
        ?: return null
    val identity = resolve.infoHash
        ?: resolve.magnetUri
        ?: resolve.torrentName
        ?: resolve.filename
        ?: return null

    return listOf(
        providerId,
        apiKey.stableFingerprint(),
        identity.trim().lowercase(),
        resolve.fileIdx?.toString().orEmpty(),
        (resolve.filename ?: behaviorHints.filename).orEmpty().trim().lowercase(),
        (season ?: resolve.season)?.toString().orEmpty(),
        (episode ?: resolve.episode)?.toString().orEmpty(),
    ).joinToString("|")
}

private fun StreamItem.toResolveMetadata(season: Int?, episode: Int?, providerId: String): StreamClientResolve =
    StreamClientResolve(
        type = "torrent",
        infoHash = infoHash,
        fileIdx = fileIdx,
        magnetUri = torrentMagnetUri,
        sources = sources,
        filename = behaviorHints.filename,
        season = season,
        episode = episode,
        service = providerId,
        isCached = debridCacheStatus?.state == StreamDebridCacheState.CACHED,
    )

// BUG-21: 409 keeps its NotCached meaning; everything else (auth failures, plan limits,
// success=false envelopes, unexpected shapes) surfaces TorBox's own error code + detail
// instead of the old blanket Stale/Error split that hid which call failed.
private fun DebridApiResponse<TorboxEnvelopeDto<TorboxCreateTorrentDataDto>>.toFailureForCreate(): DirectDebridResolveResult =
    when (status) {
        409 -> DirectDebridResolveResult.NotCached
        else -> torboxStepFailure("adding the item", status, body)
    }

private fun String.stableFingerprint(): String {
    val hash = fold(1125899906842597L) { acc, char -> (acc * 31L) + char.code }
    return hash.toULong().toString(16)
}

private fun StreamItem.withResolvedDebridUrl(result: DirectDebridResolveResult.Success): StreamItem =
    copy(
        url = result.url,
        externalUrl = null,
        behaviorHints = behaviorHints.mergeResolvedDebridHints(result),
        debridResolved = true,
    )

private fun StreamBehaviorHints.mergeResolvedDebridHints(result: DirectDebridResolveResult.Success): StreamBehaviorHints =
    copy(
        filename = result.filename ?: filename,
        videoSize = result.videoSize ?: videoSize,
    )
