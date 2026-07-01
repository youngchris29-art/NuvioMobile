package com.nuvio.app.features.trailer

/**
 * tvOS-facing entry point for resolving a YouTube trailer URL into a directly-playable
 * [TrailerPlaybackSource] (video + optional audio), via the pure-Kotlin [InAppYouTubeExtractor].
 *
 * On mobile this resolution lives behind the flavor-gated `TrailerPlaybackResolver` (the App Store
 * flavor returns null). tvOS is a "full" experience with no App Store flavor, so it calls this
 * directly. Swift consumes the `suspend fun` as a completion-handler method:
 * `HeroTrailerResolver.shared.resolveYouTube(youtubeUrl:) { source, error in ... }`.
 *
 * Fails soft — any extraction error returns null so the caller can fall back to the static backdrop.
 */
object HeroTrailerResolver {
    private val extractor by lazy { InAppYouTubeExtractor() }

    suspend fun resolveYouTube(youtubeUrl: String): TrailerPlaybackSource? {
        if (youtubeUrl.isBlank()) return null
        return runCatching { extractor.extractPlaybackSource(youtubeUrl) }.getOrNull()
    }
}
