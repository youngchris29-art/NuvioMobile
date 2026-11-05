package com.nuvio.app.features.player

import com.nuvio.app.core.coroutines.uncaughtCoroutineLogger
import co.touchlab.kermit.Logger
import com.nuvio.app.features.addons.AddonRepository
import com.nuvio.app.features.addons.AddonResource
import com.nuvio.app.features.addons.buildAddonResourceUrl
import com.nuvio.app.features.addons.enabledAddons
import com.nuvio.app.features.addons.fetchAddonResponseText
import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.Job
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.async
import kotlinx.coroutines.awaitAll
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asStateFlow
import kotlinx.coroutines.flow.first
import kotlinx.coroutines.flow.update
import kotlinx.coroutines.launch
import kotlinx.coroutines.supervisorScope
import kotlinx.coroutines.withContext
import kotlinx.coroutines.withTimeoutOrNull
import kotlinx.serialization.json.Json
import kotlinx.serialization.json.JsonArray
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.contentOrNull
import kotlinx.serialization.json.jsonArray
import kotlinx.serialization.json.jsonObject
import kotlinx.serialization.json.jsonPrimitive
import kotlin.time.TimeSource
import com.nuvio.app.core.i18n.StringKey
import com.nuvio.app.core.i18n.resourceString

object SubtitleRepository {
    private const val ADDON_READY_TIMEOUT_MS = 8_000L

    // Per-addon network budget for the parallel fetch below. This STACKS on the readiness wait
    // above — the wait runs first, then every addon gets its own 10s — so a cold start whose
    // addons never answer is ~18s worst case before the fetch reports completion.
    private const val ADDON_FETCH_TIMEOUT_MS = 10_000L

    private val kermit = Logger.withTag("SubtitleRepo")

    // Kermit goes to os_log on Apple targets, which the tvOS device console pipe
    // (devicectl --console) can't see — mirror to stdout so device runs are diagnosable.
    private object log {
        fun d(message: () -> String) {
            val text = message()
            kermit.d { text }
            println("[SubtitleRepo] $text")
        }
        fun w(message: () -> String) {
            val text = message()
            kermit.w { text }
            println("[SubtitleRepo] WARN $text")
        }
    }
    private val scope = CoroutineScope(SupervisorJob() + Dispatchers.Default + uncaughtCoroutineLogger("SubtitleRepository"))
    private val json = Json { ignoreUnknownKeys = true }

    private val _addonSubtitles = MutableStateFlow<List<AddonSubtitle>>(emptyList())
    val addonSubtitles: StateFlow<List<AddonSubtitle>> = _addonSubtitles.asStateFlow()

    private val _isLoading = MutableStateFlow(false)
    val isLoading: StateFlow<Boolean> = _isLoading.asStateFlow()

    private val _error = MutableStateFlow<String?>(null)
    val error: StateFlow<String?> = _error.asStateFlow()

    // Request key of the last COMPLETED fetch — state, not an edge, so a consumer that subscribes
    // after the fetch finished (or whose fetch call was deduplicated) still sees completion.
    private val _completedRequest = MutableStateFlow<String?>(null)
    val completedRequest: StateFlow<String?> = _completedRequest.asStateFlow()

