package com.nuvio.app.features.plugins.runtime.network

import co.touchlab.kermit.Logger
import com.dokar.quickjs.QuickJs
import com.dokar.quickjs.binding.asyncFunction
import com.nuvio.app.features.addons.httpRequestRaw
import com.nuvio.app.features.plugins.runtime.host.HostModule
import kotlinx.coroutines.CancellationException
import kotlinx.serialization.json.Json
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.JsonPrimitive
import kotlinx.serialization.json.contentOrNull
import kotlinx.serialization.json.jsonPrimitive
import kotlin.io.encoding.Base64
import kotlin.io.encoding.ExperimentalEncodingApi

private const val MAX_FETCH_HEADER_VALUE_CHARS = 8 * 1024
private const val FETCH_TRUNCATION_SUFFIX = "\n...[truncated]"

internal class FetchBridge : HostModule {
    private val log = Logger.withTag("PluginRuntime")
    private val json = Json { ignoreUnknownKeys = true }

    override fun register(runtime: QuickJs) {
        // Upstream 2e244028: an async binding instead of runBlocking inside a sync one, so the JS
        // thread is not parked for the whole request, parallel fetches (Promise.all) actually run
        // in parallel, and cancelling the run (timeout, leaving the screen) cancels the request.
        // Upstream 12621c65: args are (url, method, headersJson, bodyKind, body, followRedirects);
        // bodyKind "base64" carries a binary request body.
        runtime.asyncFunction("__native_fetch") { args ->
            val url = args.getOrNull(0)?.toString() ?: ""
            val method = args.getOrNull(1)?.toString() ?: "GET"
            val headersJson = args.getOrNull(2)?.toString() ?: "{}"
            val bodyKind = args.getOrNull(3)?.toString() ?: "none"
            val body = args.getOrNull(4)?.toString() ?: ""
            val followRedirects = args.getOrNull(5) as? Boolean ?: true
            try {
                performNativeFetch(url, method, headersJson, bodyKind, body, followRedirects)
            } catch (cancelled: CancellationException) {
                throw cancelled
            } catch (t: Throwable) {
                log.e(t) { "Fetch bridge error for $method $url" }
                JsonObject(
                    mapOf(
                        "ok" to JsonPrimitive(false),
                        "status" to JsonPrimitive(0),
                        "statusText" to JsonPrimitive(t.message ?: "Fetch failed"),
                        "url" to JsonPrimitive(url),
                        "body" to JsonPrimitive(""),
                        "bodyBase64" to JsonPrimitive(""),
                        "headers" to JsonObject(emptyMap()),
                    ),
                ).toString()
            }
        }
    }

    private suspend fun performNativeFetch(
        url: String,
        method: String,
        headersJson: String,
        bodyKind: String,
        body: String,
        followRedirects: Boolean,
    ): String {
        val headers = parseHeaders(headersJson).toMutableMap()
        if (!headers.containsKey("User-Agent")) {
            headers["User-Agent"] = "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36"
        }

        val response = httpRequestRaw(
            method = method,
            url = url,
            headers = headers,
            body = if (bodyKind == "text") body else "",
            followRedirects = followRedirects,
            bodyBytes = decodeFetchRequestBody(bodyKind, body),
        )

        val responseHeaders = response.headers.mapKeys { (key, _) -> key.lowercase() }
            .mapValues { (_, value) -> truncateString(value, MAX_FETCH_HEADER_VALUE_CHARS) }
        val result = JsonObject(
            mapOf(
                "ok" to JsonPrimitive(response.status in 200..299),
                "status" to JsonPrimitive(response.status),
                "statusText" to JsonPrimitive(response.statusText),
                "url" to JsonPrimitive(response.url),
                "body" to JsonPrimitive(response.body),
                "bodyBase64" to JsonPrimitive(encodeFetchBodyBase64(response.bodyBytes)),
                "headers" to JsonObject(responseHeaders.mapValues { JsonPrimitive(it.value) }),
            ),
        )
        return result.toString()
    }

    private fun parseHeaders(headersJson: String): Map<String, String> {
        return runCatching {
            val obj = json.parseToJsonElement(headersJson) as? JsonObject ?: JsonObject(emptyMap())
            obj.entries
                .mapNotNull { (key, value) ->
                    value.jsonPrimitive.contentOrNull?.let { key to it }
                }
                .toMap()
        }.getOrDefault(emptyMap())
    }

    private fun truncateString(value: String, maxChars: Int): String {
        if (value.length <= maxChars) return value
        val end = maxChars - FETCH_TRUNCATION_SUFFIX.length
        if (end <= 0) return FETCH_TRUNCATION_SUFFIX.take(maxChars)
        return value.substring(0, end) + FETCH_TRUNCATION_SUFFIX
    }
}

/**
 * Upstream 12621c65: the request body the JS fetch polyfill hands across the bridge. "base64"
 * is a binary body (ArrayBuffer / typed-array view) sent verbatim; "text" and "none" return null
 * so the caller sends the string body as before. `internal` for the tvOS-native test.
 */
@OptIn(ExperimentalEncodingApi::class)
internal fun decodeFetchRequestBody(bodyKind: String, body: String): ByteArray? = when (bodyKind) {
    "base64" -> Base64.decode(body)
    "none", "text" -> null
    else -> error("Unsupported fetch body kind: $bodyKind")
}

/** Upstream 12621c65: response bytes before charset decoding, for Response.arrayBuffer(). */
@OptIn(ExperimentalEncodingApi::class)
internal fun encodeFetchBodyBase64(bytes: ByteArray): String = Base64.encode(bytes)
