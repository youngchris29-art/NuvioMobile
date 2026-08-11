package com.nuvio.app.features.home

import com.nuvio.app.core.coroutines.uncaughtCoroutineLogger
import com.nuvio.app.features.addons.ManagedAddon
import com.nuvio.app.features.addons.AddonRepository
import com.nuvio.app.features.addons.enabledAddons
import com.nuvio.app.features.catalog.CatalogTarget
import com.nuvio.app.features.catalog.fetchCatalogPage
import com.nuvio.app.features.collection.Collection
import com.nuvio.app.features.collection.CollectionRepository
import com.nuvio.app.features.collection.CollectionSource
import com.nuvio.app.features.collection.TmdbCollectionSourceResolver
import com.nuvio.app.features.collection.catalogRouteKey
import com.nuvio.app.features.collection.findCollectionCatalog
import com.nuvio.app.features.tmdb.TmdbMetadataService
import com.nuvio.app.features.tmdb.TmdbPreviewEnrichment
import com.nuvio.app.features.tmdb.TmdbSettings
import com.nuvio.app.features.tmdb.TmdbSettingsRepository
import com.nuvio.app.features.trakt.TraktPublicListSourceResolver
import com.nuvio.app.features.watchprogress.CurrentDateProvider
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.Job
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.async
import kotlinx.coroutines.awaitAll
import kotlinx.coroutines.delay
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asStateFlow
import kotlinx.coroutines.sync.Mutex
import kotlinx.coroutines.sync.withLock
import kotlinx.coroutines.flow.update
import kotlinx.coroutines.launch
import kotlin.math.absoluteValue
import kotlin.random.Random

object HomeRepository {
    private val scope = CoroutineScope(SupervisorJob() + Dispatchers.Default + uncaughtCoroutineLogger("HomeRepository"))
    private val _uiState = MutableStateFlow(HomeUiState())
    val uiState: StateFlow<HomeUiState> = _uiState.asStateFlow()

    private var activeJob: Job? = null
    private var activeRequestKey: String? = null
    private var completedRequestKey: String? = null
    private var currentDefinitions: List<HomeCatalogDefinition> = emptyList()
    private var cachedSections: Map<String, HomeCatalogSection> = emptyMap()
    private var cachedCollectionHeroItems: List<MetaPreview> = emptyList()
    private var collectionHeroJob: Job? = null
    private var collectionHeroRequestKey: String? = null
    private var lastPublishedCatalogHeroEmpty: Boolean = true
    private var lastErrorMessage: String? = null
    private var heroEnrichmentOverlay: Map<String, TmdbPreviewEnrichment> = emptyMap()
    private var heroEnrichmentAttempted: Set<String> = emptySet()
    /**
     * Items whose enrichment fetch is running right now. Dedup is PER ITEM, not per batch: the hero
     * set changes between catalog batches, and a batch-keyed dedup that cancels the running fetch on
     * every set change never resolves a held publish (BUG-42 deadlock) — it just restarts the work.
     */
    private var heroEnrichmentInFlight: Set<String> = emptySet()
    /**
     * Serializes every read-modify-write of the three sets above (Codex review): concurrent
     * per-batch fetch jobs on Dispatchers.Default would otherwise interleave their completions and
     * silently drop another job's overlay additions — leaving keys stuck in [heroEnrichmentInFlight],
     * which the dedup then excludes from refetching forever (hero pinned raw past the timeout).
     */
    private val heroEnrichmentMutex = Mutex()
    /** Parent of every in-flight enrichment fetch, so invalidation cancels them all in one call. */
    private var heroEnrichmentFetchParent: Job = SupervisorJob()
    private var heroEnrichmentHoldJob: Job? = null
    /** Bumped by every [releaseHeroEnrichmentHold]; a hold timer only acts if its era is current. */
    private var heroEnrichmentHoldGeneration: Long = 0
    /**
     * True once a held hero publish hit [HERO_ENRICHMENT_HOLD_TIMEOUT_MS]. Sticky until the hold
     * resolves cleanly (or settings/refresh invalidate it) so a stalled TMDB can never re-arm the
     * hold publish after publish and keep the hero region empty.
     */
    private var heroEnrichmentHoldExpired: Boolean = false