    // Dedupe state below (activeFetchJob, upgradeJob, activeKey, activeExtras, activeSourceUrl,
    // hashJob, hashAttemptKey) is MAIN-CONFINED: it is written only by `fetchAddonSubtitles*` and
    // `clear()`, which callers invoke on the main thread (every Swift call site does), and by the
    // hash job, which hops to Dispatchers.Main before touching it. Fetch jobs publish through
    // `publish`, which hops to Main too, so the generation check and the write are one step
    // against a content switch or `clear()` (review r1).
    // Review r3: `clear()` can arrive off the main thread (account cleanup from the credential
    // observer on Default), so every state change and every publication holds this lock as well;
    // the Main hop keeps the ordering with the Swift callers, the lock makes the generation check
    // and the write one step against a `clear()` from anywhere. Reentrant.
    private val stateLock = kotlinx.atomicfu.locks.SynchronizedObject()
    private var activeFetchJob: Job? = null
    // Review r1: a hash upgrade runs beside the first fetch instead of cancelling it, so a fast
    // add-on's first answer and `completedRequest` never wait for the slowest re-query.
    private var upgradeJob: Job? = null
    private var activeKey: String? = null
    // Extras of the active/completed fetch for `activeKey` — decides whether a second call for the
    // same content brings anything new (see `isRicherThan`).
    private var activeExtras: SubtitleRequestExtras? = null
    // The stream the hash was asked for (URL plus its request headers, like the players' own
    // playback identity: the same endpoint with other headers can serve another file); another
    // source of the same title starts over, since a measured hash describes one file only
    // (review r1/r2).
    private var activeSourceIdentity: String? = null
    // Review r2: completion of the first fetch and of the upgrade, recorded on Main inside their
    // final publish; `isLoading` ends when both are done. (A job's `isActive` is not usable for
    // this: it stays true until the coroutine fully returns, after its final publish.)
    private var firstFetchDone = false
    private var upgradeDone = true
    // Bumped per content change and on clear(), so a job for the previous content can't publish.
    // Atomic: written on Main, read by fetch jobs on Default (K/N gives a plain var no visibility).
    private val contentGeneration = kotlinx.atomicfu.atomic(0L)

    private var hashJob: Job? = null
    // "<requestKey>|<sourceUrl>" of the last hash attempt (running or finished) — one attempt per
    // content + source, whatever the outcome; reset when the content changes or on clear().
    private var hashAttemptKey: String? = null

    fun requestKey(type: String, videoId: String): String =
        "${canonicalSubtitleType(type)}|$videoId"

    /**
     * Fetch add-on subtitles for [type]/[videoId], sending [extras] (filename / size / hash) as
     * the request's extra path segment when present.
     *
     * Deduplicated per content: a call for the content already fetched (or in flight) is a no-op
     * unless its extras carry something the previous request lacked (typically the video hash).
     * Such an upgrade re-queries every add-on in place: the current list and `completedRequest`
     * stay as they are until the richer results land, then the list is replaced by the new
     * results followed by any previous entries they don't repeat. `completedRequest` is always
     * the plain [requestKey], so the players' completion polling is unaffected by extras.
     */
    // Explicit overload rather than a default argument: the ObjC/Swift export drops defaults,
    // and the Swift call sites without extras keep calling `fetchAddonSubtitles(type:videoId:)`.
    fun fetchAddonSubtitles(type: String, videoId: String) = fetchAddonSubtitles(type, videoId, null)

    fun fetchAddonSubtitles(type: String, videoId: String, extras: SubtitleRequestExtras?) = kotlinx.atomicfu.locks.synchronized(stateLock) {
        val key = requestKey(type, videoId)
        val sameContent = key == activeKey &&
            (activeFetchJob?.isActive == true || upgradeJob?.isActive == true || _completedRequest.value == key)
        if (sameContent && !extras.isRicherThan(activeExtras)) return@synchronized
        if (!sameContent) {
            // New content: the previous jobs stop, and the state is cleared HERE, synchronously, so
            // an upgrade that follows at once never merges into the previous title's list.
            startNewContent(key, type, videoId, extras)
            return@synchronized
        }
        // Richer extras for the content in flight or shown: re-query beside the first fetch.
        val effectiveExtras = extras.mergedOver(activeExtras)
        activeExtras = effectiveExtras
        upgradeJob?.cancel()
        upgradeDone = false
        val generation = contentGeneration.value
        upgradeJob = scope.launch {
            runFetch(key = key, type = type, videoId = videoId, extras = effectiveExtras, upgrade = true, generation = generation)
        }
    }

