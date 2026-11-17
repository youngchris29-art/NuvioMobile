package com.nuvio.app.features.streams

import com.nuvio.app.core.build.FeaturePolicyProvider
import com.nuvio.app.core.profile.ActiveProfileProvider
import com.nuvio.app.features.addons.AddonRepository
import com.nuvio.app.features.addons.ManagedAddon
import com.nuvio.app.features.addons.enabledAddons
import com.nuvio.app.features.plugins.PluginScraperHostProvider
import com.nuvio.app.features.plugins.PluginsUiState
import com.nuvio.app.features.tmdb.TmdbService

/**
 * Fork (W4): what a source search reads from the rest of the app, in one place, so the stream
 * picker, the player's source list and the fallback facade build the SAME [StreamSearchKey] for
 * the same request, and so repository-level tests can stand in for the installed add-ons, the
 * debrid account and the profile without touching those repositories.
 */
internal object StreamSearchEnvironment {
    private val defaultInstalledAddons: () -> List<ManagedAddon> = { AddonRepository.uiState.value.addons.enabledAddons() }
    private val defaultDebrid: () -> StreamSearchDebrid = { StreamSearchDebrid.current() }

    // The provider tvOS and the phone install over ProfileRepository at start-up (a direct
    // ProfileRepository import from here would re-introduce the cycle the provider exists to avoid).
    private val defaultProfileId: () -> Int = { ActiveProfileProvider.activeProfileId }

    /** The enabled add-ons, in the user's order. */
    var installedAddons: () -> List<ManagedAddon> = defaultInstalledAddons

    /** The account torrents are cache-checked with, and its key-safe identity (captured per search). */
    var debrid: () -> StreamSearchDebrid = defaultDebrid

    /** The active profile, part of every search key. */
    var profileId: () -> Int = defaultProfileId

    /**
     * Review r10: everything outside the store a search is built from, read FIRST by every builder
     * (before the profile, the account, the add-ons or the plugins it then uses). The store reads it
     * again when the request arrives and runs the request privately when anything changed between.
     */
    fun stamp(): StreamSearchEnvironmentStamp = StreamSearchEnvironmentStamp(
        profileId = profileId(),
        debridConfiguration = debrid().configuration,
        addons = installedAddons(),
        // A repository's refresh flags, error and timestamp flip on a refresh that changes nothing.
        plugins = StreamSearchRequests.pluginUiState().let { state ->
            state.copy(repositories = state.repositories.map { it.copy(isRefreshing = false, errorMessage = null, lastUpdated = 0L) })
        },
    )

    /** Tests: back to the app's sources. */
    fun resetForTesting() {
        installedAddons = defaultInstalledAddons
        debrid = defaultDebrid
        profileId = defaultProfileId
    }
}

/**
 * Review r10: the profile, debrid account, enabled add-ons (manifests included) and plugin settings
 * (scrapers and their code included) one request was built under. Equal stamps: the same world.
 */
internal data class StreamSearchEnvironmentStamp(
    val profileId: Int,
    val debridConfiguration: String,
    val addons: List<ManagedAddon>,
    val plugins: PluginsUiState,
)

internal object StreamSearchRequests {
    /** The plugin groups for [type] under the current plugin settings (the lines both repositories ran). */
    fun pluginProviderGroups(type: String, pluginUiState: PluginsUiState): List<PluginProviderGroup> {
        val scrapers = if (FeaturePolicyProvider.policy.pluginsEnabled) {
            PluginScraperHostProvider.host.getEnabledScrapersForType(type)
        } else {
            emptyList()
        }
        return scrapers.toPluginProviderGroups(
            repositories = pluginUiState.repositories,
            groupByRepository = pluginUiState.groupStreamsByRepository,
        )
    }

    /** The plugin settings a request reads (initialising the host first, as both repositories did). */
    fun pluginUiState(): PluginsUiState =
        if (FeaturePolicyProvider.policy.pluginsEnabled) {
            PluginScraperHostProvider.host.initialize()
            PluginScraperHostProvider.host.uiState.value
        } else {
            PluginsUiState(pluginsEnabled = false)
        }

    /** BUG-74: each installed add-on's stream id prefixes for [type], for [StreamVideoIdRemap.wouldReachMoreAddons]. */
    fun typeStreamIdPrefixes(installed: List<ManagedAddon>, type: String): List<List<String>> =
        installed.mapNotNull { addon ->
            addon.manifest?.resources
                ?.filter { it.name == "stream" && it.types.contains(type) }
                ?.flatMap { it.idPrefixes }
                ?.takeIf { it.isNotEmpty() }
        }

    /**
     * The targets a repository would search for this request, BUG-74 remap included, for callers
     * outside the repositories (the fallback facade). Null when there is nothing to search.
     */
    suspend fun resolveTargets(type: String, videoId: String, season: Int?, episode: Int?): StreamSearchTargets? {
        val environment = StreamSearchEnvironment.stamp()                // review r10: before anything else
        val pluginUiState = pluginUiState()
        val installed = StreamSearchEnvironment.installedAddons()
        val pluginGeneration = StreamSearchSessions.pluginGeneration()   // review r6: before the groups
        val groups = pluginProviderGroups(type, pluginUiState)
        var addons = streamAddonTargets(installed, type, videoId, imdbVideoId = null)
        val tmdbId = StreamVideoIdRemap.parseTmdbId(videoId)
        if (tmdbId != null && StreamVideoIdRemap.wouldReachMoreAddons(videoId, typeStreamIdPrefixes(installed, type))) {
            // The repositories' second pass: a failed lookup re-matches with the original id only.
            val remapped = TmdbService.tmdbToImdb(tmdbId = tmdbId, mediaType = type)
                ?.let { StreamVideoIdRemap.withImdbId(videoId, it) }
            addons = streamAddonTargets(installed, type, videoId, imdbVideoId = remapped)
        }
        if (addons.isEmpty() && groups.isEmpty()) return null
        return StreamSearchTargets(
            type = type,
            videoId = videoId,
            season = season,
            episode = episode,
            streamAddons = addons,
            pluginProviderGroups = groups,
            debrid = StreamSearchEnvironment.debrid(),
            pluginGeneration = pluginGeneration,
            environment = environment,
        )
    }

    /**
     * The key a load of this request would search under right now, with [imdbVideoId] as the
     * second BUG-74 pass resolved it last time; null when nothing would be searched. Lets a
     * repository skip a repeated load only while the store still serves exactly that search.
     */
    fun currentKey(
        type: String,
        videoId: String,
        season: Int?,
        episode: Int?,
        imdbVideoId: String?,
        pluginUiState: PluginsUiState,
    ): StreamSearchKey? {
        val addons = streamAddonTargets(StreamSearchEnvironment.installedAddons(), type, videoId, imdbVideoId)
        val pluginGeneration = StreamSearchSessions.pluginGeneration()   // review r6: before the groups
        val groups = pluginProviderGroups(type, pluginUiState)
        if (addons.isEmpty() && groups.isEmpty()) return null
        return StreamSearchTargets(type, videoId, season, episode, addons, groups, StreamSearchEnvironment.debrid(),
                                   pluginGeneration)
            .key(StreamSearchEnvironment.profileId())
    }
}
