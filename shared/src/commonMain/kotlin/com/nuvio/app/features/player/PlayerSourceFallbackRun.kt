package com.nuvio.app.features.player

import com.nuvio.app.features.streams.StreamAutoPlayMode
import com.nuvio.app.features.streams.StreamAutoPlayPlatform
import com.nuvio.app.features.streams.StreamAutoPlayRanking
import com.nuvio.app.features.streams.StreamAutoPlaySelector
import com.nuvio.app.features.streams.StreamAutoPlaySource
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
 *
 * [alreadyTried] seeds a walk that continues an earlier one (Up Next's tried set carried into the
 * player): its keys are never picked again and its attempts count against [maxSources]. Kotlin
 * default arguments do not exist in Swift, so the plain two-argument form is its own constructor.
 */
class PlayerSourceFallbackWalk(
    first: StreamItem,
    private val maxSources: Int,
    alreadyTried: PlayerSourceFallbackTried,
) {
    constructor(first: StreamItem, maxSources: Int) : this(first, maxSources, PlayerSourceFallbackTried.None)

    var candidate: StreamItem = first
        private set

    /** Further sources moved to after the first, the seeded attempts included. */
    var attempts: Int = alreadyTried.attempts
        private set

    private val triedKeys = alreadyTried.keys.toMutableSet()

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

/** Where an auto-picked source is being played from (W4). */
enum class PlayerSourceFallbackEntry {
    /** The stream picker's Auto-Play Best Source start. */
    FIRST_PLAY,

    /** Up Next's pick for the next episode (any auto-play mode: Up Next auto-picks in MANUAL too). */
    NEXT_EPISODE,
}

/**
 * What auto selection may pick from, as plain values: the first play's user settings, or Up Next's
 * effective selection (MANUAL with the next-episode toggles forces first-stream over all sources).
 */
data class StreamAutoPickScope(
    val mode: StreamAutoPlayMode,
    val regexPattern: String,
    val source: StreamAutoPlaySource,
    val selectedAddons: Set<String>,
    val selectedPlugins: Set<String>,
    val preferredBingeGroup: String?,
    val preferBingeGroupInSelection: Boolean,
    val bingeGroupOnly: Boolean,
    val ranking: StreamAutoPlayRanking,
) {
    companion object {
        /** The stream picker repository's own evaluation (`StreamsRepository.load`). */
        fun firstPlay(settings: PlayerSettingsUiState) = StreamAutoPickScope(
            mode = settings.streamAutoPlayMode,
            regexPattern = settings.streamAutoPlayRegex,
            source = settings.streamAutoPlaySource,
            selectedAddons = settings.streamAutoPlaySelectedAddons,
            selectedPlugins = settings.streamAutoPlaySelectedPlugins,
            preferredBingeGroup = null,
            preferBingeGroupInSelection = false,
            bingeGroupOnly = false,
            ranking = StreamAutoPlayPlatform.firstStreamRanking,
        )
    }
}

/** The fork's source-fallback rules (upstream 8fba6c71e / ff7500fdd, W4). */
object PlayerSourceFallback {
    /** Upstream's default, for tests and Swift's options. */
    const val DEFAULT_FURTHER_SOURCES = DEFAULT_SOURCE_FALLBACK_MAX_SOURCES

    /** The "Sources to Try" values (1 to 10) and the "Start-Up Limit" values (5 to 45 s in 5 s steps), for Swift. */
    val sourcesToTryOptions: List<Int> = SOURCE_FALLBACK_MAX_SOURCES_RANGE.toList()
    val startupLimitOptions: List<Int> =
        SOURCE_STARTUP_TIMEOUT_SECONDS_RANGE.step(SOURCE_STARTUP_TIMEOUT_SECONDS_STEP).toList()

    /** Null settings (not loaded yet; tests) read as the defaults. */
    fun isActive(settings: PlayerSettingsUiState?, entry: PlayerSourceFallbackEntry): Boolean {
        val on = settings?.streamAutoPlayFallbackOnFailure ?: DEFAULT_SOURCE_FALLBACK_ON_FAILURE
        if (!on) return false
        return when (entry) {
            PlayerSourceFallbackEntry.FIRST_PLAY ->
                (settings?.streamAutoPlayMode ?: StreamAutoPlayMode.MANUAL) != StreamAutoPlayMode.MANUAL
            PlayerSourceFallbackEntry.NEXT_EPISODE -> true
        }
    }

    /** Further sources after the first, 0 when falling back is off for [entry]. */
    fun furtherSources(settings: PlayerSettingsUiState?, entry: PlayerSourceFallbackEntry): Int =
        if (!isActive(settings, entry)) {
            0
        } else {
            normalizeSourceFallbackMaxSources(
                settings?.streamAutoPlayFallbackMaxSources ?: DEFAULT_SOURCE_FALLBACK_MAX_SOURCES,
            )
        }

    /** Stage A's name, kept for its call site: the next episode's budget. */
    fun nextEpisodeMaxFurtherSources(settings: PlayerSettingsUiState?): Int =
        furtherSources(settings, PlayerSourceFallbackEntry.NEXT_EPISODE)

    /** Seconds an auto-picked source may take to show its first frame, or null when no limit applies. */
    fun startupLimitSeconds(settings: PlayerSettingsUiState?, entry: PlayerSourceFallbackEntry): Int? =
        if (!isActive(settings, entry)) {
            null
        } else {
            (settings?.streamAutoPlayFallbackStartupTimeoutSeconds ?: DEFAULT_SOURCE_STARTUP_TIMEOUT_SECONDS)
                .coerceIn(SOURCE_STARTUP_TIMEOUT_SECONDS_RANGE)
        }

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

    /**
     * Upstream `nextSourceFallbackCandidate`, every match in order: what auto selection would pick
     * from [streams] once the tried sources and other copies of the failed torrent are left out.
     *
     * [StreamAutoPlaySelector.evaluateAutoPlayStream] returns the full ranked list in `readyStreams`
     * for FIRST_STREAM and REGEX_MATCH (a binge-group preference only moves its stream to the front).
     * Only the binge-group-only scope returns just one stream, so that scope is expanded by picking
     * repeatedly with the picked stream left out each time (`nextCandidate` stays the first entry
     * either way).
     */
    fun rankedCandidates(
        streams: List<StreamItem>,
        scope: StreamAutoPickScope,
        triedKeys: Set<String>,
        failedAddonId: String?,
        failedInfoHash: String?,
        installedAddonNames: Set<String>,
        debridEnabled: Boolean,
        activeResolverProviderId: String?,
    ): List<StreamItem> {
        val untried = streams.filterNot { isExcluded(it, triedKeys, failedAddonId, failedInfoHash) }
        fun evaluate(from: List<StreamItem>): List<StreamItem> =
            StreamAutoPlaySelector.evaluateAutoPlayStream(
                streams = from,
                mode = scope.mode,
                regexPattern = scope.regexPattern,
                source = scope.source,
                installedAddonNames = installedAddonNames,
                selectedAddons = scope.selectedAddons,
                selectedPlugins = scope.selectedPlugins,
                preferredBingeGroup = scope.preferredBingeGroup,
                preferBingeGroupInSelection = scope.preferBingeGroupInSelection,
                bingeGroupOnly = scope.bingeGroupOnly,
                debridEnabled = debridEnabled,
                activeResolverProviderId = activeResolverProviderId,
                ranking = scope.ranking,
            ).readyStreams
        if (!scope.bingeGroupOnly) return evaluate(untried)

        val remaining = untried.toMutableList()
        val ranked = mutableListOf<StreamItem>()
        while (remaining.isNotEmpty()) {
            val pick = evaluate(remaining).firstOrNull() ?: break
            ranked += pick
            val index = remaining.indexOf(pick)
            if (index < 0) break
            remaining.removeAt(index)
        }
        return ranked
    }

    fun nextCandidate(
        streams: List<StreamItem>,
        scope: StreamAutoPickScope,
        triedKeys: Set<String>,
        failedAddonId: String?,
        failedInfoHash: String?,
        installedAddonNames: Set<String>,
        debridEnabled: Boolean,
        activeResolverProviderId: String?,
    ): StreamItem? = rankedCandidates(
        streams, scope, triedKeys, failedAddonId, failedInfoHash, installedAddonNames, debridEnabled, activeResolverProviderId,
    ).firstOrNull()
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
