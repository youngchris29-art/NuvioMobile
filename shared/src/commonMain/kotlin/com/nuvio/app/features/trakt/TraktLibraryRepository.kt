package com.nuvio.app.features.trakt

import com.nuvio.app.core.coroutines.uncaughtCoroutineLogger
import co.touchlab.kermit.Logger
import com.nuvio.app.features.addons.RawHttpResponse
import com.nuvio.app.features.addons.httpRequestRaw
import com.nuvio.app.features.details.tenPointRatingText
import com.nuvio.app.features.library.LibraryItem
import com.nuvio.app.features.profiles.ProfileRepository
import kotlinx.atomicfu.atomic
import kotlinx.atomicfu.locks.SynchronizedObject
import kotlinx.atomicfu.locks.synchronized
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.async
import kotlinx.coroutines.coroutineScope
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asStateFlow
import kotlinx.coroutines.launch
import kotlinx.coroutines.sync.Mutex
import kotlinx.coroutines.sync.Semaphore
import kotlinx.coroutines.sync.withLock
import com.nuvio.app.core.i18n.StringKey
import com.nuvio.app.core.i18n.resourceString
import kotlinx.coroutines.sync.withPermit
import kotlinx.coroutines.selects.select
import kotlinx.coroutines.withContext
import kotlinx.serialization.SerialName
import kotlinx.serialization.Serializable
import kotlinx.serialization.decodeFromString
import kotlinx.serialization.encodeToString
import kotlinx.serialization.json.Json

private const val BASE_URL = "https://api.trakt.tv"
private const val WATCHLIST_KEY = "trakt:watchlist"
private const val PERSONAL_LIST_PREFIX = "trakt:list:"
private const val LIST_FETCH_CONCURRENCY = 3
private const val TRAKT_PAGE_LIMIT = 1_000
private const val SNAPSHOT_CACHE_TTL_MS = 60_000L
private const val LIST_TABS_CACHE_TTL_MS = 60_000L
private const val FORCE_REFRESH_DEDUP_MS = 10_000L
private const val MAX_VISIBLE_ERROR_MESSAGE_LENGTH = 240

data class TraktLibraryUiState(
    val listTabs: List<TraktListTab> = emptyList(),
    val entriesByList: Map<String, List<LibraryItem>> = emptyMap(),
    val allItems: List<LibraryItem> = emptyList(),
    val membershipByContent: Map<String, Set<String>> = emptyMap(),
    val isLoading: Boolean = false,
    val hasLoaded: Boolean = false,
    val errorMessage: String? = null,
)

object TraktLibraryRepository {
    private val log = Logger.withTag("TraktLibrary")
    private val json = Json {
        ignoreUnknownKeys = true
        encodeDefaults = true
    }
    private val scope = CoroutineScope(SupervisorJob() + Dispatchers.Default + uncaughtCoroutineLogger("TraktLibraryRepository"))

    private val _uiState = MutableStateFlow(TraktLibraryUiState())
    val uiState: StateFlow<TraktLibraryUiState> = _uiState.asStateFlow()

    /** W7 delta (P3): the profile whose cache is loaded; null = none. Read and written under [stateLock]. */
    private var loadedProfileId: Int? = null
    private val refreshMutex = Mutex()
    private var lastRefreshAtMs: Long = 0L
    private var lastListTabsRefreshAtMs: Long = 0L

    /**
     * W7 (P1): bumped by [onProfileChanged] and [clearLocalState]. A request captures it with the
     * active profile at its start; nothing it fetched is published or written once either moved.
     */
    private val profileGeneration = atomic(0L)

    /**
     * "Still current, then publish" against "bump, then reset" ([onProfileChanged],
     * [clearLocalState]). Never held across I/O. Lock order: [saveLock] may enclose this, never the reverse.
     */
    private val stateLock = SynchronizedObject()

    /** "Still current, then write" against sign-out's "bump, then wipe" ([clearLocalState]). */
    private val saveLock = SynchronizedObject()

    private class RequestToken(val generation: Long, val profileId: Int)

    private fun captureRequest(): RequestToken =
        RequestToken(profileGeneration.value, ProfileRepository.activeProfileId)

    private fun isCurrent(request: RequestToken): Boolean =
        request.generation == profileGeneration.value &&
            request.profileId == ProfileRepository.activeProfileId

    /** Sets `transform(latest)` unless the profile moved on; returns whether it was set. */
    private fun publishIfCurrent(
        request: RequestToken,
        transform: (TraktLibraryUiState) -> TraktLibraryUiState,
    ): Boolean = synchronized(stateLock) {
        if (isCurrent(request)) {
            _uiState.value = transform(_uiState.value)
            true
        } else {
            false
        }
    }

    /** Writes [state] to the REQUEST's profile file unless the profile moved on (encode outside the lock). */
    private fun saveIfCurrent(request: RequestToken, state: TraktLibraryUiState): Boolean {
        val payload = json.encodeToString(
            StoredTraktLibraryPayload(listTabs = state.listTabs, entriesByList = state.entriesByList),
        )
        return synchronized(saveLock) {
            if (isCurrent(request)) {
                payloadSaver(request.profileId, payload)
                true
            } else {
                false
            }
        }
    }

    /** Test seam: the full fetch (production: [fetchSnapshot]). */
    internal var snapshotFetcher: suspend (Map<String, String>, (TraktLibraryUiState) -> Unit) -> TraktLibraryUiState =
        { headers, onPartial -> fetchSnapshot(headers, onPartial) }

