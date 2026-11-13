package com.nuvio.app.features.library

import co.touchlab.kermit.Logger
import com.nuvio.app.core.coroutines.uncaughtCoroutineLogger
import com.nuvio.app.core.poster.CustomPosterScreen
import com.nuvio.app.core.poster.CustomPosterUrlRepository
import com.nuvio.app.core.poster.withCustomPosterUrls
import com.nuvio.app.core.tracking.ensureTrackingProvidersRegistered
import com.nuvio.app.features.catalog.CatalogTarget
import com.nuvio.app.features.home.HomeCatalogSection
import com.nuvio.app.features.home.MetaPreview
import com.nuvio.app.features.profiles.ProfileRepository
import com.nuvio.app.features.profiles.ProfileState
import com.nuvio.app.features.tracking.TrackingLibraryProvider
import com.nuvio.app.features.tracking.TrackingLibrarySnapshot
import com.nuvio.app.features.tracking.TrackingLibraryTabKind
import com.nuvio.app.features.tracking.TrackingProviderId
import com.nuvio.app.features.tracking.TrackingProviderRegistry
import com.nuvio.app.features.tracking.TrackingRefreshIntent
import com.nuvio.app.features.tracking.providerId
import com.nuvio.app.features.trakt.TraktSettingsRepository
import com.nuvio.app.features.watched.WatchedRepository
import com.nuvio.app.features.watchprogress.ContinueWatchingNextUp
import com.nuvio.app.features.watchprogress.ContinueWatchingNextUpResolveLimit
import com.nuvio.app.features.watchprogress.ContinueWatchingPreferencesRepository
import com.nuvio.app.features.watchprogress.WatchProgressEntry
import com.nuvio.app.features.watchprogress.WatchProgressRepository
import com.nuvio.app.features.watchprogress.mergeContinueWatchingWithNextUp
import kotlinx.atomicfu.locks.SynchronizedObject
import kotlinx.atomicfu.locks.synchronized
import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.ExperimentalCoroutinesApi
import kotlinx.coroutines.FlowPreview
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.async
import kotlinx.coroutines.flow.Flow
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.combine
import kotlinx.coroutines.flow.debounce
import kotlinx.coroutines.flow.distinctUntilChanged
import kotlinx.coroutines.flow.drop
import kotlinx.coroutines.flow.filterNotNull
import kotlinx.coroutines.flow.first
import kotlinx.coroutines.flow.flatMapLatest
import kotlinx.coroutines.flow.flow
import kotlinx.coroutines.flow.flowOf
import kotlinx.coroutines.flow.flowOn
import kotlinx.coroutines.flow.map
import kotlinx.coroutines.flow.mapLatest
import kotlinx.coroutines.flow.merge
import kotlinx.coroutines.flow.onStart
import kotlinx.coroutines.flow.runningFold
import kotlinx.coroutines.flow.take
import kotlinx.coroutines.launch
import kotlinx.coroutines.withContext

/**
 * FEAT-89 (Reddit, u/dclimaxb; decision C0 (a), 2026-10-30): two rows on the tvOS Library tab for
 * a connected Trakt or Simkl account, above the grid, with no setting and no stored state.
 *
 * - "Resume Watching": Home's Continue Watching data, unchanged. The in-progress entries come from
 *   [WatchProgressRepository.continueWatchingRow] (the active progress source with its dropped-show
 *   filter and recency window) and the next episode per finished series from the FEAT-85 engine
 *   ([ContinueWatchingNextUp]), merged by [mergeContinueWatchingWithNextUp]: one card per series,
 *   most recent first, as on Home.
 * - "Watchlist": every connected provider's watchlist (Trakt's watchlist, Simkl's Plan to Watch)
 *   merged into one row, de-duplicated across providers ([mergeLibraryWatchlists]), most recently
 *   added first. Read from each provider's existing library snapshot: no new endpoint.
 *
 * With neither provider connected both rows are empty and nothing is observed or fetched.
 */

/** The providers whose connection turns the rows on. MDBList is a list service, not the request. */
val LibraryRowProviderIds: Set<TrackingProviderId> =
    setOf(TrackingProviderId.TRAKT, TrackingProviderId.SIMKL)

