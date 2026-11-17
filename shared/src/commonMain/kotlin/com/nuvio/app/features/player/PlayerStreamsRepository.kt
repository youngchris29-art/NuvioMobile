package com.nuvio.app.features.player

import com.nuvio.app.core.coroutines.uncaughtCoroutineLogger
import co.touchlab.kermit.Logger
import com.nuvio.app.features.debrid.DebridSettingsRepository
import com.nuvio.app.features.debrid.DirectDebridStreamPreparer
import com.nuvio.app.features.details.MetaDetailsRepository
import com.nuvio.app.features.streams.AddonStreamGroup
import com.nuvio.app.features.streams.StreamAutoPlaySelector
import com.nuvio.app.features.streams.StreamBadgePresentation
import com.nuvio.app.features.streams.StreamBadgeSettingsRepository
import com.nuvio.app.features.streams.StreamDiagnostics
import com.nuvio.app.features.streams.GenerationalStreamsState
import com.nuvio.app.features.streams.StreamSearchKey
import com.nuvio.app.features.plugins.PluginsUiState
import com.nuvio.app.features.streams.StreamSearchAccumulator
import com.nuvio.app.features.streams.StreamSearchEnvironment
import com.nuvio.app.features.streams.StreamSearchRequests
import com.nuvio.app.features.streams.StreamSearchSessions
import com.nuvio.app.features.streams.StreamSearchTargets
import com.nuvio.app.features.streams.STREAM_SEARCH_MAX_WORLD_RETRIES
import com.nuvio.app.core.profile.ActiveProfileProvider
import com.nuvio.app.features.streams.StreamVideoIdRemap
import com.nuvio.app.features.streams.StreamsEmptyStateReason
import com.nuvio.app.features.streams.StreamsUiState
import com.nuvio.app.features.streams.presentSearchGroup
import com.nuvio.app.features.streams.streamAddonTargets
import com.nuvio.app.features.streams.withoutPendingGroups
import com.nuvio.app.features.tmdb.TmdbService
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.CoroutineStart
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.Job
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.first
import kotlinx.coroutines.launch

/**
 * Dedicated stream fetcher for use inside the player (sources & episodes panels).
 * Uses its own state so it doesn't interfere with the main [StreamsRepository]. W4: the search
 * itself is the shared session ([StreamSearchSessions]) the picker and Up Next join too, so the
 * same episode is fetched once; this repository only presents what arrives.
 */
object PlayerStreamsRepository {
    private val log = Logger.withTag("PlayerStreamsRepo")
    private val scope = CoroutineScope(SupervisorJob() + Dispatchers.Default + uncaughtCoroutineLogger("PlayerStreamsRepository"))

    /**
     * One state flow and the load feeding it. W4 (review r1): the state carries the generation of
     * the load that owns it inside its compared value ([GenerationalStreamsState]), so a superseded
     * load can never commit; [searchKey] / [imdbVideoId] name the session search the state comes
     * from (null when it is no session's), for the store-backed repeat check.
     */
    private class Slot {
        val state = GenerationalStreamsState()
        var job: Job? = null
        var requestKey: String? = null
        var searchKey: StreamSearchKey? = null
        var imdbVideoId: String? = null

        fun reset() {
            state.takeOver(StreamsUiState())
            job?.cancel()
            job = null
            requestKey = null
            searchKey = null
            imdbVideoId = null
        }
    }

    // source panel
    private val sourceSlot = Slot()
    val sourceState: StateFlow<StreamsUiState> = sourceSlot.state.view

    // episode streams panel
    private val episodeSlot = Slot()
    val episodeStreamsState: StateFlow<StreamsUiState> = episodeSlot.state.view

    fun loadSources(
        type: String,
        videoId: String,
        season: Int? = null,
        episode: Int? = null,
        forceRefresh: Boolean = false,
    ) {
        fetchStreams(type = type, videoId = videoId, season = season, episode = episode, forceRefresh = forceRefresh, slot = sourceSlot)
    }

    fun loadEpisodeStreams(
        type: String,
        videoId: String,
        season: Int? = null,
        episode: Int? = null,
        forceRefresh: Boolean = false,
    ) {
        fetchStreams(type = type, videoId = videoId, season = season, episode = episode, forceRefresh = forceRefresh, slot = episodeSlot)
    }

    fun selectSourceFilter(addonId: String?) {
        sourceSlot.state.update { it.copy(selectedFilter = addonId) }
    }

    fun selectEpisodeStreamsFilter(addonId: String?) {
        episodeSlot.state.update { it.copy(selectedFilter = addonId) }
    }

    /** Stops this consumer only: the shared search goes on, and the next load of the episode replays it. */
    fun clearEpisodeStreams() {
        episodeSlot.reset()
    }