    /** Test seam: reads the NAMED profile's cached payload (production: [TraktLibraryStorage.loadPayload]). */
    internal var payloadLoader: (Int) -> String? = { profileId -> TraktLibraryStorage.loadPayload(profileId) }

    /** Test seam: writes the NAMED profile's payload (production: [TraktLibraryStorage.savePayload]). */
    internal var payloadSaver: (Int, String) -> Unit = { profileId, payload ->
        TraktLibraryStorage.savePayload(profileId, payload)
    }

    fun ensureLoaded() {
        val request = synchronized(stateLock) {
            // W7 delta review 2 (P3-1): read under the lock onProfileChanged resets under, so a caller
            // that entered before a switch can never roll the latch back to the old profile.
            val active = ProfileRepository.activeProfileId
            if (loadedProfileId == active) {
                null
            } else {
                if (loadedProfileId != null) {
                    // The active profile changed without onProfileChanged (a profile change that
                    // skipped the fan-out): retire the old profile's state and requests, as a switch does.
                    profileGeneration.incrementAndGet()
                    lastRefreshAtMs = 0L
                    lastListTabsRefreshAtMs = 0L
                    _uiState.value = TraktLibraryUiState()
                }
                loadedProfileId = active
                RequestToken(profileGeneration.value, active)
            }
        } ?: return
        loadSnapshotFromDisk(request)
    }

    fun preloadListTabsAsync() {
        if (!TraktAuthRepository.isAuthenticated.value) return
        if (_uiState.value.listTabs.isNotEmpty()) return
        scope.launch {
            runCatching { preloadListTabs() }
                .onFailure { error ->
                    if (error is CancellationException) throw error
                    log.w { "Failed to preload Trakt list tabs: ${error.message}" }
                }
        }
    }

    fun onProfileChanged() {
        synchronized(stateLock) {
            profileGeneration.incrementAndGet()
            loadedProfileId = null
            lastRefreshAtMs = 0L
            lastListTabsRefreshAtMs = 0L
            _uiState.value = TraktLibraryUiState()
        }
        ensureLoaded()
    }

    fun clearLocalState() {
        // Bump and wipe as one step against a request's "still current, then write".
        synchronized(saveLock) {
            synchronized(stateLock) {
                profileGeneration.incrementAndGet()
                loadedProfileId = null
                lastRefreshAtMs = 0L
                lastListTabsRefreshAtMs = 0L
                _uiState.value = TraktLibraryUiState()
            }
            payloadSaver(ProfileRepository.activeProfileId, "")
        }
    }

    fun currentListTabs(): List<TraktListTab> = _uiState.value.listTabs

    fun isInAnyList(itemId: String, itemType: String): Boolean {
        val key = contentKey(itemId, itemType)
        return _uiState.value.membershipByContent[key].orEmpty().isNotEmpty()
    }

    suspend fun refreshNow() {
        refresh(force = true)
    }

    suspend fun ensureFresh() {
        refresh(force = false)
    }

    /** Test seam: the list-tab fetch [preloadListTabs] runs (production: [fetchListTabs]). */
    internal var listTabsFetcher: suspend (Map<String, String>) -> List<TraktListTab> = { headers -> fetchListTabs(headers) }

    private suspend fun preloadListTabs() {
        ensureLoaded()
        refreshMutex.withLock {
            if (_uiState.value.listTabs.isNotEmpty()) return
            val request = captureRequest()
            val headers = authorizedHeadersSource() ?: return
            val tabs = listTabsFetcher(headers)
            publishIfCurrent(request) { state ->
                lastListTabsRefreshAtMs = TraktPlatformClock.nowEpochMs()
                state.copy(listTabs = tabs, errorMessage = null)
            }
        }
    }

    private suspend fun refresh(force: Boolean) {
        ensureLoaded()
        refreshMutex.withLock {
            // W7 (P1): captured under the mutex, so a request queued behind an older profile's
            // fetch runs for the profile active when it starts, and the older one is discarded.
            val request = captureRequest()
            val now = TraktPlatformClock.nowEpochMs()
            val current = _uiState.value
            // W7 delta (P3): fetchSnapshot refetches the tabs exactly when this is false; the stamp
            // is set only by the guarded final publish below.
            val tabsCached = current.listTabs.isNotEmpty() && now - lastListTabsRefreshAtMs <= LIST_TABS_CACHE_TTL_MS
            val cacheWindowMs = if (force) FORCE_REFRESH_DEDUP_MS else SNAPSHOT_CACHE_TTL_MS
            if (
                current.hasLoaded &&
                current.errorMessage == null &&
                now - lastRefreshAtMs <= cacheWindowMs
            ) {
                return
            }

            val headers = authorizedHeadersSource()
            if (headers == null) {
                publishIfCurrent(request) {
                    lastRefreshAtMs = 0L
                    lastListTabsRefreshAtMs = 0L
                    TraktLibraryUiState()
                }
                return
            }

            if (!publishIfCurrent(request) { it.copy(isLoading = true, errorMessage = null) }) return

            val result = runCatching {
                snapshotFetcher(headers) { partialState ->
                    publishIfCurrent(request) {
                        partialState.copy(isLoading = true, hasLoaded = true, errorMessage = null)
                    }
                }
            }
            result.exceptionOrNull()?.let { error ->
                if (error is CancellationException) throw error
                log.w(error) { "Failed to refresh Trakt library" }
                val message = traktLibraryLoadErrorMessage(error) // suspend: never inside a lock
                publishIfCurrent(request) {
                    it.copy(isLoading = false, hasLoaded = true, errorMessage = message)
                }
                return
            }

            val finalState = result.getOrThrow().copy(isLoading = false, hasLoaded = true, errorMessage = null)
            // Write first, then publish (Simkl's order). A switch between the two leaves the
            // request's own file correct and the new profile's state untouched.
            if (!saveIfCurrent(request, finalState)) return
            publishIfCurrent(request) {
                lastRefreshAtMs = now // inside the lock: a reset right after can never be overwritten
                if (!tabsCached) lastListTabsRefreshAtMs = now
                finalState
            }
        }
    }