/**
 * The Watchlist row's length. The full list stays one List-pill pick away in the grid below; the
 * row is the recent end of it.
 */
const val LibraryWatchlistRowLimit = 40

/** One provider's watchlist items, in that provider's own order. */
data class LibraryProviderWatchlist(
    val providerId: TrackingProviderId,
    val items: List<LibraryItem>,
)

/** The two rows. Swift hides a row whose list is empty. */
data class LibraryProviderRows(
    val resumeWatching: List<WatchProgressEntry> = emptyList(),
    val watchlist: List<LibraryItem> = emptyList(),
) {
    val isEmpty: Boolean
        get() = resumeWatching.isEmpty() && watchlist.isEmpty()
}

/** The Home Watchlist row's length: the length of every other Home row (`CatalogRowView.homePreviewLimit`). */
const val HomeWatchlistRowLimit = 18

/** The Home row's key: its `HomeCatalogSection.key`, Home's row key and its focus key. */
const val HOME_WATCHLIST_ROW_KEY = "home-watchlist"

/** The Home Watchlist row. Swift hides the row while [items] is empty. */
data class HomeWatchlistRow(val items: List<LibraryItem> = emptyList())

/** One provider's refresh decision on the Home path (DEBUG pull line). */
data class HomeWatchlistPullDecision(
    val provider: String,        // TrackingProviderId.storageId: "trakt" | "simkl"
    val afterFirstRows: Boolean,
    val decision: String,        // one of the HomeWatchlistPull* constants
    val profileId: Int,
)
const val HomeWatchlistPullDeferred = "deferred"
const val HomeWatchlistPullPull = "pull"
const val HomeWatchlistPullThrottled = "throttled"
const val HomeWatchlistPullSource = "source"

/**
 * Pure (unit-tested): the watchlist half of [buildLibraryProviderRows], shared by the Library row
 * and the Home row. No Trakt or Simkl connection → empty.
 */
fun buildLibraryWatchlistRow(
    connectedProviderIds: Set<TrackingProviderId>,
    watchlists: List<LibraryProviderWatchlist>,
    limit: Int,
): List<LibraryItem> {
    val connected = connectedProviderIds.filterTo(mutableSetOf()) { it in LibraryRowProviderIds }
    if (connected.isEmpty()) return emptyList()
    return mergeLibraryWatchlists(watchlists.filter { it.providerId in connected }).take(limit)
}

/**
 * Pure (unit-tested): both rows from their inputs. No Trakt or Simkl connection → no rows,
 * whatever the inputs hold. A next-up entry without an episode is dropped, so a series whose next
 * episode is unknown gets no card from the Up Next side (its in-progress episode, if any, still
 * shows).
 */
fun buildLibraryProviderRows(
    connectedProviderIds: Set<TrackingProviderId>,
    inProgress: List<WatchProgressEntry>,
    nextUp: List<WatchProgressEntry>,
    watchlists: List<LibraryProviderWatchlist>,
    watchlistLimit: Int = LibraryWatchlistRowLimit,
): LibraryProviderRows {
    val connected = connectedProviderIds.filterTo(mutableSetOf()) { it in LibraryRowProviderIds }
    if (connected.isEmpty()) return LibraryProviderRows()
    val knownNextUp = nextUp.filter { entry ->
        entry.videoId.isNotBlank() && entry.seasonNumber != null && entry.episodeNumber != null
    }
    return LibraryProviderRows(
        resumeWatching = mergeContinueWatchingWithNextUp(inProgress = inProgress, nextUp = knownNextUp),
        watchlist = buildLibraryWatchlistRow(connected, watchlists, watchlistLimit),
    )
}

/**
 * Pure (unit-tested): the providers' watchlists as one list, most recently added first
 * ([LibraryItem.savedAtEpochMs]: Trakt's `listed_at`, Simkl's `added_to_watchlist_at`), a tie
 * going to the provider listed first in [TrackingProviderId] (Trakt, then Simkl). A title on both
 * keeps its most recently added copy: two items are the same title when they share a content id,
 * or when their kinds match and they share an IMDb or TMDB id, since the providers do not always
 * resolve a title to the same canonical content id. A content id is matched whatever the kind
 * (review r1): `CatalogRowView` keys its cards by id alone, and `tmdb:N` can name a movie and a
 * show (TMDB's two id spaces overlap), so the older of the two leaves the row.
 */
