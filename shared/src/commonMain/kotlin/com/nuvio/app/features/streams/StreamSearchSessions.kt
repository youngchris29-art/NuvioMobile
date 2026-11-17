package com.nuvio.app.features.streams

import co.touchlab.kermit.Logger
import com.nuvio.app.core.coroutines.uncaughtCoroutineLogger
import com.nuvio.app.core.i18n.StringKey
import com.nuvio.app.core.i18n.resourceString
import com.nuvio.app.features.addons.buildAddonResourceUrl
import com.nuvio.app.features.addons.fetchAddonResponseText
import com.nuvio.app.features.debrid.DebridServiceCredential
import com.nuvio.app.features.debrid.LocalDebridAvailabilityService
import com.nuvio.app.features.plugins.PluginScraper
import com.nuvio.app.features.plugins.PluginScraperHostProvider
import com.nuvio.app.features.plugins.pluginContentId
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.CoroutineStart
import kotlinx.coroutines.Dispatchers
import kotlinx.atomicfu.locks.SynchronizedObject
import kotlinx.atomicfu.locks.synchronized
import kotlinx.coroutines.Job
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.coroutineScope
import kotlinx.coroutines.flow.Flow
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.emitAll
import kotlinx.coroutines.flow.flow
import kotlinx.coroutines.flow.transformWhile
import kotlinx.coroutines.flow.update
import kotlinx.coroutines.launch

/** One source search: the same title, episode and source setup for the same profile (upstream 8fba6c71e). */
internal data class StreamSearchKey(
    val profileId: Int,
    val type: String,
    val videoId: String,
    val season: Int?,
    val episode: Int?,
    val sourceConfiguration: String,
    /** The debrid part of [sourceConfiguration] on its own (review r1: another account drops every search). */
    val debridConfiguration: String,
) {
    /** Stage B review finding 6: the search runs at least one plugin scraper. */
    val holdsPluginTargets: Boolean
        get() = sourceConfiguration.split('|').any { it.startsWith("plugin:") }
}

/**
 * The debrid account a search cache-checks with, captured when the search is built (review r1):
 * the check runs with THIS account even if the active one changes while an add-on answers, so a
 * result is always kept under the key of the account it was checked with. [configuration] is
 * [LocalDebridAvailabilityService.cacheCheckConfiguration]'s form (no raw key).
 */
internal data class StreamSearchDebrid(val configuration: String, val account: DebridServiceCredential?) {
    companion object {
        val None = StreamSearchDebrid("none", null)

        fun current(): StreamSearchDebrid {
            val account = LocalDebridAvailabilityService.currentCacheCheckAccount()
            return StreamSearchDebrid(LocalDebridAvailabilityService.configurationOf(account), account)
        }
    }
}

/**
 * The add-ons and plugin scrapers one search queries. Fork: no server sources; each add-on carries
 * the id it is asked with (BUG-74), which is part of the key.
 */
internal class StreamSearchTargets(
    val type: String,
    val videoId: String,
    val season: Int?,
    val episode: Int?,
    val streamAddons: List<InstalledStreamAddonTarget>,
    val pluginProviderGroups: List<PluginProviderGroup>,
    /** Upstream 4c414a5f4: the account streams are cache-checked with; the checked streams are kept. */
    val debrid: StreamSearchDebrid = StreamSearchEnvironment.debrid(),
) {
    val debridConfiguration: String
        get() = debrid.configuration

    val totalTasks: Int
        get() = streamAddons.size + pluginProviderGroups.sumOf { it.scrapers.size }

    /**
     * Changes whenever the queried sources, the id each add-on is asked with (BUG-74) or the debrid
     * account change, so a search for an older setup is not reused. Plugin grouping ("Group by
     * Repository") changes the group ids, so it is covered without a flag of its own.
     */
    val sourceConfiguration: String
        get() = buildList {
            streamAddons.forEach { add("addon:${it.addonId}@${it.videoId}") }
            pluginProviderGroups.forEach { group ->
                add("plugin:${group.addonId}:${group.scrapers.joinToString(",") { it.id }}")
            }
            add("debrid:$debridConfiguration")
        }.joinToString("|")

    fun key(profileId: Int): StreamSearchKey = StreamSearchKey(
        profileId = profileId,
        type = type,
        videoId = videoId,
        season = season,
        episode = episode,
        sourceConfiguration = sourceConfiguration,
        debridConfiguration = debridConfiguration,
    )
}