    suspend fun getMembershipSnapshot(item: LibraryItem): TraktMembershipSnapshot {
        ensureLoaded()
        if (TraktAuthRepository.isAuthenticated.value) {
            ensureFresh()
        }
        // Issue #17 (review r1): by any of the item's ids, like the Detail page's saved-state lookup.
        val itemMembership = membershipListKeys(_uiState.value, item)
        val map = _uiState.value.listTabs.associate { tab ->
            tab.key to itemMembership.contains(tab.key)
        }
        return TraktMembershipSnapshot(listMembership = map)
    }

    suspend fun toggleWatchlist(item: LibraryItem) {
        ensureLoaded()
        val snapshot = getMembershipSnapshot(item)
        val currentlyInWatchlist = snapshot.listMembership[WATCHLIST_KEY] == true
        val desired = snapshot.listMembership.toMutableMap().apply {
            this[WATCHLIST_KEY] = !currentlyInWatchlist
        }
        applyMembershipChanges(item, TraktMembershipChanges(desiredMembership = desired))
    }

    /**
     * Test seam: the active profile's Trakt request headers, null when signed out or the token
     * could not be refreshed. Production always reads [TraktAuthRepository.authorizedHeaders].
     */
    internal var authorizedHeadersSource: suspend () -> Map<String, String>? = {
        TraktAuthRepository.authorizedHeaders()
    }

    /** Test seam: the list-tab loader [ensureListTabs] runs (production: [preloadListTabs]). */
    internal var listTabsLoader: suspend () -> Unit = { preloadListTabs() }

    /**
     * Issue #17: loads the list tabs (the watchlist among them) when none are loaded yet. Tabs
     * otherwise load lazily, so the Detail page's + could run before the watchlist tab exists.
     * Never throws (other than cancellation): membership reads stay as they were, and the toggle
     * reports a still-missing watchlist itself (`toggledTraktDefaultMembership`).
     */
    suspend fun ensureListTabs() {
        if (_uiState.value.listTabs.isNotEmpty()) return
        try {
            listTabsLoader()
        } catch (error: CancellationException) {
            throw error
        } catch (error: Throwable) {
            log.w(error) { "Failed to load Trakt list tabs on demand" }
        }
    }

    suspend fun applyMembershipChanges(item: LibraryItem, changes: TraktMembershipChanges) {
        // W7 delta (P2): bound to the profile active when the toggle starts, before any suspension.
        val request = captureRequest()
        // Issue #17: this used to `return` silently when the token was missing or expired, so the
        // Detail page's + did nothing. Fail loudly instead: the caller logs and shows the message.
        val headers = authorizedHeadersSource() ?: run {
            log.e { "Trakt library change refused item=${item.id} type=${item.type}: not signed in or token expired" }
            throw TraktSessionExpiredException()
        }
        ensureLoaded()
        ensureFresh()

        val current = getMembershipSnapshot(item).listMembership
        // A profile switch or sign-out during the two suspensions above: abandon quietly (no write
        // to the old profile's Trakt, no change to the new profile's state), as Simkl and
        // LibraryRepository.removeFromListAsync do.
        if (!isCurrent(request)) {
            log.i { "Trakt library change abandoned item=${item.id}: the profile changed" }
            return
        }
        val desired = changes.desiredMembership
        val keys = (current.keys + desired.keys).distinct()
        // W7 delta review 2 (P3-2): both set inside the publish's lock, for the rollback below.
        var previousState = _uiState.value
        var optimisticState = previousState

        if (!publishIfCurrent(request) { state ->
                previousState = state
                applyOptimisticMembershipChanges(state = state, item = item, desiredMembership = desired)
                    .also { optimisticState = it }
            }
        ) {
            log.i { "Trakt library change abandoned item=${item.id}: the profile changed" }
            return
        }

        try {
            for (key in keys) {
                val before = current[key] == true
                val after = desired[key] == true
                if (before == after) continue

                if (key != WATCHLIST_KEY) {
                    val listId = key.removePrefix(PERSONAL_LIST_PREFIX)
                    if (listId == key || listId.isBlank()) continue
                }
                membershipWriter(headers, key, after, item)
            }
        } catch (error: Throwable) {
            publishIfCurrent(request) { latest ->
                rolledBackMembership(
                    latest = latest,
                    previousState = previousState,
                    optimisticState = optimisticState,
                    item = item,
                    before = current,
                    desired = desired,
                )
            }
            throw error
        }
    }

