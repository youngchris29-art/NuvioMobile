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
import kotlinx.coroutines.async
import kotlinx.coroutines.awaitAll
import kotlinx.coroutines.coroutineScope
import kotlinx.coroutines.flow.Flow
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.map
import kotlinx.coroutines.flow.update
import kotlinx.coroutines.launch
import kotlinx.coroutines.sync.Mutex
import kotlinx.coroutines.sync.Semaphore
import kotlinx.coroutines.sync.withLock
import kotlinx.coroutines.sync.withPermit
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
 */
internal class MdbListEpisodeMappingService(
    private val addonEpisodes: AddonEpisodeListSource = AddonEpisodeListService,
    private val tmdb: TmdbSeasonListSource = TmdbSeasonListService,
    private val scope: CoroutineScope? = null,
) {
    private val log = Logger.withTag("MdbListEpMap")
    private val resolved = MutableStateFlow<Map<String, MdbListEpisodeMapping>>(emptyMap())
    private val inFlightMutex = Mutex()
    private val inFlight = mutableMapOf<String, CompletableDeferred<MdbListEpisodeMapping?>>()
    // Guarded by inFlightMutex. Background resolution from snapshot readers is throttled after a
    // failure (no add-on list, TMDB unreachable); explicit resolves are not.
    private val backgroundFailedAt = mutableMapOf<String, TimeMark>()

    /** Emits whenever a show's mapping resolves. */
    val changes: Flow<Unit> = resolved.map { }

    /** The mapping for [contentId] when it was already resolved, without touching the network. */
    fun cached(contentId: String): MdbListEpisodeMapping? = resolved.value[contentId.trim()]

    /**
     * Resolves the mapping for the show the add-on serves as [contentId]. [tmdbShowId] skips the
     * TMDB id lookup when MDBList already reported it. Returns null when either side's episodes
     * could not be loaded, so the caller keeps the numbering it has.
     */
    suspend fun resolve(contentId: String, tmdbShowId: Long? = null): MdbListEpisodeMapping? {
        val key = contentId.trim().takeIf(String::isNotBlank) ?: return null
        resolved.value[key]?.let { return it }
        val (deferred, owner) = inFlightMutex.withLock {
            resolved.value[key]?.let { return it }
            inFlight[key]?.let { it to false }
                ?: CompletableDeferred<MdbListEpisodeMapping?>().also { inFlight[key] = it }.let { it to true }
        }
        if (!owner) return deferred.await()
        return try {
            load(key, tmdbShowId).also { mapping ->
                if (mapping != null) resolved.update { it + (key to mapping) }
                deferred.complete(mapping)
            }
        } catch (error: CancellationException) {
            deferred.complete(null)
            throw error
        } catch (error: Exception) {
            log.w { "episode mapping failed for $key: ${error.message}" }
            deferred.complete(null)
            null
        } finally {
            inFlightMutex.withLock { inFlight.remove(key) }
        }
    }

    /**
     * Resolves [contentId]'s mapping on [scope] unless it is cached, in flight, or failed in the
     * last [BACKGROUND_RETRY_INTERVAL]. For readers that cannot suspend: [changes] ticks when done.
     */
    fun resolveInBackground(contentId: String, tmdbShowId: Long? = null) {
        val scope = scope ?: return
        val key = contentId.trim().takeIf(String::isNotBlank) ?: return
        if (resolved.value.containsKey(key)) return
        scope.launch {
            val skip = inFlightMutex.withLock {
                inFlight.containsKey(key) ||
                    backgroundFailedAt[key]?.let { it.elapsedNow() < BACKGROUND_RETRY_INTERVAL } == true
            }
            if (skip) return@launch
            if (resolve(key, tmdbShowId) == null) {
                inFlightMutex.withLock { backgroundFailedAt[key] = TimeSource.Monotonic.markNow() }
            }
        }
    }

    /**
     * [reference] with its episode moved from the add-on's numbering to TMDB's, which MDBList reads
     * season and episode numbers in. References that need no remapping come back unchanged.
     */
    suspend fun toMdbListNumbering(
        reference: TrackingMediaReference,
        mediaIndex: MdbListMediaIndex?,
    ): TrackingMediaReference {
        if (reference.kind == TrackingMediaKind.MOVIE) return reference
        val episode = reference.episode ?: return reference
        val season = episode.season ?: return reference
        val catalog = reference.catalog ?: return reference
        if (catalog.contentType.trim().lowercase() in MOVIE_CONTENT_TYPES) return reference
        val tmdbShowId = reference.ids.tmdb ?: reference.ids.toMdbListIds()?.let { ids ->
            mediaIndex?.resolve(MdbListItemType.SHOW, ids)?.ids?.tmdb
        }
        val tmdb = resolve(catalog.contentId, tmdbShowId)
            ?.toTmdb(season, episode.number, catalog.videoId) ?: return reference
        if (tmdb.season == season && tmdb.episode == episode.number) return reference
        return reference.copy(episode = episode.copy(season = tmdb.season, number = tmdb.episode))
    }

    fun clearCache() {
        resolved.value = emptyMap()
    }

    private suspend fun load(contentId: String, tmdbShowId: Long?): MdbListEpisodeMapping? {
        val addon = addonEpisodes.episodes(contentId, "series")
        if (addon.isEmpty()) return null
        val tmdbId = tmdbShowId?.takeIf { it in 1..Int.MAX_VALUE }?.toInt() ?: lookupTmdbShowId(contentId) ?: return null
        val seasons = tmdb.seasonEpisodeCounts(tmdbId) ?: return null
        if (seasons.isEmpty()) return null
        // Same seasons with a few episodes more or fewer, as when one side merges two-parters, keep
        // their numbers: matching those by position would shift every later season.
        if (seasons.keys == addon.seasonCounts().keys) return MdbListEpisodeMapping.Unchanged

        val tmdbEpisodes = coroutineScope {
            val semaphore = Semaphore(TMDB_SEASON_REQUEST_CONCURRENCY)
            seasons.keys.sorted().map { season ->
                async {
                    semaphore.withPermit {
                        tmdb.seasonEpisodes(tmdbId, season).map { (number, title) ->
                            EpisodeMappingEntry(season = season, episode = number, title = title)
                        }
                    }
                }
            }.awaitAll().flatten()
        }
        if (tmdbEpisodes.isEmpty()) return null
        if (TraktEpisodeMappingService.hasSameSeasonStructure(addon, tmdbEpisodes)) return MdbListEpisodeMapping.Unchanged
        log.d { "remapping $contentId: addon=${addon.seasonCounts()} tmdb=${tmdbEpisodes.seasonCounts()}" }
        return MdbListEpisodeMapping.build(addon, tmdbEpisodes)
    }

    private suspend fun lookupTmdbShowId(contentId: String): Int? {
        val ids = parseTrackingExternalIds(contentId)
        ids.tmdb?.takeIf { it in 1..Int.MAX_VALUE }?.let { return it.toInt() }
        if (ids.imdb.isNullOrBlank() && ids.tvdb.isNullOrBlank()) return null
        return tmdb.findTmdbShowId(imdbId = ids.imdb, tvdbId = ids.tvdb)
    }

    private fun List<EpisodeMappingEntry>.seasonCounts(): Map<Int, Int> =
        groupBy { it.season }.mapValues { it.value.size }

    private companion object {
        const val TMDB_SEASON_REQUEST_CONCURRENCY = 4
        val BACKGROUND_RETRY_INTERVAL = 10.minutes
        val MOVIE_CONTENT_TYPES = setOf("movie", "film")
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
) {
    /** False when both sides split the show the same way and episodes keep their numbers. */
    val remaps: Boolean
        get() = addonByTmdb.isNotEmpty() || tmdbByAddon.isNotEmpty()

    /** The add-on's episode for TMDB [season]/[episode], or null when nothing needs remapping. */
    fun toAddon(season: Int, episode: Int): EpisodeMappingEntry? = addonByTmdb[season to episode]

    /** TMDB's episode for the add-on's [season]/[episode], or null when nothing needs remapping. */
    fun toTmdb(season: Int, episode: Int, videoId: String? = null): EpisodeMappingEntry? =
        videoId?.takeIf(String::isNotBlank)?.let(tmdbByAddonVideoId::get) ?: tmdbByAddon[season to episode]

    companion object {
        val Unchanged = MdbListEpisodeMapping(emptyMap(), emptyMap(), emptyMap())

        suspend fun build(
            addonEpisodes: List<EpisodeMappingEntry>,
            tmdbEpisodes: List<EpisodeMappingEntry>,
        ): MdbListEpisodeMapping {
            if (addonEpisodes.isEmpty() || tmdbEpisodes.isEmpty()) return Unchanged
            val addonByTmdb = HashMap<Pair<Int, Int>, EpisodeMappingEntry>(tmdbEpisodes.size)
            for (entry in tmdbEpisodes) {
                val addon = TraktEpisodeMappingService.reverseRemapEpisodeByTitleOrIndex(
                    requestedSeason = entry.season,
                    requestedEpisode = entry.episode,
                    requestedTitle = entry.title,
                    addonEpisodes = addonEpisodes,
                    traktEpisodes = tmdbEpisodes,
                ) ?: continue
                addonByTmdb[entry.season to entry.episode] = addon
            }
            val tmdbByAddon = HashMap<Pair<Int, Int>, EpisodeMappingEntry>(addonEpisodes.size)
            val tmdbByAddonVideoId = HashMap<String, EpisodeMappingEntry>(addonEpisodes.size)
            for (entry in addonEpisodes) {
                val tmdb = TraktEpisodeMappingService.remapEpisodeByTitleOrIndex(
                    requestedSeason = entry.season,
                    requestedEpisode = entry.episode,
                    requestedVideoId = entry.videoId,
                    requestedTitle = entry.title,
                    addonEpisodes = addonEpisodes,
                    traktEpisodes = tmdbEpisodes,
                ) ?: continue
                tmdbByAddon.getOrPut(entry.season to entry.episode) { tmdb }
                entry.videoId?.let { tmdbByAddonVideoId[it] = tmdb }
            }
            return MdbListEpisodeMapping(addonByTmdb, tmdbByAddon, tmdbByAddonVideoId)
        }
    }
}