    fun refresh(addons: List<ManagedAddon>, force: Boolean = false) {
        val activeAddons = addons.enabledAddons()
        val requests = buildHomeCatalogDefinitions(activeAddons)
        currentDefinitions = requests
        val requestCacheKeys = requests.mapTo(mutableSetOf(), HomeCatalogDefinition::cacheKey)
        cachedSections = cachedSections.filterKeys(requestCacheKeys::contains)
        val requestKey = requests.joinToString(separator = "|", transform = HomeCatalogDefinition::cacheKey)

        if (!force && activeRequestKey == requestKey && _uiState.value.isLoading) return

        if (
            !force &&
            requestKey == completedRequestKey &&
            requestCacheKeys.all(cachedSections::containsKey) &&
            requestCacheKeys.any(::hasRenderableCachedSection)
        ) {
            if (_uiState.value.sections.isEmpty() || _uiState.value.heroItems.isEmpty()) {
                applyCurrentSettings()
            }
            return
        }
        activeRequestKey = requestKey
        // A new load is a new hero, so it gets a fresh hold budget: a timeout burnt on the previous
        // request must not force this one's first hero commit to publish raw metadata.
        releaseHeroEnrichmentHold()

        if (requests.isEmpty()) {
            activeJob?.cancel()
            activeJob = null
            activeRequestKey = null
            completedRequestKey = requestKey
            cachedSections = emptyMap()
            lastErrorMessage = null
            publishCurrentState(
                isLoading = false,
                requestKey = requestKey,
            )
            ensureCollectionHeroFallback(
                addons = activeAddons,
                force = force,
                requestKey = requestKey,
            )
            return
        }

        activeJob?.cancel()
        _uiState.update { it.copy(isLoading = true, errorMessage = null) }
        activeJob = scope.launch {
            val prioritizedRequests = prioritizeDefinitions(
                definitions = requests,
                snapshot = HomeCatalogSettingsRepository.snapshot(),
            )
            val pendingRequests = prioritizedRequests.filter { definition ->
                force || cachedSections[definition.cacheKey] == null
            }
            if (pendingRequests.isEmpty()) {
                publishCurrentState(
                    isLoading = false,
                    requestKey = requestKey,
                )
                return@launch
            }
            val loadedSections = linkedMapOf<String, HomeCatalogSection>().apply {
                putAll(cachedSections)
            }
            var firstErrorMessage: String? = null
            var batchIndex = 0

            pendingRequests.chunked(HOME_CATALOG_FETCH_BATCH_SIZE).forEach { batch ->
                if (activeRequestKey != requestKey) return@launch
                val results = batch.map { request ->
                    async { request to runCatching { request.toSection() } }
                }.awaitAll()

                if (activeRequestKey != requestKey) return@launch

                results.mapNotNull { (request, result) ->
                    result.getOrNull()?.let { section -> request.cacheKey to section }
                }.forEach { (cacheKey, section) ->
                    loadedSections[cacheKey] = section
                }
                if (firstErrorMessage == null) {
                    firstErrorMessage = results.firstNotNullOfOrNull { (_, result) ->
                        result.exceptionOrNull()?.message
                    }
                }
                cachedSections = loadedSections.toMap()
                lastErrorMessage = firstErrorMessage
                if (batchIndex == 0 || (batchIndex + 1) % HOME_CATALOG_PUBLISH_INTERVAL == 0) {
                    publishCurrentState(
                        isLoading = true,
                        requestKey = requestKey,
                    )
                }
                batchIndex++
            }

            if (activeRequestKey != requestKey) return@launch

            cachedSections = loadedSections.toMap()
            lastErrorMessage = firstErrorMessage
            if (cachedSections.values.any { section -> section.items.isNotEmpty() }) {
                completedRequestKey = requestKey
            }
            activeRequestKey = null
            publishCurrentState(
                isLoading = false,
                requestKey = requestKey,
            )
            ensureCollectionHeroFallback(
                addons = activeAddons,
                force = force,
                requestKey = requestKey,
            )
        }
    }