    /**
     * W7 delta review 2 (P3-2): a failed toggle's rollback. When nothing was published since the
     * optimistic change, the exact pre-toggle state (as before). Otherwise (a refresh landed during
     * the writes) only the lists this toggle changed go back to their pre-toggle membership, on the
     * latest state, so the refresh's items survive. Pure; runs inside [publishIfCurrent]'s lock.
     */
    private fun rolledBackMembership(
        latest: TraktLibraryUiState,
        previousState: TraktLibraryUiState,
        optimisticState: TraktLibraryUiState,
        item: LibraryItem,
        before: Map<String, Boolean>,
        desired: Map<String, Boolean>,
    ): TraktLibraryUiState {
        if (latest === optimisticState) return previousState
        val itemKeys = allContentKeys(item)
        // Re-adding a removed title restores its stored entry (poster, savedAt), not the bare toggle item.
        val restoredItem = previousState.allItems.firstOrNull { entry ->
            allContentKeys(entry).any(itemKeys::contains)
        } ?: item
        val membership = membershipListKeys(latest, restoredItem).associateWith { true }.toMutableMap()
        (before.keys + desired.keys).forEach { key ->
            val wasMember = before[key] == true
            if (wasMember != (desired[key] == true)) membership[key] = wasMember
        }
        return applyOptimisticMembershipChanges(state = latest, item = restoredItem, desiredMembership = membership)
    }

    /** Test seam: one membership change on Trakt (production: [writeMembership]). */
    internal var membershipWriter: suspend (Map<String, String>, String, Boolean, LibraryItem) -> Unit =
        { headers, listKey, add, item -> writeMembership(headers, listKey, add, item) }

    private suspend fun writeMembership(headers: Map<String, String>, listKey: String, add: Boolean, item: LibraryItem) {
        if (listKey == WATCHLIST_KEY) {
            if (add) addToWatchlist(headers, item) else removeFromWatchlist(headers, item)
        } else {
            val listId = listKey.removePrefix(PERSONAL_LIST_PREFIX)
            if (add) addToPersonalList(headers, listId, item) else removeFromPersonalList(headers, listId, item)
        }
    }

    private fun applyOptimisticMembershipChanges(
        state: TraktLibraryUiState,
        item: LibraryItem,
        desiredMembership: Map<String, Boolean>,
    ): TraktLibraryUiState {
        if (state.listTabs.isEmpty()) return state

        // Issue #17 (review r1): the entry may be stored under another of the item's ids.
        val itemKeys = allContentKeys(item)
        val currentMembership = membershipListKeys(state, item)
        val updatedEntriesByList = state.entriesByList.toMutableMap()
        val keys = (currentMembership + desiredMembership.keys).distinct()

        keys.forEach { listKey ->
            val before = currentMembership.contains(listKey)
            val after = desiredMembership[listKey] == true
            if (before == after) return@forEach

            if (after) {
                val resolvedItem = resolveOptimisticItem(state, item)
                updatedEntriesByList[listKey] = listOf(resolvedItem) +
                    updatedEntriesByList[listKey].orEmpty().filterNot {
                        allContentKeys(it).any(itemKeys::contains)
                    }
            } else {
                updatedEntriesByList[listKey] = updatedEntriesByList[listKey].orEmpty().filterNot {
                    allContentKeys(it).any(itemKeys::contains)
                }
            }
        }

        return rebuildUiState(
            listTabs = state.listTabs,
            entriesByList = updatedEntriesByList,
        )
    }

    private fun resolveOptimisticItem(
        state: TraktLibraryUiState,
        item: LibraryItem,
    ): LibraryItem {
        val itemKeys = allContentKeys(item)
        val existing = state.allItems.firstOrNull {
            allContentKeys(it).any(itemKeys::contains)
        }
        val base = existing ?: item
        val savedAt = base.savedAtEpochMs.takeIf { it > 0L }
            ?: item.savedAtEpochMs.takeIf { it > 0L }
            ?: TraktPlatformClock.nowEpochMs()

        return base.copy(savedAtEpochMs = savedAt)
    }

    private fun rebuildUiState(
        listTabs: List<TraktListTab>,
        entriesByList: Map<String, List<LibraryItem>>,
    ): TraktLibraryUiState {
        val normalizedEntriesByList = linkedMapOf<String, List<LibraryItem>>()
        listTabs.forEach { tab ->
            normalizedEntriesByList[tab.key] = entriesByList[tab.key].orEmpty()
        }

        val membershipByContent = mutableMapOf<String, MutableSet<String>>()
        normalizedEntriesByList.forEach { (listKey, entries) ->
            entries.forEach { entry ->
                allContentKeys(entry).forEach { key ->
                    membershipByContent
                        .getOrPut(key) { mutableSetOf() }
                        .add(listKey)
                }
            }
        }

        val entriesWithMembership = normalizedEntriesByList.mapValues { (_, entries) ->
            entries.map { entry ->
                entry.copy(listKeys = membershipByContent[contentKey(entry.id, entry.type)].orEmpty())
            }
        }

        val allItemsByContent = linkedMapOf<String, LibraryItem>()
        entriesWithMembership.values
            .flatten()
            .sortedByDescending { it.savedAtEpochMs }
            .forEach { entry ->
                val key = contentKey(entry.id, entry.type)
                allItemsByContent[key] = entry.copy(listKeys = membershipByContent[key].orEmpty())
            }

        return TraktLibraryUiState(
            listTabs = listTabs,
            entriesByList = entriesWithMembership,
            allItems = allItemsByContent.values.toList().sortedByDescending { it.savedAtEpochMs },
            membershipByContent = membershipByContent.mapValues { it.value.toSet() },
            isLoading = false,
            hasLoaded = true,
            errorMessage = null,
        )
    }