    private fun startNewContent(key: String, type: String, videoId: String, extras: SubtitleRequestExtras?) {
        activeFetchJob?.cancel()
        upgradeJob?.cancel()
        upgradeJob = null
        hashJob?.cancel()
        hashJob = null
        hashAttemptKey = null
        activeSourceIdentity = null
        activeKey = key
        activeExtras = extras
        firstFetchDone = false
        upgradeDone = true
        val generation = contentGeneration.incrementAndGet()
        _addonSubtitles.value = emptyList()
        _error.value = null
        if (_completedRequest.value != null) _completedRequest.value = null
        _isLoading.value = true
        activeFetchJob = scope.launch {
            runFetch(key = key, type = type, videoId = videoId, extras = extras, upgrade = false, generation = generation)
        }
    }

    /**
     * [fetchAddonSubtitles] now with [extras], then — when [extras] has no hash and [sourceUrl]
     * is a hashable http(s) file — compute the OpenSubtitles hash from two 64 KiB range requests
     * and re-fetch with it (upstream `fetchAddonSubtitlesWithHashComputation`, made non-blocking:
     * the first results don't wait for the hash). A failed or timed-out hash just leaves the
     * first results in place. [sourceHeaders] go with the range requests (CDN Referer/UA).
     *
     * Review r1: another source of the same title (a failover, a manual switch) starts the
     * content over, because a hash measured on the first file describes that file only; a
     * declared hash ends any measurement still running.
     */
    fun fetchAddonSubtitlesWithHashComputation(
        type: String,
        videoId: String,
        extras: SubtitleRequestExtras?,
        sourceUrl: String,
        sourceHeaders: Map<String, String>,
    ) = kotlinx.atomicfu.locks.synchronized(stateLock) {
        val key = requestKey(type, videoId)
        val sourceIdentity = subtitleSourceIdentity(sourceUrl, sourceHeaders)
        if (key == activeKey && activeSourceIdentity != null && activeSourceIdentity != sourceIdentity) {
            log.d { "Source changed for $key — subtitles start over for the new file" }
            activeKey = null
        }
        fetchAddonSubtitles(type, videoId, extras)
        activeSourceIdentity = sourceIdentity
        val attemptKey = "$key|$sourceIdentity"
        if (extras?.usableHash != null) {
            // The stream declared its hash: nothing to measure, and a measurement in flight for
            // this title must not replace it later.
            hashJob?.cancel()
            hashJob = null
            hashAttemptKey = attemptKey
            return@synchronized
        }
        if (activeExtras?.usableHash != null) return@synchronized
        if (!isHashableSubtitleSource(sourceUrl)) return@synchronized
        if (attemptKey == hashAttemptKey) return@synchronized
        hashJob?.cancel()
        hashAttemptKey = attemptKey
        hashJob = scope.launch {
            // Review r4 (Opus stand-in): no subtitle-capable add-on, no hash — the two range GETs
            // would compete with the player for the stream host, and the re-query would find
            // nothing to ask. Waits for the add-on repository the way runFetch does.
            if (!subtitleAddonPresent()) {
                log.d { "No subtitle-capable addon for $key — skipping the video hash" }
                return@launch
            }
            val hashStart = TimeSource.Monotonic.markNow()
            val result = OpenSubtitlesHasher.compute(sourceUrl, sourceHeaders)
            if (result == null) {
                log.d { "Video hash unavailable for $key after ${hashStart.elapsedNow()} — keeping unhashed results" }
                return@launch
            }
            val enriched = (extras ?: SubtitleRequestExtras()).copy(
                videoHash = result.hash,
                // An add-on declared size wins over the measured one (upstream behaviour).
                videoSize = extras?.usableSize ?: result.fileSize,
            )
            // The dedupe state is main-confined (see the note on `activeKey`): the hash ran on
            // Default, the staleness check and the re-fetch happen back on Main.
            withContext(Dispatchers.Main) {
                kotlinx.atomicfu.locks.synchronized(stateLock) {
                    if (activeKey != key || hashAttemptKey != attemptKey) return@synchronized
                    log.d { "Video hash ${result.hash} (size ${result.fileSize}) for $key in ${hashStart.elapsedNow()}" }
                    fetchAddonSubtitles(type, videoId, enriched)
                }
            }
        }
    }