    fun applyCurrentSettings() {
        publishCurrentState(
            isLoading = _uiState.value.isLoading,
            requestKey = activeRequestKey ?: completedRequestKey,
        )
        ensureCollectionHeroFallback(
            addons = AddonRepository.uiState.value.addons.enabledAddons(),
            force = false,
            requestKey = activeRequestKey ?: completedRequestKey,
        )
    }

    /**
     * Called when TMDB settings (enabled/apiKey/language) change so the hero overlay is rebuilt
     * under the new settings instead of continuing to show enrichment fetched under the old ones.
     */
    fun onTmdbSettingsChanged() {
        resetHeroEnrichment()
        applyCurrentSettings()
    }

    fun clear() {
        activeJob?.cancel()
        activeJob = null
        activeRequestKey = null
        completedRequestKey = null
        currentDefinitions = emptyList()
        cachedSections = emptyMap()
        cachedCollectionHeroItems = emptyList()
        collectionHeroJob?.cancel()
        collectionHeroJob = null
        collectionHeroRequestKey = null
        resetHeroEnrichment()
        lastPublishedCatalogHeroEmpty = true
        lastErrorMessage = null
        _uiState.value = HomeUiState()
    }

    private fun hasRenderableCachedSection(cacheKey: String): Boolean =
        cachedSections[cacheKey]?.items?.isNotEmpty() == true

    private fun publishCurrentState(
        isLoading: Boolean,
        requestKey: String?,
    ) {
        val snapshot = HomeCatalogSettingsRepository.snapshot()
        val preferences = snapshot.preferences
        val todayIsoDate = if (snapshot.hideUnreleasedContent) CurrentDateProvider.todayIsoDate() else null
        fun HomeCatalogSection.withReleaseFilter(): HomeCatalogSection =
            if (todayIsoDate == null) this else filterReleasedItems(todayIsoDate)

        val sections = currentDefinitions
            .sortedBy { definition -> preferences[definition.key]?.order ?: Int.MAX_VALUE }
            .mapNotNull { definition ->
                val preference = preferences[definition.key]
                if (preference?.enabled == false) return@mapNotNull null

                val section = cachedSections[definition.cacheKey]?.withReleaseFilter() ?: return@mapNotNull null
                if (section.items.isEmpty()) return@mapNotNull null
                val customTitle = preference?.customTitle.orEmpty()
                section.copy(
                    title = customTitle.ifBlank { definition.titleFor(snapshot.showCatalogType) },
                )
            }

        val catalogHeroItems = if (snapshot.heroEnabled) {
            val heroRandom = Random((requestKey?.hashCode() ?: 0).absoluteValue + 1)
            currentDefinitions
                .filter { definition -> preferences[definition.key]?.heroSourceEnabled != false }
                .mapNotNull { definition -> cachedSections[definition.cacheKey] }
                .map { section -> section.withReleaseFilter() }
                .flatMap { section -> section.items }
                .distinctBy { item -> "${item.type}:${item.id}" }
                .shuffled(heroRandom)
                .take(HOME_HERO_ITEM_LIMIT)
        } else {
            emptyList()
        }
        lastPublishedCatalogHeroEmpty = snapshot.heroEnabled && catalogHeroItems.isEmpty()
        val heroItems = if (snapshot.heroEnabled) {
            catalogHeroItems.ifEmpty { cachedCollectionHeroItems }
        } else {
            emptyList()
        }

        val tmdbSettings = TmdbSettingsRepository.snapshot()

        // BUG-42: the hero commits each item's metadata exactly ONCE. Publishing raw catalog
        // metadata and then re-publishing the TMDB-localized payload rendered the same title twice
        // (English under French, caught frame-by-frame in a tester video), so a hero whose items
        // still have enrichment outstanding HOLDS — it keeps whatever was last published — until
        // the fetch lands or [HERO_ENRICHMENT_HOLD_TIMEOUT_MS] expires. Rows are NOT held: they are
        // published on this same pass regardless, so catalog loading never serializes behind TMDB.
        val awaitingEnrichment = heroItemsAwaitingEnrichment(heroItems, tmdbSettings)
        val holdHeroPublish = awaitingEnrichment.isNotEmpty() && !heroEnrichmentHoldExpired

        _uiState.value = HomeUiState(
            isLoading = isLoading,
            heroItems = if (holdHeroPublish) {
                _uiState.value.heroItems
            } else {
                heroItems.map { it.withTmdbEnrichment(tmdbSettings) }
            },
            sections = sections.map { section -> section.withTmdbEnrichment(tmdbSettings) },
            errorMessage = if (sections.isEmpty()) lastErrorMessage else null,
        )

        if (awaitingEnrichment.isEmpty()) {
            releaseHeroEnrichmentHold()
            return
        }
        // Scheduled on every publish, loading included — a hold with no fetch behind it can only end
        // at the timeout, which would put hero first paint behind the whole catalog fan-out.
        scheduleHeroEnrichment(awaitingEnrichment, tmdbSettings)
        if (holdHeroPublish) armHeroEnrichmentHold()
    }