    private suspend fun fetchSnapshot(
        headers: Map<String, String>,
        onPartialState: ((TraktLibraryUiState) -> Unit)? = null,
    ): TraktLibraryUiState = withContext(Dispatchers.Default) {
        val now = TraktPlatformClock.nowEpochMs()
        val cachedTabs = _uiState.value.listTabs
        val allTabs = if (
            cachedTabs.isNotEmpty() &&
            now - lastListTabsRefreshAtMs <= LIST_TABS_CACHE_TTL_MS
        ) {
            cachedTabs
        } else {
            fetchListTabs(headers)
        }

        val entriesByList = fetchEntriesByList(
            headers = headers,
            allTabs = allTabs,
            onProgress = onPartialState?.let { emitPartial ->
                { partialEntriesByList ->
                    emitPartial(
                        rebuildUiState(
                            listTabs = allTabs,
                            entriesByList = partialEntriesByList,
                        ),
                    )
                }
            },
        )

        rebuildUiState(
            listTabs = allTabs,
            entriesByList = entriesByList,
        )
    }

    private fun loadSnapshotFromDisk(request: RequestToken) {
        val payload = payloadLoader(request.profileId).orEmpty().trim()
        if (payload.isBlank()) return

        val cached = runCatching {
            json.decodeFromString<StoredTraktLibraryPayload>(payload)
        }.onFailure {
            log.w { "Failed to parse cached Trakt library payload: ${it.message}" }
        }.getOrNull() ?: return

        val state = rebuildUiState(
            listTabs = cached.listTabs,
            entriesByList = cached.entriesByList,
        )
        publishIfCurrent(request) { state.copy(isLoading = false, errorMessage = null, hasLoaded = true) }
    }

    private suspend fun traktLibraryLoadErrorMessage(error: Throwable): String {
        val fallback = resourceString("Failed to load Trakt library", StringKey.trakt_library_load_failed)
        val detail = error.userVisibleMessage()
        return when {
            detail.isBlank() -> fallback
            detail.equals(fallback, ignoreCase = true) -> fallback
            else -> detail
        }
    }

    private fun Throwable.userVisibleMessage(): String {
        val raw = message?.trim()?.takeIf { it.isNotBlank() }
            ?: toString().trim()
        val firstLine = raw.lines().firstOrNull()?.trim().orEmpty()
        return if (firstLine.length <= MAX_VISIBLE_ERROR_MESSAGE_LENGTH) {
            firstLine
        } else {
            firstLine.take(MAX_VISIBLE_ERROR_MESSAGE_LENGTH).trimEnd() + "..."
        }
    }

    private suspend fun fetchListTabs(headers: Map<String, String>): List<TraktListTab> {
        val watchlistTabs = listOf(
            TraktListTab(
                key = WATCHLIST_KEY,
                title = resourceString("Watchlist", StringKey.trakt_watchlist),
                type = TraktListType.WATCHLIST,
                sortBy = "rank",
                sortHow = "asc",
            ),
        )
        return watchlistTabs + fetchPersonalLists(headers)
    }

    private suspend fun fetchEntriesByList(
        headers: Map<String, String>,
        allTabs: List<TraktListTab>,
        onProgress: ((Map<String, List<LibraryItem>>) -> Unit)? = null,
    ): Map<String, List<LibraryItem>> = coroutineScope {
        val entriesByList = linkedMapOf<String, List<LibraryItem>>()
        allTabs.forEach { tab ->
            entriesByList[tab.key] = emptyList()
        }
        val listSemaphore = Semaphore(LIST_FETCH_CONCURRENCY)
        val personalTabs = allTabs.filter { it.type == TraktListType.PERSONAL }

        val watchlistDeferred = async {
            listSemaphore.withPermit {
                fetchWatchlistItems(headers)
            }
        }
        val personalEntries = personalTabs.associate { tab ->
            tab.key to async {
                val listId = tab.traktListId?.toString() ?: tab.slug.orEmpty()
                if (listId.isBlank()) {
                    emptyList()
                } else {
                    listSemaphore.withPermit {
                        fetchPersonalListItems(headers, tab)
                    }
                }
            }
        }

        entriesByList[WATCHLIST_KEY] = watchlistDeferred.await()
        onProgress?.invoke(entriesByList.toMap())

        val pendingEntries = personalEntries.toMutableMap()
        while (pendingEntries.isNotEmpty()) {
            val (listKey, listItems) = select<Pair<String, List<LibraryItem>>> {
                pendingEntries.forEach { (key, deferred) ->
                    deferred.onAwait { key to it }
                }
            }
            entriesByList[listKey] = listItems
            pendingEntries.remove(listKey)
            onProgress?.invoke(entriesByList.toMap())
        }

        entriesByList.toMap()
    }

    private suspend fun fetchPersonalLists(headers: Map<String, String>): List<TraktListTab> {
        val payload = getJson(headers = headers, url = "$BASE_URL/users/me/lists")
        val lists = json.decodeFromString<List<TraktListSummaryDto>>(payload)
        return lists
            .filter { it.type.equals("personal", ignoreCase = true) }
            .mapNotNull { list ->
                val traktId = list.ids?.trakt
                val listIdPath = traktId?.toString() ?: list.ids?.slug ?: return@mapNotNull null
                val fallbackTitle = traktId?.let { resourceString("List $it", StringKey.trakt_list_fallback_title, it) }
                    ?: "List $listIdPath"
                TraktListTab(
                    key = "$PERSONAL_LIST_PREFIX$listIdPath",
                    title = list.name?.ifBlank { null } ?: fallbackTitle,
                    type = TraktListType.PERSONAL,
                    traktListId = traktId,
                    slug = list.ids?.slug,
                    description = list.description,
                    privacy = TraktListPrivacy.fromApi(list.privacy),
                    sortBy = list.sortBy,
                    sortHow = list.sortHow,
                )
            }
    }

