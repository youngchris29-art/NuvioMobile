package com.nuvio.app.features.streams

import com.nuvio.app.core.coroutines.uncaughtCoroutineLogger
import co.touchlab.kermit.Logger
import com.nuvio.app.features.debrid.DirectDebridStreamPreparer
import com.nuvio.app.features.debrid.DebridSettingsRepository
import com.nuvio.app.features.details.MetaDetailsRepository
import com.nuvio.app.features.player.PlayerSettingsRepository
import com.nuvio.app.features.plugins.PluginsUiState
import com.nuvio.app.features.tmdb.TmdbService
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.CoroutineStart
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.Job
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.delay
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.launch

object StreamsRepository {
    private val log = Logger.withTag("StreamsRepo")
    private val scope = CoroutineScope(SupervisorJob() + Dispatchers.Default + uncaughtCoroutineLogger("StreamsRepository"))
    /**
     * W4 (review r1): the state and the generation of the load that owns it, swapped as one value.
     * Every new load, [cancelLoading] and [clear] take it over; a load writes only with the
     * generation it took, so a superseded load can never commit (see [GenerationalStreamsState]).
     */
    private val state = GenerationalStreamsState()
    val uiState: StateFlow<StreamsUiState> = state.view

    private var activeJob: Job? = null
    private var activeRequestKey: String? = null

    /**
     * W4 (review r1): the session search the current state comes from, and the BUG-74 id it was
     * built with; null while the state is not a session's (embedded streams, an empty outcome, a
     * remap in progress). A repeated request is skipped only while the store still serves exactly
     * this search, so its identity (profile, add-ons, debrid account) and expiry rule apply.
     */
    private var activeSearchKey: StreamSearchKey? = null
    private var activeImdbVideoId: String? = null

    fun requestToken(
        type: String,
        videoId: String,
        season: Int? = null,
        episode: Int? = null,
        manualSelection: Boolean = false,
    ): String =
        "$type::$videoId::$season::$episode::$manualSelection"

    fun load(type: String, videoId: String, parentMetaId: String? = null, season: Int? = null, episode: Int? = null, manualSelection: Boolean = false) {
        load(
            type = type,
            videoId = videoId,
            parentMetaId = parentMetaId,
            season = season,
            episode = episode,
            manualSelection = manualSelection,
            forceRefresh = false,
        )
    }

    fun reload(type: String, videoId: String, parentMetaId: String? = null, season: Int? = null, episode: Int? = null, manualSelection: Boolean = false) {
        load(
            type = type,
            videoId = videoId,
            parentMetaId = parentMetaId,
            season = season,
            episode = episode,
            manualSelection = manualSelection,
            forceRefresh = true,
        )
    }

