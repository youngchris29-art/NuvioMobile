package com.nuvio.app.features.trailer

import co.touchlab.kermit.Logger
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.withContext
import kotlinx.coroutines.withTimeout
import kotlinx.serialization.json.Json
import kotlinx.serialization.json.JsonArray
import kotlinx.serialization.json.JsonElement
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.JsonPrimitive

internal const val TRAILER_EXTRACTOR_TAG = "InAppYouTubeExtractor"
internal const val TRAILER_REQUEST_TIMEOUT_MS = 20_000L

/**
 * Ceiling on a whole extraction. `internal` (it was file-private) so [HeroTrailerResolver] can name
 * it as the default for callers that don't impose a shorter deadline of their own — BUG-46/B4.
 */
internal const val TRAILER_EXTRACTOR_TIMEOUT_MS = 30_000L
private const val PREFERRED_SEPARATE_CLIENT = "android_vr"

private val VIDEO_ID_REGEX = Regex("^[a-zA-Z0-9_-]{11}$")
private val API_KEY_REGEX = Regex("\"INNERTUBE_API_KEY\":\"([^\"]+)\"")
private val VISITOR_DATA_REGEX = Regex("\"VISITOR_DATA\":\"([^\"]+)\"")
private val QUALITY_LABEL_REGEX = Regex("(\\d{2,4})p")
private val CODECS_REGEX = Regex("codecs=\"([^\"]+)\"")

private data class YouTubeClient(
    val key: String,
    val id: String,
    val version: String,
    val userAgent: String,
    val context: JsonObject,
    val priority: Int,
)

private data class WatchConfig(
    val apiKey: String?,
    val visitorData: String?,
)

internal data class StreamCandidate(
    val client: String,
    val priority: Int,
    val url: String,
    val score: Double,
    val hasN: Boolean,
    val height: Int,
    val fps: Int,
    val ext: String,
    /** RFC 6381 codec string parsed from the mimeType (empty when absent). */
    val codecs: String = "",
    val bitrateBps: Long = 0,
    val width: Int = 0,
    val durationMs: Long = 0,
    /** Inclusive byte ranges for the fMP4 header (ftyp+moov) and sidx index; -1 when absent. */
    val initStart: Long = -1,
    val initEnd: Long = -1,
    val indexStart: Long = -1,
    val indexEnd: Long = -1,
) {
    /** True when the stream is a demuxed fMP4 with the ranges local HLS repackaging needs. */
    val hasSegmentRanges: Boolean
        get() = initStart >= 0 && initEnd > initStart && indexStart > initEnd && indexEnd > indexStart
}

private data class ManifestBestVariant(
    val url: String,
    val width: Int,
    val height: Int,
    val bandwidth: Long,
)

internal data class ManifestCandidate(
    val client: String,
    val priority: Int,
    val manifestUrl: String,
    val selectedVariantUrl: String,
    val height: Int,
    val bandwidth: Long,
)

internal data class TrailerRequestResponse(
    val ok: Boolean,
    val status: Int,
    val statusText: String,
    val url: String,
    val body: String,
)

private val JSON = Json { ignoreUnknownKeys = true }

