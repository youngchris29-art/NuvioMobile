package com.nuvio.app.features.player

import com.nuvio.app.core.coroutines.uncaughtCoroutineLogger
import co.touchlab.kermit.Logger
import com.nuvio.app.features.addons.AddonRepository
import com.nuvio.app.features.addons.AddonResource
import com.nuvio.app.features.addons.buildAddonResourceUrl
import com.nuvio.app.features.addons.enabledAddons
import com.nuvio.app.features.addons.httpGetText
import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.Job
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asStateFlow
import kotlinx.coroutines.flow.first
import kotlinx.coroutines.flow.update
import kotlinx.coroutines.launch
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

    private var activeFetchJob: Job? = null
    private var activeKey: String? = null

    fun requestKey(type: String, videoId: String): String =
        "${canonicalSubtitleType(type)}|$videoId"

    fun fetchAddonSubtitles(type: String, videoId: String) {
        val key = requestKey(type, videoId)
        // The stream picker prefetches and the player kicks again for the same content — don't
        // cancel a fetch (or discard results) that already covers this request.
        if (key == activeKey && (activeFetchJob?.isActive == true || _completedRequest.value == key)) return
        activeKey = key
        activeFetchJob?.cancel()
        activeFetchJob = scope.launch {
            val requestType = canonicalSubtitleType(type)
            _isLoading.value = true
            _error.value = null
            _addonSubtitles.value = emptyList()
            if (_completedRequest.value != null) _completedRequest.value = null

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
            log.d { "Fetching subtitles type=$requestType id=$videoId across ${addons.size} enabled addons" }
            val allSubs = mutableListOf<AddonSubtitle>()

            for (addon in addons) {
                val manifest = addon.manifest
                if (manifest == null) {
                    log.d { "Skip ${addon.displayTitle}: no manifest" }
                    continue
                }
                val subtitleResource = manifest.resources.find { it.name.isSubtitleResourceName() }
                if (subtitleResource == null) {
                    log.d { "Skip ${addon.displayTitle}: no subtitles resource" }
                    continue
                }
                if (!subtitleResource.supportsSubtitleType(requestType, videoId)) {
                    log.d {
                        "Skip ${addon.displayTitle}: type/id mismatch (types=${subtitleResource.types} " +
                            "idPrefixes=${subtitleResource.idPrefixes} vs type=$requestType id=$videoId)"
                    }
                    continue
                }

                val subtitleUrl = buildAddonResourceUrl(
                    manifestUrl = manifest.transportUrl,
                    resource = "subtitles",
                    type = requestType,
                    id = videoId,
                )
                log.d { "Querying ${addon.displayTitle}: $subtitleUrl" }

                val addonStart = TimeSource.Monotonic.markNow()
                val before = allSubs.size
                try {
                    val response = withContext(Dispatchers.Default) {
                        httpGetText(subtitleUrl)
                    }
                    val parsed = json.parseToJsonElement(response).jsonObject
                    val subtitlesArray = parsed["subtitles"]?.jsonArray ?: continue

                    for (element in subtitlesArray) {
                        val obj = element.jsonObject
                        val id = obj.stringValue("id")
                            ?: "${manifest.id}_${allSubs.size}"
                        val url = obj.stringValue("url") ?: continue
                        val rawLang = obj.subtitleLanguage() ?: "unknown"
                        val normalizedLang = normalizeLanguageCode(rawLang) ?: rawLang

                        allSubs.add(
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
                    log.d { "${addon.displayTitle}: ${allSubs.size - before} subtitles in ${addonStart.elapsedNow()}" }
                } catch (error: Throwable) {
                    if (error is CancellationException) throw error
                    log.w { "${addon.displayTitle}: subtitle fetch failed after ${addonStart.elapsedNow()} — $error" }
                }
            }

            log.d { "Subtitle fetch done: ${allSubs.size} total in ${fetchStart.elapsedNow()}" }
            _addonSubtitles.value = allSubs
            if (allSubs.isEmpty() && addons.any { it.manifest?.resources?.any { r -> r.name.isSubtitleResourceName() } == true }) {
                _error.value = resourceString(
                    "No subtitles found",
                    StringKey.compose_player_no_subtitles_found,
                )
            }
            _completedRequest.value = key
            _isLoading.value = false
        }
    }

    fun clear() {
        activeFetchJob?.cancel()
        activeKey = null
        _completedRequest.value = null
        _addonSubtitles.value = emptyList()
        _isLoading.value = false
        _error.value = null
    }
}

private fun canonicalSubtitleType(type: String): String =
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