fun mergeLibraryWatchlists(watchlists: List<LibraryProviderWatchlist>): List<LibraryItem> {
    val seen = mutableSetOf<String>()
    return watchlists
        .flatMap { watchlist -> watchlist.items.map { item -> watchlist.providerId to item } }
        .sortedWith(
            compareByDescending<Pair<TrackingProviderId, LibraryItem>> { (_, item) -> item.savedAtEpochMs }
                .thenBy { (providerId, _) -> providerId.ordinal },
        )
        .mapNotNull { (_, item) ->
            val keys = item.watchlistIdentityKeys()
            if (keys.any { it in seen }) {
                null
            } else {
                seen += keys
                item
            }
        }
}

/** Every key a title answers to: `id:…`, plus `kind:imdb:…` / `kind:tmdb:…` when known. */
internal fun LibraryItem.watchlistIdentityKeys(): Set<String> {
    val kind = when (type.trim().lowercase()) {
        "movie", "film" -> "movie"
        "series", "show", "shows", "tv", "anime" -> "series"
        else -> type.trim().lowercase()
    }
    val normalizedId = id.trim().lowercase()
    return buildSet {
        add("id:$normalizedId")
        val imdb = imdbId?.trim()?.lowercase()?.takeIf(String::isNotEmpty)
            ?: normalizedId.takeIf { it.startsWith("tt") }
        imdb?.let { add("$kind:imdb:$it") }
        val tmdb = tmdbId?.toString()
            ?: normalizedId.removePrefix("tmdb:").takeIf { normalizedId.startsWith("tmdb:") && it.isNotEmpty() }
        tmdb?.let { add("$kind:tmdb:$it") }
    }
}

/** The watchlist sections of one provider snapshot (Trakt's watchlist, Simkl's Plan to Watch). */
internal fun TrackingLibrarySnapshot.watchlistItems(): List<LibraryItem> {
    val watchlistKeys = tabs
        .filter { tab -> tab.kind == TrackingLibraryTabKind.WATCHLIST }
        .mapTo(mutableSetOf()) { tab -> tab.key }
    return sections.filter { section -> section.type in watchlistKeys }.flatMap(LibrarySection::items)
}

/**
 * The Watchlist row as the section `CatalogRowView` (Home's poster row) takes. [title] is
 * localized by the caller. No "See All": the section reports no more items.
 */
fun libraryWatchlistRowSection(title: String, items: List<LibraryItem>): HomeCatalogSection =
    HomeCatalogSection(
        key = LIBRARY_WATCHLIST_ROW_KEY,
        title = title,
        subtitle = "",
        addonName = "",
        target = CatalogTarget.Library(contentType = "", sectionType = LIBRARY_WATCHLIST_ROW_KEY),
        items = items.map(LibraryItem::toMetaPreview),
    )

const val LIBRARY_WATCHLIST_ROW_KEY = "library.providerRows.watchlist"

/** The Home row as `CatalogRowView` takes it. [title] is localized by Swift. No See All. */
fun homeWatchlistRowSection(title: String, items: List<LibraryItem>): HomeCatalogSection =
    homeWatchlistRowSectionOf(title, items.map(LibraryItem::toMetaPreview))

/** The same section from previews (the DEBUG seed builds previews in Swift). */
fun homeWatchlistRowSectionOf(title: String, previews: List<MetaPreview>): HomeCatalogSection =
    HomeCatalogSection(
        key = HOME_WATCHLIST_ROW_KEY,
        title = title,
        subtitle = "",
        addonName = "",
        target = CatalogTarget.Library(contentType = "", sectionType = HOME_WATCHLIST_ROW_KEY),
        items = previews,
    )

/**
 * How often the rows ask a provider that is NOT the Library source to refresh its library (review
 * r1). The active source is refreshed by [LibraryRepository] and never by the rows. Trakt's own
 * AUTOMATIC window is 60 s and a pull refetches every list, so a per-visit refresh would refetch
 * the whole Trakt library on ordinary tab visits; Simkl's own window is the same 15 minutes.
 */