    /**
     * Codex review: the key is LANGUAGE-QUALIFIED so an enrichment fetched under one TMDB
     * language can never be served under another — even if a settings-change reset races an
     * in-flight completion (reset can't take [heroEnrichmentMutex] from its non-suspend callers,
     * so a straggler write CAN land after the clear; with the language in the key, that straggler
     * is simply unmatchable dead weight until the next reset instead of stale UI).
     */
    private fun MetaPreview.heroEnrichmentKey(settings: TmdbSettings): String =
        "$type:$id:${settings.language}"

    /**
     * BUG-35 (beta.12): the fetch-volume product call landed on VISIBILITY-DRIVEN row enrichment —
     * see [requestRowEnrichment]. This application step is unchanged: row items render whatever
     * the shared overlay already holds (hero-fetched or row-fetched alike), and a section with no
     * resident overlay entries passes through untouched.
     */
    private fun HomeCatalogSection.withTmdbEnrichment(settings: TmdbSettings): HomeCatalogSection {
        if (!settings.enabled || !settings.hasApiKey || heroEnrichmentOverlay.isEmpty()) return this
        if (items.none { item -> item.heroEnrichmentKey(settings) in heroEnrichmentOverlay }) return this
        return copy(items = items.map { item -> item.withTmdbEnrichment(settings) })
    }

    /**
     * Applies cached TMDB preview enrichment. Gated on [settings] so a disabled/removed TMDB config
     * stops showing stale enrichment on the very next publish, and never touches id/type/poster —
     * those identify and route the card.
     */
    private fun MetaPreview.withTmdbEnrichment(settings: TmdbSettings): MetaPreview {
        if (!settings.enabled || !settings.hasApiKey) return this
        val enrichment = heroEnrichmentOverlay[heroEnrichmentKey(settings)] ?: return this

        var updated = this
        if (settings.useBasicInfo) {
            updated = updated.copy(
                name = enrichment.localizedTitle ?: updated.name,
                description = enrichment.description ?: updated.description,
                genres = enrichment.genres.ifEmpty { updated.genres },
            )
        }
        if (settings.useArtwork) {
            updated = updated.copy(
                logo = enrichment.logo ?: updated.logo,
                banner = enrichment.backdrop ?: updated.banner,
            )
        }
        return updated
    }

    /**
     * Hero items whose enrichment is neither cached nor already known to be unavailable — i.e. the
     * items a hero publish would have to commit raw. Empty whenever enrichment cannot change the
     * payload at all (disabled, no key, both TMDB categories off), which is the "publish raw
     * immediately, exactly as before" path.
     */
    private fun heroItemsAwaitingEnrichment(
        items: List<MetaPreview>,
        settings: TmdbSettings,
    ): List<MetaPreview> {
        if (!settings.enabled || !settings.hasApiKey) return emptyList()
        if (!settings.useBasicInfo && !settings.useArtwork) return emptyList()
        return items.filter { item ->
            val key = item.heroEnrichmentKey(settings)
            key !in heroEnrichmentOverlay && key !in heroEnrichmentAttempted
        }
    }