    fun clearAll() {
        sourceSlot.reset()
        clearEpisodeStreams()
    }

    /** See StreamsRepository.isStillServed: the store's identity and expiry rule, nothing weaker. */
    private fun Slot.isStillServed(type: String, videoId: String, season: Int?, episode: Int?, pluginUiState: PluginsUiState): Boolean {
        val key = searchKey ?: return true
        return StreamSearchRequests.currentKey(type, videoId, season, episode, imdbVideoId, pluginUiState) == key &&
            StreamSearchSessions.isHeld(key)
    }

    private fun fetchStreams(
        type: String,
        videoId: String,
        season: Int?,
        episode: Int?,
        forceRefresh: Boolean,
        slot: Slot,
        imdbVideoId: String? = null,
        remapAttempted: Boolean = false,
        searchGeneration: Long? = null,
        worldRetries: Int = 0,
    ) {
        // Review r10 findings: the store generation before any other input; the BUG-74 second pass
        // keeps the first pass's, so a wipe during the lookup still refuses it.
        val pluginGeneration = searchGeneration ?: StreamSearchSessions.pluginGeneration()
        val environment = StreamSearchEnvironment.stamp()                // review r10: before anything else
        val pluginUiState = StreamSearchRequests.pluginUiState()
        val requestKey = "$type::$videoId::$season::$episode::pluginsGrouped=${pluginUiState.groupStreamsByRepository}"
        val current = slot.state.value
        if (
            !forceRefresh &&
            slot.requestKey == requestKey &&
            (current.groups.isNotEmpty() || current.emptyStateReason != null || current.isAnyLoading) &&
            slot.isStillServed(type, videoId, season, episode, pluginUiState)
        ) {
            return
        }

        slot.requestKey = requestKey
        slot.searchKey = null
        slot.imdbVideoId = null
        slot.job?.cancel()
        val generation = slot.state.takeOver(StreamsUiState())

        val streamBadgeRules = StreamBadgeSettingsRepository.snapshot()
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
            slot.state.setIfCurrent(generation, StreamsUiState(
                groups = listOf(presentedGroup),
                activeAddonIds = setOf("embedded"),
                // Embedded streams come from the (installed) meta addon, so they classify as an
                // installed-addon source for the auto-play scope (Codex r2 on the 58864ec1 port).
                installedAddonIds = setOf("embedded"),
                isAnyLoading = false,
            ))
            return
        }

        val installedAddons = StreamSearchEnvironment.installedAddons()
        PlayerSettingsRepository.ensureLoaded()
        val playerSettings = PlayerSettingsRepository.uiState.value
        val debridSettings = DebridSettingsRepository.snapshot()
        val pluginProviderGroups = StreamSearchRequests.pluginProviderGroups(type, pluginUiState)

        if (installedAddons.isEmpty() && pluginProviderGroups.isEmpty()) {
            slot.state.setIfCurrent(generation, StreamsUiState(
                isAnyLoading = false,
                emptyStateReason = StreamsEmptyStateReason.NoAddonsInstalled,
            ))
            return
        }

        // BUG-74: each addon is asked with the id IT accepts — see StreamsRepository's copy and
        // [StreamVideoIdRemap]. This path matters most for next-episode autoplay, whose videoId
        // comes from persisted watch progress and so can be `tmdb:`-namespaced even when the detail
        // screen handed the picker a clean one. W4: the same `streamAddonTargets` the picker uses,
        // so both build the same search key for the same episode.
        val streamAddons = streamAddonTargets(installedAddons, type, videoId, imdbVideoId)

        val typeStreamIdPrefixes = StreamSearchRequests.typeStreamIdPrefixes(installedAddons, type)
        val tmdbId = StreamVideoIdRemap.parseTmdbId(videoId)
        if (
            !remapAttempted &&
            tmdbId != null &&
            StreamVideoIdRemap.wouldReachMoreAddons(videoId, typeStreamIdPrefixes)
        ) {
            slot.state.setIfCurrent(generation, StreamsUiState(isAnyLoading = true))
            val remapJob = scope.launch(start = CoroutineStart.LAZY) {
                val imdbId = TmdbService.tmdbToImdb(tmdbId = tmdbId, mediaType = type)
                val remapped = imdbId?.let { StreamVideoIdRemap.withImdbId(videoId, it) }
                if (remapped != null) {
                    log.d { "Remapped tmdb id for player streams: $videoId -> $remapped" }
                    StreamDiagnostics.log("player remap $videoId → $remapped")
                } else {
                    log.w { "No IMDb id for tmdb:$tmdbId ($type) — tt-only stream addons stay unreachable" }
                    StreamDiagnostics.log("player remap FAILED $videoId → no imdb id on tmdb")
                }
                // W4: a lookup that returned after a newer load or a clear took this flow over
                // must not re-enter over it.
                if (slot.state.generation != generation) return@launch
                // Re-enter either way, so a failed resolution never costs the user an addon that
                // did accept the original id. Release the request key so the re-entry is not
                // skipped, and the job so it does not cancel THIS coroutine (StreamsRepository
                // nulls `activeJob` before its own re-entry for the same reason).
                slot.requestKey = null
                slot.job = null
                fetchStreams(
                    type = type,
                    videoId = videoId,
                    season = season,
                    episode = episode,
                    forceRefresh = forceRefresh,
                    slot = slot,
                    imdbVideoId = remapped,
                    remapAttempted = true,
                    searchGeneration = pluginGeneration,
                )
            }
            slot.job = remapJob
            remapJob.start()
            return
        }