internal const val LibraryRowsProviderRefreshIntervalMs = 15L * 60L * 1_000L

/**
 * The rows' refresh bookkeeping (unit-tested): one timestamp per profile and provider, owned by the
 * rows, not by a subscription. In memory only, so a new app session refreshes on its first visit.
 * Review r2: an entry only stands for a pull that worked. A failed pull is [forget]-ten, so the
 * next visit tries again (as Trakt's own error path does), and a provider that leaves the connected
 * set is dropped ([retainConnected]), so reconnecting refreshes its watchlist at once.
 *
 * Review r3: only [throttled] providers (Trakt) are timed here. Simkl's AUTOMATIC refresh already
 * has the same 15-minute gate on a persisted `lastCheckedAt` that always runs after a wipe, so a
 * Simkl refresh goes straight to that gate (its `ensureLoaded` reports loaded even when empty, so
 * the [refreshTargets] `unloaded` rule could not catch a Simkl sign-out).
 */
internal class LibraryRowsRefreshThrottle(
    private val intervalMs: Long = LibraryRowsProviderRefreshIntervalMs,
    private val throttled: Set<TrackingProviderId> = setOf(TrackingProviderId.TRAKT),
) {
    private val lock = SynchronizedObject()
    private val lastRefreshAt = mutableMapOf<Pair<Int, TrackingProviderId>, Long>()

    /**
     * The providers one subscription should refresh: every connected provider but [activeSource].
     * A [throttled] one is recorded and refreshed at most once per [intervalMs] for [profileId],
     * unless it is in [unloaded] (no library snapshot yet, e.g. after a sign-out cleared it while
     * the rows were not watching); any other is always passed on to its own gate.
     */
    fun refreshTargets(
        connected: Collection<TrackingProviderId>,
        activeSource: TrackingProviderId?,
        profileId: Int,
        nowEpochMs: Long,
        unloaded: Collection<TrackingProviderId> = emptyList(),
    ): List<TrackingProviderId> = synchronized(lock) {
        connected.filter { providerId ->
            if (providerId == activeSource) return@filter false
            if (providerId !in throttled) return@filter true
            val key = profileId to providerId
            val last = lastRefreshAt[key]
            val due = last == null || nowEpochMs < last || nowEpochMs - last >= intervalMs ||
                providerId in unloaded
            if (due) lastRefreshAt[key] = nowEpochMs
            due
        }
    }

    /** A pull for [providerId] under [profileId] failed: the next subscription refreshes it again. */
    fun forget(profileId: Int, providerId: TrackingProviderId) = synchronized(lock) {
        lastRefreshAt.remove(profileId to providerId)
        Unit
    }

    /** Drops every profile's entry for a provider that is no longer connected. */
    fun retainConnected(connected: Set<TrackingProviderId>) = synchronized(lock) {
        lastRefreshAt.keys.removeAll { (_, providerId) -> providerId !in connected }
        Unit
    }
}

/** How long the Up Next resolution waits for progress saves to settle (Home's pacing). */
internal const val LibraryRowsNextUpDebounceMs = 1_500L

/**
 * The rows' wiring with its sources injected (unit-tested): nothing below [resumeInputs] or
 * [watchlists] is collected while no Trakt or Simkl account is connected.
 */
@OptIn(ExperimentalCoroutinesApi::class)
internal fun libraryProviderRowsFlow(
    connectedProviderIds: Flow<Set<TrackingProviderId>>,
    resumeInputs: () -> Flow<Pair<List<WatchProgressEntry>, List<WatchProgressEntry>>>,
    watchlists: (Set<TrackingProviderId>) -> Flow<List<LibraryProviderWatchlist>>,
    onConnectedChanged: (Set<TrackingProviderId>) -> Unit = {},
): Flow<LibraryProviderRows> = connectedProviderIds
    .map { ids -> ids.filterTo(linkedSetOf()) { it in LibraryRowProviderIds } }
    .distinctUntilChanged()
    .flatMapLatest { connected ->
        onConnectedChanged(connected)
        if (connected.isEmpty()) {
            flowOf(LibraryProviderRows())
        } else {
            combine(resumeInputs(), watchlists(connected)) { (inProgress, nextUp), lists ->
                buildLibraryProviderRows(
                    connectedProviderIds = connected,
                    inProgress = inProgress,
                    nextUp = nextUp,
                    watchlists = lists,
                )
            }
        }
    }
    .distinctUntilChanged()

