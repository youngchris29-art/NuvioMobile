package com.nuvio.app.features.streams

import com.nuvio.app.core.build.FeaturePolicyProvider
import com.nuvio.app.core.coroutines.uncaughtCoroutineLogger
import com.nuvio.app.features.addons.AddonRepository
import com.nuvio.app.features.addons.ManagedAddon
import com.nuvio.app.features.addons.buildAddonResourceUrl
import com.nuvio.app.features.addons.enabledAddons
import com.nuvio.app.features.addons.fetchAddonResponseText
import com.nuvio.app.features.debrid.DebridSettings
import com.nuvio.app.features.debrid.DebridSettingsRepository
import com.nuvio.app.features.debrid.DebridStreamMetadata
import com.nuvio.app.features.debrid.DebridStreamPresentation
import com.nuvio.app.features.debrid.LocalDebridAvailabilityService
import com.nuvio.app.features.details.MetaDetailsRepository
import com.nuvio.app.features.plugins.PluginScraperHostProvider
import com.nuvio.app.features.profiles.ProfilePinCrypto
import com.nuvio.app.features.tmdb.TmdbService
import kotlinx.atomicfu.locks.SynchronizedObject
import kotlinx.atomicfu.locks.synchronized
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.CoroutineStart
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.Job
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.coroutineScope
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asStateFlow
import kotlinx.coroutines.flow.update
import kotlinx.coroutines.isActive
import kotlinx.coroutines.job
import kotlinx.coroutines.launch
import kotlinx.coroutines.withTimeoutOrNull

/**
 * What the Detail page asks the format probe about: the title (movie) or the episode the Play
 * button targets (series). The caller passes no request until it knows that target; there is no
 * S1E1 fallback.
 */
data class TitleFormatRequest(
    val type: String,
    val videoId: String,
    val season: Int?,
    val episode: Int?,
) {
    /** The key of this request in [TitleFormatProbe.states]: `type:videoId[:season:episode]`. */
    val key: String
        get() = if (season == null && episode == null) "$type:$videoId" else "$type:$videoId:$season:$episode"

    /** Whether the picker's [StreamsUiState.requestToken] is this request, in either selection mode. */
    internal fun matchesPickerToken(token: String): Boolean =
        token == StreamsRepository.requestToken(type, videoId, season, episode, manualSelection = true) ||
            token == StreamsRepository.requestToken(type, videoId, season, episode, manualSelection = false)
}

/** Where a request's badges came from: the background probe, or the open stream picker. */
enum class TitleFormatSource { PROBE, PICKER }

/**
 * The badge row's model for one request. [source] is null until anything has been learned.
 * [generation] changes whenever the engine resets the request's badges (a new cache key, or an
 * answer that expired from the cache): within one generation badges only grow, so a watcher merges
 * within it and replaces on a change.
 */
data class TitleFormatState(
    val badges: List<TitleFormatBadge> = emptyList(),
    val isProbing: Boolean = false,
    val source: TitleFormatSource? = null,
    val generation: Int = 0,
)

/** The probe's I/O, faked in tests. */
internal interface TitleFormatFetcher {
    /** Streams embedded in the open meta for [videoId]; non-empty replaces the add-on fan-out. */
    fun embeddedStreams(videoId: String): List<StreamItem>

    /** One add-on's stream list for [target]. Throws on failure. */
    suspend fun streams(target: InstalledStreamAddonTarget, type: String): List<StreamItem>

    /** BUG-74: the IMDb id for a TMDB id, or null when TMDB has none. */
    suspend fun imdbFor(tmdbId: Int, type: String): String?

    /** The picker's local debrid cache check for one add-on's group (identity when none is due). */
    suspend fun annotateCache(group: AddonStreamGroup): AddonStreamGroup
}

/** Production I/O: the same calls the picker makes in `StreamsRepository`. */
internal object AddonTitleFormatFetcher : TitleFormatFetcher {
    override fun embeddedStreams(videoId: String): List<StreamItem> =
        MetaDetailsRepository.findEmbeddedStreams(videoId)

