package com.nuvio.app.features.trailer

/**
 * Platform HTTP + URL plumbing for [InAppYouTubeExtractor], relocated into `:shared` so the tvOS
 * target can resolve trailers too. The iOS/tvOS actual uses ktor-Darwin; the Android actual uses
 * OkHttp. (In composeApp this used to be a per-flavor `internal object`; here it is a proper
 * `expect`/`actual` because `:shared` has no flavor source sets.)
 */
internal expect object TrailerExtractionPlatform {
    val defaultHeaders: Map<String, String>

    suspend fun performRequest(
        url: String,
        method: String,
        headers: Map<String, String>,
        body: String?,
        timeoutMillis: Long,
    ): TrailerRequestResponse

    suspend fun buildPlaybackSource(
        bestManifest: ManifestCandidate?,
        bestProgressive: StreamCandidate?,
        bestVideo: StreamCandidate?,
        bestAudio: StreamCandidate?,
    ): TrailerPlaybackSource?
}