/**
 * The Home Watchlist row's wiring with its sources injected (unit-tested): [watchlists] is never
 * called while no Trakt or Simkl account is connected. Keyed by the active profile too: a profile
 * change empties the row and starts a fresh subscription for that profile.
 */
@OptIn(ExperimentalCoroutinesApi::class)
internal fun libraryWatchlistFlow(
    connectedProviderIds: Flow<Set<TrackingProviderId>>,
    activeProfileIds: Flow<Int>,
    watchlists: (connected: Set<TrackingProviderId>, profileId: Int) -> Flow<List<LibraryProviderWatchlist>>,
    limit: Int = HomeWatchlistRowLimit,
    onConnectedChanged: (Set<TrackingProviderId>) -> Unit = {},
): Flow<HomeWatchlistRow> = combine(
    connectedProviderIds
        .map { ids -> ids.filterTo(linkedSetOf()) { it in LibraryRowProviderIds } }
        .distinctUntilChanged(),
    activeProfileIds.distinctUntilChanged(),
) { connected, profileId -> connected to profileId }
    .distinctUntilChanged()
    .runningFold(null as HomeWatchlistKey?) { previous, (connected, profileId) ->
        HomeWatchlistKey(connected, profileId, profileChanged = previous != null && previous.profileId != profileId)
    }
    .filterNotNull()
    .flatMapLatest { key ->
        onConnectedChanged(key.connected)
        if (key.connected.isEmpty()) {
            flowOf(HomeWatchlistRow())
        } else {
            watchlists(key.connected, key.profileId)
                .map { lists -> HomeWatchlistRow(buildLibraryWatchlistRow(key.connected, lists, limit)) }
                // A new profile never shows the last profile's row, even for one frame.
                .onStart { if (key.profileChanged) emit(HomeWatchlistRow()) }
        }
    }
    .distinctUntilChanged()

private data class HomeWatchlistKey(
    val connected: Set<TrackingProviderId>,
    val profileId: Int,
    val profileChanged: Boolean,
)

/**
 * The snapshot triggers, read at once, plus ONE refresh once [released] first reads true.
 * [onDeferred] runs at subscription (the caller logs `deferred` lines when the release has not
 * happened yet); [onReleased] runs once per subscription, never before [released] is true.
 */
internal fun deferredRefreshTriggers(
    triggers: Flow<Unit>,
    released: Flow<Boolean>,
    onDeferred: () -> Unit,
    onReleased: suspend () -> Unit,
): Flow<Unit> = merge(
    triggers.onStart { onDeferred(); emit(Unit) },
    flow { released.first { it }; onReleased(); emit(Unit) },
)

/**
 * The Home path's triggers for one profile's subscription: snapshots at once, then ONE refresh
 * once [releasedFor] names [profileId]. The release is re-checked inside [onMain] (production:
 * `withContext(Dispatchers.Main)`, where Swift's hold and release also run), so a hold, or a
 * profile change, between the release and the hop revokes the pull. A revoked pull is not
 * retried by this subscription; the next subscription pulls.
 */
internal fun homeWatchlistTriggers(
    changes: Flow<Unit>,
    profileId: Int,
    releasedFor: StateFlow<Int?>,
    isActiveProfile: (Int) -> Boolean,
    onMain: suspend (() -> Unit) -> Unit,
    onDeferred: () -> Unit,
    onReleased: () -> Unit,
): Flow<Unit> = deferredRefreshTriggers(
    triggers = changes,
    released = releasedFor.map { it == profileId },
    onDeferred = { if (releasedFor.value != profileId) onDeferred() },
    onReleased = {
        onMain {
            if (releasedFor.value == profileId && isActiveProfile(profileId)) onReleased()
        }
    },
)

/**
 * The refresh decision per connected provider, from one [LibraryRowsRefreshThrottle.refreshTargets]
 * call. Both the Library and the Home path use it with the repository's single throttle.
 */