    override suspend fun streams(target: InstalledStreamAddonTarget, type: String): List<StreamItem> {
        val url = buildAddonResourceUrl(
            manifestUrl = target.manifest.transportUrl,
            resource = "stream",
            type = type,
            id = target.videoId,
        )
        StreamDiagnostics.log("probe fetch ${target.addonName}: ${StreamDiagnostics.redactUrl(url)}")
        // forceRefresh = false: a CDN or URL cache may serve the picker's identical GET.
        val payload = fetchAddonResponseText(url = url, forceRefresh = false)
        return StreamParser.parse(
            payload = payload,
            addonName = target.addonName,
            addonId = target.addonId,
            addonLogo = target.manifest.logoUrl,
        )
    }

    override suspend fun imdbFor(tmdbId: Int, type: String): String? =
        TmdbService.tmdbToImdb(tmdbId = tmdbId, mediaType = type)

    override suspend fun annotateCache(group: AddonStreamGroup): AddonStreamGroup {
        val eligible = setOf(group.addonId)
        if (!LocalDebridAvailabilityService.hasPendingCacheCheck(groups = listOf(group), eligibleGroupIds = eligible)) {
            return group
        }
        return LocalDebridAvailabilityService.annotateCachedAvailability(
            groups = listOf(group),
            eligibleGroupIds = eligible,
        ).firstOrNull() ?: group
    }
}

/**
 * The streams of one add-on's (cache-checked) group that the picker would present and list: the
 * picker's own presenter (Sources filters, excluded qualities, Cached Sources Only, inactive
 * resolver, NOT_CACHED hiding, per-group limits), then [StreamListability]. Badges are aggregated
 * from these, so a badge never advertises a stream the picker hides.
 */
internal fun presentForBadges(group: AddonStreamGroup, settings: DebridSettings): List<StreamItem> {
    val presented = DebridStreamPresentation.apply(
        groups = listOf(group),
        settings = settings,
        allStreams = StreamPresentationPlatform.filtersApplyToAllStreams,
    ).firstOrNull()?.streams.orEmpty()
        .filter { StreamListability.isListable(it, settings.canResolvePlayableLinks) }
    // The presenter's name/description templates can rewrite a managed stream's text (and drop a
    // "DV" or "CAM" in it); facts are read from the add-on's own stream that survived presentation.
    // Only an unambiguous match is used: when two originals share the playback fields, the
    // presented stream is kept as is, so a filtered-out sibling's format is never advertised.
    val originals = group.streams.groupBy { it.presentationIdentity() }
    return presented.map { stream ->
        val matches = originals[stream.presentationIdentity()].orEmpty()
        if (stream in matches) stream else matches.singleOrNull() ?: stream
    }
}

/** A stream without the two fields `DebridStreamFormatter` rewrites. */
private fun StreamItem.presentationIdentity(): StreamItem = copy(name = null, description = null)

/**
 * Detail-page format badges: a background probe of up to [MAX_ADDONS] of the user's stream add-ons
 * per request, plus a fold of the open picker's streams. Swift calls [start] / [cancel] and watches
 * [states] with `FlowWatcher` (Kotlin→Swift `async` does not propagate cancellation).
 *
 * - **Probe.** Embedded meta streams, when present, are aggregated with no network. Otherwise a
 *   cache hit answers at once; a miss resolves the BUG-74 tmdb→imdb remap (same gate as the
 *   repository), takes the first [MAX_ADDONS] matching add-ons in user order and fetches them in
 *   parallel. Each add-on (fetch, debrid cache check, presentation) has [ADDON_TIMEOUT_MS]; a late
 *   or failed add-on is dropped and the others count. The whole probe has [PROBE_TIMEOUT_MS]; what
 *   is in by then counts. Remaining fetches stop early once [TitleFormatBadges.isComplete].
 * - **Fold.** One long-lived collector of the picker's state, independent of any probe job. While
 *   the picker's request token is a tracked request (either `manualSelection`), its presented,
 *   listable streams merge into that request's badges and into the cache (source PICKER), per
 *   emission. [cancel] stops only the network probe, so the fold keeps working under the picker.
 * - **Growth.** Within one [TitleFormatState.generation] of a request key, badges only grow
 *   ([TitleFormatBadges.merge]). Starting a request whose cache key changed (add-ons, debrid keys or
 *   filter settings), or whose earlier answer expired from the cache, resets it to a new generation.
 * - **Cache.** [TitleFormatProbeCache]: LRU 200, 6 h / 30 min TTL. A probe where every add-on failed
 *   or timed out is not cached; nor are embedded streams (no network to save).
 *
 * [scope] hosts the probe jobs and the fold collector (tests pass `backgroundScope`, since the
 * collector never completes). State is guarded by one lock, so [start] / [cancel] may be called
 * from any thread.
 */
