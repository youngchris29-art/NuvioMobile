package com.nuvio.app.features.trakt

import com.nuvio.app.features.library.LibraryItem
import com.nuvio.app.features.library.LibrarySection
import com.nuvio.app.features.tracking.TrackingLibraryProvider
import com.nuvio.app.features.tracking.TrackingLibrarySnapshot
import com.nuvio.app.features.tracking.TrackingLibraryTab
import com.nuvio.app.features.tracking.TrackingLibraryTabKind
import com.nuvio.app.features.tracking.TrackingMembershipResolution
import com.nuvio.app.features.tracking.TrackingProviderId
import com.nuvio.app.features.tracking.TrackingRefreshIntent
import kotlinx.coroutines.flow.Flow
import kotlinx.coroutines.flow.map

/**
 * Adapter that exposes the fork's existing [TraktLibraryRepository] through the provider-neutral
 * [TrackingLibraryProvider] port. No Trakt logic lives here — every call forwards to the shipped
 * repository so behaviour is unchanged.
 *
 * Per-profile auth isolation: [TraktLibraryRepository] resolves credentials through
 * `TraktAuthRepository.authorizedHeaders()`, which loads the *active* profile's tokens. The
 * adapter deliberately adds no profile parameter of its own (the `profileId` handed to
 * [applyMembership] is the caller's bookkeeping id, exactly as upstream) so there is no second,
 * divergent notion of "current profile" in the Trakt path.
 */
object TraktTrackingLibraryProvider : TrackingLibraryProvider {
    override val providerId: TrackingProviderId = TrackingProviderId.TRAKT
    override val changes: Flow<Unit> = TraktLibraryRepository.uiState.map { Unit }
    override val connectionRefreshIntent: TrackingRefreshIntent = TrackingRefreshIntent.INVALIDATED

    override fun ensureLoaded() = TraktLibraryRepository.ensureLoaded()

    override fun prepare() = TraktLibraryRepository.preloadListTabsAsync()

    override fun onProfileChanged() = TraktLibraryRepository.onProfileChanged()

    override fun clearLocalState() = TraktLibraryRepository.clearLocalState()

    override suspend fun refresh(intent: TrackingRefreshIntent) = when (intent) {
        TrackingRefreshIntent.AUTOMATIC -> TraktLibraryRepository.ensureFresh()
        TrackingRefreshIntent.USER_INITIATED,
        TrackingRefreshIntent.INVALIDATED,
        -> TraktLibraryRepository.refreshNow()
    }

    override fun snapshot(): TrackingLibrarySnapshot {
        val state = TraktLibraryRepository.uiState.value
        return TrackingLibrarySnapshot(
            items = state.allItems,
            sections = state.listTabs.mapNotNull { tab ->
                state.entriesByList[tab.key]
                    .orEmpty()
                    .takeIf(List<LibraryItem>::isNotEmpty)
                    ?.let { items ->
                        LibrarySection(
                            type = tab.key,
                            displayTitle = tab.title,
                            items = items,
                        )
                    }
            },
            tabs = state.listTabs.map(TraktListTab::toTrackingLibraryTab),
            hasLoaded = state.hasLoaded,
            isLoading = state.isLoading,
            errorMessage = state.errorMessage,
        )
    }

    override fun contains(contentId: String, contentType: String?): Boolean {
        if (contentType != null) return TraktLibraryRepository.isInAnyList(contentId, contentType)
        val item = find(contentId) ?: return false
        return TraktLibraryRepository.isInAnyList(item.id, item.type)
    }

    override fun find(contentId: String): LibraryItem? =
        TraktLibraryRepository.uiState.value.allItems.firstOrNull { item -> item.id == contentId }

    override suspend fun membership(item: LibraryItem): Map<String, Boolean> =
        traktMembershipWithListTabs(
            hasWatchlistTab = { hasWatchlistTab(snapshot().tabs) },
            readMembership = { TraktLibraryRepository.getMembershipSnapshot(item).listMembership },
            loadListTabs = TraktLibraryRepository::ensureListTabs,
        )

    override fun toggledDefaultMembership(
        currentMembership: Map<String, Boolean>,
    ): Map<String, Boolean> = toggledTraktDefaultMembership(
        currentMembership = currentMembership,
        tabs = snapshot().tabs,
        isSignedIn = TraktAuthRepository.isAuthenticated.value,
    )

    override suspend fun applyMembership(
        profileId: Int,
        item: LibraryItem,
        desiredMembership: Map<String, Boolean>,
        destructiveRemovalConfirmed: Boolean,
    ): TrackingMembershipResolution? {
        TraktLibraryRepository.applyMembershipChanges(
            item = item,
            changes = TraktMembershipChanges(desiredMembership = desiredMembership),
        )
        return null
    }
}

private fun hasWatchlistTab(tabs: List<TrackingLibraryTab>): Boolean =
    tabs.any { tab -> tab.kind == TrackingLibraryTabKind.WATCHLIST }

/**
 * Issue #17: the membership the library + toggles. Tabs load lazily, so when the watchlist tab
 * is not loaded yet, load the list tabs and read the membership again (only the tabs that exist
 * have a membership entry). Pure over its arguments, for tests.
 */
internal suspend fun traktMembershipWithListTabs(
    hasWatchlistTab: () -> Boolean,
    readMembership: suspend () -> Map<String, Boolean>,
    loadListTabs: suspend () -> Unit,
): Map<String, Boolean> {
    val membership = readMembership()
    if (hasWatchlistTab()) return membership
    loadListTabs()
    return readMembership()
}

/**
 * Issue #17: the library +'s default toggle (watchlist membership only). When no watchlist tab
 * exists even after [traktMembershipWithListTabs] tried to load it, this used to return the
 * membership unchanged, a silent no-op; it now throws [TraktSessionExpiredException] when signed
 * out, else [TraktWatchlistUnavailableException], and the caller shows the message.
 */
internal fun toggledTraktDefaultMembership(
    currentMembership: Map<String, Boolean>,
    tabs: List<TrackingLibraryTab>,
    isSignedIn: Boolean,
): Map<String, Boolean> {
    val watchlistKey = tabs.firstOrNull { tab -> tab.kind == TrackingLibraryTabKind.WATCHLIST }?.key
        ?: throw if (isSignedIn) TraktWatchlistUnavailableException() else TraktSessionExpiredException()
    return toggledTraktWatchlistMembership(currentMembership, watchlistKey)
}

// Fork: public (upstream: internal) — shared tests consume this cross-module.
fun toggledTraktWatchlistMembership(
    currentMembership: Map<String, Boolean>,
    watchlistKey: String,
): Map<String, Boolean> = currentMembership.toMutableMap().apply {
    this[watchlistKey] = currentMembership[watchlistKey] != true
}

private fun TraktListTab.toTrackingLibraryTab(): TrackingLibraryTab =
    TrackingLibraryTab(
        key = key,
        title = title,
        providerId = TrackingProviderId.TRAKT,
        kind = when (type) {
            TraktListType.WATCHLIST -> TrackingLibraryTabKind.WATCHLIST
            TraktListType.PERSONAL -> TrackingLibraryTabKind.PERSONAL
        },
    )