    private suspend fun fetchWatchlistItems(headers: Map<String, String>): List<LibraryItem> {
        val (movieItems, showItems) = coroutineScope {
            val moviesDeferred = async {
                fetchPagedListItems(
                    headers = headers,
                    urlForPage = { page ->
                        "$BASE_URL/users/me/watchlist/movies/rank?extended=full,images&page=$page&limit=$TRAKT_PAGE_LIMIT"
                    },
                )
            }
            val showsDeferred = async {
                fetchPagedListItems(
                    headers = headers,
                    urlForPage = { page ->
                        "$BASE_URL/users/me/watchlist/shows/rank?extended=full,images&page=$page&limit=$TRAKT_PAGE_LIMIT"
                    },
                )
            }
            moviesDeferred.await() to showsDeferred.await()
        }
        return (movieItems + showItems)
            .mapNotNull(::mapToLibraryItem)
            .sortedByDescending { it.savedAtEpochMs }
    }

    private suspend fun fetchPersonalListItems(
        headers: Map<String, String>,
        tab: TraktListTab,
    ): List<LibraryItem> {
        val listId = tab.traktListId?.toString() ?: tab.slug.orEmpty()
        if (listId.isBlank()) return emptyList()

        val sortQuery = buildSortQuery(tab.sortBy, tab.sortHow)
        val (movieItems, showItems) = coroutineScope {
            val moviesDeferred = async {
                fetchPagedListItems(
                    headers = headers,
                    urlForPage = { page ->
                        "$BASE_URL/users/me/lists/$listId/items/movie?extended=full,images&page=$page&limit=$TRAKT_PAGE_LIMIT$sortQuery"
                    },
                )
            }
            val showsDeferred = async {
                fetchPagedListItems(
                    headers = headers,
                    urlForPage = { page ->
                        "$BASE_URL/users/me/lists/$listId/items/show?extended=full,images&page=$page&limit=$TRAKT_PAGE_LIMIT$sortQuery"
                    },
                )
            }
            moviesDeferred.await() to showsDeferred.await()
        }

        return (movieItems + showItems)
            .mapNotNull(::mapToLibraryItem)
            .sortedWith(
                compareBy<LibraryItem> { it.traktRank ?: Int.MAX_VALUE }
                    .thenByDescending { it.savedAtEpochMs },
            )
    }

    private suspend fun fetchPagedListItems(
        headers: Map<String, String>,
        urlForPage: (Int) -> String,
    ): List<TraktListItemDto> {
        val items = mutableListOf<TraktListItemDto>()
        var page = 1

        while (true) {
            val response = getJsonResponse(headers = headers, url = urlForPage(page))
            val pageItems = json.decodeFromString<List<TraktListItemDto>>(response.body)
            items.addAll(pageItems)

            val pageCount = response.headerInt("x-pagination-page-count") ?: page
            if (page >= pageCount || pageItems.size < TRAKT_PAGE_LIMIT) break
            page += 1
        }

        return items
    }

    private suspend fun getJson(headers: Map<String, String>, url: String): String =
        getJsonResponse(headers, url).body

    private suspend fun getJsonResponse(
        headers: Map<String, String>,
        url: String,
    ): RawHttpResponse {
        val response = httpRequestRaw(
            method = "GET",
            url = url,
            headers = mapOf("Accept" to "application/json") + headers,
            body = "",
            followRedirects = true,
        )
        if (response.status !in 200..299) {
            throw IllegalStateException(errorMessageForStatus(response.status, resourceString("Trakt request failed", StringKey.trakt_error_request_failed)))
        }
        if (response.body.isBlank()) {
            throw IllegalStateException(resourceString("Empty response body", StringKey.trakt_error_empty_response))
        }
        return response
    }

    private suspend fun postJson(
        url: String,
        body: String,
        headers: Map<String, String>,
    ): RawHttpResponse {
        val response = httpRequestRaw(
            method = "POST",
            url = url,
            headers = mapOf(
                "Accept" to "application/json",
                "Content-Type" to "application/json",
            ) + headers,
            body = body,
            followRedirects = true,
        )
        if (response.status !in 200..299) {
            throw IllegalStateException(errorMessageForStatus(response.status, resourceString("Trakt request failed", StringKey.trakt_error_request_failed)))
        }
        return response
    }

    private fun RawHttpResponse.headerInt(name: String): Int? =
        headers.entries.firstOrNull { (key, _) -> key.equals(name, ignoreCase = true) }
            ?.value
            ?.substringBefore(',')
            ?.trim()
            ?.toIntOrNull()

    private fun buildSortQuery(sortBy: String?, sortHow: String?): String = buildString {
        sortBy?.takeIf { it.isNotBlank() }?.let { append("&sort_by=").append(it) }
        sortHow?.takeIf { it.isNotBlank() }?.let { append("&sort_how=").append(it) }
    }

    private suspend fun addToWatchlist(headers: Map<String, String>, item: LibraryItem) {
        val body = buildMutationBody(item)
        val response = postJson(
            url = "$BASE_URL/sync/watchlist",
            body = body,
            headers = headers,
        )
        if (!isSuccessfulAddResponse(response.body)) {
            throw IllegalStateException(errorMessageForStatus(response.status, resourceString("Failed to add to Trakt watchlist", StringKey.trakt_error_add_watchlist_failed)))
        }
    }