private val CLIENTS = listOf(
    YouTubeClient(
        key = "android_vr",
        id = "28",
        version = "1.56.21",
        userAgent = "com.google.android.apps.youtube.vr.oculus/1.56.21 " +
            "(Linux; U; Android 12; en_US; Quest 3; Build/SQ3A.220605.009.A1) gzip",
        context = jsonObjectOf(
            "clientName" to "ANDROID_VR",
            "clientVersion" to "1.56.21",
            "deviceMake" to "Oculus",
            "deviceModel" to "Quest 3",
            "osName" to "Android",
            "osVersion" to "12",
            "platform" to "MOBILE",
            "androidSdkVersion" to 32,
            "hl" to "en",
            "gl" to "US",
        ),
        priority = 0,
    ),
    YouTubeClient(
        key = "android",
        id = "3",
        version = "20.10.35",
        userAgent = "com.google.android.youtube/20.10.35 (Linux; U; Android 14; en_US) gzip",
        context = jsonObjectOf(
            "clientName" to "ANDROID",
            "clientVersion" to "20.10.35",
            "osName" to "Android",
            "osVersion" to "14",
            "platform" to "MOBILE",
            "androidSdkVersion" to 34,
            "hl" to "en",
            "gl" to "US",
        ),
        priority = 1,
    ),
    YouTubeClient(
        key = "ios",
        id = "5",
        version = "20.10.1",
        userAgent = "com.google.ios.youtube/20.10.1 (iPhone16,2; U; CPU iOS 17_4 like Mac OS X)",
        context = jsonObjectOf(
            "clientName" to "IOS",
            "clientVersion" to "20.10.1",
            "deviceModel" to "iPhone16,2",
            "osName" to "iPhone",
            "osVersion" to "17.4.0.21E219",
            "platform" to "MOBILE",
            "hl" to "en",
            "gl" to "US",
        ),
        priority = 2,
    ),
)

class InAppYouTubeExtractor {
    private val log = Logger.withTag(TRAILER_EXTRACTOR_TAG)

    /**
     * [timeoutMillis] lets a caller impose a deadline shorter than [TRAILER_EXTRACTOR_TIMEOUT_MS];
     * it can never *raise* the ceiling (BUG-46/B4 — the tvOS inline card gives up at 15s, and an
     * extraction that outlives the caller only competes with the next one). Defaulted, so the
     * mobile flavor resolver's existing single-argument call is unchanged.
     */
    suspend fun extractPlaybackSource(
        youtubeUrl: String,
        timeoutMillis: Long = TRAILER_EXTRACTOR_TIMEOUT_MS,
    ): TrailerPlaybackSource? = withContext(Dispatchers.Default) {
        if (youtubeUrl.isBlank()) return@withContext null

        runCatching {
            withTimeout(timeoutMillis.coerceIn(1L, TRAILER_EXTRACTOR_TIMEOUT_MS)) {
                extractPlaybackSourceInternal(youtubeUrl)
            }
        }.onFailure {
            log.w { "Trailer extractor failed for $youtubeUrl: ${it.message}" }
        }.getOrNull()
    }

