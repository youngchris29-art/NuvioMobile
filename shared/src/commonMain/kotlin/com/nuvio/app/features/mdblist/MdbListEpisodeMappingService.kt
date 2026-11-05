package com.nuvio.app.features.mdblist

import co.touchlab.kermit.Logger
import com.nuvio.app.features.tmdb.TmdbSeasonListService
import com.nuvio.app.features.tmdb.TmdbSeasonListSource
import com.nuvio.app.features.tracking.AddonEpisodeListService
import com.nuvio.app.features.tracking.AddonEpisodeListSource
import com.nuvio.app.features.tracking.TrackingMediaKind
import com.nuvio.app.features.tracking.TrackingMediaReference
import com.nuvio.app.features.tracking.parseTrackingExternalIds
import com.nuvio.app.features.trakt.EpisodeMappingEntry
import com.nuvio.app.features.trakt.TraktEpisodeMappingService
import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.CompletableDeferred
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.NonCancellable
import kotlinx.coroutines.async
import kotlinx.coroutines.awaitAll
import kotlinx.coroutines.coroutineScope
import kotlinx.coroutines.currentCoroutineContext
import kotlinx.coroutines.ensureActive
import kotlinx.coroutines.flow.Flow
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.map
import kotlinx.coroutines.flow.update
import kotlinx.coroutines.launch
import kotlinx.coroutines.sync.Mutex
import kotlinx.coroutines.sync.Semaphore
import kotlinx.coroutines.sync.withLock
import kotlinx.coroutines.sync.withPermit
import kotlinx.coroutines.withContext
import kotlin.math.abs
import kotlin.time.Duration
import kotlin.time.Duration.Companion.hours
import kotlin.time.Duration.Companion.minutes
import kotlin.time.TimeMark
import kotlin.time.TimeSource

/**
 * Remaps episodes between the add-on's numbering and MDBList's, which follows TMDB (upstream
 * NuvioTV facf25ec3, PR #4439).
 *
 * Anime is often split into seasons differently on TMDB and in the metadata an add-on serves, so
 * TMDB S1E35 can be S2E11 for the add-on. When the two sides have different seasons, episodes are
 * matched by title and otherwise by their position in the whole episode list, the same way Trakt
 * numbering is remapped ([TraktEpisodeMappingService]'s remap functions do the matching).
 *
 * Fork shape: the tvOS progress provider hands out a plain snapshot, not a flow, so a mapping that
 * is not cached yet is resolved in the background on [scope] and [changes] ticks once it is, which
 * makes the repositories read the snapshot again. Explicit readers and every write resolve inline.
 *
 * A resolved mapping is filed under every alias of the show MDBList knows (Codex r1 #8) and tagged
 * with the add-on source's generation, so a list from a previous add-on set or metadata language
 * is never reused (Codex r1 #3); [clearCache] also runs on profile changes.
 */