internal fun refreshDecisions(
    throttle: LibraryRowsRefreshThrottle,
    connected: List<TrackingProviderId>,
    activeSource: TrackingProviderId?,
    profileId: Int,
    nowEpochMs: Long,
    unloaded: Collection<TrackingProviderId> = emptyList(),
): List<Pair<TrackingProviderId, String>> {
    val due = throttle.refreshTargets(connected, activeSource, profileId, nowEpochMs, unloaded)
    return connected.map { id ->
        id to when {
            id == activeSource -> HomeWatchlistPullSource
            id in due -> HomeWatchlistPullPull
            else -> HomeWatchlistPullThrottled
        }
    }
}

/** The production wiring of [libraryProviderRowsFlow] over the app's repositories; what Swift watches. */
object LibraryProviderRowsRepository {
    private val log = Logger.withTag("LibraryProviderRows")
    private val refreshScope = CoroutineScope(
        SupervisorJob() + Dispatchers.Default + uncaughtCoroutineLogger("LibraryProviderRows"),
    )
    private val refreshThrottle = LibraryRowsRefreshThrottle()
    /** Profile whose Home first rows have drawn; null = held. */
    private val homeRefreshReleasedFor = MutableStateFlow<Int?>(null)
    /** Profiles whose Library source this path has loaded this launch (decision O). Main thread only. */
    private val librarySourceLoadedProfiles = mutableSetOf<Int>()
    /** DEBUG sink for the pull line; Swift sets it in DEBUG builds only. */
    @kotlin.concurrent.Volatile
    var homeWatchlistPullListener: ((HomeWatchlistPullDecision) -> Unit)? = null

    /**
     * Both rows for the active profile. A plain `Flow` (Swift: `watchFlow`, collected on the main
     * thread). Call it from the main thread: it loads every repository the rows read up front,
     * so nothing below runs a first load off main. The row is built on the collector's thread, as
     * Home builds its Continue Watching row; the Up Next resolution moves itself to
     * `Dispatchers.Default`, as does the watchlist merge. A connected Trakt / Simkl library that
     * is not the Library source is asked for an AUTOMATIC refresh (Trakt at most once per
     * [LibraryRowsProviderRefreshIntervalMs], [LibraryRowsRefreshThrottle]; Simkl through its own
     * 15-minute gate), so it still fills its watchlist in; the Library source is left to
     * [LibraryRepository].
     */
    fun observeRows(): Flow<LibraryProviderRows> {
        ensureTrackingProvidersRegistered()
        TrackingProviderRegistry.ensureLoaded()
        WatchProgressRepository.ensureLoaded()
        WatchedRepository.ensureLoaded()
        ContinueWatchingPreferencesRepository.ensureLoaded()
        TraktSettingsRepository.ensureLoaded()
        CustomPosterUrlRepository.ensureLoaded()
        LibraryRowProviderIds
            .mapNotNull(TrackingProviderRegistry::libraryProvider)
            .forEach(TrackingLibraryProvider::ensureLoaded)
        return libraryProviderRowsFlow(
            connectedProviderIds = TrackingProviderRegistry.connectedProviderIds,
            resumeInputs = ::resumeInputs,
            watchlists = { connected -> watchlists(connected, CustomPosterScreen.LIBRARY, null) },
            onConnectedChanged = refreshThrottle::retainConnected,
        )
    }

    /**
     * The Home row's Watchlist: the Library's Watchlist half without Up Next, capped at
     * [HomeWatchlistRowLimit]. A plain `Flow` (Swift: `watchFlow`, collected on the main thread).
     * Call it from the main thread. Reads snapshots at once; any pull waits for
     * [releaseHomeWatchlistRefresh]. Nothing is observed with no Trakt or Simkl connection.
     * Keyed by the active profile too: a profile change empties the row and waits for that
     * profile's release.
     */
    fun observeWatchlist(): Flow<HomeWatchlistRow> {
        ensureTrackingProvidersRegistered()
        TrackingProviderRegistry.ensureLoaded()
        CustomPosterUrlRepository.ensureLoaded()
        LibraryRowProviderIds
            .mapNotNull(TrackingProviderRegistry::libraryProvider)
            .forEach(TrackingLibraryProvider::ensureLoaded)
        return libraryWatchlistFlow(
            connectedProviderIds = TrackingProviderRegistry.connectedProviderIds,
            activeProfileIds = ProfileRepository.state.map { activeHomeProfileId(it) },
            watchlists = { connected, profileId -> watchlists(connected, CustomPosterScreen.HOME, profileId) },
            limit = HomeWatchlistRowLimit,
            onConnectedChanged = refreshThrottle::retainConnected,
        )
    }