    /**
     * Bounds the held hero publish. Deliberately NOT restarted while a hold is already running: the
     * hero set grows with each catalog batch, and re-arming per publish would let the cap slide
     * forward indefinitely. One timer per hold, so the worst case stays one
     * [HERO_ENRICHMENT_HOLD_TIMEOUT_MS] window from the first held publish.
     */
    private fun armHeroEnrichmentHold() {
        if (heroEnrichmentHoldJob?.isActive == true) return
        // Codex review: cancellation racing the delay's completion can let a stale timer resume
        // AFTER releaseHeroEnrichmentHold() started a new hold era — the generation token makes
        // such a zombie a no-op instead of expiring the new request's hold.
        val generation = heroEnrichmentHoldGeneration
        heroEnrichmentHoldJob = scope.launch {
            delay(HERO_ENRICHMENT_HOLD_TIMEOUT_MS)
            if (generation != heroEnrichmentHoldGeneration) return@launch
            heroEnrichmentHoldExpired = true
            publishCurrentState(
                isLoading = _uiState.value.isLoading,
                requestKey = activeRequestKey ?: completedRequestKey,
            )
        }
    }

    /** Clears the hold without touching the overlay — the next unresolved hero may hold again. */
    private fun releaseHeroEnrichmentHold() {
        heroEnrichmentHoldGeneration += 1
        heroEnrichmentHoldJob?.cancel()
        heroEnrichmentHoldJob = null
        heroEnrichmentHoldExpired = false
    }

    /** Full invalidation (settings changed, signed out): nothing may survive into the next language. */
    private fun resetHeroEnrichment() {
        heroEnrichmentFetchParent.cancel()
        heroEnrichmentFetchParent = SupervisorJob()
        heroEnrichmentOverlay = emptyMap()
        heroEnrichmentAttempted = emptySet()
        heroEnrichmentInFlight = emptySet()
        releaseHeroEnrichmentHold()
    }

    /**
     * BUG-35 (beta.12): localize a row's LEADING items when the row actually scrolls into view.
     * tvOS calls this from each catalog row's `onAppear`, which bounds fetch volume by what the
     * user actually looks at instead of the whole catalog fan-out (the deferred fetch-volume
     * product call, resolved): ≤ [HOME_ROW_ENRICHMENT_PREFIX] items per row, deduped per
     * item+language for the whole session by the same overlay/attempted/in-flight sets the hero
     * uses, fetched through the same mutex-guarded pipeline, republished by its existing
     * completion path. Rows are never HELD like the hero — the caption text updating in place as
     * the localized payload lands is the accepted row-level trade (BUG-42's double-commit
     * objection was about the full-bleed hero, which keeps its once-only hold).
     */
    fun requestRowEnrichment(sectionKey: String) {
        val settings = TmdbSettingsRepository.snapshot()
        if (!settings.enabled || !settings.hasApiKey) return
        // Same gate the hero path applies (heroItemsAwaitingEnrichment): with both output
        // categories off, a fetch could not change a single rendered field — don't spend it.
        if (!settings.useBasicInfo && !settings.useArtwork) return
        val section = _uiState.value.sections.find { it.key == sectionKey } ?: return
        // No pre-filter against the overlay sets here: this is a non-suspend caller, and
        // [scheduleHeroEnrichment] re-checks all three sets under the mutex before claiming —
        // an already-resident prefix just claims nothing and the launch returns immediately.
        scheduleHeroEnrichment(section.items.take(HOME_ROW_ENRICHMENT_PREFIX), settings)
    }

