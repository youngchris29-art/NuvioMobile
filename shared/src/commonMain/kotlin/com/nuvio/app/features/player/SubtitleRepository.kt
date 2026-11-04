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

    // Dedupe state below (activeFetchJob, activeKey, activeExtras, fetchGeneration, hashJob,
    // hashAttemptKey) is MAIN-CONFINED: it is written only by `fetchAddonSubtitles*` and `clear()`,
    // which callers invoke on the main thread (every Swift call site does), and by the hash job,
    // which hops to Dispatchers.Main before touching it. Fetch jobs on Default only read
    // `fetchGeneration` to discard superseded results.
    private var activeFetchJob: Job? = null
    private var activeKey: String? = null
    // Extras of the active/completed fetch for `activeKey` — decides whether a second call for the
    // same content brings anything new (see `isRicherThan`).
    private var activeExtras: SubtitleRequestExtras? = null
    // Bumped per launched fetch, so a superseded job that slipped past cancellation can't publish.
    private var fetchGeneration = 0L

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

    fun fetchAddonSubtitles(type: String, videoId: String, extras: SubtitleRequestExtras?) {
        val key = requestKey(type, videoId)
        val sameContent = key == activeKey && (activeFetchJob?.isActive == true || _completedRequest.value == key)
        if (sameContent && !extras.isRicherThan(activeExtras)) return
        if (key != activeKey) {
            hashJob?.cancel()
            hashJob = null
            hashAttemptKey = null
        }
        val effectiveExtras = if (sameContent) extras.mergedOver(activeExtras) else extras
        activeKey = key
        activeExtras = effectiveExtras
        activeFetchJob?.cancel()
        val generation = ++fetchGeneration
        activeFetchJob = scope.launch {
            runFetch(key = key, type = type, videoId = videoId, extras = effectiveExtras, upgrade = sameContent, generation = generation)
        }
    }

    /**
     * [fetchAddonSubtitles] now with [extras], then — when [extras] has no hash and [sourceUrl]
     * is a hashable http(s) file — compute the OpenSubtitles hash from two 64 KiB range requests
     * and re-fetch with it (upstream `fetchAddonSubtitlesWithHashComputation`, made non-blocking:
     * the first results don't wait for the hash). A failed or timed-out hash just leaves the
     * first results in place. [sourceHeaders] go with the range requests (CDN Referer/UA).
     */
    fun fetchAddonSubtitlesWithHashComputation(
        type: String,
        videoId: String,
        extras: SubtitleRequestExtras?,
        sourceUrl: String,
        sourceHeaders: Map<String, String>,
    ) {
        fetchAddonSubtitles(type, videoId, extras)
        if (extras?.usableHash != null || activeExtras?.usableHash != null) return
        if (!isHashableSubtitleSource(sourceUrl)) return
        val key = requestKey(type, videoId)
        val attemptKey = "$key|$sourceUrl"
        if (attemptKey == hashAttemptKey) return
        hashJob?.cancel()
        hashAttemptKey = attemptKey
        hashJob = scope.launch {
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
                if (activeKey != key || hashAttemptKey != attemptKey) return@withContext
                log.d { "Video hash ${result.hash} (size ${result.fileSize}) for $key in ${hashStart.elapsedNow()}" }
                fetchAddonSubtitles(type, videoId, enriched)
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
        fun current() = fetchGeneration == generation
        val requestType = canonicalSubtitleType(type)
        val extraSegment = extras?.toPathSegment()
        _isLoading.value = true
        _error.value = null
        if (!upgrade) {
            _addonSubtitles.value = emptyList()
            if (_completedRequest.value != null) _completedRequest.value = null
        }

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
            if (!current()) return
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
            _completedRequest.value = key
            _isLoading.value = false
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
                        // Atomic CAS append — several addons can land at once. The generation
                        // check keeps a superseded fetch that slipped past cancellation from
                        // splicing a previous request's subtitles into the current list.
                        if (addonSubs.isNotEmpty() && current()) {
                            if (upgrade) collected.update { it + addonSubs }
                            else _addonSubtitles.update { it + addonSubs }
                        }
                    } catch (error: Throwable) {
                        if (error is CancellationException) throw error
                        log.w { "${addon.displayTitle}: subtitle fetch failed after ${addonStart.elapsedNow()} — $error" }
                    }
                }
            }.awaitAll()
        }

        if (!current()) return
        if (upgrade) {
            _addonSubtitles.value = mergeUpgradedSubtitles(collected.value, _addonSubtitles.value)
        }
        val total = _addonSubtitles.value.size
        log.d { "Subtitle fetch done: $total total in ${fetchStart.elapsedNow()}" }
        // Every addon here declared support for this type/id, so an empty list is a real miss.
        if (total == 0) {
            _error.value = resourceString(
                "No subtitles found",
                StringKey.compose_player_no_subtitles_found,
            )
        }
        _completedRequest.value = key
        _isLoading.value = false
    }

    fun clear() {
        activeFetchJob?.cancel()
        hashJob?.cancel()
        hashJob = null
        hashAttemptKey = null
        fetchGeneration++
        activeKey = null
        activeExtras = null
        _completedRequest.value = null
        _addonSubtitles.value = emptyList()
        _isLoading.value = false
        _error.value = null
    }
}

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