    private suspend fun extractPlaybackSourceInternal(youtubeUrl: String): TrailerPlaybackSource? {
        val videoId = extractVideoId(youtubeUrl) ?: return null

        val watchUrl = "https://www.youtube.com/watch?v=$videoId&hl=en"
        val watchResponse = TrailerExtractionPlatform.performRequest(
            url = watchUrl,
            method = "GET",
            headers = TrailerExtractionPlatform.defaultHeaders,
            body = null,
            timeoutMillis = TRAILER_REQUEST_TIMEOUT_MS,
        )
        if (!watchResponse.ok) {
            throw IllegalStateException("Failed to fetch watch page (${watchResponse.status})")
        }

        val watchConfig = getWatchConfig(watchResponse.body)
        val apiKey = watchConfig.apiKey
            ?: throw IllegalStateException("Unable to extract INNERTUBE_API_KEY")

        val progressive = mutableListOf<StreamCandidate>()
        val adaptiveVideo = mutableListOf<StreamCandidate>()
        val adaptiveAudio = mutableListOf<StreamCandidate>()
        val manifestUrls = mutableListOf<Triple<String, Int, String>>()

        for (client in CLIENTS) {
            runCatching {
                val playerResponse = fetchPlayerResponse(
                    apiKey = apiKey,
                    videoId = videoId,
                    client = client,
                    visitorData = watchConfig.visitorData,
                )

                val streamingData = playerResponse.objectValue("streamingData")
                if (streamingData == null) {
                    val status = playerResponse.objectValue("playabilityStatus")
                    trailerDebugLog(
                        "client=${client.key} NO streamingData " +
                            "(playability=${status?.stringValue("status")} " +
                            "reason=${status?.stringValue("reason")?.take(60)})"
                    )
                    return@runCatching
                }
                val hlsManifestUrl = streamingData.stringValue("hlsManifestUrl")
                trailerDebugLog(
                    "client=${client.key} video=$videoId hls=${!hlsManifestUrl.isNullOrBlank()} " +
                        "formats=${streamingData.listObjectValue("formats").size} " +
                        "adaptive=${streamingData.listObjectValue("adaptiveFormats").size} " +
                        "sdKeys=${streamingData.keys.joinToString(",")}"
                )
                if (!hlsManifestUrl.isNullOrBlank()) {
                    manifestUrls += Triple(client.key, client.priority, hlsManifestUrl)
                }

                for (format in streamingData.listObjectValue("formats")) {
                    val url = format.stringValue("url") ?: continue
                    val mimeType = format.stringValue("mimeType").orEmpty()
                    if (!mimeType.contains("video/") && mimeType.isNotBlank()) continue

                    val height = (
                        format.numberValue("height")
                            ?: parseQualityLabel(format.stringValue("qualityLabel"))?.toDouble()
                            ?: 0.0
                        ).toInt()
                    val fps = (format.numberValue("fps") ?: 0.0).toInt()
                    val bitrate = format.numberValue("bitrate")
                        ?: format.numberValue("averageBitrate")
                        ?: 0.0

                    progressive += StreamCandidate(
                        client = client.key,
                        priority = client.priority,
                        url = url,
                        score = videoScore(height, fps, bitrate),
                        hasN = hasNParam(url),
                        height = height,
                        fps = fps,
                        ext = if (mimeType.contains("webm")) "webm" else "mp4",
                    )
                }

                for (format in streamingData.listObjectValue("adaptiveFormats")) {
                    val url = format.stringValue("url") ?: continue
                    val mimeType = format.stringValue("mimeType").orEmpty()
                    val hasVideo = mimeType.contains("video/")
                    val hasAudio = mimeType.contains("audio/") || mimeType.startsWith("audio/")

                    if (hasVideo) {
                        val height = (
                            format.numberValue("height")
                                ?: parseQualityLabel(format.stringValue("qualityLabel"))?.toDouble()
                                ?: 0.0
                            ).toInt()
                        val fps = (format.numberValue("fps") ?: 0.0).toInt()
                        val bitrate = format.numberValue("bitrate")
                            ?: format.numberValue("averageBitrate")
                            ?: 0.0

                        adaptiveVideo += StreamCandidate(
                            client = client.key,
                            priority = client.priority,
                            url = url,
                            score = videoScore(height, fps, bitrate),
                            hasN = hasNParam(url),
                            height = height,
                            fps = fps,
                            ext = if (mimeType.contains("webm")) "webm" else "mp4",
                            codecs = parseCodecs(mimeType),
                            bitrateBps = bitrate.toLong(),
                            width = (format.numberValue("width") ?: 0.0).toInt(),
                            durationMs = format.stringValue("approxDurationMs")?.toLongOrNull() ?: 0,
                            initStart = rangeValue(format, "initRange", "start"),
                            initEnd = rangeValue(format, "initRange", "end"),
                            indexStart = rangeValue(format, "indexRange", "start"),
                            indexEnd = rangeValue(format, "indexRange", "end"),
                        )
                    } else if (hasAudio) {
                        val bitrate = format.numberValue("bitrate")
                            ?: format.numberValue("averageBitrate")
                            ?: 0.0
                        val audioSampleRate = format.numberValue("audioSampleRate") ?: 0.0

                        adaptiveAudio += StreamCandidate(
                            client = client.key,
                            priority = client.priority,
                            url = url,
                            score = audioScore(bitrate, audioSampleRate),
                            hasN = hasNParam(url),
                            height = 0,
                            fps = 0,
                            ext = if (mimeType.contains("webm")) "webm" else "m4a",
                            codecs = parseCodecs(mimeType),
                            bitrateBps = bitrate.toLong(),
                            durationMs = format.stringValue("approxDurationMs")?.toLongOrNull() ?: 0,
                            initStart = rangeValue(format, "initRange", "start"),
                            initEnd = rangeValue(format, "initRange", "end"),
                            indexStart = rangeValue(format, "indexRange", "start"),
                            indexEnd = rangeValue(format, "indexRange", "end"),
                        )
                    }
                }
            }.onFailure {
                trailerDebugLog("client=${client.key} REQUEST FAILED: ${it.message?.take(80)}")
            }
        }

        if (manifestUrls.isEmpty() && progressive.isEmpty() && adaptiveVideo.isEmpty() && adaptiveAudio.isEmpty()) {
            return null
        }

        var bestManifest: ManifestCandidate? = null
        for ((clientKey, priority, manifestUrl) in manifestUrls) {
            runCatching {
                val variant = parseHlsManifest(manifestUrl)
                if (variant == null) {
                    trailerDebugLog("manifest client=$clientKey parsed but no variants")
                    return@runCatching
                }
                trailerDebugLog("manifest client=$clientKey top variant ${variant.width}x${variant.height}")
                val candidate = ManifestCandidate(
                    client = clientKey,
                    priority = priority,
                    manifestUrl = manifestUrl,
                    selectedVariantUrl = variant.url,
                    height = variant.height,
                    bandwidth = variant.bandwidth,
                )
                if (
                    bestManifest == null ||
                    candidate.height > bestManifest.height ||
                    (candidate.height == bestManifest.height && candidate.bandwidth > bestManifest.bandwidth)
                ) {
                    bestManifest = candidate
                }
            }.onFailure {
                trailerDebugLog("manifest client=$clientKey FETCH/PARSE FAILED: ${it.message?.take(80)}")
            }
        }

        val bestProgressive = sortCandidates(progressive).firstOrNull()
        trailerDebugLog(
            "selection: manifest=${bestManifest?.height ?: "none"} " +
                "progressive=${bestProgressive?.height ?: "none"} " +
                "(manifests collected=${manifestUrls.size})"
        )
        val bestVideo = pickBestForClient(adaptiveVideo, PREFERRED_SEPARATE_CLIENT)
        val bestAudio = pickBestForClient(adaptiveAudio, PREFERRED_SEPARATE_CLIENT)

        // AVPlayer-decodable demuxed pair for local HLS repackaging (SABR fallback): H.264 fMP4
        // video + AAC fMP4 audio, both with init/index ranges. Audio prefers the video's client so
        // the pair shares one CDN session shape.
        val bestAvcVideo = pickBestForClient(
            adaptiveVideo.filter { it.ext == "mp4" && it.codecs.startsWith("avc1") && it.hasSegmentRanges },
            PREFERRED_SEPARATE_CLIENT,
        )
        val bestM4aAudio = bestAvcVideo?.let { video ->
            pickBestForClient(
                adaptiveAudio.filter { it.ext == "m4a" && it.codecs.startsWith("mp4a") && it.hasSegmentRanges },
                video.client,
            )
        }
        trailerDebugLog(
            "repack candidates: avcVideo=${bestAvcVideo?.let { "${it.height}p ${it.codecs} (${it.client})" } ?: "none"} " +
                "m4aAudio=${bestM4aAudio?.let { "${it.codecs} (${it.client})" } ?: "none"}"
        )

        return TrailerExtractionPlatform.buildPlaybackSource(
            bestManifest = bestManifest,
            bestProgressive = bestProgressive,
            bestVideo = bestVideo,
            bestAudio = bestAudio,
            bestAvcVideo = bestAvcVideo,
            bestM4aAudio = bestM4aAudio,
        )
    }