    /** Home's first rows have drawn: the Home path may pull now, for the active profile. Idempotent. Main thread. */
    fun releaseHomeWatchlistRefresh() { homeRefreshReleasedFor.value = activeHomeProfileId() }

    /**
     * Profile switch, sign-out, toggle off or Home teardown: the next subscription waits again, and
     * a release not yet acted on is revoked. Idempotent.
     */
    fun holdHomeWatchlistRefresh() { homeRefreshReleasedFor.value = null }

    private fun activeHomeProfileId(state: ProfileState = ProfileRepository.state.value): Int =
        state.activeProfile?.profileIndex ?: ProfileRepository.activeProfileId

    /** Once per profile per launch, after first rows, so the Library source gets its own gates. */
    private fun ensureLibrarySourceLoaded(profileId: Int) {
        if (!librarySourceLoadedProfiles.add(profileId)) return
        LibraryRepository.ensureLoaded()
    }

    private fun logPull(decisions: List<Pair<TrackingProviderId, String>>, profileId: Int, afterFirstRows: Boolean) {
        val listener = homeWatchlistPullListener ?: return
        decisions.forEach { (id, decision) ->
            listener(HomeWatchlistPullDecision(id.storageId, afterFirstRows, decision, profileId))
        }
    }

    private fun logPull(providers: List<TrackingLibraryProvider>, profileId: Int, afterFirstRows: Boolean, deferred: Boolean) {
        if (!deferred) return
        logPull(providers.map { it.providerId to HomeWatchlistPullDeferred }, profileId, afterFirstRows)
    }

    /** Home's Continue Watching inputs: the in-progress row and the Up Next entries. */
    @OptIn(FlowPreview::class, ExperimentalCoroutinesApi::class)
    private fun resumeInputs(): Flow<Pair<List<WatchProgressEntry>, List<WatchProgressEntry>>> {
        // Everything Home re-reads the row on (`HomeViewModel.refreshContinueWatching` and its
        // Up Next triggers): progress, the active source, the Trakt days cap, history, preferences.
        val triggers = combine(
            WatchProgressRepository.uiState,
            WatchProgressRepository.activeSourceState,
            TraktSettingsRepository.uiState.map { it.continueWatchingDaysCap }.distinctUntilChanged(),
            WatchedRepository.uiState,
            ContinueWatchingPreferencesRepository.uiState,
        ) { _, _, _, _, _ -> Unit }
        val inProgress = triggers
            .map { WatchProgressRepository.continueWatchingRow() }
            .distinctUntilChanged()
        // The first resolution runs at once (the engine's cache makes a repeat cheap); later ones
        // wait for progress saves to settle, as Home's scheduler does.
        val nextUp = merge(triggers.take(1), triggers.drop(1).debounce(LibraryRowsNextUpDebounceMs))
            .mapLatest {
                try {
                    // Review r1: run in the rows' own scope, so a newer trigger (or leaving the tab)
                    // cancels only this wait, never the engine's run, which keeps its fetches and
                    // leaves its results cached for the next call.
                    // Review r3: on `Dispatchers.Main`, so `resolveEntries`' `ensureInputsLoaded`
                    // runs on the main thread as Home calls it, and its `withContext(Default)`
                    // really hops (from a Default context it would not, and the engine's seed work
                    // would then stay on main). Still a child of the rows' scope, not of this
                    // collector, so a cancel stops only the wait.
                    refreshScope.async(Dispatchers.Main) {
                        ContinueWatchingNextUp.resolveEntries(limit = ContinueWatchingNextUpResolveLimit)
                    }.await()
                } catch (error: CancellationException) {
                    throw error
                } catch (error: Throwable) {
                    // Keep the last result; the next trigger tries again.
                    log.w(error) { "Up Next resolution failed" }
                    null
                }
            }
            .filterNotNull()
            .onStart { emit(emptyList()) }
        // A dismissal drops its card at once (Home does the same); the re-resolution confirms it.
        return combine(inProgress, nextUp, ContinueWatchingPreferencesRepository.uiState) { rows, next, _ ->
            rows to ContinueWatchingNextUp.withoutDismissed(next)
        }
    }