internal class MdbListEpisodeMappingService(
    private val addonEpisodes: AddonEpisodeListSource = AddonEpisodeListService,
    private val tmdb: TmdbSeasonListSource = TmdbSeasonListService,
    private val scope: CoroutineScope? = null,
    private val timeSource: TimeSource = TimeSource.Monotonic,
    private val mappingTtl: Duration = 6.hours,
) {
    private val log = Logger.withTag("MdbListEpMap")

    private class Resolved(val mapping: MdbListEpisodeMapping, val generation: Any, val epoch: Long, val resolvedAt: TimeMark)
    /** A load's result with the sources it was made under; a receiver uses it only while those are current. */
    private class Outcome(val mapping: MdbListEpisodeMapping?, val generation: Any, val epoch: Long)

    private val resolved = MutableStateFlow<Map<String, Resolved>>(emptyMap())
    private val inFlightMutex = Mutex()
    // In-flight loads, keyed by show, add-on generation and epoch: a caller joins only a load
    // started under its own view of the sources (Codex r2 #4, #5).
    private val inFlight = mutableMapOf<String, CompletableDeferred<Outcome>>()
    // Guarded by inFlightMutex. Background resolution from snapshot readers is throttled after a
    // failure (no add-on list, TMDB unreachable); explicit resolves are not.
    private val backgroundFailedAt = mutableMapOf<String, TimeMark>()
    /** Bumped by [clearCache]: loads and cache entries from an earlier epoch are not this profile's. */
    private val epoch = MutableStateFlow(0L)
    // Shows whose last reload failed, answered from the cache until RELOAD_RETRY_INTERVAL has
    // passed. An immutable map swapped atomically: read without a lock from any thread.
    private val reloadFailedAt = MutableStateFlow<Map<String, TimeMark>>(emptyMap())

    private fun reloadFailedRecently(key: String): Boolean =
        reloadFailedAt.value[key]?.let { it.elapsedNow() < RELOAD_RETRY_INTERVAL } == true

    /**
     * Whether a non-forced resolve answers from the cache: while the entry is fresh and no reload
     * failed, or during the backoff after one failed. A failed reload whose backoff has passed
     * loads again however fresh the entry is (Codex r10 #1).
     */
    private fun Resolved.servesNow(key: String): Boolean =
        reloadFailedAt.value[key]?.let { it.elapsedNow() < RELOAD_RETRY_INTERVAL } ?: isFresh()

    /** Emits whenever a show's mapping resolves or the cache is cleared. */
    val changes: Flow<Unit> = resolved.map { }

    /**
     * The mapping for [contentId] when it was already resolved, without touching the network. A
     * mapping older than [mappingTtl] is still answered (the show's structure rarely changes) but
     * [resolve] and [resolveInBackground] reload it, so a show that grew a season is seen.
     */
    fun cached(contentId: String): MdbListEpisodeMapping? = entry(contentId.trim())?.mapping

    private fun entry(key: String): Resolved? {
        val entry = resolved.value[key] ?: return null
        return entry.takeIf { it.generation == addonEpisodes.generation() && it.epoch == epoch.value }
    }

    private fun Resolved.isFresh(): Boolean = resolvedAt.elapsedNow() < mappingTtl

    /**
     * Resolves the mapping for the show the add-on serves as [contentId]. [tmdbShowId] skips the
     * TMDB id lookup when MDBList already reported it; [aliases] are the other ids MDBList files
     * the show under, which the result is cached under too. Returns null when either side's
     * episodes could not be loaded, so the caller keeps the numbering it has.
     */
    suspend fun resolve(
        contentId: String,
        tmdbShowId: Long? = null,
        aliases: Set<String> = emptySet(),
    ): MdbListEpisodeMapping? = resolve(contentId, tmdbShowId, aliases, reload = false)

    /**
     * [reload]: load again even when a fresh mapping is cached, past the add-on list cache too
     * (an episode the lists did not have when they were fetched, Codex r7 #2). A load that fails
     * leaves a still-valid cached mapping in place and answers with it (Codex r7 #1): the last
     * known structure beats the add-on's raw numbers for a show known to remap.
     */
    internal suspend fun resolve(
        contentId: String,
        tmdbShowId: Long?,
        aliases: Set<String>,
        reload: Boolean,
    ): MdbListEpisodeMapping? {
        val key = contentId.trim().takeIf(String::isNotBlank) ?: return null
        var forced = reload
        repeat(MAX_ATTEMPTS) {
            currentCoroutineContext().ensureActive()
            if (!forced) entry(key)?.takeIf { it.servesNow(key) }?.let { return it.mapping }
            val generation = addonEpisodes.generation()
            val currentEpoch = epoch.value
            // A forced load (past the add-on list cache) never joins a plain one, whose lists may
            // be the ones that lack the episode; and a joiner stays forced if the load it joined is
            // cancelled (Codex r10 #2).
            val refreshLists = forced
            val flightKey = "$key|$generation|$currentEpoch|$refreshLists"
            val deferred = CompletableDeferred<Outcome>()
            val existing = inFlightMutex.withLock {
                if (!forced) entry(key)?.takeIf { it.servesNow(key) }?.let { return it.mapping }
                inFlight[flightKey] ?: run {
                    inFlight[flightKey] = deferred
                    null
                }
            }
            if (existing != null) {
                // Another caller is loading this show. Its cancellation is not an answer: a writer
                // that read it as "no mapping" would send the add-on's numbers (Codex r1 #4).
                val outcome = try {
                    existing.await()
                } catch (_: CancellationException) {
                    currentCoroutineContext().ensureActive()
                    return@repeat
                }
                if (outcome.isCurrent()) return outcome.mapping
                return@repeat
            }
            val outcome = try {
                val loaded = runCatching { load(key, tmdbShowId, refreshLists) }
                    .onFailure { if (it is CancellationException) throw it }
                    .onFailure { log.w { "episode mapping failed for $key: ${it.message}" } }
                    .getOrNull()
                // Published under the mutex: a source or profile change lands either before this
                // check (the mapping is not kept) or after it (every receiver checks again before
                // using the outcome, Codex r2 #4, r3 #5). A newer entry is never overwritten. A
                // load that failed leaves the cached entry as it is, old timestamp included, so it
                // is tried again after [RELOAD_RETRY_INTERVAL] rather than in six hours (Codex r8 #3).
                val mapping = inFlightMutex.withLock {
                    if (loaded == null) {
                        reloadFailedAt.update { it + (key to timeSource.markNow()) }
                        // An episode's earlier reload no longer stands for the show: once the
                        // backoff passes every episode of it may reload again (Codex r10 #1).
                        episodeRefreshedAt.keys.removeAll { it.startsWith("$key|") }
                        entry(key)?.mapping
                    } else {
                        reloadFailedAt.update { it - key }
                        if (generation == addonEpisodes.generation() && currentEpoch == epoch.value) {
                            val entry = Resolved(loaded, generation, currentEpoch, timeSource.markNow())
                            resolved.update { current ->
                                current + (aliases + key).filter { alias -> current[alias]?.let { it.epoch > currentEpoch } != true }
                                    .associateWith { entry }
                            }
                        }
                        loaded
                    }
                }
                Outcome(mapping, generation, currentEpoch).also(deferred::complete)
            } catch (error: CancellationException) {
                deferred.cancel(error)
                throw error
            } finally {
                withContext(NonCancellable) {
                    inFlightMutex.withLock { if (inFlight[flightKey] === deferred) inFlight.remove(flightKey) }
                }
            }
            if (outcome.isCurrent()) return outcome.mapping
            forced = false // the lists were reloaded; a retry after a source change may use the cache
        }
        return null
    }

    private fun Outcome.isCurrent(): Boolean = generation == addonEpisodes.generation() && epoch == this@MdbListEpisodeMappingService.epoch.value

    /**
     * Resolves [contentId]'s mapping on [scope] unless it is cached and fresh, in flight, or failed
     * in the last [BACKGROUND_RETRY_INTERVAL]. For readers that cannot suspend: [changes] ticks when done.
     */
    fun resolveInBackground(contentId: String, tmdbShowId: Long? = null, aliases: Set<String> = emptySet()) {
        val scope = scope ?: return
        val key = contentId.trim().takeIf(String::isNotBlank) ?: return
        entry(key)?.let { if (it.servesNow(key)) return }
        scope.launch {
            val skip = inFlightMutex.withLock {
                inFlight.keys.any { it.startsWith("$key|") } ||
                    backgroundFailedAt[key]?.let { it.elapsedNow() < BACKGROUND_RETRY_INTERVAL } == true
            }
            if (skip) return@launch
            if (resolve(key, tmdbShowId, aliases) == null) {
                inFlightMutex.withLock { backgroundFailedAt[key] = timeSource.markNow() }
            }
        }
    }

    /**
     * [reference] with its episode moved from the add-on's numbering to TMDB's, which MDBList reads
     * season and episode numbers in. References that need no remapping, and those whose show could
     * not be resolved, come back unchanged. Null when the show's mapping is known and says the
     * add-on's episode has no TMDB counterpart (a recap the add-on lists and TMDB does not): there
     * is nothing on MDBList to write it to, and its number there is another episode (Codex r5 #2).
     */
    suspend fun toMdbListNumbering(
        reference: TrackingMediaReference,
        mediaIndex: MdbListMediaIndex?,
    ): TrackingMediaReference? {
        if (reference.kind == TrackingMediaKind.MOVIE) return reference
        val episode = reference.episode ?: return reference
        val season = episode.season ?: return reference
        val catalog = reference.catalog ?: return reference
        if (catalog.contentType.trim().lowercase() in MOVIE_CONTENT_TYPES) return reference
        val ids = reference.ids.toMdbListIds()
        val known = ids?.let { mediaIndex?.resolve(MdbListItemType.SHOW, it)?.ids ?: it }
        val tmdbShowId = reference.ids.tmdb ?: known?.tmdb
        val aliases = known?.aliases().orEmpty()
        var mapping = resolve(catalog.contentId, tmdbShowId, aliases) ?: return reference
        // The lists may predate this episode (the add-on got it first, or TMDB has just added it,
        // or both lists ended before it while nothing moved): load both again before trusting or
        // dismissing its numbers, once an hour per episode (Codex r7 #2, r8 #1).
        val outsideTheLists = if (mapping.remaps) mapping.toTmdb(season, episode.number, catalog.videoId) == null
        else !mapping.covers(season, episode.number)
        if (outsideTheLists) {
            mapping = refreshForEpisode(catalog.contentId, tmdbShowId, aliases, season, episode.number, mapping) ?: return reference
        }
        if (!mapping.remaps) return reference
        val tmdb = mapping.toTmdb(season, episode.number, catalog.videoId) ?: return null
        if (tmdb.season == season && tmdb.episode == episode.number) return reference
        return reference.copy(episode = episode.copy(season = tmdb.season, number = tmdb.episode))
    }

    // Guarded by inFlightMutex: the reload a write for an episode outside the lists is running
    // (every other write for it awaits that one, Codex r9 #1), and when each last succeeded.
    private val episodeRefreshes = mutableMapOf<String, CompletableDeferred<MdbListEpisodeMapping?>>()
    private val episodeRefreshedAt = mutableMapOf<String, TimeMark>()

    /**
     * The show's mapping after reloading both lists for [season]/[episode], which the current
     * lists do not have. One reload per episode at a time, shared by every writer that needs it;
     * the hour between reloads starts when one succeeds, and while the show's last reload failed
     * [current] is answered until [RELOAD_RETRY_INTERVAL] has passed, so TMDB coming back is seen
     * ten minutes later, not an hour (Codex r9 #2).
     */
    private suspend fun refreshForEpisode(
        contentId: String,
        tmdbShowId: Long?,
        aliases: Set<String>,
        season: Int,
        episode: Int,
        current: MdbListEpisodeMapping,
    ): MdbListEpisodeMapping? {
        val showKey = contentId.trim()
        val key = "$showKey|$season|$episode"
        repeat(MAX_ATTEMPTS) {
            currentCoroutineContext().ensureActive()
            val deferred = CompletableDeferred<MdbListEpisodeMapping?>()
            val existing = inFlightMutex.withLock {
                episodeRefreshes[key] ?: run {
                    if (reloadFailedRecently(showKey)) return current
                    episodeRefreshedAt[key]?.let { if (it.elapsedNow() < UNMATCHED_REFRESH_INTERVAL) return current }
                    episodeRefreshes[key] = deferred
                    null
                }
            }
            if (existing != null) {
                return try {
                    existing.await()
                } catch (_: CancellationException) {
                    currentCoroutineContext().ensureActive()
                    return@repeat
                }
            }
            return try {
                val mapping = resolve(contentId, tmdbShowId, aliases, reload = true)
                inFlightMutex.withLock {
                    if (!reloadFailedRecently(showKey)) episodeRefreshedAt[key] = timeSource.markNow()
                }
                mapping.also(deferred::complete)
            } catch (error: CancellationException) {
                deferred.cancel(error)
                throw error
            } finally {
                withContext(NonCancellable) {
                    inFlightMutex.withLock { if (episodeRefreshes[key] === deferred) episodeRefreshes.remove(key) }
                }
            }
        }
        return current
    }

    /** Forgets every mapping; loads still running belong to the previous epoch and are dropped. */
    fun clearCache() {
        epoch.update { it + 1 }
        resolved.value = emptyMap()
    }

    private suspend fun load(contentId: String, tmdbShowId: Long?, refreshLists: Boolean = false): MdbListEpisodeMapping? {
        val addon = addonEpisodes.episodes(contentId, "series", refresh = refreshLists)
        if (addon.isEmpty()) return null
        val tmdbId = tmdbShowId?.takeIf { it in 1..Int.MAX_VALUE }?.toInt() ?: lookupTmdbShowId(contentId) ?: return null
        val seasons = tmdb.seasonEpisodeCounts(tmdbId) ?: return null
        if (seasons.isEmpty()) return null
        val addonCounts = addon.seasonCounts()
        // Identical seasons and counts: nothing to load. Any other difference, the last season's
        // or a single-season show's included, is decided by the episodes themselves (Codex r1 #2,
        // r2 #2, r4 #1): a dropped recap or a merged two-parter leaves every episode in its season
        // and is matched within the season; an episode found in the other side's neighbouring
        // season is a moved boundary and the whole show is matched by position.
        val sameSeasons = seasons.keys == addonCounts.keys
        // The cheap path needs the add-on's numbers to be the 1..n TMDB uses, not just n of them
        // (Codex r6 #1): an add-on numbering season 2 as E13..E24 has twelve too.
        if (sameSeasons && addonCounts == seasons && addon.isNumberedContiguously()) return MdbListEpisodeMapping.unchanged(addon)

        val tmdbEpisodes = coroutineScope {
            val semaphore = Semaphore(TMDB_SEASON_REQUEST_CONCURRENCY)
            seasons.entries.sortedBy { it.key }.map { (season, count) ->
                async {
                    semaphore.withPermit {
                        val episodes = tmdb.seasonEpisodes(tmdbId, season)
                        // A season that failed or came back short would shift every later episode's
                        // position; the mapping is not built from it (Codex r1 #1). Not cached, so
                        // the next caller tries again.
                        if (episodes == null || episodes.isEmpty() || episodes.size < count) {
                            log.w { "TMDB season $season of $tmdbId unavailable or short (${episodes?.size}/$count); not mapping $contentId" }
                            return@withPermit null
                        }
                        episodes.map { EpisodeMappingEntry(season = season, episode = it.number, title = it.title, airDate = it.airDate) }
                    }
                }
            }.awaitAll()
        }
        if (tmdbEpisodes.any { it == null }) return null
        val tmdbList = tmdbEpisodes.filterNotNull().flatten()
        if (tmdbList.isEmpty()) return null
        if (addon.coordinates() == tmdbList.coordinates()) return MdbListEpisodeMapping.unchanged(addon)
        val withinSeasons = sameSeasons && when (seasonsHoldTheSameEpisodes(addon, tmdbList)) {
            true -> true
            false -> false
            // Nothing to go by: a small difference is taken for a merged or dropped episode, a
            // larger one for a moved boundary.
            null -> seasonsAlignUpToTheLast(addonCounts, seasons)
        }
        if (withinSeasons) {
            val mapping = MdbListEpisodeMapping.buildWithinSeasons(addon, tmdbList)
            if (mapping.isIdentity) return MdbListEpisodeMapping.unchanged(addon)
            log.d { "remapping $contentId within seasons: addon=$addonCounts tmdb=$seasons" }
            return mapping
        }
        log.d { "remapping $contentId: addon=$addonCounts tmdb=$seasons" }
        return MdbListEpisodeMapping.build(addon, tmdbList)
    }

    private suspend fun lookupTmdbShowId(contentId: String): Int? {
        val ids = parseTrackingExternalIds(contentId)
        ids.tmdb?.takeIf { it in 1..Int.MAX_VALUE }?.let { return it.toInt() }
        if (ids.imdb.isNullOrBlank() && ids.tvdb.isNullOrBlank()) return null
        return tmdb.findTmdbShowId(imdbId = ids.imdb, tvdbId = ids.tvdb)
    }

    private fun List<EpisodeMappingEntry>.seasonCounts(): Map<Int, Int> =
        groupBy { it.season }.mapValues { it.value.size }

    private fun List<EpisodeMappingEntry>.coordinates(): Set<Pair<Int, Int>> = mapTo(HashSet()) { it.season to it.episode }

    /** True when every season's episodes are numbered 1..n, as TMDB numbers its own. */
    private fun List<EpisodeMappingEntry>.isNumberedContiguously(): Boolean =
        groupBy { it.season }.values.all { episodes -> episodes.map { it.episode }.sorted() == (1..episodes.size).toList() }

    internal companion object {
        const val TMDB_SEASON_REQUEST_CONCURRENCY = 4
        /** Episodes a season may differ by on the two sides and still be the same season, pending the identity check. */
        const val MERGED_EPISODE_TOLERANCE = 2
        /** Loads that straddle a source change or profile switch are retried this often before giving up. */
        const val MAX_ATTEMPTS = 3
        val BACKGROUND_RETRY_INTERVAL = 10.minutes
        /** How long a show whose reload failed is answered from its cached mapping before trying again. */
        val RELOAD_RETRY_INTERVAL = 10.minutes
        /** How often a write for an episode the lists do not have may reload them. */
        val UNMATCHED_REFRESH_INTERVAL = 1.hours
        val MOVIE_CONTENT_TYPES = setOf("movie", "film")
        val NON_ALPHANUMERIC = Regex("[^a-z0-9]+")
        val GENERIC_TITLE = Regex("(episode|ep|e) ?\\d+")

        /** True when every season but the last has the same count on both sides, give or take [MERGED_EPISODE_TOLERANCE]. */
        fun seasonsAlignUpToTheLast(addon: Map<Int, Int>, tmdb: Map<Int, Int>): Boolean =
            addon.keys.sorted().dropLast(1).all { season ->
                abs((addon[season] ?: 0) - (tmdb[season] ?: 0)) <= MERGED_EPISODE_TOLERANCE
            }

        /**
         * Whether the add-on's and TMDB's episodes sit in the same seasons, judged by title and then
         * air date. Any add-on episode placed in a different TMDB season is a moved boundary (false).
         * True needs evidence for every season boundary next to a season whose count differs: the
         * add-on's last episode before the boundary placed in its own TMDB season and its first
         * episode after it placed in its own (Codex r5 #1); a single-season show needs one placed
         * episode. Only titles and dates unique to one TMDB season count, so a recurring title
         * ("Recap") cannot flag a move. Null when the evidence is not there: nothing to go by.
         */
        fun seasonsHoldTheSameEpisodes(addon: List<EpisodeMappingEntry>, tmdb: List<EpisodeMappingEntry>): Boolean? {
            val tmdbSeasonByTitle = uniqueSeasonBy(tmdb) { it.title?.let(::usefulTitle) }
            val tmdbSeasonByDate = uniqueSeasonBy(tmdb) { it.airDate }
            fun placedSeason(episode: EpisodeMappingEntry): Int? =
                episode.title?.let(::usefulTitle)?.let(tmdbSeasonByTitle::get) ?: episode.airDate?.let(tmdbSeasonByDate::get)

            val placed = HashSet<EpisodeMappingEntry>()
            for (episode in addon) {
                val season = placedSeason(episode) ?: continue
                if (season != episode.season) return false
                placed += episode
            }
            if (placed.isEmpty()) return null

            val addonBySeason = addon.groupBy { it.season }.mapValues { (_, episodes) -> episodes.sortedBy { it.episode } }
            val addonCounts = addonBySeason.mapValues { it.value.size }
            val tmdbCounts = tmdb.groupBy { it.season }.mapValues { it.value.size }
            val seasons = addonBySeason.keys.sorted()
            if (seasons.size == 1) return true
            for (index in 0 until seasons.lastIndex) {
                val before = seasons[index]
                val after = seasons[index + 1]
                val boundaryMoves = addonCounts[before] != tmdbCounts[before] || addonCounts[after] != tmdbCounts[after]
                if (!boundaryMoves) continue
                val lastBefore = addonBySeason.getValue(before).last()
                val firstAfter = addonBySeason.getValue(after).first()
                if (lastBefore !in placed || firstAfter !in placed) return null
            }
            return true
        }

        private fun uniqueSeasonBy(episodes: List<EpisodeMappingEntry>, key: (EpisodeMappingEntry) -> String?): Map<String, Int> {
            val seasons = HashMap<String, MutableSet<Int>>()
            for (episode in episodes) {
                val k = key(episode) ?: continue
                seasons.getOrPut(k) { HashSet() }.add(episode.season)
            }
            return seasons.filterValues { it.size == 1 }.mapValues { it.value.single() }
        }

        fun usefulTitle(title: String): String? {
            val normalized = title.lowercase().replace(NON_ALPHANUMERIC, " ").trim()
            if (normalized.isBlank() || GENERIC_TITLE.matches(normalized)) return null
            return normalized
        }
    }
}