    private suspend fun fetchPlayerResponse(
        apiKey: String,
        videoId: String,
        client: YouTubeClient,
        visitorData: String?,
    ): JsonObject {
        val endpoint = "https://www.youtube.com/youtubei/v1/player?key=${encodeUrlComponent(apiKey)}"

        val headers = buildMap {
            putAll(TrailerExtractionPlatform.defaultHeaders)
            put("content-type", "application/json")
            put("origin", "https://www.youtube.com")
            put("x-youtube-client-name", client.id)
            put("x-youtube-client-version", client.version)
            put("user-agent", client.userAgent)
            if (!visitorData.isNullOrBlank()) put("x-goog-visitor-id", visitorData)
        }

        val payload = jsonObjectOf(
            "videoId" to videoId,
            "contentCheckOk" to true,
            "racyCheckOk" to true,
            "context" to jsonObjectOf("client" to client.context),
            "playbackContext" to jsonObjectOf(
                "contentPlaybackContext" to jsonObjectOf("html5Preference" to "HTML5_PREF_WANTS"),
            ),
        )

        val response = TrailerExtractionPlatform.performRequest(
            url = endpoint,
            method = "POST",
            headers = headers,
            body = payload.toString(),
            timeoutMillis = TRAILER_REQUEST_TIMEOUT_MS,
        )

        if (!response.ok) {
            val preview = response.body.take(200)
            throw IllegalStateException("player API ${client.key} failed (${response.status}): $preview")
        }

        val parsed = JSON.parseToJsonElement(response.body)
        return parsed as? JsonObject ?: JsonObject(emptyMap())
    }

