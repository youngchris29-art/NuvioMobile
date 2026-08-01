package com.nuvio.app.features.trailer

import io.ktor.client.HttpClient
import io.ktor.client.engine.darwin.Darwin
import io.ktor.client.plugins.HttpTimeout
import io.ktor.client.plugins.timeout
import io.ktor.client.request.header
import io.ktor.client.request.request
import io.ktor.client.request.setBody
import io.ktor.client.statement.bodyAsText
import io.ktor.client.statement.request
import io.ktor.http.HttpMethod
import io.ktor.http.isSuccess
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.async
import kotlinx.coroutines.awaitAll
import kotlinx.coroutines.coroutineScope
import kotlinx.coroutines.withContext
import kotlinx.coroutines.withTimeoutOrNull
import platform.Foundation.NSURLComponents
import platform.Foundation.NSURLQueryItem

internal actual object TrailerExtractionPlatform {
    actual val defaultHeaders: Map<String, String> = mapOf(
        "accept-language" to "en-US,en;q=0.9",
        "user-agent" to
            "Mozilla/5.0 (iPhone; CPU iPhone OS 17_4 like Mac OS X) AppleWebKit/605.1.15 " +
            "(KHTML, like Gecko) Version/17.4 Mobile/15E148 Safari/604.1",
    )

    private val httpClient = HttpClient(Darwin) {
        install(HttpTimeout)
        followRedirects = true
        expectSuccess = false
    }

    actual suspend fun performRequest(
        url: String,
        method: String,
        headers: Map<String, String>,
        body: String?,
        timeoutMillis: Long,
    ): TrailerRequestResponse = withContext(Dispatchers.Default) {
        val response = httpClient.request(url) {
            this.method = when (method.uppercase()) {
                "POST" -> HttpMethod.Post
                "PUT" -> HttpMethod.Put
                "DELETE" -> HttpMethod.Delete
                else -> HttpMethod.Get
            }
            headers.forEach { (name, value) ->
                header(name, value)
            }
            if (body != null) {
                setBody(body)
            }
            timeout {
                requestTimeoutMillis = timeoutMillis
                connectTimeoutMillis = timeoutMillis
                socketTimeoutMillis = timeoutMillis
            }
        }

        val bodyText = runCatching { response.bodyAsText() }.getOrElse { "" }
        TrailerRequestResponse(
            ok = response.status.isSuccess(),
            status = response.status.value,
            statusText = response.status.description,
            url = response.request.url.toString(),
            body = bodyText,
        )
    }

    actual suspend fun buildPlaybackSource(
        bestManifest: ManifestCandidate?,
        bestProgressive: StreamCandidate?,
        bestVideo: StreamCandidate?,
        bestAudio: StreamCandidate?,
    ): TrailerPlaybackSource? = withContext(Dispatchers.Default) {
        val bestManifestHeight = bestManifest?.height ?: -1
        val bestCombinedIsManifest = bestManifest != null &&
            (bestProgressive == null || bestManifestHeight > bestProgressive.height)

        val combinedUrl = if (bestCombinedIsManifest) {
            bestManifest.selectedVariantUrl
        } else {
            bestProgressive?.url
        }

        val videoUrl = resolveReachableUrl(bestVideo?.url ?: combinedUrl ?: return@withContext null)
        val audioUrl = bestAudio?.url?.let { resolveReachableUrl(it) }

        // AVPlayer-friendly URL for tvOS — both candidates play natively via AVPlayer, so pick
        // by QUALITY, not by kind (UX-4c "all the trailers are low quality"): YouTube's muxed
        // progressive MP4 is effectively capped at 360p today, while the HLS manifest carries
        // up to 1080p variants. Preferring progressive unconditionally pinned every trailer to
        // the 360p file; use the same height comparison as `combinedUrl` above. When the
        // manifest wins we hand AVPlayer the concrete top-resolution variant playlist
        // (selectedVariantUrl), not the master playlist — under the small inline hero layer
        // ABR parks the master playlist at a low rung, so pinning the variant directly is what
        // actually gets us the high-res stream (UX-4c round 2).
        val progressiveUrl = if (bestCombinedIsManifest) {
            bestManifest.selectedVariantUrl
        } else {
            bestProgressive?.url?.let { resolveReachableUrl(it) } ?: bestManifest?.selectedVariantUrl
        }

        TrailerPlaybackSource(
            videoUrl = videoUrl,
            audioUrl = audioUrl,
            progressiveUrl = progressiveUrl,
        )
    }

    private suspend fun resolveReachableUrl(url: String): String {
        if (!url.contains("googlevideo.com")) return url

        val mnParam = getQueryParameter(url, "mn") ?: return url
        val servers = mnParam.split(',').map { it.trim() }.filter { it.isNotBlank() }
        if (servers.size < 2) return url

        val host = getHost(url) ?: return url
        val candidates = mutableListOf(url)

        servers.forEachIndexed { index, server ->
            val altHost = host
                .replaceFirst(Regex("^rr\\d+---"), "rr${index + 1}---")
                .replaceFirst(Regex("sn-[a-z0-9]+-[a-z0-9]+"), server)
            if (altHost != host) {
                candidates += url.replace(host, altHost)
            }
        }

        if (candidates.size == 1) return candidates.first()

        return coroutineScope {
            val probes = candidates.map { candidate ->
                async {
                    if (isUrlReachable(candidate)) candidate else null
                }
            }
            withTimeoutOrNull(2_000L) {
                probes.awaitAll().firstOrNull { !it.isNullOrBlank() }
            } ?: url
        }
    }

    private suspend fun isUrlReachable(url: String): Boolean {
        val response = runCatching {
            performRequest(
                url = url,
                method = "GET",
                headers = mapOf(
                    "range" to "bytes=0-0",
                    "user-agent" to defaultHeaders.getValue("user-agent"),
                ),
                body = null,
                timeoutMillis = 2_000L,
            )
        }.getOrNull() ?: return false

        return response.status in 200..299
    }

    private fun getHost(url: String): String? {
        val components = NSURLComponents(string = url)
        return components.host
    }

    private fun getQueryParameter(url: String, name: String): String? {
        val components = NSURLComponents(string = url)
        return queryItems(components).firstOrNull { it.name == name }?.value
    }

    private fun queryItems(components: NSURLComponents): List<NSURLQueryItem> {
        return components.queryItems?.mapNotNull { it as? NSURLQueryItem } ?: emptyList()
    }
}