/**
 * Episode numbering of one show, translated between the add-on and MDBList (TMDB). Both directions
 * are computed once from the two lists (the Trakt remap functions suspend on a title cache, and the
 * tvOS snapshot readers cannot), keyed by the lists' own titles and the add-on's video ids.
 */
internal class MdbListEpisodeMapping private constructor(
    private val addonByTmdb: Map<Pair<Int, Int>, EpisodeMappingEntry>,
    private val tmdbByAddon: Map<Pair<Int, Int>, EpisodeMappingEntry>,
    private val tmdbByAddonVideoId: Map<String, EpisodeMappingEntry>,
    /** Episodes on either side with no counterpart on the other (a recap one side skips). */
    internal val unmatched: Int,
    /** The add-on's coordinates the lists held when an unchanged mapping was made; null: all of them. */
    private val covered: Set<Pair<Int, Int>>?,
) {
    /**
     * Whether the add-on's [season]/[episode] was in the lists this mapping was built from. An
     * unchanged mapping answers false for an episode past them (the add-on's new S2E1 while both
     * lists ended at S1E24), so a write reloads the lists before trusting the numbers (Codex r8 #1).
     */
    fun covers(season: Int, episode: Int): Boolean =
        season == SPECIALS_SEASON || covered == null || (season to episode) in covered || (season to episode) in tmdbByAddon
    /** False when both sides split the show the same way and episodes keep their numbers. */
    val remaps: Boolean
        get() = addonByTmdb.isNotEmpty() || tmdbByAddon.isNotEmpty()

    /**
     * True when every episode maps to its own number on both sides and no episode is left out,
     * so nothing moves and nothing is hidden (Codex r5 #3: a TMDB-only recap keeps the mapping,
     * else it would be shown as an add-on episode).
     */
    val isIdentity: Boolean
        get() = unmatched == 0 &&
            addonByTmdb.all { (tmdb, addon) -> tmdb == addon.season to addon.episode } &&
            tmdbByAddon.all { (addon, tmdb) -> addon == tmdb.season to tmdb.episode }

    /** The add-on seasons TMDB season [tmdbSeason] maps into (several when TMDB's is longer). */
    fun addonSeasonsOf(tmdbSeason: Int): Set<Int> =
        if (tmdbSeason == SPECIALS_SEASON) setOf(tmdbSeason)
        else addonByTmdb.entries.filter { it.key.first == tmdbSeason }.mapTo(HashSet()) { it.value.season }

    /** [tmdbSeasons] as the add-on seasons they cover; what [addonSeasonsOf] gives for each. */
    fun addonSeasonsOf(tmdbSeasons: Set<Int>): Set<Int> = tmdbSeasons.flatMapTo(HashSet(), ::addonSeasonsOf)

    /**
     * The add-on's episode for TMDB [season]/[episode]. Null when nothing needs remapping
     * ([remaps] false) or, for a show that does remap, when TMDB's episode has no counterpart in
     * the add-on's list (a recap the add-on skips): such a row must not be shown as another episode.
     */
    fun toAddon(season: Int, episode: Int): EpisodeMappingEntry? =
        if (season == SPECIALS_SEASON) EpisodeMappingEntry(season, episode) else addonByTmdb[season to episode]

    /** TMDB's episode for the add-on's [season]/[episode]; null as for [toAddon]. */
    fun toTmdb(season: Int, episode: Int, videoId: String? = null): EpisodeMappingEntry? {
        if (season == SPECIALS_SEASON) return EpisodeMappingEntry(season, episode)
        return videoId?.takeIf(String::isNotBlank)?.let(tmdbByAddonVideoId::get) ?: tmdbByAddon[season to episode]
    }

    companion object {
        /** Nothing moves and every coordinate counts as known; [unchanged] records what the lists held. */
        val Unchanged = MdbListEpisodeMapping(emptyMap(), emptyMap(), emptyMap(), unmatched = 0, covered = null)

        /** An unchanged mapping that remembers the add-on's coordinates, so a later episode is noticed. */
        fun unchanged(addonEpisodes: List<EpisodeMappingEntry>): MdbListEpisodeMapping =
            MdbListEpisodeMapping(emptyMap(), emptyMap(), emptyMap(), unmatched = 0, covered = addonEpisodes.mapTo(HashSet()) { it.season to it.episode })

        /**
         * Season 0: neither list carries specials (both drop season ≤ 0), so they are never
         * remapped and keep their coordinates at every port (Codex r6 #2).
         */
        const val SPECIALS_SEASON = 0

        /**
         * Matches episodes season by season: within season N the add-on's and TMDB's lists are
         * remapped by title then position, as [build] does for the whole show, and nothing crosses
         * a season. For shows whose seasons hold the same episodes with one merged or dropped.
         */
        suspend fun buildWithinSeasons(
            addonEpisodes: List<EpisodeMappingEntry>,
            tmdbEpisodes: List<EpisodeMappingEntry>,
        ): MdbListEpisodeMapping {
            val addonBySeason = addonEpisodes.groupBy { it.season }
            val tmdbBySeason = tmdbEpisodes.groupBy { it.season }
            val addonByTmdb = HashMap<Pair<Int, Int>, EpisodeMappingEntry>(tmdbEpisodes.size)
            val tmdbByAddon = HashMap<Pair<Int, Int>, EpisodeMappingEntry>(addonEpisodes.size)
            val tmdbByAddonVideoId = HashMap<String, EpisodeMappingEntry>(addonEpisodes.size)
            for (season in (addonBySeason.keys + tmdbBySeason.keys).sorted()) {
                val addon = addonBySeason[season].orEmpty()
                val tmdb = tmdbBySeason[season].orEmpty()
                if (addon.isEmpty() || tmdb.isEmpty()) continue
                val part = build(addon, tmdb)
                addonByTmdb += part.addonByTmdb
                tmdbByAddon += part.tmdbByAddon
                tmdbByAddonVideoId += part.tmdbByAddonVideoId
                // An airing season the add-on lists further than TMDB: when everything matched in
                // the season kept its number, the add-on's tail keeps its numbers too, so the newest
                // episode is still written rather than held back as unmatched.
                if (part.isIdentity || part.unmatched == part.unmatchedTail(addon, tmdb)) {
                    val lastTmdb = tmdb.maxOf { it.episode }
                    for (entry in addon) {
                        val key = entry.season to entry.episode
                        if (entry.episode <= lastTmdb || key in tmdbByAddon) continue
                        val same = EpisodeMappingEntry(entry.season, entry.episode, entry.title, airDate = entry.airDate)
                        tmdbByAddon[key] = same
                        entry.videoId?.let { tmdbByAddonVideoId[it] = same }
                    }
                }
            }
            val unmatched = (tmdbEpisodes.size - addonByTmdb.size) + (addonEpisodes.size - tmdbByAddon.size)
            return MdbListEpisodeMapping(addonByTmdb, tmdbByAddon, tmdbByAddonVideoId, unmatched, covered = null)
        }

        /** How many of a season's unmatched episodes are the add-on's tail past TMDB's last episode. */
        private fun MdbListEpisodeMapping.unmatchedTail(addon: List<EpisodeMappingEntry>, tmdb: List<EpisodeMappingEntry>): Int {
            val lastTmdb = tmdb.maxOf { it.episode }
            val matchedIdentity = tmdbByAddon.all { (k, v) -> k == v.season to v.episode } && addonByTmdb.all { (k, v) -> k == v.season to v.episode }
            if (!matchedIdentity) return -1
            return addon.count { it.episode > lastTmdb && (it.season to it.episode) !in tmdbByAddon }
        }

        /**
         * Matches every episode of each list to the other by title, then position, through the
         * Trakt remap. A positional match that lands on an episode another episode already owns by
         * title is dropped rather than kept (Codex r4 #2): TMDB's recap, which the add-on does not
         * have, must not stand in for the add-on's next episode. Such episodes have no counterpart
         * and [toAddon] / [toTmdb] answer null for them.
         */
        suspend fun build(
            addonEpisodes: List<EpisodeMappingEntry>,
            tmdbEpisodes: List<EpisodeMappingEntry>,
        ): MdbListEpisodeMapping {
            if (addonEpisodes.isEmpty() || tmdbEpisodes.isEmpty()) return Unchanged
            val addonByTmdb = matchAll(tmdbEpisodes, addonEpisodes) { entry ->
                TraktEpisodeMappingService.reverseRemapEpisodeByTitleOrIndex(
                    requestedSeason = entry.season,
                    requestedEpisode = entry.episode,
                    requestedTitle = entry.title,
                    addonEpisodes = addonEpisodes,
                    traktEpisodes = tmdbEpisodes,
                )
            }
            val tmdbByAddon = matchAll(addonEpisodes, tmdbEpisodes) { entry ->
                TraktEpisodeMappingService.remapEpisodeByTitleOrIndex(
                    requestedSeason = entry.season,
                    requestedEpisode = entry.episode,
                    requestedVideoId = entry.videoId,
                    requestedTitle = entry.title,
                    addonEpisodes = addonEpisodes,
                    traktEpisodes = tmdbEpisodes,
                )
            }
            val tmdbByAddonVideoId = HashMap<String, EpisodeMappingEntry>(addonEpisodes.size)
            for (entry in addonEpisodes) {
                val videoId = entry.videoId ?: continue
                tmdbByAddon[entry.season to entry.episode]?.let { tmdbByAddonVideoId[videoId] = it }
            }
            val unmatched = (tmdbEpisodes.size - addonByTmdb.size) + (addonEpisodes.size - tmdbByAddon.size)
            return MdbListEpisodeMapping(addonByTmdb, tmdbByAddon, tmdbByAddonVideoId, unmatched, covered = null)
        }

        private suspend fun matchAll(
            source: List<EpisodeMappingEntry>,
            target: List<EpisodeMappingEntry>,
            remap: suspend (EpisodeMappingEntry) -> EpisodeMappingEntry?,
        ): Map<Pair<Int, Int>, EpisodeMappingEntry> {
            class Match(val key: Pair<Int, Int>, val counterpart: EpisodeMappingEntry, val byIdentity: Boolean)
            // Air dates unique on both sides stand in for titles when those do not match (localized
            // titles, Codex r6 #3), before the positional fallback.
            val targetByDate = target.filter { it.airDate != null }.groupBy { it.airDate!! }.filterValues { it.size == 1 }.mapValues { it.value.single() }
            val sourceDates = source.filter { it.airDate != null }.groupBy { it.airDate!! }.filterValues { it.size == 1 }.keys
            val matches = ArrayList<Match>(source.size)
            val ownedByIdentity = HashSet<Pair<Int, Int>>()
            for (entry in source) {
                val remapped = remap(entry)
                val title = entry.title?.let(MdbListEpisodeMappingService::usefulTitle)
                val byTitle = remapped != null && title != null && title == remapped.title?.let(MdbListEpisodeMappingService::usefulTitle)
                val counterpart = when {
                    byTitle -> remapped
                    entry.airDate in sourceDates -> targetByDate[entry.airDate] ?: remapped
                    else -> remapped
                } ?: continue
                val byIdentity = byTitle || (counterpart.airDate != null && counterpart.airDate == entry.airDate && entry.airDate in sourceDates)
                if (byIdentity) ownedByIdentity += counterpart.season to counterpart.episode
                matches += Match(entry.season to entry.episode, counterpart, byIdentity)
            }
            val result = LinkedHashMap<Pair<Int, Int>, EpisodeMappingEntry>(matches.size)
            for (match in matches) {
                val counterpartKey = match.counterpart.season to match.counterpart.episode
                // A positional match on an episode that another episode owns by title or date is no match.
                if (!match.byIdentity && counterpartKey in ownedByIdentity) continue
                result[match.key] = match.counterpart
            }
            return result
        }
    }
}