    /** True once the add-on repository is ready (bounded wait) and an enabled add-on declares a `subtitles` resource. */
    private suspend fun subtitleAddonPresent(): Boolean {
        withTimeoutOrNull(ADDON_READY_TIMEOUT_MS) {
            AddonRepository.initializedState.first { it }
            AddonRepository.uiState.first { state ->
                state.addons.enabledAddons().none { it.manifest == null && it.isRefreshing }
            }
        }
        return AddonRepository.uiState.value.addons.enabledAddons().any { addon ->
            addon.manifest?.resources?.any { it.name.isSubtitleResourceName() } == true
        }
    }

    /**
     * Review r1: every write a fetch job makes goes through here, on Main, after the generation
     * check — the same thread `clear()` and a content switch run on, so a job for the previous
     * content can neither append to the new list nor mark it complete.
     */
    private suspend fun publish(generation: Long, write: () -> Unit) {
        withContext(Dispatchers.Main) {
            kotlinx.atomicfu.locks.synchronized(stateLock) {
                if (contentGeneration.value == generation) write()
            }
        }
    }

    private suspend fun runFetch(
        key: String,
        type: String,
        videoId: String,
        extras: SubtitleRequestExtras?,
        upgrade: Boolean,
        generation: Long,
    ) {
        fun current() = contentGeneration.value == generation
        val requestType = canonicalSubtitleType(type)
        val extraSegment = extras?.toPathSegment()
        if (upgrade) publish(generation) { _isLoading.value = true }

        val fetchStart = TimeSource.Monotonic.markNow()
        // The player can outrun addon bootstrap (cold launch straight into playback, debug
        // harness): wait briefly for the repository to initialize and manifest refreshes to
        // settle instead of snapshotting an empty/partial list. No-op once the app is warm.
        withTimeoutOrNull(ADDON_READY_TIMEOUT_MS) {
            AddonRepository.initializedState.first { it }
            AddonRepository.uiState.first { state ->
                state.addons.enabledAddons().none { it.manifest == null && it.isRefreshing }
            }
        } ?: log.w { "Addon repository not ready after ${ADDON_READY_TIMEOUT_MS}ms — fetching with current snapshot" }
        val addons = AddonRepository.uiState.value.addons.enabledAddons()
        log.d {
            "Fetching subtitles type=$requestType id=$videoId extras=${extraSegment ?: "none"}" +
                "${if (upgrade) " (upgrade)" else ""} across ${addons.size} enabled addons"
        }

        val subtitleAddons = addons.filter { addon ->
            val manifest = addon.manifest
            if (manifest == null) {
                log.d { "Skip ${addon.displayTitle}: no manifest" }
                return@filter false
            }
            val subtitleResource = manifest.resources.find { it.name.isSubtitleResourceName() }
            if (subtitleResource == null) {
                log.d { "Skip ${addon.displayTitle}: no subtitles resource" }
                return@filter false
            }
            if (!subtitleResource.supportsSubtitleType(requestType, videoId)) {
                log.d {
                    "Skip ${addon.displayTitle}: type/id mismatch (types=${subtitleResource.types} " +
                        "idPrefixes=${subtitleResource.idPrefixes} vs type=$requestType id=$videoId)"
                }
                return@filter false
            }
            true
        }

        if (subtitleAddons.isEmpty()) {
            log.d { "No subtitle-capable addon for type=$requestType id=$videoId — nothing to query" }
            publish(generation) {
                // An addon that declares a subtitles resource but doesn't cover this type/id is
                // still a real empty result, so keep the fork's user-visible message for it.
                if (_addonSubtitles.value.isEmpty() &&
                    addons.any { it.manifest?.resources?.any { r -> r.name.isSubtitleResourceName() } == true }
                ) {
                    _error.value = resourceString(
                        "No subtitles found",
                        StringKey.compose_player_no_subtitles_found,
                    )
                }
                // Terminal path — both tvOS players poll `completedRequest`
                // (NativePlaybackCoordinator.subsFetchCompleted, MPVPlayerView's prefetch
                // side-load). Returning without setting it hangs the native player's subtitle wait.
                if (!upgrade) _completedRequest.value = key
                finishLoading(upgrade)
            }
            return
        }

        // An upgrade collects privately and publishes once at the end, so the list the players
        // already show never shrinks mid-fetch.
        val collected = MutableStateFlow<List<AddonSubtitle>>(emptyList())

        // One coroutine per addon: a slow/dead addon no longer delays the ones behind it, and
        // each addon's results are published as they land instead of at the very end.
        supervisorScope {
            subtitleAddons.map { addon ->
                async {
                    val manifest = addon.manifest ?: return@async
                    val subtitleUrl = buildAddonResourceUrl(
                        manifestUrl = manifest.transportUrl,
                        resource = "subtitles",
                        type = requestType,
                        id = videoId,
                        extraPathSegment = extraSegment,
                    )
                    log.d { "Querying ${addon.displayTitle}: $subtitleUrl" }

                    val addonStart = TimeSource.Monotonic.markNow()
                    try {
                        val response = withTimeoutOrNull(ADDON_FETCH_TIMEOUT_MS) {
                            withContext(Dispatchers.Default) {
                                fetchAddonResponseText(subtitleUrl)
                            }
                        }
                        if (response == null) {
                            log.w {
                                "${addon.displayTitle}: subtitle fetch timed out after " +
                                    "${addonStart.elapsedNow()} (budget ${ADDON_FETCH_TIMEOUT_MS}ms)"
                            }
                            return@async
                        }

                        val parsed = json.parseToJsonElement(response).jsonObject
                        val subtitlesArray = parsed["subtitles"]?.jsonArray
                        if (subtitlesArray == null) {
                            log.d { "${addon.displayTitle}: response has no subtitles array" }
                            return@async
                        }

                        val addonSubs = mutableListOf<AddonSubtitle>()
                        for (element in subtitlesArray) {
                            val obj = element.jsonObject
                            val id = obj.stringValue("id")
                                ?: "${manifest.id}_${addonSubs.size}"
                            val url = obj.stringValue("url") ?: continue
                            val rawLang = obj.subtitleLanguage() ?: "unknown"
                            val normalizedLang = normalizeLanguageCode(rawLang) ?: rawLang

                            addonSubs.add(
                                AddonSubtitle(
                                    id = id,
                                    url = url,
                                    language = normalizedLang,
                                    display = run {
                                        val languageLabel =
                                            SubtitleLanguageLabelProvider.labeler.label(rawLang)
                                        resourceString(
                                            "$languageLabel (${addon.displayTitle})",
                                            StringKey.player_addon_subtitle_display_format,
                                            languageLabel,
                                            addon.displayTitle,
                                        )
                                    },
                                    addonName = addon.displayTitle,
                                )
                            )
                        }

                        log.d { "${addon.displayTitle}: ${addonSubs.size} subtitles in ${addonStart.elapsedNow()}" }
                        // Published on Main after the generation check (review r1), so a fetch for
                        // the previous content can't splice its subtitles into the current list.
                        // The first fetch appends what the list doesn't hold yet (an upgrade for
                        // the same content may have published the same URLs already).
                        if (addonSubs.isNotEmpty()) {
                            if (upgrade) collected.update { it + addonSubs }
                            else publish(generation) {
                                _addonSubtitles.update { it + addonSubs.filter { sub -> it.none { have -> have.url == sub.url } } }
                            }
                        }
                    } catch (error: Throwable) {
                        if (error is CancellationException) throw error
                        log.w { "${addon.displayTitle}: subtitle fetch failed after ${addonStart.elapsedNow()} — $error" }
                    }
                }
            }.awaitAll()
        }

        if (!current()) return
        publish(generation) {
            if (upgrade) {
                _addonSubtitles.value = mergeUpgradedSubtitles(collected.value, _addonSubtitles.value)
            }
            val total = _addonSubtitles.value.size
            log.d { "Subtitle fetch done${if (upgrade) " (upgrade)" else ""}: $total total in ${fetchStart.elapsedNow()}" }
            // Every addon here declared support for this type/id, so an empty list is a real miss.
            if (total == 0) {
                _error.value = resourceString(
                    "No subtitles found",
                    StringKey.compose_player_no_subtitles_found,
                )
            } else if (_error.value != null) {
                _error.value = null
            }
            // Review r3: only the first fetch completes the request for the players' polling (Aether
            // decides its auto-selection on that signal and never revisits it); an upgrade only
            // refines the list, whether it finishes before or after.
            if (!upgrade) _completedRequest.value = key
            finishLoading(upgrade)
        }
    }