internal class TitleFormatProbeEngine(
    private val fetcher: TitleFormatFetcher,
    clock: () -> Long,
    private val scope: CoroutineScope,
    private val settings: () -> DebridSettings,
    private val installedAddons: () -> List<ManagedAddon>,
    private val pickerState: StateFlow<StreamsUiState>,
    /** The enabled plugin scrapers for a type (`repositoryUrl#id@version`): the picker fold caches their streams. */
    private val pluginScrapers: (type: String) -> List<String> = { emptyList() },
) {
    /**
     * A request the engine answers for. [cacheKey] is null for embedded streams (never cached).
     * [canResolve] is the debrid flag read at [start], reused by the fold off the main thread.
     */
    private class Tracked(
        val request: TitleFormatRequest,
        val cacheKey: String?,
        val canResolve: Boolean,
        var job: Job? = null,
        /** A run answered (embedded, cache hit or a finished probe); a later miss means it expired. */
        var answered: Boolean = false,
    )

    private val lock = SynchronizedObject()
    private val cache = TitleFormatProbeCache(clock)
    /** By [TitleFormatRequest.key], oldest first; bounded by [MAX_TRACKED]. */
    private val tracked = LinkedHashMap<String, Tracked>()
    private var foldJob: Job? = null
    /** The last [TitleFormatState.generation] handed out; guarded by [lock]. */
    private var lastGeneration = 0

    private val _states = MutableStateFlow<Map<String, TitleFormatState>>(emptyMap())
    val states: StateFlow<Map<String, TitleFormatState>> = _states.asStateFlow()

    /**
     * What [request] may show right now, before any [start]: its published state, unless that was
     * learned under another configuration (cache key) or its cached answer has expired, in which
     * case an empty state of the same generation (the next [start] resets it). No network.
     */
    fun state(request: TitleFormatRequest): TitleFormatState {
        val published = rawState(request)
        val (entryKey, answered) = synchronized(lock) {
            val entry = tracked[request.key] ?: return published
            (entry.cacheKey ?: return published) to entry.answered
        }
        val currentKey = currentCacheKey(request)
        val stale = currentKey != entryKey || (answered && synchronized(lock) { cache.get(entryKey) } == null)
        return if (stale) TitleFormatState(generation = published.generation) else published
    }

    private fun rawState(request: TitleFormatRequest): TitleFormatState =
        _states.value[request.key] ?: TitleFormatState()

    /**
     * Tracks [request] for the picker fold with no network (Detail calls it at once, before the
     * dwell), so a picker opened during the dwell still lands. Folds the picker's current state.
     * A request tracked under another configuration is reset to a new generation.
     */
    fun watch(request: TitleFormatRequest) {
        ensureFoldCollector()
        val currentSettings = settings()
        val embedded = fetcher.embeddedStreams(request.videoId)
        val cacheKey = if (embedded.isEmpty()) currentCacheKey(request, currentSettings) else null
        synchronized(lock) {
            val previous = tracked[request.key]
            if (previous != null && previous.cacheKey == cacheKey) {
                foldInto(previous, pickerState.value, configChecked = true)
                return
            }
            previous?.job?.cancel()
            resetState(request.key)
            val entry = Tracked(request, cacheKey, currentSettings.canResolvePlayableLinks)
            track(entry)
            foldInto(entry, pickerState.value, configChecked = true)
        }
    }

    private fun currentCacheKey(request: TitleFormatRequest, currentSettings: DebridSettings = settings()): String =
        cacheKeyFor(request, installedAddons(), currentSettings, pluginScrapers(request.type))

    /** Starts (or answers from cache) the probe for [request]. A no-op while the same probe runs. */
    fun start(request: TitleFormatRequest) {
        ensureFoldCollector()
        val currentSettings = settings()
        val installed = installedAddons()
        val canResolve = currentSettings.canResolvePlayableLinks
        val embedded = fetcher.embeddedStreams(request.videoId)
        val cacheKey = if (embedded.isEmpty()) cacheKeyFor(request, installed, currentSettings, pluginScrapers(request.type)) else null

        val job = synchronized(lock) {
            val previous = tracked[request.key]
            if (previous != null && previous.cacheKey == cacheKey && previous.job?.isActive == true) return
            previous?.job?.cancel()
            val hit = cacheKey?.let { cache.get(it) }
            // Same cache key: what this key already showed stays (badges only grow), unless its
            // answer is no longer cached (expired): then the fresh probe must not inherit it.
            // A run cancelled before it answered keeps its partial badges and grows on.
            if (previous == null || previous.cacheKey != cacheKey || (hit == null && previous.answered)) {
                resetState(request.key)
            }
            val entry = Tracked(request, cacheKey, canResolve)
            track(entry)
            // The collector folds only new emissions: a picker that settled on this request before
            // it was tracked (opened during the dwell) is folded here, under the same lock.
            foldInto(entry, pickerState.value, configChecked = true)

            if (cacheKey == null) {
                entry.answered = true
                val badges = TitleFormatBadges.aggregateStreams(
                    embedded.filter { StreamListability.isListable(it, canResolve) },
                )
                publish(request.key) { it.copy(badges = TitleFormatBadges.merge(it.badges, badges), isProbing = false, source = TitleFormatSource.PROBE) }
                StreamDiagnostics.log("probe done ${badges.describe()} (embedded)")
                return
            }

            if (hit != null) {
                entry.answered = true
                StreamDiagnostics.log("probe cache hit $cacheKey")
                publish(request.key) { it.copy(badges = TitleFormatBadges.merge(it.badges, hit.badges), isProbing = false, source = it.source.upgradedTo(hit.source)) }
                return
            }

            publish(request.key) { it.copy(isProbing = true) }
            scope.launch(start = CoroutineStart.LAZY) {
                runProbe(entry, cacheKey, installed, currentSettings)
            }.also { entry.job = it }
        }
        // Assigned before it can run, so cancel() always finds the job it must stop.
        job.start()
    }

    /**
     * Stops [request]'s network probe (Detail disappeared). The request stays tracked, so the picker
     * fold still lands; a later [start] answers from cache or probes again.
     */
    fun cancel(request: TitleFormatRequest) {
        synchronized(lock) {
            val entry = tracked[request.key] ?: return
            val job = entry.job ?: return
            entry.job = null
            // isCompleted, not isActive: a LAZY job start() has not started yet is not active, and
            // must still be cancelled so its start() is a no-op.
            if (job.isCompleted) return
            job.cancel()
            StreamDiagnostics.log("probe cancel ${entry.cacheKey}")
            publish(request.key) { it.copy(isProbing = false) }
        }
    }

    private suspend fun runProbe(
        entry: Tracked,
        cacheKey: String,
        installed: List<ManagedAddon>,
        settings: DebridSettings,
    ) = coroutineScope {
        val request = entry.request
        var anySucceeded = false // guarded by lock
        // What this run's add-ons answered (guarded by lock): the cache records only this, never
        // badges the visible state carried over from an earlier run.
        var runBadges = emptyList<TitleFormatBadge>()
        // Parent of the per-add-on fetches, so early exit and the overall cap can stop them all
        // without cancelling this coroutine. Supervisor: one add-on's bug never stops the others.
        val fetches = SupervisorJob(parent = coroutineContext.job)
        val inTime = withTimeoutOrNull(PROBE_TIMEOUT_MS) {
            val targets = probeTargets(request, installed)
            targets.forEach { target ->
                launch(fetches) {
                    val badges = probeAddon(target, request.type, settings) ?: return@launch
                    val complete = synchronized(lock) {
                        // Checked under the lock cancel() takes, so a cancelled run never publishes.
                        if (!isActive) return@launch
                        anySucceeded = true
                        runBadges = TitleFormatBadges.merge(runBadges, badges)
                        publish(request.key) { it.copy(badges = TitleFormatBadges.merge(it.badges, badges)) }
                        // This run's own answer, which is what gets cached: badges carried over
                        // from an interrupted run must not stop the fetches short of a full answer.
                        TitleFormatBadges.isComplete(runBadges)
                    }
                    if (complete) fetches.cancel()
                }
            }
            fetches.complete()
            fetches.join()
        }
        if (inTime == null) {
            fetches.cancel()
            StreamDiagnostics.log("probe timeout overall")
        }

        val badges = synchronized(lock) {
            if (!isActive) return@coroutineScope
            if (anySucceeded) cache.record(cacheKey, runBadges, TitleFormatSource.PROBE)
            entry.answered = true
            publish(request.key) { it.copy(isProbing = false, source = it.source.upgradedTo(TitleFormatSource.PROBE)) }
            rawState(request).badges
        }
        StreamDiagnostics.log("probe done ${badges.describe()}")
    }

    /** The first [MAX_ADDONS] matching add-ons, with the repository's BUG-74 remap gate. */
    private suspend fun probeTargets(
        request: TitleFormatRequest,
        installed: List<ManagedAddon>,
    ): List<InstalledStreamAddonTarget> {
        val enabled = installed.enabledAddons()
        val typeStreamIdPrefixes = enabled.mapNotNull { addon ->
            addon.manifest?.resources
                ?.filter { it.name == "stream" && it.types.contains(request.type) }
                ?.flatMap { it.idPrefixes }
                ?.takeIf { it.isNotEmpty() }
        }
        val tmdbId = StreamVideoIdRemap.parseTmdbId(request.videoId)
        val imdbVideoId = if (
            tmdbId != null &&
            StreamVideoIdRemap.wouldReachMoreAddons(request.videoId, typeStreamIdPrefixes)
        ) {
            runCatchingUnlessCancelled { fetcher.imdbFor(tmdbId, request.type) }
                .getOrNull()
                ?.let { StreamVideoIdRemap.withImdbId(request.videoId, it) }
        } else {
            null
        }
        return streamAddonTargets(enabled, request.type, request.videoId, imdbVideoId).take(MAX_ADDONS)
    }

    /**
     * One add-on's badges, or null when it failed or timed out. `withTimeoutOrNull` sits OUTSIDE
     * `runCatchingUnlessCancelled`: the timeout's cancellation is rethrown by the runCatching and
     * caught by `withTimeoutOrNull`, so a late add-on drops alone and a real cancel still propagates.
     */
    private suspend fun probeAddon(
        target: InstalledStreamAddonTarget,
        type: String,
        settings: DebridSettings,
    ): List<TitleFormatBadge>? {
        val result = withTimeoutOrNull(ADDON_TIMEOUT_MS) {
            runCatchingUnlessCancelled {
                val streams = fetcher.streams(target, type)
                StreamDiagnostics.log("probe got ${streams.size} from ${target.addonName}")
                val group = AddonStreamGroup(
                    addonName = target.addonName,
                    addonId = target.addonId,
                    streams = streams,
                    isLoading = false,
                )
                val checked = if (streams.isEmpty()) group else fetcher.annotateCache(group)
                TitleFormatBadges.aggregateStreams(presentForBadges(checked, settings))
            }
        }
        if (result == null) {
            StreamDiagnostics.log("probe timeout ${target.addonName}")
            return null
        }
        return result.getOrElse { error ->
            StreamDiagnostics.log("probe FAILED ${target.addonName}: ${redactMessage(error.message)}")
            null
        }
    }

    private fun ensureFoldCollector() {
        synchronized(lock) {
            if (foldJob != null) return
            foldJob = scope.launch { pickerState.collect { fold(it) } }
        }
    }

    /** Folds the picker's presented, listable streams into every tracked request it is showing. */
    private fun fold(state: StreamsUiState) {
        synchronized(lock) {
            tracked.values.forEach { foldInto(it, state, configChecked = false) }
        }
    }

    /**
     * Call under [lock]. Folds [state] into [entry] when the picker is showing its request and
     * [entry] was tracked under the current configuration: a picker opened after an account, add-on
     * or filter change must not write into the old configuration's cache entry (the next [start]
     * re-tracks the request under the new key and folds the picker then). [configChecked]: the
     * caller just computed [entry]'s key from the current configuration.
     */
    private fun foldInto(entry: Tracked, state: StreamsUiState, configChecked: Boolean) {
        val token = state.requestToken ?: return
        if (!entry.request.matchesPickerToken(token)) return
        if (!configChecked && entry.cacheKey != null &&
            entry.cacheKey != currentCacheKey(entry.request)
        ) {
            return
        }
        val settled = !state.isAnyLoading
        val badges = TitleFormatBadges.aggregateStreams(
            state.groups.flatMap { it.streams }.filter { StreamListability.isListable(it, entry.canResolve) },
        )
        if (badges.isEmpty() && !settled) return
        // The entry's earlier answer expired from the cache: start a new generation, so the
        // picker's answer is not merged into (and re-cached with) the expired badges.
        if (entry.answered && entry.cacheKey != null && cache.get(entry.cacheKey) == null) {
            resetState(entry.request.key)
            entry.answered = false
        }
        // Like the probe: an empty answer is cached only if some source actually answered,
        // and only once the picker settled (a partial answer would suppress a full probe).
        val answered = badges.isNotEmpty() || state.groups.any { it.error.isNullOrBlank() }
        if (entry.cacheKey != null && answered && settled) {
            cache.record(entry.cacheKey, badges, TitleFormatSource.PICKER)
            // A cached answer: once it expires, the next start resets instead of growing on it.
            entry.answered = true
        }
        publish(entry.request.key) {
            it.copy(badges = TitleFormatBadges.merge(it.badges, badges), source = TitleFormatSource.PICKER)
        }
    }

    /** Call under [lock]. Re-inserts [entry] as the newest; the oldest beyond [MAX_TRACKED] is dropped. */
    private fun track(entry: Tracked) {
        tracked.remove(entry.request.key)
        tracked[entry.request.key] = entry
        while (tracked.size > MAX_TRACKED) {
            val oldest = tracked.remove(tracked.keys.first()) ?: break
            oldest.job?.cancel()
            _states.update { it - oldest.request.key }
        }
    }

    /** Call under [lock]. Replaces [requestKey]'s state with an empty one of a new generation. */
    private fun resetState(requestKey: String) {
        lastGeneration += 1
        val fresh = TitleFormatState(generation = lastGeneration)
        _states.update { it + (requestKey to fresh) }
    }

    private fun publish(requestKey: String, transform: (TitleFormatState) -> TitleFormatState) {
        _states.update { states -> states + (requestKey to transform(states[requestKey] ?: TitleFormatState())) }
    }

    internal companion object {
        const val MAX_ADDONS = 3
        const val ADDON_TIMEOUT_MS = 8_000L
        const val PROBE_TIMEOUT_MS = 10_000L
        /** Requests kept for the picker fold and [states]; far above what one browsing session holds open. */
        const val MAX_TRACKED = 32

        private val urlRegex = Regex("""https?://\S+""")

        /**
         * `type:videoId[:s:e]:<hash>` (the first 16 hex digits of a SHA-256). The hash covers the enabled stream add-ons for the type in
         * user order (order picks the first [MAX_ADDONS]; the instance id embeds the manifest URL, so a
         * config change counts), the debrid resolve flag, the active resolver, Cached Sources Only and
         * the effective Sources filters, the enabled plugin scrapers (the picker fold caches their
         * streams), and the debrid API keys (two accounts on one provider can
         * differ in cached availability). Only the hash is kept: add-on ids and keys are secrets.
         */
        fun cacheKeyFor(
            request: TitleFormatRequest,
            installed: List<ManagedAddon>,
            settings: DebridSettings,
            pluginScrapers: List<String> = emptyList(),
        ): String {
            val streamAddonIds = installed.enabledAddons().mapNotNull { addon ->
                val manifest = addon.manifest ?: return@mapNotNull null
                val servesType = manifest.resources.any { it.name == "stream" && it.types.contains(request.type) }
                if (servesType) addon.streamAddonInstanceId(manifest.id) else null
            }
            val fingerprint = listOf(
                streamAddonIds,
                pluginScrapers,
                settings.canResolvePlayableLinks,
                settings.activeResolverProviderId,
                settings.providerApiKeys,
                settings.streamCachedOnly,
                DebridStreamMetadata.effectivePreferences(settings),
                // The picker fold parses presented streams, whose text these templates rewrite.
                settings.streamNameTemplate,
                settings.streamDescriptionTemplate,
            ).toString()
            // SHA-256, not hashCode(): two accounts' keys must not collide into one cache entry.
            return "${request.key}:${ProfilePinCrypto.sha256Hex(fingerprint).take(16)}"
        }

        /** An error message with any URL in it shortened by [StreamDiagnostics.redactUrl]. */
        fun redactMessage(message: String?): String =
            message?.replace(urlRegex) { StreamDiagnostics.redactUrl(it.value) } ?: "unknown error"

        private fun List<TitleFormatBadge>.describe(): String =
            if (isEmpty()) "none" else joinToString(" ") { it.label }

        private fun TitleFormatSource?.upgradedTo(source: TitleFormatSource): TitleFormatSource =
            if (this == TitleFormatSource.PICKER) TitleFormatSource.PICKER else source
    }
}