    /**
     * [imdbVideoId] is BUG-74's resolved alternate id: non-null only on the second pass, after the
     * suspend TMDB lookup below has turned a `tmdb:` request into the `tt` one that most stream
     * addons are keyed on. Addons are then matched against whichever of the two they accept.
     */
    private fun load(type: String, videoId: String, parentMetaId: String?, season: Int?, episode: Int?, manualSelection: Boolean, forceRefresh: Boolean, imdbVideoId: String? = null, remapAttempted: Boolean = false) {
        val environment = StreamSearchEnvironment.stamp()                // review r10: before anything else
        val pluginUiState = StreamSearchRequests.pluginUiState()
        val requestToken = requestToken(
            type = type,
            videoId = videoId,
            season = season,
            episode = episode,
            manualSelection = manualSelection,
        )
        val requestKey = "$requestToken::pluginsGrouped=${pluginUiState.groupStreamsByRepository}"
        val currentState = state.value
        if (
            !forceRefresh &&
            activeRequestKey == requestKey &&
            (currentState.groups.isNotEmpty() || currentState.emptyStateReason != null || currentState.isAnyLoading) &&
            isStillServed(type, videoId, season, episode, pluginUiState)
        ) {
            log.d { "Skipping stream reload for unchanged request type=$type id=$videoId" }
            return
        }

        activeRequestKey = requestKey
        activeSearchKey = null
        activeImdbVideoId = null
        activeJob?.cancel()
        // Stream picker A, P0.1: the per-add-on chip survives a refresh of the same title (tvOS
        // only, see StreamFilterRetention) and resets on a new one. Every fresh state built below
        // carries it, and the fan-out drops it if the add-on is no longer asked.
        val carriedFilter = StreamFilterRetention.carriedFilter(currentState, requestToken)
        val generation = state.takeOver(StreamsUiState(requestToken = requestToken, selectedFilter = carriedFilter))

        PlayerSettingsRepository.ensureLoaded()
        val playerSettings = PlayerSettingsRepository.uiState.value
        val debridSettings = DebridSettingsRepository.snapshot()
        val streamBadgeRules = StreamBadgeSettingsRepository.snapshot()
        val autoPlayMode = playerSettings.streamAutoPlayMode
        val isAutoPlayEnabled = !manualSelection && autoPlayMode != StreamAutoPlayMode.MANUAL &&
            !(autoPlayMode == StreamAutoPlayMode.REGEX_MATCH &&
                !StreamAutoPlayPolicy.isRegexSelectionConfigured(playerSettings.streamAutoPlayRegex))

        // Look up persisted binge group when both settings are enabled
        val persistedBingeGroup = if (
            playerSettings.streamAutoPlayPreferBingeGroup &&
            playerSettings.streamAutoPlayReuseBingeGroup
        ) {
            parentMetaId?.let { BingeGroupCacheRepository.get(it) }
        } else null

        // Enable direct auto-play flow if normal auto-play is enabled,
        // OR if we have a persisted binge group in MANUAL mode
        val bingeGroupDirectFlow = !manualSelection &&
            persistedBingeGroup != null &&
            autoPlayMode == StreamAutoPlayMode.MANUAL
        val isDirectAutoPlayFlow = isAutoPlayEnabled || bingeGroupDirectFlow

        if (isDirectAutoPlayFlow) {
            state.setIfCurrent(generation, StreamsUiState(
                requestToken = requestToken,
                selectedFilter = carriedFilter,
                isDirectAutoPlayFlow = true,
                showDirectAutoPlayOverlay = true,
            ))
        }

        val embeddedStreams = MetaDetailsRepository.findEmbeddedStreams(videoId)
        if (embeddedStreams.isNotEmpty()) {
            log.d { "Using ${embeddedStreams.size} embedded streams for type=$type id=$videoId" }
            val group = AddonStreamGroup(
                addonName = embeddedStreams.first().addonName,
                addonId = "embedded",
                streams = embeddedStreams,
                isLoading = false,
            )
            val presentedGroup = StreamBadgePresentation.apply(
                groups = listOf(group),
                rules = streamBadgeRules,
            ).firstOrNull() ?: group
            state.setIfCurrent(generation, StreamsUiState(
                requestToken = requestToken,
                groups = listOf(presentedGroup),
                activeAddonIds = setOf("embedded"),
                selectedFilter = StreamFilterRetention.validated(carriedFilter, listOf(presentedGroup)),
                // Embedded streams come from the (installed) meta addon, so they classify as an
                // installed-addon source for the auto-play scope (Codex r2 on the 58864ec1 port).
                installedAddonIds = setOf("embedded"),
                isAnyLoading = false,
            ))
            return
        }

        val installedAddons = StreamSearchEnvironment.installedAddons()
        val pluginGeneration = StreamSearchSessions.pluginGeneration()   // review r6: before the groups
        val pluginProviderGroups = StreamSearchRequests.pluginProviderGroups(type, pluginUiState)

        if (installedAddons.isEmpty() && pluginProviderGroups.isEmpty()) {
            state.setIfCurrent(generation, StreamsUiState(
                requestToken = requestToken,
                selectedFilter = carriedFilter,
                isAnyLoading = false,
                emptyStateReason = StreamsEmptyStateReason.NoAddonsInstalled,
            ))
            return
        }

        // BUG-74: per-addon request id selection lives in streamAddonTargets().
        val streamAddons = streamAddonTargets(installedAddons, type, videoId, imdbVideoId)

        log.d { "Found ${streamAddons.size} addons for stream type=$type id=$videoId" }
        // Name BOTH ids on the second pass. The first version of this line printed only the
        // original, so a photographed log showed "id=tmdb:550" twice with different addon counts
        // and no visible reason — the remap is the reason, and the line has to say so.
        StreamDiagnostics.log(
            "match type=$type id=$videoId" +
                (imdbVideoId?.let { " +$it" } ?: "") +
                " → addons=${streamAddons.size}/${installedAddons.size} plugins=${pluginProviderGroups.size}"
        )

        // BUG-74: if a `tmdb:` request is leaving some of the user's stream addons unasked, resolve
        // the IMDb id and run the match again with BOTH ids available, so each addon can be asked
        // with the one it accepts. Gated on `remapAttempted`, not on the result, so a title with no
        // IMDb id on TMDB resolves once and then proceeds normally instead of looping.
        val typeStreamIdPrefixes = StreamSearchRequests.typeStreamIdPrefixes(installedAddons, type)
        val tmdbId = StreamVideoIdRemap.parseTmdbId(videoId)
        if (
            !remapAttempted &&
            tmdbId != null &&
            StreamVideoIdRemap.wouldReachMoreAddons(videoId, typeStreamIdPrefixes)
        ) {
            state.setIfCurrent(generation, StreamsUiState(requestToken = requestToken, selectedFilter = carriedFilter, isAnyLoading = true))
            // LAZY + assign + start, not a bare `activeJob = scope.launch {}`: the body must not be
            // able to run before the field holds it. It nulls that same field below, and a plain
            // launch could interleave the two so `activeJob` ended up pointing at this finished
            // remap instead of the real fetch — leaving `clear()` cancelling a corpse.
            val remapJob = scope.launch(start = CoroutineStart.LAZY) {
                val imdbId = TmdbService.tmdbToImdb(tmdbId = tmdbId, mediaType = type)
                // Cancellation is the supersede guard: `clear()` and any newer `load()` both cancel
                // `activeJob`, which is this job until the lines below, so a request replaced while
                // resolving dies at the suspension above and never re-enters.
                val remapped = imdbId?.let { StreamVideoIdRemap.withImdbId(videoId, it) }
                if (remapped != null) {
                    log.d { "Remapped tmdb id for streams: $videoId -> $remapped" }
                    StreamDiagnostics.log("remap $videoId → $remapped")
                } else {
                    log.w { "No IMDb id for tmdb:$tmdbId ($type) — tt-only stream addons stay unreachable" }
                    StreamDiagnostics.log("remap FAILED $videoId → no imdb id on tmdb")
                }
                // Re-enter either way. On failure `imdbVideoId` stays null and the second pass
                // matches exactly as the first did, so whatever addons DID accept the tmdb id are
                // still fetched — the resolution failing must not cost the user a working source.
                // Release both guards first: `activeRequestKey` so the reload isn't skipped as
                // "unchanged", `activeJob` so the reload's own `activeJob?.cancel()` can't cancel
                // the coroutine making the call. `videoId` stays the ORIGINAL — the second pass
                // needs both ids. parentMetaId passes through untouched; it keys the binge-group
                // cache, not an addon request.
                // W4: and a lookup that returned after a newer load (or clear) took over must not
                // re-enter over it; cancellation alone misses a lookup that ignores it.
                if (state.generation != generation) return@launch
                activeRequestKey = null
                activeJob = null
                load(
                    type = type,
                    videoId = videoId,
                    parentMetaId = parentMetaId,
                    season = season,
                    episode = episode,
                    manualSelection = manualSelection,
                    forceRefresh = forceRefresh,
                    imdbVideoId = remapped,
                    remapAttempted = true,
                )
            }
            activeJob = remapJob
            remapJob.start()
            return
        }

        if (streamAddons.isEmpty() && pluginProviderGroups.isEmpty()) {
            state.setIfCurrent(generation, StreamsUiState(
                requestToken = requestToken,
                selectedFilter = carriedFilter,
                isAnyLoading = false,
                // BUG-74: a `tmdb:` id that reached here either had no IMDb equivalent or found no
                // addon willing to take either form. Either way the id — not the user's addon
                // list — is why nothing was asked, and saying so is the whole point of the split.
                emptyStateReason = if (tmdbId != null) {
                    StreamsEmptyStateReason.IncompatibleContentId
                } else {
                    StreamsEmptyStateReason.NoCompatibleAddons
                },
            ))
            return
        }

        // Initialise loading placeholders
        val installedAddonOrder = streamAddons.map { it.addonName }
        val initialGroups = StreamAutoPlaySelector.orderAddonStreams(streamAddons.map { addon ->
            AddonStreamGroup(
                addonName = addon.addonName,
                addonId = addon.addonId,
                streams = emptyList(),
                isLoading = true,
            )
        } + pluginProviderGroups.map { providerGroup ->
            AddonStreamGroup(
                addonName = providerGroup.addonName,
                addonId = providerGroup.addonId,
                streams = emptyList(),
                isLoading = true,
            )
        }, installedAddonOrder)
        val isInitiallyLoading = initialGroups.any { it.isLoading }
        state.setIfCurrent(generation, StreamsUiState(
            requestToken = requestToken,
            groups = initialGroups,
            activeAddonIds = initialGroups.map { it.addonId }.toSet(),
            selectedFilter = StreamFilterRetention.validated(carriedFilter, initialGroups),
            installedAddonIds = streamAddons.map { it.addonId }.toSet(),
            isAnyLoading = isInitiallyLoading,
            emptyStateReason = null,
            isDirectAutoPlayFlow = isDirectAutoPlayFlow,
            showDirectAutoPlayOverlay = isDirectAutoPlayFlow,
        ))

        val searchTargets = StreamSearchTargets(
            type = type,
            videoId = videoId,
            season = season,
            episode = episode,
            streamAddons = streamAddons,
            pluginProviderGroups = pluginProviderGroups,
            debrid = StreamSearchEnvironment.debrid(),
            pluginGeneration = pluginGeneration,
            environment = environment,
        )
        val searchProfileId = StreamSearchEnvironment.profileId()
        activeSearchKey = searchTargets.key(searchProfileId)
        activeImdbVideoId = imdbVideoId

        activeJob = scope.launch {
            val installedAddonNames = installedAddonOrder.toSet()
            val installedAddonIds = streamAddons.map { it.addonId }.toSet()
            var autoSelectTriggered = false
            var timeoutElapsed = false

            // W4: every write of this load goes through here, so a superseded load (a newer load,
            // clear, cancelLoading) cannot land a late write on the state that replaced it, even
            // from a write already in flight on another thread when the job was cancelled.
            fun updateIfCurrent(transform: (StreamsUiState) -> StreamsUiState) {
                state.updateIfCurrent(generation, transform)
            }

            fun evaluateAutoPlay(bingeGroupOnly: Boolean = false): StreamAutoPlayEvaluation =
                StreamAutoPlaySelector.evaluateAutoPlayStream(
                    streams = state.value.groups.flatMap { it.streams },
                    mode = autoPlayMode,
                    regexPattern = playerSettings.streamAutoPlayRegex,
                    source = playerSettings.streamAutoPlaySource,
                    installedAddonNames = installedAddonNames,
                    selectedAddons = playerSettings.streamAutoPlaySelectedAddons,
                    selectedPlugins = playerSettings.streamAutoPlaySelectedPlugins,
                    preferredBingeGroup = persistedBingeGroup,
                    preferBingeGroupInSelection = persistedBingeGroup != null,
                    bingeGroupOnly = bingeGroupOnly,
                    debridEnabled = debridSettings.canResolvePlayableLinks,
                    activeResolverProviderId = debridSettings.activeResolverProviderId,
                    // beta.19-rc1 verdict (A, BUG-136): tvOS ranks FIRST_STREAM by quality;
                    // mobile stays on list order (StreamAutoPlayPlatform).
                    ranking = StreamAutoPlayPlatform.firstStreamRanking,
                )

            fun settleAutoPlay(evaluation: StreamAutoPlayEvaluation) {
                if (autoSelectTriggered) return
                autoSelectTriggered = true
                updateIfCurrent { current ->
                    if (evaluation.stream == null) {
                        current.copy(
                            autoPlayStream = null,
                            autoPlayCandidates = emptyList(),
                            isDirectAutoPlayFlow = false,
                            showDirectAutoPlayOverlay = false,
                        )
                    } else {
                        current.copy(
                            autoPlayStream = evaluation.stream,
                            autoPlayCandidates = evaluation.readyStreams,
                        )
                    }
                }
            }

            fun updateAutoPlayAfterStreamsChanged() {
                if (!isDirectAutoPlayFlow || autoSelectTriggered) return

                val earlyEvaluation = when {
                    timeoutElapsed -> evaluateAutoPlay()
                    persistedBingeGroup != null -> evaluateAutoPlay(bingeGroupOnly = true)
                    else -> null
                }
                if (earlyEvaluation?.stream != null) {
                    settleAutoPlay(earlyEvaluation)
                    return
                }

                if (
                    state.value.groups.areAutoPlaySourcesLoaded(
                        source = playerSettings.streamAutoPlaySource,
                        installedAddonIds = installedAddonIds,
                    )
                ) {
                    settleAutoPlay(evaluateAutoPlay())
                }
            }

            updateAutoPlayAfterStreamsChanged()

            val timeoutJob = if (isDirectAutoPlayFlow) {
                val timeoutSeconds = playerSettings.streamAutoPlayTimeoutSeconds
                val isUnlimitedTimeout = timeoutSeconds == Int.MAX_VALUE
                // Timeout semantics:
                // - 0 (instant): timeoutElapsed immediately, full select on each response
                // - 1-30 (bounded): wait the configured delay, then full select
                // - unlimited (Int.MAX_VALUE): timeoutElapsed immediately, full select on each response,
                //   with 60s hard fallback to stream picker
                if (timeoutSeconds <= 0 || isUnlimitedTimeout) {
                    timeoutElapsed = true
                    // For unlimited: launch a hard 60s fallback to dismiss overlay
                    if (isUnlimitedTimeout) {
                        launch {
                            delay(60_000L)
                            if (!autoSelectTriggered) {
                                settleAutoPlay(evaluateAutoPlay())
                            }
                        }
                    } else {
                        null
                    }
                } else {
                    // Bounded timeout (1-30s)
                    launch {
                        delay(timeoutSeconds * 1_000L)
                        timeoutElapsed = true
                        if (!autoSelectTriggered) {
                            val allStreams = state.value.groups.flatMap { it.streams }
                            if (allStreams.isNotEmpty()) {
                                val evaluation = evaluateAutoPlay()
                                if (evaluation.stream != null || !evaluation.hasPendingDebridCandidate) {
                                    settleAutoPlay(evaluation)
                                }
                            }
                        }
                    }
                }
            } else {
                null
            }

            // W4 (upstream 8fba6c71e / 4c414a5f4): the fan-out and the debrid cache check run once
            // in the shared search session, joined here; this load only presents what arrives.
            val accumulator = StreamSearchAccumulator(
                installedAddonOrder = installedAddonOrder,
                pluginProviderGroups = pluginProviderGroups,
                present = { group -> presentSearchGroup(group, streamBadgeRules, debridSettings) },
                debridSettings = debridSettings,
            )
            StreamSearchSessions.search(
                profileId = searchProfileId,
                targets = searchTargets,
                forceRefresh = forceRefresh,
            ).collect { completion ->
                updateIfCurrent(accumulator.record(completion))
                updateAutoPlayAfterStreamsChanged()
            }
            // A search dropped before it finished (a forced refresh elsewhere, eviction, a wipe)
            // leaves its remaining sources without a result.
            updateIfCurrent { it.withoutPendingGroups() }

            launch {
                DirectDebridStreamPreparer.prepare(
                    streams = state.value.groups
                        .filter { it.addonId in installedAddonIds }
                        .flatMap { it.streams },
                    season = season,
                    episode = episode,
                    playerSettings = playerSettings,
                    installedAddonNames = installedAddonNames,
                ) { original, prepared ->
                    updateIfCurrent { current ->
                        current.copy(
                            groups = DirectDebridStreamPreparer.replacePreparedStream(
                                groups = current.groups,
                                original = original,
                                prepared = prepared,
                                eligibleGroupIds = installedAddonIds,
                            ),
                        )
                    }
                    updateAutoPlayAfterStreamsChanged()
                }
            }

            if (isDirectAutoPlayFlow && !autoSelectTriggered) {
                settleAutoPlay(evaluateAutoPlay())
            }
            timeoutJob?.cancel()
        }
    }

