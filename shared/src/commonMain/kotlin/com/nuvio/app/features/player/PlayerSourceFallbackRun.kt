package com.nuvio.app.features.player

import com.nuvio.app.features.streams.StreamItem

/** The sources auto source selection tried before the one that plays, and how many further ones. */
data class PlayerSourceFallbackTried(val keys: Set<String>, val attempts: Int) {
    companion object {
        /** A source auto selection picked first, with nothing tried before it. */
        val None = PlayerSourceFallbackTried(keys = emptySet(), attempts = 0)
    }
}

/** What resolving one auto-selected source gave. */
internal sealed interface PlayerSourceResolveAttempt<out T, out F> {
    /** The source is ready to play. */
    data class Resolved<T>(val value: T) : PlayerSourceResolveAttempt<T, Nothing>

    /** The source cannot be played, in a way the next source may get past. */
    data class Failed<F>(val failure: F) : PlayerSourceResolveAttempt<Nothing, F>
}

internal data class PlayerSourceFallbackRun<T, F>(
    /** What the source that resolved gave, or null when none did. */
    val resolved: T?,
    /** The failure of the last source tried, to show when none resolved. */
    val failure: F?,
    /** The sources tried, the one that resolved included. */
    val tried: PlayerSourceFallbackTried,
)

/**
 * The bookkeeping of one fallback walk, driven one resolve at a time: [candidate] is the source to
 * resolve now. After it resolves call [resolved]; after it fails call [failed], which returns the
 * next source to resolve or null when the walk ends (no candidate left, or [maxSources] further
 * sources already tried). tvOS drives it from Swift (`NextEpisodeEngine.play`), so every await and
 * cancellation check stays on the main actor.
 */
class PlayerSourceFallbackWalk(first: StreamItem, private val maxSources: Int) {
    var candidate: StreamItem = first
        private set

    /** Further sources moved to after the first. */
    var attempts: Int = 0
        private set

    private val triedKeys = mutableSetOf<String>()

    val tried: PlayerSourceFallbackTried
        get() = PlayerSourceFallbackTried(triedKeys.toSet(), attempts)

    fun resolved(): PlayerSourceFallbackTried {
        candidate.playerSourceIdentityKey()?.let(triedKeys::add)
        return tried
    }

    fun failed(nextCandidate: (failed: StreamItem, triedKeys: Set<String>) -> StreamItem?): StreamItem? {
        candidate.playerSourceIdentityKey()?.let(triedKeys::add)
        if (attempts >= maxSources) return null
        val next = nextCandidate(candidate, triedKeys.toSet()) ?: return null
        attempts++
        candidate = next
        return next
    }
}

/**
 * Resolves [first] and, while a source cannot be played, the one [nextCandidate] picks next, up to
 * [maxSources] further ones. With [maxSources] at 0 only [first] is tried. Upstream ff7500fdd's
 * function, kept on top of [PlayerSourceFallbackWalk] so both share one rule.
 */
internal suspend fun <T : Any, F : Any> resolveWithSourceFallback(
    first: StreamItem,
    maxSources: Int,
    resolve: suspend (StreamItem) -> PlayerSourceResolveAttempt<T, F>,
    nextCandidate: (failed: StreamItem, triedKeys: Set<String>) -> StreamItem?,
): PlayerSourceFallbackRun<T, F> {
    val walk = PlayerSourceFallbackWalk(first, maxSources)
    while (true) {
        when (val attempt = resolve(walk.candidate)) {
            is PlayerSourceResolveAttempt.Resolved ->
                return PlayerSourceFallbackRun(attempt.value, null, walk.resolved())
            is PlayerSourceResolveAttempt.Failed ->
                if (walk.failed(nextCandidate) == null) {
                    return PlayerSourceFallbackRun(null, attempt.failure, walk.tried)
                }
        }
    }
}

/** The fork's source-fallback rules until W4 brings upstream's settings (8fba6c71e). */
object PlayerSourceFallback {
    /** Decision B (batch 2026-11-16): up to 3 further sources for the next episode's auto pick. */
    const val NEXT_EPISODE_MAX_FURTHER_SOURCES = 3

    /**
     * How many further sources the next episode's auto pick may try. W4 replaces the body with
     * `if (settings.streamAutoPlayFallbackActive) settings.streamAutoPlayFallbackMaxSources else 0`.
     */
    @Suppress("UNUSED_PARAMETER")
    fun nextEpisodeMaxFurtherSources(settings: PlayerSettingsUiState?): Int = NEXT_EPISODE_MAX_FURTHER_SOURCES

    /**
     * Upstream's candidate filter: a source already tried, or another copy of the torrent that
     * failed from the same add-on, is never picked again in the same walk.
     */
    fun isExcluded(
        stream: StreamItem,
        triedKeys: Set<String>,
        failedAddonId: String?,
        failedInfoHash: String?,
    ): Boolean {
        val key = stream.playerSourceIdentityKey()
        if (key != null && key in triedKeys) return true
        return failedInfoHash != null &&
            stream.addonId == failedAddonId &&
            stream.p2pInfoHash.equals(failedInfoHash, ignoreCase = true)
    }
}

/**
 * A stable identity for a source across resolves (moved from the fork's composeApp
 * `PlayerScreenRuntimeSourceActions.kt`; same body). Public: the composeApp runtime calls it.
 */
fun StreamItem.playerSourceIdentityKey(): String? {
    p2pInfoHash?.trim()?.lowercase()?.takeIf { it.isNotBlank() }?.let { hash ->
        return "torrent:$hash:${p2pFileIdx ?: -1}"
    }

    clientResolve?.let { resolve ->
        val raw = resolve.stream?.raw
        val keyParts = listOf(
            addonId,
            resolve.service,
            resolve.serviceIndex?.toString(),
            resolve.infoHash?.trim()?.lowercase(),
            resolve.fileIdx?.toString(),
            resolve.magnetUri,
            resolve.torrentName,
            resolve.filename,
            raw?.torrentName,
            raw?.filename,
            raw?.size?.toString(),
            behaviorHints.filename,
            behaviorHints.videoSize?.toString(),
            streamLabel,
            streamSubtitle,
        ).map { it.orEmpty().trim() }
        if (keyParts.any { it.isNotBlank() }) {
            return "resolve:${keyParts.joinToString("|")}"
        }
    }

    behaviorHints.videoHash?.trim()?.takeIf { it.isNotBlank() }?.let { hash ->
        return "hash:$addonId:$hash:${behaviorHints.videoSize ?: ""}:${behaviorHints.filename.orEmpty()}"
    }

    playableDirectUrl?.trim()?.takeIf { it.isNotBlank() }?.let { url ->
        return "url:$url"
    }

    val fallbackParts = listOf(
        addonId,
        addonName,
        streamLabel,
        streamSubtitle.orEmpty(),
        behaviorHints.filename.orEmpty(),
        behaviorHints.videoSize?.toString().orEmpty(),
        sourceName.orEmpty(),
        sources.joinToString(","),
    ).map { it.trim() }
    return fallbackParts
        .takeIf { parts -> parts.any { it.isNotBlank() } }
        ?.joinToString(separator = "|", prefix = "meta:")
}
