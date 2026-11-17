package com.nuvio.app.features.player

import com.nuvio.app.features.streams.StreamAutoPlayMode
import com.nuvio.app.features.streams.StreamAutoPlayPlatform
import com.nuvio.app.features.streams.StreamAutoPlayRanking
import com.nuvio.app.features.streams.StreamAutoPlaySelector
import com.nuvio.app.features.streams.StreamAutoPlaySource
import com.nuvio.app.features.streams.StreamItem

/**
 * The sources auto source selection tried before the one that plays, and how many further ones.
 * [keys] are opaque: shared builds them ([including], [includingFailed], the walk) and decides
 * with them ([contains], [PlayerSourceFallback.isExcluded]); Swift only carries them back
 * unchanged. Besides one key per tried source they hold one marker per torrent that FAILED from
 * an add-on during the walk (review r2), so the same-add-on copy rule covers every failure of the
 * walk, across the hand-off from Up Next into the player, not just the last one.
 */
data class PlayerSourceFallbackTried(val keys: Set<String>, val attempts: Int) {
    /** This set with [stream] added as tried (attempts unchanged). */
    fun including(stream: StreamItem): PlayerSourceFallbackTried =
        stream.playerSourceFallbackKey()?.let { copy(keys = keys + it) } ?: this

    /**
     * This set with [stream] added as tried AND, when it is a torrent, as a failed torrent of its
     * add-on: every other copy of that torrent from that add-on is then excluded for the rest of
     * the walk (the same torrent from another add-on stays a candidate). Use it when the source
     * failed; [including] when it was only tried (it started and was replaced for another reason).
     */
    fun includingFailed(stream: StreamItem): PlayerSourceFallbackTried {
        val marker = stream.failedTorrentMarker() ?: return including(stream)
        return including(stream).let { it.copy(keys = it.keys + marker) }
    }

    /** Whether [stream] was tried (review r1: the one tried-test, see [PlayerSourceFallback.isTried]). */
    fun contains(stream: StreamItem): Boolean = PlayerSourceFallback.isTried(stream, keys)

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
 * player): its sources are never picked again, nor other copies of the torrents it recorded as
 * failed from the same add-on, and its attempts count against [maxSources]. Kotlin
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
        candidate.playerSourceFallbackKey()?.let(triedKeys::add)
        return tried
    }

    fun failed(nextCandidate: (failed: StreamItem, triedKeys: Set<String>) -> StreamItem?): StreamItem? {
        candidate.playerSourceFallbackKey()?.let(triedKeys::add)
        // Review r2: remembered for the whole walk, not only as the last failure.
        candidate.failedTorrentMarker()?.let(triedKeys::add)
        return moveOn(nextCandidate)
    }

    /**
     * Review r7: the source did not answer in time (a resolve time-out). It is recorded as tried
     * only, with no failed-torrent marker, so the other files of its torrent from its add-on stay
     * candidates (a time-out is not proof the torrent is dead); then the walk moves on as [moveOn].
     */
    fun passed(nextCandidate: (failed: StreamItem, triedKeys: Set<String>) -> StreamItem?): StreamItem? {
        candidate.playerSourceFallbackKey()?.let(triedKeys::add)
        return moveOn(nextCandidate)
    }

    /** Decision BC: a further source may still be moved to ("Sources to Try" not used up). */
    val hasBudget: Boolean
        get() = attempts < maxSources

    /**
     * Decision BC: after [failed] found nothing and the walk waited for the search, look again.
     * The failed source is already recorded; a source found here counts against [maxSources]
     * exactly like one found by [failed], so the cap holds across the wait.
     */
    fun moveOn(nextCandidate: (failed: StreamItem, triedKeys: Set<String>) -> StreamItem?): StreamItem? {
        if (attempts >= maxSources) return null
        val next = nextCandidate(candidate, triedKeys.toSet()) ?: return null
        attempts++
        candidate = next
        return next
    }
}

/** Decision BC: what the next-episode walk does after a source failed. */
sealed interface PlayerSourceFallbackStep {
    /** Resolve and play this source next. */
    data class Try(val stream: StreamItem) : PlayerSourceFallbackStep

    /**
     * No further source is known yet but the episode's search is still open: wait for new sources
     * at most [atMostMillis] (the time left to the search deadline), then look again.
     */
    data class Wait(val atMostMillis: Long) : PlayerSourceFallbackStep

    /** Nothing left to try: the no-stream card. */
    data object End : PlayerSourceFallbackStep
}

/**
 * Decision BC (Christian, 2026-11-17: "Wait up to the search deadline"). Device row R25 showed the
 * next-episode walk ending the moment its candidates ran out while an add-on was still answering
 * (it did, 12 s later). The walk now waits for new sources while the episode's search is still
 * open, never past the search deadline, never once the search has settled, and never after the
 * viewer acted (Menu, a source pick, leaving the player). "Sources to Try" still caps the walk:
 * waiting costs nothing, a source tried after it counts.
 */
