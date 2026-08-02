package com.nuvio.app.features.watchprogress

import com.nuvio.app.features.tracking.TrackingProgressSnapshot
import com.nuvio.app.features.tracking.WatchProgressSource

/**
 * Chooses the entry list the active source owns.
 *
 * Fork note: upstream returns the provider projection verbatim once a provider is active, because
 * their anime ids are handled by a second provider. The fork keeps the shipped behaviour of
 * merging in local-only rows whose ids the active provider can never return (`kitsu:`, `mal:`,
 * `anilist:`) — otherwise those titles vanish from continue watching while Trakt is the source.
 * [canProviderRepresent] comes from `TrackingProgressProvider.canRepresentContentId`.
 */
fun projectWatchProgressSourceEntries(
    source: WatchProgressSource,
    nuvioEntries: Collection<WatchProgressEntry>,
    providerEntries: Collection<WatchProgressEntry>,
    canProviderRepresent: (String) -> Boolean = { true },
): List<WatchProgressEntry> {
    if (source.providerId == null) return nuvioEntries.toList()

    val localOnlyEntries = nuvioEntries.filterNot { entry -> canProviderRepresent(entry.parentMetaId) }
    if (localOnlyEntries.isEmpty()) return providerEntries.toList()

    val providerKeys = providerEntries.mapTo(mutableSetOf()) { entry -> entry.resolvedProgressKey() }
    val merged = providerEntries.toMutableList()
    localOnlyEntries.forEach { localEntry ->
        if (localEntry.resolvedProgressKey() !in providerKeys) {
            merged += localEntry
        }
    }
    return merged
}

fun projectWatchProgressUiState(
    source: WatchProgressSource,
    entries: List<WatchProgressEntry>,
    providerSnapshot: TrackingProgressSnapshot?,
    hasLoadedNuvioRemoteProgress: Boolean,
): WatchProgressUiState = WatchProgressUiState(
    source = source,
    entries = entries,
    hiddenContentIds = providerSnapshot?.hiddenContentIds.orEmpty(),
    hasLoadedRemoteProgress =
        providerSnapshot?.hasLoadedRemoteProgress ?: hasLoadedNuvioRemoteProgress,
)