    /**
     * Fetches TMDB preview enrichment for the given items, keyed by item so a removed/failed item
     * never gets retried on every publish and so overlapping publishes (each catalog batch reshuffles
     * the hero) never fetch the same item twice. Fetches are additive and are never cancelled by a
     * later publish — a cancelled fetch would leave its items neither resolved nor attempted, which
     * is precisely the state a held publish waits on. The completion republish sources its requestKey
     * the same way the settings-driven republishes do, so the seeded hero shuffle always matches
     * whatever request is currently live — a job that outlives its request can't resurrect an old seed.
     */
    private fun scheduleHeroEnrichment(items: List<MetaPreview>, settings: TmdbSettings) {
        if (items.isEmpty()) return
        scope.launch(heroEnrichmentFetchParent) {
            // Claiming the batch happens under the mutex (not synchronously in the caller) so two
            // concurrent publishes can never both claim — and both fetch — the same item. All
            // THREE sets are rechecked here (Codex review): a queued job can reach this lock
            // after an earlier fetch already moved its item from in-flight into the overlay or
            // attempted set, and claiming on the in-flight set alone would refetch it.
            val missing = heroEnrichmentMutex.withLock {
                val claimable = items.filter { item ->
                    val key = item.heroEnrichmentKey(settings)
                    key !in heroEnrichmentInFlight &&
                        key !in heroEnrichmentOverlay &&
                        key !in heroEnrichmentAttempted
                }
                heroEnrichmentInFlight = heroEnrichmentInFlight + claimable.map { it.heroEnrichmentKey(settings) }
                claimable
            }
            if (missing.isEmpty()) return@launch
            val results = missing.map { item ->
                async {
                    item.heroEnrichmentKey(settings) to runCatching {
                        TmdbMetadataService.fetchPreviewEnrichment(item.type, item.id, settings)
                    }.getOrNull()
                }
            }.awaitAll()

            val additions = results.mapNotNull { (key, enrichment) -> enrichment?.let { key to it } }.toMap()
            val nullKeys = results.filter { (_, enrichment) -> enrichment == null }.map { (key, _) -> key }.toSet()

            heroEnrichmentMutex.withLock {
                heroEnrichmentOverlay = heroEnrichmentOverlay + additions
                heroEnrichmentAttempted = heroEnrichmentAttempted + nullKeys
                heroEnrichmentInFlight = heroEnrichmentInFlight - additions.keys - nullKeys

                // Republished even when every fetch missed: an all-miss batch is what releases a
                // held hero publish (the items are now "attempted"), so gating this on additions
                // would pin the hero on the timeout path for no reason.
                //
                // EXCEPT after the hold timed out (Codex review): the raw hero is already on
                // screen then, and a completion-triggered republish would swap its text in place —
                // the exact BUG-35/42 double commit this hold exists to prevent, just slower. The
                // overlay/attempted bookkeeping above still lands, so the NEXT natural publish (a
                // catalog batch, a refresh, a settings change — all visual transitions anyway)
                // serves the localized payload.
                //
                // The publish itself stays INSIDE the lock (Codex review round 2 on this spot):
                // two completions finishing close together could otherwise publish out of order —
                // the earlier batch's state overwriting the later, fully-localized one, and
                // re-arming the hold. Safe against self-deadlock: publishCurrentState only
                // ever *launches* the claim coroutine, it never takes this mutex inline.
                if (!heroEnrichmentHoldExpired) {
                    publishCurrentState(
                        isLoading = _uiState.value.isLoading,
                        requestKey = activeRequestKey ?: completedRequestKey,
                    )
                } else {
                    // BUG-35 (beta.12, Codex gate 4-5): once the hero hold has expired, the full
                    // republish above stays suppressed so the raw hero on screen never swaps its
                    // text in place — but row enrichment (requestRowEnrichment) rides this same
                    // completion, and skipping entirely left row batches updating only the overlay,
                    // invisible until an unrelated publish. Sections-only update: hero untouched
                    // (exact objects last published), rows re-run the overlay application, which
                    // never touches id/type/poster and is idempotent for already-localized items.
                    val settingsNow = TmdbSettingsRepository.snapshot()
                    // CAS update, not read-copy-write (Codex gate 4-5 round 3): a catalog batch
                    // publishing between a plain read and write would be clobbered by the stale
                    // copy. `update` retries on contention, and the transform touches ONLY
                    // `sections`, so whatever state won the race keeps its loading/error/hero.
                    _uiState.update { state ->
                        state.copy(sections = state.sections.map { section -> section.withTmdbEnrichment(settingsNow) })
                    }
                }
            }
        }
    }