object PlayerSourceFallbackWaitPolicy {
    /**
     * [next] is the walk's next source ([PlayerSourceFallbackWalk.failed] or
     * [PlayerSourceFallbackWalk.moveOn], so the tried set is already applied); [hasBudget] is
     * [PlayerSourceFallbackWalk.hasBudget]; [searchOpen] says add-ons are still answering;
     * [millisToDeadline] is the time left to the search deadline; [cancelled] is a viewer action.
     */
    fun decide(
        next: StreamItem?,
        hasBudget: Boolean,
        searchOpen: Boolean,
        millisToDeadline: Long,
        cancelled: Boolean,
    ): PlayerSourceFallbackStep = when {
        cancelled -> PlayerSourceFallbackStep.End
        next != null -> PlayerSourceFallbackStep.Try(next)
        !hasBudget -> PlayerSourceFallbackStep.End
        searchOpen && millisToDeadline > 0 -> PlayerSourceFallbackStep.Wait(millisToDeadline)
        else -> PlayerSourceFallbackStep.End
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

    /** The key a tried set holds for [stream]; opaque to Swift (pass it back, never build one). */
    fun triedKey(stream: StreamItem): String? = stream.playerSourceFallbackKey()

    /**
     * Whether [stream] is in [triedKeys]. Review r1: a torrent's key names its add-on, so the same
     * torrent from another add-on is not "tried". Transitional: a key in the old add-on-blind
     * identity form (`torrent:<hash>:<file>`, still built by callers that call
     * `playerSourceIdentityKey()` themselves) also matches, so such a caller can never re-pick a
     * source it tried; it keeps the old add-on-blind exclusion for that key until it uses
     * [triedKey] / [PlayerSourceFallbackTried.including]. The walk itself never records one.
     */
    fun isTried(stream: StreamItem, triedKeys: Set<String>): Boolean {
        if (triedKeys.isEmpty()) return false
        val key = stream.playerSourceFallbackKey()
        if (key != null && key in triedKeys) return true
        val legacy = stream.playerSourceIdentityKey()
        return legacy != null && legacy != key && legacy in triedKeys
    }

    /**
     * Upstream's candidate filter, for the whole walk: a source already tried, or another copy
     * (any file, or none) of a torrent that failed from the same add-on, is not picked again. The
     * failures are the ones recorded in [triedKeys] ([PlayerSourceFallbackTried.includingFailed],
     * the walk's own [PlayerSourceFallbackWalk.failed]) plus the one named by [failedAddonId] /
     * [failedInfoHash]. A caller that records failures with plain `including` gets only the
     * last-failure rule (upstream's behaviour). The same torrent from another add-on stays a
     * candidate (review r1).
     */
    fun isExcluded(
        stream: StreamItem,
        triedKeys: Set<String>,
        failedAddonId: String?,
        failedInfoHash: String?,
    ): Boolean {
        if (isTried(stream, triedKeys)) return true
        val marker = stream.failedTorrentMarker()
        if (marker != null && marker in triedKeys) return true
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

    /** [isExcluded] with the failed source itself (its add-on and torrent read here, not by the caller). */
    fun isExcludedAfter(stream: StreamItem, tried: PlayerSourceFallbackTried, failed: StreamItem?): Boolean =
        isExcluded(stream, tried.keys, failed?.addonId, failed?.p2pInfoHash)

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
 * W4 (review r1): the identity a fallback walk's tried set uses. The same as
 * [playerSourceIdentityKey] except for torrents, where it also names the add-on: two add-ons
 * serving the same torrent and file are two sources to the walk (a dead link or expired resolve
 * from one must not rule out the other). Other copies of a torrent that failed from the SAME
 * add-on are left out by [PlayerSourceFallback.isExcluded]'s own rule. The identity key itself is
 * unchanged, because the phone's player marks the playing row with it.
 */
fun StreamItem.playerSourceFallbackKey(): String? {
    p2pInfoHash?.trim()?.lowercase()?.takeIf { it.isNotBlank() }?.let { hash ->
        // Its own prefix, so it can never be mistaken for an identity key (`torrent:`).
        return "p2p:$hash:${p2pFileIdx ?: -1}@$addonId"
    }
    return playerSourceIdentityKey()
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

/**
 * Review r2: the tried-set marker of "this torrent failed from this add-on" (hash and add-on, no
 * file: every copy of it from that add-on is excluded). Its own prefix: never a source key.
 */
private fun StreamItem.failedTorrentMarker(): String? =
    p2pInfoHash?.trim()?.lowercase()?.takeIf { it.isNotBlank() }?.let { hash -> "failed-p2p:$hash@$addonId" }