    /** Main-confined: loading ends once the first fetch and any upgrade have both finished. */
    private fun finishLoading(fromUpgrade: Boolean) {
        if (fromUpgrade) upgradeDone = true else firstFetchDone = true
        if (firstFetchDone && upgradeDone) _isLoading.value = false
    }

    fun clear() = kotlinx.atomicfu.locks.synchronized(stateLock) {
        activeFetchJob?.cancel()
        upgradeJob?.cancel()
        upgradeJob = null
        hashJob?.cancel()
        hashJob = null
        hashAttemptKey = null
        contentGeneration.incrementAndGet()
        activeKey = null
        activeExtras = null
        activeSourceIdentity = null
        firstFetchDone = false
        upgradeDone = true
        _completedRequest.value = null
        _addonSubtitles.value = emptyList()
        _isLoading.value = false
        _error.value = null
    }
}

/**
 * Review r2: what tells one stream from another for the hash — the URL and its request headers
 * (sorted, so order never matters), joined with separators `sanitizePlaybackHeaders` never lets
 * through. The same endpoint with other authorization or routing headers can be another file.
 */
internal fun subtitleSourceIdentity(sourceUrl: String, headers: Map<String, String>): String =
    headers.entries.sortedBy { it.key.lowercase() }
        .joinToString(separator = "\u001E", prefix = "$sourceUrl\u001F") { "${it.key.lowercase()}\u001F${it.value}" }