/** The network half of one search. Tests replace it; [LiveStreamSearchFetcher] is the app's. */
internal interface StreamSearchFetcher {
    /** One add-on's streams; a failure is a failed [Result], never a throw. */
    suspend fun fetchAddon(target: InstalledStreamAddonTarget, type: String, forceRefresh: Boolean): Result<List<StreamItem>>

    /** One plugin scraper's streams, or its error, as a completion of its group. */
    suspend fun runScraper(
        group: PluginProviderGroup,
        scraper: PluginScraper,
        targets: StreamSearchTargets,
    ): StreamLoadCompletion.PluginScraper

    /**
     * Upstream `withDebridAvailability`: the group with its torrents cache-checked with [account]
     * (the one the search started under; unchanged when null or nothing to check).
     */
    suspend fun withDebridAvailability(group: AddonStreamGroup, account: DebridServiceCredential?): AddonStreamGroup
}

internal object LiveStreamSearchFetcher : StreamSearchFetcher {
    private val log = Logger.withTag("StreamSearch")

    override suspend fun fetchAddon(
        target: InstalledStreamAddonTarget,
        type: String,
        forceRefresh: Boolean,
    ): Result<List<StreamItem>> {
        val url = buildAddonResourceUrl(
            manifestUrl = target.manifest.transportUrl,
            resource = "stream",
            type = type,
            id = target.videoId,
        )
        log.d { "Fetching streams from: $url" }
        StreamDiagnostics.log("fetch ${target.addonName}: ${StreamDiagnostics.redactUrl(url)}")
        return runCatchingUnlessCancelled {
            val payload = fetchAddonResponseText(url = url, forceRefresh = forceRefresh)
            StreamParser.parse(
                payload = payload,
                addonName = target.addonName,
                addonId = target.addonId,
                addonLogo = target.manifest.logoUrl,
            )
        }.onSuccess { streams ->
            log.d { "Got ${streams.size} streams from ${target.addonName}" }
            StreamDiagnostics.log("got ${streams.size} from ${target.addonName}")
        }.onFailure { err ->
            log.w(err) { "Failed to fetch streams from ${target.addonName}" }
            StreamDiagnostics.log("FAILED ${target.addonName}: ${err.message ?: "unknown error"}")
        }
    }

    override suspend fun runScraper(
        group: PluginProviderGroup,
        scraper: PluginScraper,
        targets: StreamSearchTargets,
    ): StreamLoadCompletion.PluginScraper =
        PluginScraperHostProvider.host.executeScraper(
            scraper = scraper,
            tmdbId = pluginContentId(videoId = targets.videoId, season = targets.season, episode = targets.episode),
            mediaType = targets.type,
            season = targets.season,
            episode = targets.episode,
        ).fold(
            onSuccess = { results ->
                StreamLoadCompletion.PluginScraper(
                    addonId = group.addonId,
                    streams = results.map { result ->
                        result.toStreamItem(
                            scraper = scraper,
                            addonName = group.addonName,
                            addonId = group.addonId,
                            includeScraperNameInSubtitle = false,
                        )
                    },
                    error = null,
                )
            },
            onFailure = { error ->
                log.w(error) { "Plugin scraper failed: ${scraper.name}" }
                StreamLoadCompletion.PluginScraper(
                    addonId = group.addonId,
                    streams = emptyList(),
                    error = error.message ?: scraperFailureText(scraper),
                )
            },
        )

    override suspend fun withDebridAvailability(group: AddonStreamGroup, account: DebridServiceCredential?): AddonStreamGroup {
        if (account == null || group.streams.isEmpty()) return group
        val eligible = setOf(group.addonId)
        if (!LocalDebridAvailabilityService.hasPendingCacheCheck(listOf(group), eligible, account)) return group
        val checking = LocalDebridAvailabilityService.markChecking(listOf(group), eligible, account).firstOrNull() ?: group
        return LocalDebridAvailabilityService.annotateCachedAvailability(listOf(checking), eligible, account).firstOrNull()
            ?: checking
    }
}

