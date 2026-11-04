package com.nuvio.app.features.player

import com.nuvio.app.features.addons.buildAddonResourceUrl
import com.nuvio.app.features.addons.encodeAddonPathSegment
import com.nuvio.app.features.streams.StreamBehaviorHints

/**
 * File extras a Stremio subtitles add-on can use to match subtitles to the exact release
 * (upstream 9cb86845 / 1aacf178). Sent as the optional extra path segment:
 * `subtitles/<type>/<id>/videoHash=..&videoSize=..&filename=...json`.
 *
 * Field order and encoding match upstream exactly so add-ons parse it the same way.
 */
data class SubtitleRequestExtras(
    val filename: String? = null,
    val videoSize: Long? = null,
    val videoHash: String? = null,
) {
    fun toPathSegment(): String? = buildList {
        videoHash?.trim()?.takeIf(String::isNotBlank)?.let { hash ->
            add("videoHash=${hash.encodeAddonPathSegment()}")
        }
        videoSize?.takeIf { it > 0L }?.let { size ->
            add("videoSize=$size")
        }
        filename?.trim()?.takeIf(String::isNotBlank)?.let { name ->
            add("filename=${name.encodeAddonPathSegment()}")
        }
    }.joinToString(separator = "&").ifBlank { null }

    internal val usableHash: String?
        get() = videoHash?.trim()?.takeIf(String::isNotBlank)

    internal val usableSize: Long?
        get() = videoSize?.takeIf { it > 0L }

    internal val usableFilename: String?
        get() = filename?.trim()?.takeIf(String::isNotBlank)

    companion object {
        fun from(hints: StreamBehaviorHints): SubtitleRequestExtras? =
            of(filename = hints.filename, videoSize = hints.videoSize, videoHash = hints.videoHash, sourceUrl = null)

        /**
         * Extras from stream behavior hints, falling back to a filename taken from the playback
         * URL when the hints carry none (NuvioTV's `streamFilenameFromUrl`).
         */
        fun from(hints: StreamBehaviorHints, sourceUrl: String?): SubtitleRequestExtras? =
            of(filename = hints.filename, videoSize = hints.videoSize, videoHash = hints.videoHash, sourceUrl = sourceUrl)

        /**
         * Same as [from] for callers that hold the fields rather than a [StreamBehaviorHints]
         * (the tvOS playback context). Returns null when nothing usable remains, and for local
         * `file:` sources (upstream clears extras for downloaded/local playback).
         */
        fun of(
            filename: String?,
            videoSize: Long?,
            videoHash: String?,
            sourceUrl: String?,
        ): SubtitleRequestExtras? {
            if (sourceUrl != null && sourceUrl.trim().startsWith("file:", ignoreCase = true)) return null
            val name = filename?.takeIf { it.isNotBlank() } ?: sourceFilenameFromUrl(sourceUrl)
            return SubtitleRequestExtras(
                filename = name,
                videoSize = videoSize,
                videoHash = videoHash,
            ).takeIf { it.toPathSegment() != null }
        }
    }
}

/**
 * The last path segment of [url] (query and fragment stripped) when it looks like a file name,
 * i.e. contains an extension dot. Mirrors upstream `sourceFilenameFromUrl`.
 */
fun sourceFilenameFromUrl(url: String?): String? =
    url?.substringBefore('?')?.substringBefore('#')?.substringAfterLast('/')
        ?.takeIf { it.isNotBlank() && it.contains('.') }

/**
 * True when [other] carries information this request lacks — the only case where a second
 * fetch for the same content is worth making (a picker prefetch without a hash must never
 * block the player's hashed fetch, and a later call with fewer extras must not replace it).
 */
internal fun SubtitleRequestExtras?.isRicherThan(other: SubtitleRequestExtras?): Boolean {
    val mine = this ?: return false
    val hash = mine.usableHash
    val otherHash = other?.usableHash
    if (hash != null && hash != otherHash) return true
    if (otherHash != null) return false
    if (mine.usableSize != null && other?.usableSize == null) return true
    if (mine.usableFilename != null && other?.usableFilename == null) return true
    return false
}

/** Field-wise merge: this request's values win, gaps are filled from [fallback]. */
internal fun SubtitleRequestExtras?.mergedOver(fallback: SubtitleRequestExtras?): SubtitleRequestExtras? {
    if (this == null) return fallback
    if (fallback == null) return this
    return SubtitleRequestExtras(
        filename = usableFilename ?: fallback.usableFilename,
        videoSize = usableSize ?: fallback.usableSize,
        videoHash = usableHash ?: fallback.usableHash,
    )
}

internal fun buildSubtitleRequestUrl(
    manifestUrl: String,
    type: String,
    videoId: String,
    extras: SubtitleRequestExtras? = null,
): String = buildAddonResourceUrl(
    manifestUrl = manifestUrl,
    resource = "subtitles",
    type = canonicalSubtitleType(type),
    id = videoId,
    extraPathSegment = extras?.toPathSegment(),
)

/**
 * Whether the OpenSubtitles hash may be computed from [url]: an http(s) file URL. Skips
 * playlists/manifests (HLS/DASH, including the app's own local remux output), loopback
 * servers (tvOS has no local P2P engine; its loopback servers are remux/HLS), and YouTube.
 */
fun isHashableSubtitleSource(url: String?): Boolean {
    val trimmed = url?.trim().orEmpty()
    val scheme = trimmed.substringBefore("://", "").lowercase()
    if (scheme != "http" && scheme != "https") return false
    val afterScheme = trimmed.substringAfter("://")
    val authority = afterScheme.substringBefore('/').substringBefore('?').substringBefore('#')
    val host = authority.substringAfterLast('@').let { hostPort ->
        if (hostPort.startsWith("[")) hostPort.substringAfter('[').substringBefore(']')
        else hostPort.substringBefore(':')
    }.lowercase()
    if (host.isEmpty()) return false
    if (host == "localhost" || host == "::1" || host.startsWith("127.")) return false
    if (host.endsWith("youtube.com") || host == "youtu.be" || host.endsWith("googlevideo.com")) return false
    val path = afterScheme.substringAfter('/', "").substringBefore('?').substringBefore('#').lowercase()
    val playlistSuffixes = listOf(".m3u8", ".m3u", ".mpd", ".ism", "/manifest")
    if (playlistSuffixes.any { path.endsWith(it) }) return false
    return true
}