/** Upgrade results first (hash-matched releases lead), then earlier entries not repeated by URL. */
internal fun mergeUpgradedSubtitles(
    upgraded: List<AddonSubtitle>,
    previous: List<AddonSubtitle>,
): List<AddonSubtitle> {
    if (previous.isEmpty()) return upgraded
    val seen = upgraded.mapTo(HashSet()) { it.url }
    return upgraded + previous.filter { seen.add(it.url) }
}

internal fun canonicalSubtitleType(type: String): String =
    if (type.equals("tv", ignoreCase = true)) "series" else type.lowercase()

private fun String.isSubtitleResourceName(): Boolean =
    equals("subtitles", ignoreCase = true) || equals("subtitle", ignoreCase = true)

private fun AddonResource.supportsSubtitleType(type: String, videoId: String): Boolean {
    val canonical = canonicalSubtitleType(type)
    val typeMatches = types.isEmpty() || types.any { canonicalSubtitleType(it).equals(canonical, ignoreCase = true) }
    if (!typeMatches) return false
    return idPrefixes.isEmpty() || idPrefixes.any { prefix -> videoId.startsWith(prefix) }
}

private fun JsonObject.subtitleLanguage(): String? =
    stringValue("lang")
        ?: stringValue("language")
        ?: stringValue("languageCode")
        ?: stringValue("locale")
        ?: stringValue("label")

private fun JsonObject.stringValue(name: String): String? =
    this[name]
        ?.jsonPrimitive
        ?.contentOrNull
        ?.trim()
        ?.takeIf { it.isNotBlank() }