private fun scraperFailureText(scraper: PluginScraper): String =
    resourceString("Failed to load ${scraper.name}", StringKey.streams_failed_to_load_scraper, scraper.name)

/**
 * Keeps source searches alive independently of the screens that show them, so the stream picker,
 * the player's source list, Up Next and its preload share one search per title and episode
 * (upstream 8fba6c71e). A search in progress is joined; a finished one is reused for a short time.
 * Memory only: links may expire.
 *
 * Every rule here is driven by [search] and [clear]; the clock, the fetcher and the scope are
 * injected so the races are tested as event sequences (StreamSearchSessionScenarioTest).
 */
internal class StreamSearchSessionStore(
    private val fetcher: StreamSearchFetcher,
    private val now: () -> Long = ::epochMs,
    private val scope: CoroutineScope =
        CoroutineScope(SupervisorJob() + Dispatchers.Default + uncaughtCoroutineLogger("StreamSearchSessions")),
) {
    private val log = Logger.withTag("StreamSearchSessions")
    // Every operation on the map is short and non-suspending, so a plain lock serves: [clear] and
    // [isHeld] are synchronous (review r1: a wipe invalidates at its call, not later).
    private val lock = SynchronizedObject()
    private val sessions = LinkedHashMap<StreamSearchKey, Session>()

    /** Tests: how many searches were started (a join does not count). Written under [lock]. */
    var startedCount = 0
        private set

    private data class Progress(
        val completions: List<StreamLoadCompletion> = emptyList(),
        val isComplete: Boolean = false,
    )

    private class Session {
        val progress = MutableStateFlow(Progress())
        var job: Job? = null

        // The fields below are written by the session's own job or under the store's lock and
        // read under the lock.
        var completedAtMs: Long? = null
        var reuseTtlMs: Long = COMPLETED_TTL_MS
        var invalidated = false

        /** A cache check that threw: its group was kept unchecked, so the search is re-run soon. */
        var cacheCheckFailed = false

        /**
         * Appends [completion] unless the session already ended. A dropped (cancelled) search can
         * still have a fetch finishing on another thread; without this a consumer that has not yet
         * seen the end could read that late result together with the end and emit it.
         */
        fun append(completion: StreamLoadCompletion) {
            progress.update { current ->
                if (current.isComplete) current else current.copy(completions = current.completions + completion)
            }
        }
    }

    /**
     * Every result of the search for [targets]: first the ones that already arrived, then new ones,
     * completing when the search ends or is dropped. A new search starts only when none is held for
     * the key or [forceRefresh] is set (which drops the held one: its consumers complete).
     */
    fun search(profileId: Int, targets: StreamSearchTargets, forceRefresh: Boolean): Flow<StreamLoadCompletion> = flow {
        val session = acquire(targets.key(profileId), targets, forceRefresh)
        var emitted = 0
        emitAll(
            session.progress.transformWhile { progress ->
                while (emitted < progress.completions.size) {
                    emit(progress.completions[emitted])
                    emitted++
                }
                !progress.isComplete
            },
        )
    }

    /**
     * Drops and cancels every held search (account wipe), before it returns: nothing can join one
     * of them afterwards, and a search started afterwards is never touched by it. Their consumers
     * complete; an answer still in flight is not recorded.
     */
    fun clear() {
        synchronized(lock) {
            sessions.values.forEach { it.cancel() }
            sessions.clear()
        }
    }

    /**
     * Stage B review finding 6: drops and cancels every held search that runs a plugin scraper.
     * A scraper refresh or a sync can change a scraper's code under the same id, which the key
     * does not see; add-on-only searches are untouched.
     */
    fun dropPluginSessions() {
        synchronized(lock) {
            sessions.keys.filter { it.holdsPluginTargets }.forEach { key ->
                val session = sessions[key]       // K/N: read the entry before removing it
                sessions.remove(key)
                session?.cancel()
            }
        }
    }

    /**
     * Whether a search for [key] is held and would be served to a new consumer right now (running,
     * or finished and not expired). The repositories skip a repeated load only on this answer
     * (review r1: one identity and expiry rule, this store's).
     */
    fun isHeld(key: StreamSearchKey): Boolean = synchronized(lock) {
        removeExpiredLocked()
        sessions.containsKey(key)
    }

    /** Tests: the keys held, oldest first. */
    fun heldKeys(): List<StreamSearchKey> = synchronized(lock) { sessions.keys.toList() }

    private fun acquire(key: StreamSearchKey, targets: StreamSearchTargets, forceRefresh: Boolean): Session {
        var created: Session? = null
        val selected = synchronized(lock) {
            removeExpiredLocked()
            removeObsoleteLocked(key)
            if (forceRefresh) {
                sessions.remove(key)?.cancel()
            } else {
                val existing = sessions[key]
                if (existing != null) {
                    log.d { "Joining source search for ${key.type} ${key.videoId}" }
                    StreamDiagnostics.log("search join ${key.type} ${key.videoId}")
                    return@synchronized existing
                }
            }
            Session().also { session ->
                session.job = scope.launch(start = CoroutineStart.LAZY) {
                    try {
                        coroutineScope { launchTasks(session, targets, forceRefresh) }
                    } finally {
                        complete(key, session)
                    }
                }
                sessions[key] = session
                startedCount++
                trimLocked()
                created = session
                StreamDiagnostics.log(
                    "search start ${key.type} ${key.videoId} tasks=${targets.totalTasks}" +
                        if (forceRefresh) " (refresh)" else "",
                )
            }
        }
        // Started outside the lock (its completion takes the lock); a non-suspending start, so a
        // caller cancelled right now still starts it for the consumers that may already join it.
        created?.job?.start()
        return selected
    }

    /** Queries every add-on and plugin scraper of [targets] in parallel and records each result. */
    private fun CoroutineScope.launchTasks(session: Session, targets: StreamSearchTargets, forceRefresh: Boolean) {
        targets.streamAddons.forEach { addon ->
            launch {
                // A fetcher that throws instead of returning a failure still yields a failed group.
                val result = runCatchingUnlessCancelled { fetcher.fetchAddon(addon, targets.type, forceRefresh) }
                    .getOrElse { Result.failure(it) }
                val group = addonStreamGroupFromFetch(
                    addonName = addon.addonName,
                    addonId = addon.addonId,
                    result = result,
                )
                // Upstream 4c414a5f4: checked once here, before the result is kept for every screen.
                // A failed check never fails the search: the group is kept unchecked.
                // Review r1: with the account the search started under, never the one active now.
                val checked = runCatchingUnlessCancelled { fetcher.withDebridAvailability(group, targets.debrid.account) }
                    .getOrElse { error ->
                        log.w(error) { "Debrid cache check failed for ${addon.addonName}" }
                        session.cacheCheckFailed = true
                        group
                    }
                session.append(StreamLoadCompletion.Addon(checked))
            }
        }
        targets.pluginProviderGroups.forEach { group ->
            group.scrapers.forEach { scraper ->
                launch {
                    val completion = runCatchingUnlessCancelled { fetcher.runScraper(group, scraper, targets) }
                        .getOrElse { error ->
                            StreamLoadCompletion.PluginScraper(
                                addonId = group.addonId,
                                streams = emptyList(),
                                error = error.message?.takeIf { it.isNotBlank() } ?: scraperFailureText(scraper),
                            )
                        }
                    session.append(completion)
                }
            }
        }
    }

    private fun complete(key: StreamSearchKey, session: Session) {
        session.progress.update { it.copy(isComplete = true) }
        synchronized(lock) {
            // A dropped session (forced refresh, eviction, profile or setup change, clear) is no
            // longer in the map under its key, or never was the one held there.
            if (session.invalidated || sessions[key] !== session) return@synchronized
            val completions = session.progress.value.completions
            val hasResults = completions.any { completion ->
                when (completion) {
                    is StreamLoadCompletion.Addon -> completion.group.streams.isNotEmpty()
                    is StreamLoadCompletion.PluginScraper -> completion.streams.isNotEmpty()
                }
            }
            if (!hasResults) {
                // Offline, or every source failed: the next ask fetches again.
                sessions.remove(key)
                return@synchronized
            }
            session.completedAtMs = now()
            // Fork (decision AF): an UNKNOWN cache answer (or a check that threw) is not final, so
            // the next screen within about a minute gets a fresh check instead of a 15 minute copy.
            val shortLived = session.cacheCheckFailed || completions.any { it.hasUnknownDebridState() }
            session.reuseTtlMs = if (shortLived) UNKNOWN_REUSE_TTL_MS else COMPLETED_TTL_MS
        }
    }

    private fun removeExpiredLocked() {
        val nowMs = now()
        val iterator = sessions.entries.iterator()
        while (iterator.hasNext()) {
            val session = iterator.next().value
            val completedAt = session.completedAtMs ?: continue
            if (nowMs - completedAt >= session.reuseTtlMs) {
                iterator.remove()
                session.cancel()
            }
        }
    }

    /**
     * Another profile's searches, every search checked with another debrid account (review r1: a
     * result for an account that is no longer current is discarded, not kept for a switch back),
     * and the same episode's searches with another setup, are dropped.
     */
    private fun removeObsoleteLocked(requested: StreamSearchKey) {
        val iterator = sessions.entries.iterator()
        while (iterator.hasNext()) {
            // Key and session are read before `remove()`: Kotlin/Native's LinkedHashMap entry
            // refuses any access once the map has changed (ConcurrentModificationException).
            val entry = iterator.next()
            val existing = entry.key
            val session = entry.value
            val otherProfile = existing.profileId != requested.profileId
            val otherAccount = existing.debridConfiguration != requested.debridConfiguration
            val sameEpisode = existing.type == requested.type &&
                existing.videoId == requested.videoId &&
                existing.season == requested.season &&
                existing.episode == requested.episode
            if (otherProfile || otherAccount || (sameEpisode && existing.sourceConfiguration != requested.sourceConfiguration)) {
                iterator.remove()
                session.cancel()
            }
        }
    }

    private fun trimLocked() {
        while (sessions.size > MAX_SESSIONS) {
            val oldest = sessions.entries.iterator()
            if (!oldest.hasNext()) return
            val session = oldest.next().value
            oldest.remove()
            session.cancel()
        }
    }

    private fun Session.cancel() {
        invalidated = true
        progress.update { it.copy(isComplete = true) }
        job?.cancel()
    }

    companion object {
        const val COMPLETED_TTL_MS = 15 * 60 * 1_000L
        const val UNKNOWN_REUSE_TTL_MS = 60 * 1_000L
        const val MAX_SESSIONS = 12
    }
}