    /**
     * The refresh half of the old `onStart`: asks the throttle which providers to pull, launches
     * those pulls and returns the decision per provider.
     */
    private fun requestRefresh(
        providers: List<TrackingLibraryProvider>,
        profileId: Int = ProfileRepository.activeProfileId,
    ): List<Pair<TrackingProviderId, String>> {
        val decisions = refreshDecisions(
            throttle = refreshThrottle,
            connected = providers.map(TrackingLibraryProvider::providerId),
            activeSource = LibraryRepository.uiState.value.sourceMode.providerId,
            profileId = profileId,
            nowEpochMs = LibraryClock.nowEpochMs(),
            unloaded = providers
                .filterNot { provider -> provider.snapshot().hasLoaded }
                .map(TrackingLibraryProvider::providerId),
        )
        providers
            .filter { provider -> decisions.any { (id, decision) -> id == provider.providerId && decision == HomeWatchlistPullPull } }
            .forEach { provider -> refreshScope.launch { refresh(provider, profileId) } }
        return decisions
    }

    /**
     * Each connected provider's watchlist, re-read on its library changes and poster pattern.
     * [homeProfileId] null is the Library path (refresh at subscription); non-null is the Home path
     * for that profile (snapshots at once, one refresh once the release names the profile).
     */
    private fun watchlists(
        connected: Set<TrackingProviderId>,
        posterScreen: CustomPosterScreen,
        homeProfileId: Int?,
    ): Flow<List<LibraryProviderWatchlist>> {
        val providers = connected.mapNotNull(TrackingProviderRegistry::libraryProvider)
        if (providers.isEmpty()) return flowOf(emptyList())
        val posterPattern = combine(
            CustomPosterUrlRepository.pattern,
            CustomPosterUrlRepository.enabledScreens,
        ) { _, _ -> Unit }
        val changes = merge(posterPattern, *providers.map(TrackingLibraryProvider::changes).toTypedArray())
        val triggers = if (homeProfileId == null) {
            changes.onStart {
                requestRefresh(providers)
                emit(Unit)
            }
        } else {
            homeWatchlistTriggers(
                changes = changes,
                profileId = homeProfileId,
                releasedFor = homeRefreshReleasedFor,
                isActiveProfile = { id -> id == activeHomeProfileId() && id == ProfileRepository.activeProfileId },
                onMain = { block -> withContext(Dispatchers.Main) { block() } },
                onDeferred = { logPull(providers, homeProfileId, afterFirstRows = false, deferred = true) },
                onReleased = {
                    ensureLibrarySourceLoaded(homeProfileId)
                    logPull(requestRefresh(providers, homeProfileId), homeProfileId, afterFirstRows = true)
                },
            )
        }
        return triggers
            .map {
                val pattern = CustomPosterUrlRepository.patternForScreen(posterScreen)
                providers.map { provider ->
                    LibraryProviderWatchlist(
                        providerId = provider.providerId,
                        items = provider.snapshot().watchlistItems().withCustomPosterUrls(pattern),
                    )
                }
            }
            .distinctUntilChanged()
            // Review r1: StateFlow reads and pure work, so off the main thread.
            .flowOn(Dispatchers.Default)
    }

    /**
     * A failed pull leaves no throttle entry, so the next visit retries. Neither provider throws on
     * a failed pull: both report it in the snapshot's `errorMessage` (Trakt's `refresh`, Simkl's
     * sync state).
     */
    private suspend fun refresh(provider: TrackingLibraryProvider, profileId: Int) {
        val failed = try {
            provider.refresh(TrackingRefreshIntent.AUTOMATIC)
            provider.snapshot().errorMessage != null
        } catch (error: CancellationException) {
            throw error
        } catch (error: Throwable) {
            log.w(error) { "Watchlist refresh failed for ${provider.providerId.storageId}" }
            true
        }
        if (failed) refreshThrottle.forget(profileId, provider.providerId)
    }
}