    /**
     * W4 (review r1): a repeated request may keep the current state only while the session store
     * still serves the very search it came from: same key now (profile, add-ons and the ids they
     * are asked with, plugin groups, debrid account) and held (running, or finished and within its
     * reuse time). States that are no session's keep the old rule.
     */
    private fun isStillServed(type: String, videoId: String, season: Int?, episode: Int?, pluginUiState: PluginsUiState): Boolean {
        val key = activeSearchKey ?: return true
        return StreamSearchRequests.currentKey(type, videoId, season, episode, activeImdbVideoId, pluginUiState) == key &&
            StreamSearchSessions.isHeld(key)
    }

    fun selectFilter(addonId: String?) {
        state.update { it.copy(selectedFilter = addonId) }
    }

    fun consumeAutoPlay() {
        activeRequestKey = null
        state.update {
            it.copy(
                autoPlayStream = null,
                autoPlayCandidates = emptyList(),
                isDirectAutoPlayFlow = false,
                showDirectAutoPlayOverlay = false,
            )
        }
    }

    fun skipAutoPlayStream(stream: StreamItem): Boolean {
        var hasNext = false
        state.update { current ->
            val failedIndex = current.autoPlayCandidates.indexOf(stream)
            val remaining = if (failedIndex >= 0) {
                current.autoPlayCandidates.drop(failedIndex + 1)
            } else {
                current.autoPlayCandidates.drop(1)
            }
            hasNext = remaining.isNotEmpty()
            current.copy(
                autoPlayStream = remaining.firstOrNull(),
                autoPlayCandidates = remaining,
                isDirectAutoPlayFlow = remaining.isNotEmpty(),
                showDirectAutoPlayOverlay = remaining.isNotEmpty(),
            )
        }
        return hasNext
    }

    fun cancelLoading() {
        activeJob?.cancel()
        activeJob = null
        // W4 (review r1): the state stops following its search here, so the next identical load
        // replays the search (cheap while it is held) instead of keeping this settled snapshot.
        activeRequestKey = null
        activeSearchKey = null
        state.takeOver { current ->
            if (!current.isAnyLoading && current.groups.none { it.isLoading }) {
                current
            } else {
                val updatedGroups = current.groups.map { group ->
                    if (group.isLoading) group.copy(isLoading = false) else group
                }
                current.copy(
                    groups = updatedGroups,
                    isAnyLoading = false,
                    emptyStateReason = if (updatedGroups.isEmpty()) {
                        current.emptyStateReason
                    } else {
                        updatedGroups.toEmptyStateReason(anyLoading = false)
                    },
                )
            }
        }
    }

    fun clear() {
        state.takeOver(StreamsUiState())
        activeJob?.cancel()
        activeJob = null
        activeRequestKey = null
        activeSearchKey = null
        activeImdbVideoId = null
    }

    fun setOverlayVisible(visible: Boolean, message: String? = null) {
        state.update { it.copy(showDirectAutoPlayOverlay = visible, overlayMessage = message) }
    }
}