/**
 * The production probe, shared with Swift as `TitleFormatProbe.shared`. Swift watches [states] with
 * `FlowWatcher` and reads its own entry by [TitleFormatRequest.key]; it calls [start] when the Detail
 * page has settled on a request and [cancel] when the page disappears.
 */
object TitleFormatProbe {
    private val engine = TitleFormatProbeEngine(
        fetcher = AddonTitleFormatFetcher,
        clock = { kotlin.time.Clock.System.now().toEpochMilliseconds() },
        scope = CoroutineScope(SupervisorJob() + Dispatchers.Default + uncaughtCoroutineLogger("TitleFormatProbe")),
        settings = { DebridSettingsRepository.snapshot() },
        installedAddons = { AddonRepository.uiState.value.addons },
        pickerState = StreamsRepository.uiState,
        pluginScrapers = { type ->
            if (FeaturePolicyProvider.policy.pluginsEnabled) {
                PluginScraperHostProvider.host.getEnabledScrapersForType(type).map { "${it.repositoryUrl}#${it.id}@${it.version}" }
            } else {
                emptyList()
            }
        },
    )

    /** Badge state per [TitleFormatRequest.key]. */
    val states: StateFlow<Map<String, TitleFormatState>>
        get() = engine.states

    fun state(request: TitleFormatRequest): TitleFormatState = engine.state(request)

    fun watch(request: TitleFormatRequest) = engine.watch(request)

    fun start(request: TitleFormatRequest) = engine.start(request)

    fun cancel(request: TitleFormatRequest) = engine.cancel(request)
}