    private suspend fun parseHlsManifest(manifestUrl: String): ManifestBestVariant? {
        val response = TrailerExtractionPlatform.performRequest(
            url = manifestUrl,
            method = "GET",
            headers = TrailerExtractionPlatform.defaultHeaders,
            body = null,
            timeoutMillis = TRAILER_REQUEST_TIMEOUT_MS,
        )
        if (!response.ok) {
            throw IllegalStateException("Failed to fetch HLS manifest (${response.status})")
        }

        val lines = response.body
            .lineSequence()
            .map { it.trim() }
            .filter { it.isNotBlank() }
            .toList()

        var bestVariant: ManifestBestVariant? = null
        for (index in lines.indices) {
            val line = lines[index]
            if (!line.startsWith("#EXT-X-STREAM-INF:")) continue

            val attrs = parseHlsAttributeList(line)
            val nextLine = lines.getOrNull(index + 1) ?: continue
            if (nextLine.startsWith("#")) continue

            val resolution = attrs["RESOLUTION"].orEmpty()
            val (width, height) = parseResolution(resolution)
            val bandwidth = attrs["BANDWIDTH"]?.toLongOrNull() ?: 0L

            val candidate = ManifestBestVariant(
                url = absolutizeUrl(manifestUrl, nextLine),
                width = width,
                height = height,
                bandwidth = bandwidth,
            )

            if (
                bestVariant == null ||
                candidate.height > bestVariant.height ||
                (candidate.height == bestVariant.height && candidate.bandwidth > bestVariant.bandwidth) ||
                (
                    candidate.height == bestVariant.height &&
                        candidate.bandwidth == bestVariant.bandwidth &&
                        candidate.width > bestVariant.width
                    )
            ) {
                bestVariant = candidate
            }
        }

        return bestVariant
    }

    private fun extractVideoId(input: String): String? {
        val trimmed = input.trim()
        if (VIDEO_ID_REGEX.matches(trimmed)) return trimmed

        val parsed = parseUrl(trimmed) ?: return null

        if (parsed.host.endsWith("youtu.be")) {
            val id = parsed.pathSegments.firstOrNull()
            if (!id.isNullOrBlank() && VIDEO_ID_REGEX.matches(id)) {
                return id
            }
        }

        val queryId = parsed.query["v"]?.firstOrNull()
        if (!queryId.isNullOrBlank() && VIDEO_ID_REGEX.matches(queryId)) {
            return queryId
        }

        if (parsed.pathSegments.size >= 2) {
            val first = parsed.pathSegments[0]
            val second = parsed.pathSegments[1]
            if ((first == "embed" || first == "shorts" || first == "live") && VIDEO_ID_REGEX.matches(second)) {
                return second
            }
        }

        return null
    }

