package com.nuvio.app.features.streams

import com.nuvio.app.features.debrid.DebridSettings
import com.nuvio.app.features.debrid.DebridStreamPresentation

/**
 * Badges, then the debrid filters and sort, for one add-on group (was each repository's private
 * `presentStreamGroup`). Applied per consumer, after the shared search, so a session never holds
 * one consumer's presentation.
 */
internal fun presentSearchGroup(
    group: AddonStreamGroup,
    badgeRules: StreamBadgeRules,
    debridSettings: DebridSettings,
    filtersApplyToAllStreams: Boolean = StreamPresentationPlatform.filtersApplyToAllStreams,
): AddonStreamGroup {
    val badgeGroup = StreamBadgePresentation.apply(groups = listOf(group), rules = badgeRules).firstOrNull() ?: group
    return DebridStreamPresentation.apply(
        groups = listOf(badgeGroup),
        settings = debridSettings,
        allStreams = filtersApplyToAllStreams,
    ).firstOrNull() ?: badgeGroup
}

/**
 * The pure merge both repositories ran in their receive loops (W4: the two loops were identical
 * apart from the state holder and the picker's auto-play hook): an add-on completion replaces its
 * group (presented), a plugin scraper completion merges into its group (tvOS re-presents from the
 * raw streams so far), plugin groups end their loading when their last scraper answers and show the
 * first error only when nothing came. One instance per load, fed in arrival order; never shared.
 */
internal class StreamSearchAccumulator(
    private val installedAddonOrder: List<String>,
    pluginProviderGroups: List<PluginProviderGroup>,
    private val present: (AddonStreamGroup) -> AddonStreamGroup,
    private val debridSettings: DebridSettings,
    private val filtersApplyToAllStreams: Boolean = StreamPresentationPlatform.filtersApplyToAllStreams,
) {
    private val pluginRemainingByAddonId = pluginProviderGroups.associate { it.addonId to it.scrapers.size }.toMutableMap()
    private val pluginFirstErrorByAddonId = mutableMapOf<String, String>()

    // tvOS (filtersApplyToAllStreams): every plugin group's RAW, un-presented streams so far, in
    // arrival order. The presented list is rebuilt from this on each scraper completion; feeding the
    // group's already-presented streams back through DebridStreamPresentation would present the
    // earlier scrapers' streams again for every later completion.
    private val rawPluginStreamsByAddonId = mutableMapOf<String, List<StreamItem>>()

    /**
     * Records [completion] (plugin counts, first errors and raw lists advance here, once) and
     * returns the pure state transform for it. The transform may run more than once, as
     * `MutableStateFlow.update` retries it when another writer (the debrid preparer, a filter chip)
     * changed the state in between, and gives the same result each time: that is why the receive
     * loops kept these counters outside their update lambdas, and why this is split in two.
     */
    fun record(completion: StreamLoadCompletion): (StreamsUiState) -> StreamsUiState = when (completion) {
        is StreamLoadCompletion.Addon -> {
            val presented = present(completion.group)
            val transform: (StreamsUiState) -> StreamsUiState = { current -> replaceGroup(current, presented) }
            transform
        }
        is StreamLoadCompletion.PluginScraper -> recordPlugin(completion)
    }

    /** [record] and apply at once, for a single-threaded consumer (the fallback facade, tests). */
    fun apply(current: StreamsUiState, completion: StreamLoadCompletion): StreamsUiState = record(completion)(current)

    /** Was `publishAddonGroup` / `publishStreamGroup`. */
    private fun replaceGroup(current: StreamsUiState, group: AddonStreamGroup): StreamsUiState {
        val updated = StreamAutoPlaySelector.orderAddonStreams(
            groups = current.groups.map { if (it.addonId == group.addonId) group else it },
            installedOrder = installedAddonOrder,
        )
        val anyLoading = updated.any { it.isLoading }
        return current.copy(groups = updated, isAnyLoading = anyLoading, emptyStateReason = updated.toEmptyStateReason(anyLoading))
    }

    /** The plugin branch of both receive loops: counters here, the group merge in the returned transform. */
    private fun recordPlugin(completion: StreamLoadCompletion.PluginScraper): (StreamsUiState) -> StreamsUiState {
        val remaining = (pluginRemainingByAddonId[completion.addonId] ?: 1) - 1
        pluginRemainingByAddonId[completion.addonId] = remaining.coerceAtLeast(0)
        val completionError = completion.error
        if (!completionError.isNullOrBlank() && pluginFirstErrorByAddonId[completion.addonId].isNullOrBlank()) {
            pluginFirstErrorByAddonId[completion.addonId] = completionError
        }
        val firstError = pluginFirstErrorByAddonId[completion.addonId]
        val rawPluginStreams: List<StreamItem>? =
            if (filtersApplyToAllStreams && completion.streams.isNotEmpty()) {
                ((rawPluginStreamsByAddonId[completion.addonId] ?: emptyList()) + completion.streams)
                    .also { rawPluginStreamsByAddonId[completion.addonId] = it }
            } else {
                null
            }
        return { current -> mergePlugin(current, completion, remaining, firstError, rawPluginStreams) }
    }

    private fun mergePlugin(
        current: StreamsUiState,
        completion: StreamLoadCompletion.PluginScraper,
        remaining: Int,
        firstError: String?,
        rawPluginStreams: List<StreamItem>?,
    ): StreamsUiState {
        val updated = StreamAutoPlaySelector.orderAddonStreams(
            groups = current.groups.map { group ->
                if (group.addonId != completion.addonId) {
                    group
                } else {
                    var cachedOnlyHidden = group.cachedOnlyHiddenCount
                    val mergedStreams = if (completion.streams.isEmpty()) {
                        group.streams
                    } else if (rawPluginStreams != null) {
                        // tvOS: plugin streams get the same sort / filter preferences as every
                        // add-on's. Present from the raw merged list of every scraper of this group
                        // so far, not from group.streams: those were already presented.
                        val merged = rawPluginStreams.sortedForGroupedDisplay()
                        val presented = DebridStreamPresentation.apply(
                            groups = listOf(group.copy(streams = merged)),
                            settings = debridSettings,
                            allStreams = true,
                        ).firstOrNull()
                        cachedOnlyHidden = presented?.cachedOnlyHiddenCount ?: 0
                        presented?.streams ?: merged
                    } else {
                        (group.streams + completion.streams).sortedForGroupedDisplay()
                    }
                    val stillLoading = remaining > 0
                    val finalError = if (mergedStreams.isEmpty() && !stillLoading) {
                        firstError
                    } else {
                        null
                    }
                    group.copy(
                        streams = mergedStreams,
                        cachedOnlyHiddenCount = cachedOnlyHidden,
                        isLoading = stillLoading,
                        error = finalError,
                    )
                }
            },
            installedOrder = installedAddonOrder,
        )
        val anyLoading = updated.any { it.isLoading }
        return current.copy(
            groups = updated,
            isAnyLoading = anyLoading,
            emptyStateReason = updated.toEmptyStateReason(anyLoading),
        )
    }
}