    private suspend fun removeFromWatchlist(headers: Map<String, String>, item: LibraryItem) {
        val body = buildMutationBody(item)
        postJson(
            url = "$BASE_URL/sync/watchlist/remove",
            body = body,
            headers = headers,
        )
    }

    private suspend fun addToPersonalList(headers: Map<String, String>, listId: String, item: LibraryItem) {
        val body = buildMutationBody(item)
        val response = postJson(
            url = "$BASE_URL/users/me/lists/$listId/items",
            body = body,
            headers = headers,
        )
        if (!isSuccessfulAddResponse(response.body)) {
            throw IllegalStateException(errorMessageForStatus(response.status, resourceString("Failed to add to Trakt list", StringKey.trakt_error_add_list_failed)))
        }
    }

    private suspend fun removeFromPersonalList(headers: Map<String, String>, listId: String, item: LibraryItem) {
        val body = buildMutationBody(item)
        postJson(
            url = "$BASE_URL/users/me/lists/$listId/items/remove",
            body = body,
            headers = headers,
        )
    }

    private suspend fun buildMutationBody(item: LibraryItem): String {
        val type = normalizeType(item.type)
        val ids = resolveIds(item)
        if (!ids.hasAnyId()) {
            // Issue #17: a search hit with an add-on-specific id and no IMDb/TMDB id lands here.
            throw IllegalStateException(traktMissingIdsMessage())
        }

        val request = if (type == "movie") {
            TraktListItemsMutationRequestDto(
                movies = listOf(
                    TraktListMovieRequestItemDto(
                        title = item.name,
                        year = extractYear(item.releaseInfo),
                        ids = ids,
                    ),
                ),
            )
        } else {
            TraktListItemsMutationRequestDto(
                shows = listOf(
                    TraktListShowRequestItemDto(
                        title = item.name,
                        year = extractYear(item.releaseInfo),
                        ids = ids,
                    ),
                ),
            )
        }
        return json.encodeToString(request)
    }

    private fun resolveIds(item: LibraryItem): TraktIdsDto {
        val parsed = parseTraktContentIds(item.id)

        return TraktIdsDto(
            imdb = item.imdbId ?: parsed.imdb,
            tmdb = item.tmdbId ?: parsed.tmdb,
            trakt = item.traktId ?: parsed.trakt,
        )
    }

    private fun mapToLibraryItem(item: TraktListItemDto): LibraryItem? {
        val movie = item.movie
        val show = item.show
        val type = when (item.type?.lowercase()) {
            "movie" -> "movie"
            "show" -> "series"
            else -> return null
        }
        val media = when (type) {
            "movie" -> movie
            else -> show
        } ?: return null
        val ids = media.ids

        val fallbackId = when {
            ids?.trakt != null -> "trakt:${ids.trakt}"
            item.id != null -> "trakt-item:${item.id}"
            !media.title.isNullOrBlank() -> "${type}:${media.title.lowercase()}:${media.year ?: 0}"
            else -> null
        } ?: return null

        val id = normalizeTraktContentId(
            ids?.toExternalIds(),
            fallback = fallbackId,
        ).takeIf { it.isNotBlank() }
            ?: return null

        val poster = media.images.traktBestPosterUrl()
        val banner = media.images.traktBestBackdropUrl()
        val logo = media.images.traktBestLogoUrl()

        val savedAt = item.listedAt
            ?.takeIf { it.isNotBlank() }
            ?.let(TraktPlatformClock::parseIsoDateTimeToEpochMs)
            ?: TraktPlatformClock.nowEpochMs()

        return LibraryItem(
            id = id,
            type = type,
            name = media.title?.ifBlank { id } ?: id,
            poster = poster,
            banner = banner,
            logo = logo,
            description = media.overview,
            releaseInfo = media.year?.toString(),
            imdbRating = tenPointRatingText(media.rating),
            genres = media.genres.orEmpty(),
            traktRank = item.rank,
            imdbId = ids?.imdb?.takeIf { it.isNotBlank() },
            tmdbId = ids?.tmdb,
            traktId = ids?.trakt,
            savedAtEpochMs = savedAt,
        )
    }

    private fun contentKey(itemId: String, itemType: String): String {
        val parsed = parseTraktContentIds(itemId)
        val normalizedId = normalizeTraktContentId(parsed, fallback = itemId.trim())
        val stableId = normalizedId.ifBlank { itemId.trim() }
        return "${normalizeType(itemType)}:$stableId"
    }

    /**
     * Issue #17 (review r1): the list keys the item is a member of, read by any of its content
     * keys (own id, IMDb, TMDB, Trakt), so an item Trakt holds under its `tt` id and asked for by
     * an add-on id (with the IMDb id filled in by `libraryItemForDetail`) reads as a member, and
     * the toggle removes it instead of adding it again.
     */
    internal fun membershipListKeys(state: TraktLibraryUiState, item: LibraryItem): Set<String> =
        allContentKeys(item).flatMapTo(mutableSetOf()) { key -> state.membershipByContent[key].orEmpty() }

    private fun allContentKeys(entry: LibraryItem): Set<String> {
        val type = normalizeType(entry.type)
        val keys = mutableSetOf(contentKey(entry.id, entry.type))
        entry.imdbId?.takeIf { it.isNotBlank() }?.let { keys.add("$type:$it") }
        entry.tmdbId?.let { keys.add("$type:tmdb:$it") }
        entry.traktId?.let { keys.add("$type:trakt:$it") }
        return keys
    }