    private fun getWatchConfig(html: String): WatchConfig {
        val apiKey = API_KEY_REGEX.find(html)?.groupValues?.getOrNull(1)
        val visitorData = VISITOR_DATA_REGEX.find(html)?.groupValues?.getOrNull(1)
        return WatchConfig(apiKey = apiKey, visitorData = visitorData)
    }

    private fun parseHlsAttributeList(line: String): Map<String, String> {
        val index = line.indexOf(':')
        if (index == -1) return emptyMap()

        val raw = line.substring(index + 1)
        val out = LinkedHashMap<String, String>()
        val key = StringBuilder()
        val value = StringBuilder()
        var inKey = true
        var inQuote = false

        for (ch in raw) {
            if (inKey) {
                if (ch == '=') {
                    inKey = false
                } else {
                    key.append(ch)
                }
                continue
            }

            if (ch == '"') {
                inQuote = !inQuote
                continue
            }

            if (ch == ',' && !inQuote) {
                val parsedKey = key.toString().trim()
                if (parsedKey.isNotEmpty()) {
                    out[parsedKey] = value.toString().trim()
                }
                key.clear()
                value.clear()
                inKey = true
                continue
            }

            value.append(ch)
        }

        val lastKey = key.toString().trim()
        if (lastKey.isNotEmpty()) {
            out[lastKey] = value.toString().trim()
        }

        return out
    }

    private fun parseResolution(raw: String): Pair<Int, Int> {
        val parts = raw.split('x')
        if (parts.size != 2) return 0 to 0
        val width = parts[0].toIntOrNull() ?: 0
        val height = parts[1].toIntOrNull() ?: 0
        return width to height
    }

    private fun parseQualityLabel(label: String?): Int? {
        if (label.isNullOrBlank()) return null
        return QUALITY_LABEL_REGEX.find(label)?.groupValues?.getOrNull(1)?.toIntOrNull()
    }

    private fun parseCodecs(mimeType: String): String {
        return CODECS_REGEX.find(mimeType)?.groupValues?.getOrNull(1)?.trim().orEmpty()
    }

    /** innertube serves range bounds as strings: `"initRange": {"start": "0", "end": "741"}`. */
    private fun rangeValue(format: JsonObject, rangeKey: String, boundKey: String): Long {
        return format.objectValue(rangeKey)?.stringValue(boundKey)?.toLongOrNull() ?: -1
    }

    private fun hasNParam(url: String): Boolean {
        return parseUrl(url)?.query?.get("n")?.firstOrNull()?.isNotBlank() == true
    }

    private fun videoScore(height: Int, fps: Int, bitrate: Double): Double {
        return height * 1_000_000_000.0 + fps * 1_000_000.0 + bitrate
    }

    private fun audioScore(bitrate: Double, audioSampleRate: Double): Double {
        return bitrate * 1_000_000.0 + audioSampleRate
    }

    private fun sortCandidates(items: List<StreamCandidate>): List<StreamCandidate> {
        return items.sortedWith(
            compareByDescending<StreamCandidate> { it.score }
                .thenBy { if (it.hasN) 1 else 0 }
                .thenBy { containerPreference(it.ext) }
                .thenBy { it.priority },
        )
    }

    private fun pickBestForClient(items: List<StreamCandidate>, clientKey: String): StreamCandidate? {
        val sameClient = items.filter { it.client == clientKey }
        if (sameClient.isNotEmpty()) {
            return sortCandidates(sameClient).firstOrNull()
        }
        return sortCandidates(items).firstOrNull()
    }

    private fun containerPreference(ext: String): Int {
        return when (ext.lowercase()) {
            "mp4", "m4a" -> 0
            "webm" -> 1
            else -> 2
        }
    }

    private fun absolutizeUrl(baseUrl: String, maybeRelative: String): String {
        if (maybeRelative.startsWith("http://") || maybeRelative.startsWith("https://")) {
            return maybeRelative
        }
        if (maybeRelative.startsWith('/')) {
            val scheme = baseUrl.substringBefore("://", "https")
            val host = baseUrl.substringAfter("://", "").substringBefore('/')
            return if (host.isNotBlank()) "$scheme://$host$maybeRelative" else maybeRelative
        }
        val baseDir = baseUrl.substringBeforeLast('/', missingDelimiterValue = baseUrl)
        return "$baseDir/$maybeRelative"
    }

