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
import com.nuvio.app.features.streams.StreamSearchAccumulator
import com.nuvio.app.features.streams.StreamSearchEnvironment
import com.nuvio.app.features.streams.StreamSearchRequests
import com.nuvio.app.features.streams.StreamSearchSessions
import com.nuvio.app.features.streams.StreamSearchTargets
import com.nuvio.app.features.streams.StreamVideoIdRemap
import com.nuvio.app.features.streams.StreamsEmptyStateReason
import com.nuvio.app.features.streams.StreamsUiState
import com.nuvio.app.features.streams.presentSearchGroup
import com.nuvio.app.features.streams.streamAddonTargets
import com.nuvio.app.features.streams.withoutPendingGroups
import com.nuvio.app.features.tmdb.TmdbService
import kotlin.concurrent.Volatile
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.CoroutineStart
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.Job
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asStateFlow
import kotlinx.coroutines.flow.update
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

    // source panel
    private val _sourceState = MutableStateFlow(StreamsUiState())
    val sourceState: StateFlow<StreamsUiState> = _sourceState.asStateFlow()
    private var sourceJob: Job? = null
    private var sourceRequestKey: String? = null

    // episode streams panel
    private val _episodeStreamsState = MutableStateFlow(StreamsUiState())
    val episodeStreamsState: StateFlow<StreamsUiState> = _episodeStreamsState.asStateFlow()
    private var episodeStreamsJob: Job? = null
    private var episodeStreamsRequestKey: String? = null

    // W4: one counter per state flow, bumped whenever that flow is handed to a new load or
    // cleared; a load writes only while it still holds the number it started with (see
    // StreamsRepository.loadGeneration).
    @Volatile
    private var sourceGeneration = 0L

    @Volatile
    private var episodeStreamsGeneration = 0L

    fun loadSources(
        type: String,
        videoId: String,
        season: Int? = null,
        episode: Int? = null,
        forceRefresh: Boolean = false,
    ) {
        fetchStreams(
            type = type,
            videoId = videoId,
            season = season,
            episode = episode,
            forceRefresh = forceRefresh,
            stateFlow = _sourceState,
            requestKeyHolder = { sourceRequestKey },
            setRequestKey = { sourceRequestKey = it },
            jobHolder = { sourceJob },
            setJob = { sourceJob = it },
            generationHolder = { sourceGeneration },
            nextGeneration = { sourceGeneration += 1; sourceGeneration },
        )
    }

    fun loadEpisodeStreams(
        type: String,
        videoId: String,
        season: Int? = null,
        episode: Int? = null,
        forceRefresh: Boolean = false,
    ) {
        fetchStreams(
            type = type,
            videoId = videoId,
            season = season,
            episode = episode,
            forceRefresh = forceRefresh,
            stateFlow = _episodeStreamsState,
            requestKeyHolder = { episodeStreamsRequestKey },
            setRequestKey = { episodeStreamsRequestKey = it },
            jobHolder = { episodeStreamsJob },
            setJob = { episodeStreamsJob = it },
            generationHolder = { episodeStreamsGeneration },
            nextGeneration = { episodeStreamsGeneration += 1; episodeStreamsGeneration },
        )
    }

    fun selectSourceFilter(addonId: String?) {
        _sourceState.update { it.copy(selectedFilter = addonId) }
    }

    fun selectEpisodeStreamsFilter(addonId: String?) {
        _episodeStreamsState.update { it.copy(selectedFilter = addonId) }
    }

    /** Stops this consumer only: the shared search goes on, and the next load of the episode replays it. */
    fun clearEpisodeStreams() {
        episodeStreamsGeneration += 1
        episodeStreamsJob?.cancel()
        episodeStreamsRequestKey = null
        _episodeStreamsState.value = StreamsUiState()
    }

    fun clearAll() {
        sourceGeneration += 1
        sourceJob?.cancel()
        sourceRequestKey = null
        _sourceState.value = StreamsUiState()
        clearEpisodeStreams()
    }

    private fun fetchStreams(
        type: String,
        videoId: String,
        season: Int?,
        episode: Int?,
        forceRefresh: Boolean,
        stateFlow: MutableStateFlow<StreamsUiState>,
        requestKeyHolder: () -> String?,
        setRequestKey: (String?) -> Unit,
        jobHolder: () -> Job?,
        setJob: (Job) -> Unit,
        generationHolder: () -> Long,
        nextGeneration: () -> Long,
        imdbVideoId: String? = null,
        remapAttempted: Boolean = false,
    ) {
        val pluginUiState = StreamSearchRequests.pluginUiState()
        val requestKey = "$type::$videoId::$season::$episode::pluginsGrouped=${pluginUiState.groupStreamsByRepository}"
        val current = stateFlow.value
        if (
            !forceRefresh &&
            requestKeyHolder() == requestKey &&
            (current.groups.isNotEmpty() || current.emptyStateReason != null || current.isAnyLoading)
        ) {
            return
        }

        setRequestKey(requestKey)
        val generation = nextGeneration()
        jobHolder()?.cancel()
        stateFlow.value = StreamsUiState()

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
            stateFlow.value = StreamsUiState(
                groups = listOf(presentedGroup),
                activeAddonIds = setOf("embedded"),
                // Embedded streams come from the (installed) meta addon, so they classify as an
                // installed-addon source for the auto-play scope (Codex r2 on the 58864ec1 port).
                installedAddonIds = setOf("embedded"),
                isAnyLoading = false,
            )
            return
        }

        val installedAddons = StreamSearchEnvironment.installedAddons()
        PlayerSettingsRepository.ensureLoaded()
        val playerSettings = PlayerSettingsRepository.uiState.value
        val debridSettings = DebridSettingsRepository.snapshot()
        val pluginProviderGroups = StreamSearchRequests.pluginProviderGroups(type, pluginUiState)

        if (installedAddons.isEmpty() && pluginProviderGroups.isEmpty()) {
            stateFlow.value = StreamsUiState(
                isAnyLoading = false,
                emptyStateReason = StreamsEmptyStateReason.NoAddonsInstalled,
            )
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
            stateFlow.value = StreamsUiState(isAnyLoading = true)
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
                if (generationHolder() != generation) return@launch
                // Re-enter either way, so a failed resolution never costs the user an addon that
                // did accept the original id.
                setRequestKey(null)
                fetchStreams(
                    type = type,
                    videoId = videoId,
                    season = season,
                    episode = episode,
                    forceRefresh = forceRefresh,
                    stateFlow = stateFlow,
                    requestKeyHolder = requestKeyHolder,
                    setRequestKey = setRequestKey,
                    // `{ null }`, not `jobHolder`: the re-entry cancels whatever the holder
                    // reports, and right now that is THIS coroutine. Same reason
                    // StreamsRepository nulls `activeJob` before its own re-entry.
                    jobHolder = { null },
                    setJob = setJob,
                    generationHolder = generationHolder,
                    nextGeneration = nextGeneration,
                    imdbVideoId = remapped,
                    remapAttempted = true,
                )
            }
            setJob(remapJob)
            remapJob.start()
            return
        }

        if (streamAddons.isEmpty() && pluginProviderGroups.isEmpty()) {
            stateFlow.value = StreamsUiState(
                isAnyLoading = false,
                emptyStateReason = if (tmdbId != null) {
                    StreamsEmptyStateReason.IncompatibleContentId
                } else {
                    StreamsEmptyStateReason.NoCompatibleAddons
                },
            )
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
        stateFlow.value = StreamsUiState(
            groups = initialGroups,
            activeAddonIds = initialGroups.map { it.addonId }.toSet(),
            installedAddonIds = streamAddons.map { it.addonId }.toSet(),
            isAnyLoading = isInitiallyLoading,
        )

        val searchTargets = StreamSearchTargets(
            type = type,
            videoId = videoId,
            season = season,
            episode = episode,
            streamAddons = streamAddons,
            pluginProviderGroups = pluginProviderGroups,
            debridConfiguration = StreamSearchEnvironment.debridConfiguration(),
        )
        val searchProfileId = StreamSearchEnvironment.profileId()

        val job = scope.launch {
            val installedAddonIds = streamAddons.map { it.addonId }.toSet()
            val installedAddonNames = installedAddonOrder.toSet()

            fun updateIfCurrent(transform: (StreamsUiState) -> StreamsUiState) {
                stateFlow.update { current -> if (generationHolder() == generation) transform(current) else current }
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
            ).collect { completion -> updateIfCurrent(accumulator.record(completion)) }
            // A search dropped before it finished (a forced refresh elsewhere, eviction, a wipe)
            // leaves its remaining sources without a result.
            updateIfCurrent { it.withoutPendingGroups() }

            launch {
                DirectDebridStreamPreparer.prepare(
                    streams = stateFlow.value.groups
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
        setJob(job)
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