/** The app's store. Public for the account wipes (composeApp is another module). */
object StreamSearchSessions {
    internal var store: StreamSearchSessionStore = StreamSearchSessionStore(LiveStreamSearchFetcher)
        private set

    internal fun search(profileId: Int, targets: StreamSearchTargets, forceRefresh: Boolean): Flow<StreamLoadCompletion> =
        store.search(profileId, targets, forceRefresh)

    /**
     * Account wipe: drops and cancels every held search before it returns (review r1: it used to
     * run later, so a search of the new account could join an outgoing one, or be cancelled by the
     * late wipe).
     */
    fun clear() {
        store.clear()
    }

    /** Stage B review finding 6: after plugin scrapers changed (a refresh, a sync); see the store. */
    fun dropPluginSessions() {
        store.dropPluginSessions()
    }

    /** Whether the search for [key] is still held and would be served (see [StreamSearchSessionStore.isHeld]). */
    internal fun isHeld(key: StreamSearchKey): Boolean = store.isHeld(key)

    /** Tests: replaces the app's store (the repositories read [store] on every load). */
    internal fun installForTesting(replacement: StreamSearchSessionStore) {
        store = replacement
    }

    /** Tests: back to a fresh live store. */
    internal fun resetForTesting() {
        store = StreamSearchSessionStore(LiveStreamSearchFetcher)
    }
}

private fun StreamLoadCompletion.hasUnknownDebridState(): Boolean =
    this is StreamLoadCompletion.Addon &&
        group.streams.any { it.debridCacheStatus?.state == StreamDebridCacheState.UNKNOWN }

/** Ends the loading state of sources a dropped search never reported (upstream). */
internal fun StreamsUiState.withoutPendingGroups(): StreamsUiState {
    if (groups.none { it.isLoading } && !isAnyLoading) return this
    val settled = groups.map { group -> if (group.isLoading) group.copy(isLoading = false) else group }
    return copy(
        groups = settled,
        isAnyLoading = false,
        emptyStateReason = settled.toEmptyStateReason(anyLoading = false),
    )
}