    private fun isSuccessfulAddResponse(body: String): Boolean {
        if (body.isBlank()) return false
        val parsed = runCatching {
            json.decodeFromString<TraktListItemsMutationResponseDto>(body)
        }.getOrNull() ?: return false
        val added = parsed.added
        val existing = parsed.existing
        val addCount = (added?.movies ?: 0) + (added?.shows ?: 0) + (added?.seasons ?: 0) + (added?.episodes ?: 0)
        val existingCount = (existing?.movies ?: 0) + (existing?.shows ?: 0) + (existing?.seasons ?: 0) + (existing?.episodes ?: 0)
        return addCount > 0 || existingCount > 0
    }

    private fun errorMessageForStatus(status: Int, defaultMessage: String): String =
        when (status) {
            401, 403 -> resourceString("Trakt authorization expired", StringKey.trakt_error_authorization_expired)
            404 -> resourceString("Trakt list not found", StringKey.trakt_error_list_not_found)
            420 -> resourceString("Trakt list limit reached", StringKey.trakt_error_list_limit_reached)
            429 -> resourceString("Trakt rate limit reached", StringKey.trakt_error_rate_limit_reached)
            else -> "$defaultMessage ($status)"
        }

    private fun normalizeType(type: String): String {
        val normalized = type.trim().lowercase()
        return when (normalized) {
            "movie", "film" -> "movie"
            "tv", "show", "series", "tvshow" -> "series"
            else -> normalized
        }
    }

    private fun extractYear(releaseInfo: String?): Int? {
        if (releaseInfo.isNullOrBlank()) return null
        val yearText = Regex("(19|20)\\d{2}").find(releaseInfo)?.value ?: return null
        return yearText.toIntOrNull()
    }

    private fun TraktIdsDto.hasAnyId(): Boolean =
        trakt != null || !imdb.isNullOrBlank() || tmdb != null

    private fun TraktIdsDto.toExternalIds(): TraktExternalIds =
        TraktExternalIds(
            trakt = trakt,
            imdb = imdb,
            tmdb = tmdb,
        )
}

@Serializable
private data class StoredTraktLibraryPayload(
    val listTabs: List<TraktListTab> = emptyList(),
    val entriesByList: Map<String, List<LibraryItem>> = emptyMap(),
)

@Serializable
private data class TraktListSummaryDto(
    val name: String? = null,
    val description: String? = null,
    val privacy: String? = null,
    val type: String? = null,
    @SerialName("sort_by") val sortBy: String? = null,
    @SerialName("sort_how") val sortHow: String? = null,
    val ids: TraktListIdsDto? = null,
)

@Serializable
private data class TraktListIdsDto(
    val trakt: Long? = null,
    val slug: String? = null,
)

@Serializable
private data class TraktListItemDto(
    val rank: Int? = null,
    val id: Long? = null,
    @SerialName("listed_at") val listedAt: String? = null,
    val type: String? = null,
    val movie: TraktMediaDto? = null,
    val show: TraktMediaDto? = null,
)

@Serializable
private data class TraktMediaDto(
    val title: String? = null,
    val year: Int? = null,
    val ids: TraktIdsDto? = null,
    val overview: String? = null,
    val rating: Double? = null,
    val genres: List<String>? = null,
    val images: TraktImagesDto? = null,
)

@Serializable
private data class TraktIdsDto(
    val trakt: Int? = null,
    val imdb: String? = null,
    val tmdb: Int? = null,
)

@Serializable
private data class TraktListItemsMutationRequestDto(
    val movies: List<TraktListMovieRequestItemDto>? = null,
    val shows: List<TraktListShowRequestItemDto>? = null,
)

@Serializable
private data class TraktListItemsMutationResponseDto(
    val added: TraktListMutationCountDto? = null,
    val existing: TraktListMutationCountDto? = null,
    val deleted: TraktListMutationCountDto? = null,
)

@Serializable
private data class TraktListMutationCountDto(
    val movies: Int? = null,
    val shows: Int? = null,
    val seasons: Int? = null,
    val episodes: Int? = null,
)

@Serializable
private data class TraktListMovieRequestItemDto(
    val title: String? = null,
    val year: Int? = null,
    val ids: TraktIdsDto? = null,
)

@Serializable
private data class TraktListShowRequestItemDto(
    val title: String? = null,
    val year: Int? = null,
    val ids: TraktIdsDto? = null,
)

/**
 * Issue #17: the Trakt token is missing or could not be refreshed. Deliberately not a
 * `CancellationException`: the caller must log it and show its message.
 */
class TraktSessionExpiredException : IllegalStateException(
    resourceString(
        "Trakt sign-in expired. Reconnect Trakt under Settings.",
        StringKey.trakt_error_session_expired,
    ),
)

/** Issue #17: the library + was pressed and the Trakt watchlist tab still could not be loaded. */
class TraktWatchlistUnavailableException : IllegalStateException(
    resourceString(
        "Couldn’t load your Trakt watchlist. Try again.",
        StringKey.trakt_error_watchlist_unavailable,
    ),
)

internal fun traktMissingIdsMessage(): String =
    resourceString(
        "This title has no IMDb or TMDB id, so it can’t be added to Trakt.",
        StringKey.trakt_error_title_missing_ids,
    )
