package com.nuvio.app.features.player

import com.nuvio.app.features.debrid.DebridSettingsRepository
import com.nuvio.app.features.details.MetaDetailsRepository
import com.nuvio.app.features.streams.AddonStreamGroup
import com.nuvio.app.features.streams.StreamAutoPlaySelector
import com.nuvio.app.features.streams.StreamBadgePresentation
import com.nuvio.app.features.streams.StreamBadgeSettingsRepository
import com.nuvio.app.features.streams.StreamItem
import com.nuvio.app.features.streams.StreamSearchAccumulator
import com.nuvio.app.features.streams.StreamSearchEnvironment
import com.nuvio.app.features.streams.StreamSearchRequests
import com.nuvio.app.features.streams.StreamSearchSessions
import com.nuvio.app.features.streams.StreamSearchTargets
import com.nuvio.app.features.streams.StreamsUiState
import com.nuvio.app.features.streams.presentSearchGroup
import com.nuvio.app.features.streams.withoutPendingGroups
import kotlinx.coroutines.withTimeoutOrNull

/**
 * Fork (tvOS, W4): the presented streams of one episode's source search, joined from the shared
 * session (normally a replay of the search Up Next or the picker already ran), for the in-player
 * fallback of an auto-picked source that failed to start. Touches neither repository's state and
 * never forces a refresh; it starts a search only when none is held for the episode (an evicted or
 * expired one), and the next repository load for that episode then joins it.
 *
 * Swift calls [loadChecked] (PlayerSourceFallbackBridging.kt), never [load] directly.
 */
object PlayerSourceFallbackCandidates {
    /**
     * Every stream the episode's search holds, presented as the source list presents them
     * (badges, then the debrid filters and sort), in group order. [timeoutMs] bounds the whole
     * call, the BUG-74 id lookup included: when it runs out, what arrived so far is returned
     * (empty when the targets were not resolved yet).
     */
    suspend fun load(type: String, videoId: String, season: Int?, episode: Int?, timeoutMs: Long): List<StreamItem> {
        val badgeRules = StreamBadgeSettingsRepository.snapshot()
        val embedded = MetaDetailsRepository.findEmbeddedStreams(videoId)
        if (embedded.isNotEmpty()) {
            // The repositories' embedded branch: one installed group, badges only.
            val group = AddonStreamGroup(embedded.first().addonName, "embedded", embedded, isLoading = false)
            return (StreamBadgePresentation.apply(listOf(group), badgeRules).firstOrNull() ?: group).streams
        }
        // Local to this call (concurrent calls never share it); written after every completion,
        // so a timeout still returns what arrived.
        var state: StreamsUiState? = null
        withTimeoutOrNull(timeoutMs) {
            val targets = StreamSearchRequests.resolveTargets(type, videoId, season, episode) ?: return@withTimeoutOrNull
            val debridSettings = DebridSettingsRepository.snapshot()
            val installedAddonOrder = targets.streamAddons.map { it.addonName }
            val accumulator = StreamSearchAccumulator(
                installedAddonOrder = installedAddonOrder,
                pluginProviderGroups = targets.pluginProviderGroups,
                present = { group -> presentSearchGroup(group, badgeRules, debridSettings) },
                debridSettings = debridSettings,
            )
            var current = initialState(targets, installedAddonOrder)
            state = current
            StreamSearchSessions.search(StreamSearchEnvironment.profileId(), targets, forceRefresh = false)
                .collect { completion ->
                    current = accumulator.apply(current, completion)
                    state = current
                }
        }
        return state?.withoutPendingGroups()?.groups?.flatMap { it.streams }.orEmpty()
    }

    /** The installed add-on names among [streams], for the auto-play selector's source scope. */
    fun installedAddonNames(streams: List<StreamItem>): Set<String> =
        streams.filter { it.isInstalledAddonStream }.map { it.addonName }.toSet()

    private fun initialState(targets: StreamSearchTargets, installedAddonOrder: List<String>): StreamsUiState {
        val groups = StreamAutoPlaySelector.orderAddonStreams(
            targets.streamAddons.map { AddonStreamGroup(it.addonName, it.addonId, emptyList(), isLoading = true) } +
                targets.pluginProviderGroups.map { AddonStreamGroup(it.addonName, it.addonId, emptyList(), isLoading = true) },
            installedAddonOrder,
        )
        return StreamsUiState(
            groups = groups,
            activeAddonIds = groups.map { it.addonId }.toSet(),
            installedAddonIds = targets.streamAddons.map { it.addonId }.toSet(),
            isAnyLoading = groups.any { it.isLoading },
        )
    }
}