    private suspend fun HomeCatalogDefinition.toSection(): HomeCatalogSection {
        val page = fetchCatalogPage(
            manifestUrl = manifestUrl,
            type = type,
            catalogId = catalogId,
            maxItems = HOME_CATALOG_PREVIEW_FETCH_LIMIT,
        )
        val items = page.items
        if (items.isEmpty()) {
            return HomeCatalogSection(
                key = key,
                title = defaultTitle,
                subtitle = addonName,
                addonName = addonName,
                target = CatalogTarget.Addon(
                    manifestUrl = manifestUrl,
                    contentType = type,
                    catalogId = catalogId,
                    supportsPagination = supportsPagination,
                ),
                items = emptyList(),
                availableItemCount = 0,
                hasMore = false,
            )
        }

        return HomeCatalogSection(
            key = key,
            title = defaultTitle,
            subtitle = addonName,
            addonName = addonName,
            target = CatalogTarget.Addon(
                manifestUrl = manifestUrl,
                contentType = type,
                catalogId = catalogId,
                supportsPagination = supportsPagination,
            ),
            items = items,
            availableItemCount = page.rawItemCount,
            hasMore = supportsPagination && page.nextSkip != null,
        )
    }

    private fun ensureCollectionHeroFallback(
        addons: List<ManagedAddon>,
        force: Boolean,
        requestKey: String?,
    ) {
        if (!lastPublishedCatalogHeroEmpty) return
        val snapshot = HomeCatalogSettingsRepository.snapshot()
        if (!snapshot.heroEnabled) return
        val collections = enabledCollectionsForHero(snapshot)
        if (collections.isEmpty()) {
            cachedCollectionHeroItems = emptyList()
            collectionHeroRequestKey = null
            return
        }

        val nextRequestKey = collectionHeroRequestKey(
            collections = collections,
            addons = addons,
            snapshot = snapshot,
            requestKey = requestKey,
        )
        if (!force && collectionHeroRequestKey == nextRequestKey) return

        collectionHeroJob?.cancel()
        collectionHeroRequestKey = nextRequestKey
        cachedCollectionHeroItems = emptyList()
        publishCurrentState(
            isLoading = _uiState.value.isLoading,
            requestKey = requestKey,
        )

        collectionHeroJob = scope.launch {
            val sources = collectionHeroSources(collections)
            val sourceResults = sources.map { source ->
                async {
                    runCatching {
                        source.resolveCollectionHeroItems(addons)
                    }.getOrDefault(emptyList())
                }
            }.awaitAll()
            val random = Random((nextRequestKey.hashCode()).absoluteValue + 7)
            cachedCollectionHeroItems = roundRobinCollectionHeroItems(sourceResults)
                .distinctBy { item -> item.stableKey() }
                .shuffled(random)
                .take(HOME_HERO_ITEM_LIMIT)
            publishCurrentState(
                isLoading = _uiState.value.isLoading,
                requestKey = requestKey,
            )
        }
    }

    private fun enabledCollectionsForHero(snapshot: HomeCatalogSettingsSnapshot): List<Collection> {
        val preferences = snapshot.preferences
        return CollectionRepository.collections.value
            .filter { collection ->
                collection.folders.isNotEmpty() &&
                    preferences["collection_${collection.id}"]?.enabled != false
            }
            .sortedBy { collection ->
                preferences["collection_${collection.id}"]?.order ?: Int.MAX_VALUE
            }
    }

    private fun collectionHeroSources(collections: List<Collection>): List<CollectionSource> =
        collections
            .flatMap { collection -> collection.folders }
            .flatMap { folder -> folder.resolvedSources }
            .take(HOME_COLLECTION_HERO_SOURCE_LIMIT)

    private suspend fun CollectionSource.resolveCollectionHeroItems(addons: List<ManagedAddon>): List<MetaPreview> {
        val page = when {
            isTmdb -> TmdbCollectionSourceResolver.resolve(source = this, page = 1)
            isTrakt -> TraktPublicListSourceResolver.resolve(source = this, page = 1)
            else -> {
                val catalogSource = addonCatalogSource() ?: return emptyList()
                val resolvedCatalog = addons.findCollectionCatalog(catalogSource) ?: return emptyList()
                fetchCatalogPage(
                    manifestUrl = resolvedCatalog.addon.manifestUrl,
                    type = catalogSource.type,
                    catalogId = catalogSource.catalogId,
                    genre = catalogSource.genre,
                    maxItems = HOME_COLLECTION_HERO_SOURCE_ITEM_LIMIT,
                )
            }
        }
        val items = page.items
        return if (HomeCatalogSettingsRepository.snapshot().hideUnreleasedContent) {
            items.filterReleasedItems(CurrentDateProvider.todayIsoDate())
        } else {
            items
        }
    }