        if (streamAddons.isEmpty() && pluginProviderGroups.isEmpty()) {
            slot.state.setIfCurrent(generation, StreamsUiState(
                isAnyLoading = false,
                emptyStateReason = if (tmdbId != null) {
                    StreamsEmptyStateReason.IncompatibleContentId
                } else {
                    StreamsEmptyStateReason.NoCompatibleAddons
                },
            ))
            return
        }

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
        slot.state.setIfCurrent(generation, StreamsUiState(
            groups = initialGroups,
            activeAddonIds = initialGroups.map { it.addonId }.toSet(),
            installedAddonIds = streamAddons.map { it.addonId }.toSet(),
            isAnyLoading = isInitiallyLoading,
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
        slot.searchKey = searchTargets.key(searchProfileId)
        slot.imdbVideoId = imdbVideoId

        val job = scope.launch {
            val installedAddonIds = streamAddons.map { it.addonId }.toSet()
            val installedAddonNames = installedAddonOrder.toSet()

            fun updateIfCurrent(transform: (StreamsUiState) -> StreamsUiState) {
                slot.state.updateIfCurrent(generation, transform)
            }

            // W4 (upstream 8fba6c71e / 4c414a5f4): the fan-out and the debrid cache check run once
            // in the shared search session, joined here; this load only presents what arrives.
            val accumulator = StreamSearchAccumulator(
                installedAddonOrder = installedAddonOrder,
                pluginProviderGroups = pluginProviderGroups,
                present = { group -> presentSearchGroup(group, streamBadgeRules, debridSettings) },
                debridSettings = debridSettings,
            )
            var rebuild = false
            StreamSearchSessions.search(
                profileId = searchProfileId,
                targets = searchTargets,
                forceRefresh = forceRefresh,
                onRebuild = { rebuild = true },
            ).collect { completion -> updateIfCurrent(accumulator.record(completion)) }
            // Review r10 findings: built for another profile or account, so nothing ran. Rebuilt in
            // the current world instead of settling on an empty list (see StreamsRepository).
            if (rebuild && worldRetries < STREAM_SEARCH_MAX_WORLD_RETRIES) {
                ActiveProfileProvider.transition.first { !it.changing }
                if (slot.state.generation != generation) return@launch
                slot.requestKey = null
                slot.job = null
                fetchStreams(
                    type = type,
                    videoId = videoId,
                    season = season,
                    episode = episode,
                    forceRefresh = forceRefresh,
                    slot = slot,
                    imdbVideoId = imdbVideoId,
                    remapAttempted = remapAttempted,
                    worldRetries = worldRetries + 1,
                )
                return@launch
            }
            // A search dropped before it finished (a forced refresh elsewhere, eviction, a wipe)
            // leaves its remaining sources without a result.
            updateIfCurrent { it.withoutPendingGroups() }

            launch {
                DirectDebridStreamPreparer.prepare(
                    streams = slot.state.value.groups
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
                }
            }
        }
        slot.job = job
    }
}

private fun StreamsUiState.streamDiagnostics(): String {
    val streamCount = groups.sumOf { it.streams.size }
    val loadingCount = groups.count { it.isLoading }
    val errorCount = groups.count { !it.error.isNullOrBlank() }
    val sampleGroups = groups.take(4).joinToString(prefix = "[", postfix = "]") { group ->
        buildString {
            append(group.addonName)
            append(':')
            append(group.streams.size)
            if (group.isLoading) append(":loading")
            if (!group.error.isNullOrBlank()) append(":error")
        }
    }
    val suffix = if (groups.size > 4) "+${groups.size - 4}" else ""
    return "groups=${groups.size} streams=$streamCount isAnyLoading=$isAnyLoading " +
        "loadingGroups=$loadingCount errorGroups=$errorCount empty=${emptyStateReason ?: "none"} " +
        "sample=$sampleGroups$suffix"
}
