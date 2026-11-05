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
    ): MdbListEpisodeMapping? {
        val key = contentId.trim().takeIf(String::isNotBlank) ?: return null
        repeat(MAX_ATTEMPTS) {
            currentCoroutineContext().ensureActive()
            entry(key)?.takeIf { it.isFresh() }?.let { return it.mapping }
            val generation = addonEpisodes.generation()
            val currentEpoch = epoch.value
            val flightKey = "$key|$generation|$currentEpoch"
            val deferred = CompletableDeferred<Outcome>()
            val existing = inFlightMutex.withLock {
                entry(key)?.takeIf { it.isFresh() }?.let { return it.mapping }
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
                val mapping = load(key, tmdbShowId)
                // Published under the mutex: a source or profile change lands either before this
                // check (the mapping is not kept) or after it (every receiver checks again before
                // using the outcome, Codex r2 #4, r3 #5). A newer entry is never overwritten.
                if (mapping != null) {
                    inFlightMutex.withLock {
                        if (generation == addonEpisodes.generation() && currentEpoch == epoch.value) {
                            val entry = Resolved(mapping, generation, currentEpoch, timeSource.markNow())
                            resolved.update { current ->
                                current + (aliases + key).filter { alias -> current[alias]?.let { it.epoch > currentEpoch } != true }
                                    .associateWith { entry }
                            }
                        }
                    }
                }
                Outcome(mapping, generation, currentEpoch).also(deferred::complete)
            } catch (error: CancellationException) {
                deferred.cancel(error)
                throw error
            } catch (error: Exception) {
                log.w { "episode mapping failed for $key: ${error.message}" }
                deferred.complete(Outcome(null, generation, currentEpoch))
                return null
            } finally {
                withContext(NonCancellable) {
                    inFlightMutex.withLock { if (inFlight[flightKey] === deferred) inFlight.remove(flightKey) }
                }
            }
            if (outcome.isCurrent()) return outcome.mapping
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
        if (entry(key)?.isFresh() == true) return
        scope.launch {
            val skip = inFlightMutex.withLock {
                inFlight.keys.any { it.startsWith("$key|") } ||
                    backgroundFailedAt[key]?.let { it.elapsedNow() < BACKGROUND_RETRY_INTERVAL } == true
            }
            if (skip) return@launch
            if (resolve(key, tmdbShowId, aliases) == null) {
                inFlightMutex.withLock { backgroundFailedAt[key] = TimeSource.Monotonic.markNow() }
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
        val mapping = resolve(catalog.contentId, tmdbShowId, known?.aliases().orEmpty()) ?: return reference
        if (!mapping.remaps) return reference
        val tmdb = mapping.toTmdb(season, episode.number, catalog.videoId) ?: return null
        if (tmdb.season == season && tmdb.episode == episode.number) return reference
        return reference.copy(episode = episode.copy(season = tmdb.season, number = tmdb.episode))
    }

    /** Forgets every mapping; loads still running belong to the previous epoch and are dropped. */
    fun clearCache() {
        epoch.update { it + 1 }
        resolved.value = emptyMap()
    }

    private suspend fun load(contentId: String, tmdbShowId: Long?): MdbListEpisodeMapping? {
        val addon = addonEpisodes.episodes(contentId, "series")
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
        if (sameSeasons && addonCounts == seasons) return MdbListEpisodeMapping.Unchanged

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
        if (TraktEpisodeMappingService.hasSameSeasonStructure(addon, tmdbList)) return MdbListEpisodeMapping.Unchanged
        val withinSeasons = sameSeasons && when (seasonsHoldTheSameEpisodes(addon, tmdbList)) {
            true -> true
            false -> false
            // Nothing to go by: a small difference is taken for a merged or dropped episode, a
            // larger one for a moved boundary.
            null -> seasonsAlignUpToTheLast(addonCounts, seasons)
        }
        if (withinSeasons) {
            val mapping = MdbListEpisodeMapping.buildWithinSeasons(addon, tmdbList)
            if (mapping.isIdentity) return MdbListEpisodeMapping.Unchanged
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

    internal companion object {
        const val TMDB_SEASON_REQUEST_CONCURRENCY = 4
        /** Episodes a season may differ by on the two sides and still be the same season, pending the identity check. */
        const val MERGED_EPISODE_TOLERANCE = 2
        /** Loads that straddle a source change or profile switch are retried this often before giving up. */
        const val MAX_ATTEMPTS = 3
        val BACKGROUND_RETRY_INTERVAL = 10.minutes
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
) {
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
        addonByTmdb.entries.filter { it.key.first == tmdbSeason }.mapTo(HashSet()) { it.value.season }

    /**
     * The add-on's episode for TMDB [season]/[episode]. Null when nothing needs remapping
     * ([remaps] false) or, for a show that does remap, when TMDB's episode has no counterpart in
     * the add-on's list (a recap the add-on skips): such a row must not be shown as another episode.
     */
    fun toAddon(season: Int, episode: Int): EpisodeMappingEntry? = addonByTmdb[season to episode]

    /** TMDB's episode for the add-on's [season]/[episode]; null as for [toAddon]. */
    fun toTmdb(season: Int, episode: Int, videoId: String? = null): EpisodeMappingEntry? =
        videoId?.takeIf(String::isNotBlank)?.let(tmdbByAddonVideoId::get) ?: tmdbByAddon[season to episode]

    companion object {
        val Unchanged = MdbListEpisodeMapping(emptyMap(), emptyMap(), emptyMap(), unmatched = 0)

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
            return MdbListEpisodeMapping(addonByTmdb, tmdbByAddon, tmdbByAddonVideoId, unmatched)
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
            val addonByTmdb = matchAll(tmdbEpisodes) { entry ->
                TraktEpisodeMappingService.reverseRemapEpisodeByTitleOrIndex(
                    requestedSeason = entry.season,
                    requestedEpisode = entry.episode,
                    requestedTitle = entry.title,
                    addonEpisodes = addonEpisodes,
                    traktEpisodes = tmdbEpisodes,
                )
            }
            val tmdbByAddon = matchAll(addonEpisodes) { entry ->
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
            return MdbListEpisodeMapping(addonByTmdb, tmdbByAddon, tmdbByAddonVideoId, unmatched)
        }

        private suspend fun matchAll(
            source: List<EpisodeMappingEntry>,
            remap: suspend (EpisodeMappingEntry) -> EpisodeMappingEntry?,
        ): Map<Pair<Int, Int>, EpisodeMappingEntry> {
            class Match(val key: Pair<Int, Int>, val counterpart: EpisodeMappingEntry, val byTitle: Boolean)
            val matches = ArrayList<Match>(source.size)
            val ownedByTitle = HashSet<Pair<Int, Int>>()
            for (entry in source) {
                val counterpart = remap(entry) ?: continue
                val title = entry.title?.let(MdbListEpisodeMappingService::usefulTitle)
                val byTitle = title != null && title == counterpart.title?.let(MdbListEpisodeMappingService::usefulTitle)
                if (byTitle) ownedByTitle += counterpart.season to counterpart.episode
                matches += Match(entry.season to entry.episode, counterpart, byTitle)
            }
            val result = LinkedHashMap<Pair<Int, Int>, EpisodeMappingEntry>(matches.size)
            for (match in matches) {
                val counterpartKey = match.counterpart.season to match.counterpart.episode
                // A positional match on an episode that another episode owns by title is no match.
                if (!match.byTitle && counterpartKey in ownedByTitle) continue
                result[match.key] = match.counterpart
            }
            return result
        }
    }
}