    private fun encodeUrlComponent(value: String): String {
        return value
            .replace("%", "%25")
            .replace("+", "%2B")
            .replace(" ", "%20")
            .replace("&", "%26")
            .replace("=", "%3D")
    }
}

private data class ParsedUrl(
    val host: String,
    val pathSegments: List<String>,
    val query: Map<String, List<String>>,
)

private fun parseUrl(input: String): ParsedUrl? {
    val trimmed = input.trim()
    if (trimmed.isBlank()) return null

    val normalized = if (trimmed.startsWith("http://") || trimmed.startsWith("https://")) {
        trimmed
    } else {
        "https://$trimmed"
    }

    val withoutFragment = normalized.substringBefore('#')
    val withoutScheme = withoutFragment.substringAfter("://", withoutFragment)
    val host = withoutScheme.substringBefore('/').substringBefore('?').lowercase()
    if (host.isBlank()) return null

    val pathAndQuery = withoutScheme.removePrefix(host)
    val path = when {
        pathAndQuery.startsWith("/") -> pathAndQuery.substringBefore('?')
        pathAndQuery.startsWith("?") || pathAndQuery.isBlank() -> "/"
        else -> "/${pathAndQuery.substringBefore('?')}"
    }
    val queryString = withoutFragment.substringAfter('?', "")
    val query = LinkedHashMap<String, MutableList<String>>()
    queryString.split('&')
        .filter { it.isNotBlank() }
        .forEach { pair ->
            val key = pair.substringBefore('=').trim()
            if (key.isBlank()) return@forEach
            val value = pair.substringAfter('=', "")
            query.getOrPut(key) { mutableListOf() }.add(value)
        }

    return ParsedUrl(
        host = host,
        pathSegments = path.trim('/').split('/').filter { it.isNotBlank() },
        query = query,
    )
}

private fun JsonObject.objectValue(key: String): JsonObject? {
    return this[key] as? JsonObject
}

private fun JsonObject.listObjectValue(key: String): List<JsonObject> {
    return (this[key] as? JsonArray)
        ?.mapNotNull { it as? JsonObject }
        .orEmpty()
}

private fun JsonObject.stringValue(key: String): String? {
    val primitive = this[key] as? JsonPrimitive ?: return null
    return if (primitive.isString) primitive.content else primitive.toString().trim('"')
}

private fun JsonObject.numberValue(key: String): Double? {
    val primitive = this[key] as? JsonPrimitive ?: return null
    return primitive.toString().trim('"').toDoubleOrNull()
}

private fun jsonObjectOf(vararg pairs: Pair<String, Any?>): JsonObject {
    val mapped = LinkedHashMap<String, JsonElement>()
    pairs.forEach { (key, value) ->
        value?.let { mapped[key] = toJsonElement(it) }
    }
    return JsonObject(mapped)
}

private fun toJsonElement(value: Any): JsonElement {
    return when (value) {
        is JsonElement -> value
        is JsonObject -> value
        is String -> JsonPrimitive(value)
        is Boolean -> JsonPrimitive(value)
        is Int -> JsonPrimitive(value)
        is Long -> JsonPrimitive(value)
        is Double -> JsonPrimitive(value)
        is Float -> JsonPrimitive(value)
        is Number -> JsonPrimitive(value.toDouble())
        is Map<*, *> -> {
            val map = LinkedHashMap<String, JsonElement>()
            value.forEach { (key, nestedValue) ->
                val parsedKey = key?.toString() ?: return@forEach
                if (nestedValue != null) {
                    map[parsedKey] = toJsonElement(nestedValue)
                }
            }
            JsonObject(map)
        }
        is List<*> -> JsonArray(value.mapNotNull { it?.let(::toJsonElement) })
        else -> JsonPrimitive(value.toString())
    }
}