    private fun roundRobinCollectionHeroItems(sourceResults: List<List<MetaPreview>>): List<MetaPreview> {
        val iterators = sourceResults.filter { it.isNotEmpty() }.map { it.iterator() }
        if (iterators.isEmpty()) return emptyList()
        val merged = mutableListOf<MetaPreview>()
        var hasMore = true
        while (hasMore && merged.size < HOME_COLLECTION_HERO_SOURCE_LIMIT * HOME_COLLECTION_HERO_SOURCE_ITEM_LIMIT) {
            hasMore = false
            iterators.forEach { iterator ->
                if (iterator.hasNext()) {
                    merged.add(iterator.next())
                    hasMore = true
                }
            }
        }
        return merged
    }

    private fun collectionHeroRequestKey(
        collections: List<Collection>,
        addons: List<ManagedAddon>,
        snapshot: HomeCatalogSettingsSnapshot,
        requestKey: String?,
    ): String = buildString {
        append(requestKey.orEmpty())
        append("|hideUnreleased=")
        append(snapshot.hideUnreleasedContent)
        append("|collections=")
        collections.forEach { collection ->
            val preference = snapshot.preferences["collection_${collection.id}"]
            append(collection.id)
            append(":")
            append(preference?.order ?: Int.MAX_VALUE)
            append(":")
            collection.folders.forEach { folder ->
                append(folder.id)
                append("[")
                folder.resolvedSources.forEach { source ->
                    append(collectionSourceKey(source))
                    append(",")
                }
                append("]")
            }
            append(";")
        }
        append("|addons=")
        addons.forEach { addon ->
            append(addon.manifest?.id.orEmpty())
            append(":")
            append(addon.manifestUrl)
            append(":")
            append(addon.manifest?.catalogs?.size ?: 0)
            append(";")
        }
    }

    private fun collectionSourceKey(source: CollectionSource): String =
        source.catalogRouteKey()
}

private const val HOME_HERO_ITEM_LIMIT = 8

/**
 * BUG-35 (beta.12): how many leading items of a row [HomeRepository.requestRowEnrichment]
 * localizes when the row scrolls into view. Covers the on-screen cards (~7 on Home) plus the
 * first step of a horizontal scroll; per-item+language session dedup means a row re-appearing
 * costs nothing. Worst-case fetch volume is this × rows-actually-seen, not × the catalog fan-out.
 */
private const val HOME_ROW_ENRICHMENT_PREFIX = 12
private const val HOME_COLLECTION_HERO_SOURCE_LIMIT = 6
private const val HOME_COLLECTION_HERO_SOURCE_ITEM_LIMIT = 8
private const val HOME_CATALOG_FETCH_BATCH_SIZE = 4
private const val HOME_CATALOG_PREVIEW_FETCH_LIMIT = 18
private const val HOME_CATALOG_PUBLISH_INTERVAL = 2

/**
 * Hard cap on how long the hero's METADATA commit waits for TMDB enrichment before publishing raw
 * catalog metadata instead. Hero first paint is a monitored latency metric (BUG-26 / LaunchTrace),
 * so a slow or dead TMDB must degrade to English text rather than leave the hero region empty:
 * 2s covers a warm parallel preview fetch of the whole hero set with room to spare, and past it a
 * localized title is worth less than the blank hero costs. Bounds the hero only — catalog rows
 * publish on the same pass regardless of enrichment state.
 */
private const val HERO_ENRICHMENT_HOLD_TIMEOUT_MS = 2_000L

private fun prioritizeDefinitions(
    definitions: List<HomeCatalogDefinition>,
    snapshot: HomeCatalogSettingsSnapshot,
): List<HomeCatalogDefinition> {
    val orderedDefinitions = definitions.sortedBy { definition ->
        snapshot.preferences[definition.key]?.order ?: Int.MAX_VALUE
    }
    val (priority, remainder) = orderedDefinitions.partition { definition ->
        val preference = snapshot.preferences[definition.key]
        if (preference == null) {
            true
        } else {
            preference.enabled || (snapshot.heroEnabled && preference.heroSourceEnabled)
        }
    }
    return priority + remainder
}
