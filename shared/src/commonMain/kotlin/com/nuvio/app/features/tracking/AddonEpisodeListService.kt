package com.nuvio.app.features.tracking

import co.touchlab.kermit.Logger
import com.nuvio.app.features.addons.AddonRepository
import com.nuvio.app.features.details.MetaDetailsRepository
import com.nuvio.app.features.details.MetaVideo
import com.nuvio.app.features.trakt.EpisodeMappingEntry
import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.CompletableDeferred
import kotlinx.coroutines.NonCancellable
import kotlinx.coroutines.currentCoroutineContext
import kotlinx.coroutines.ensureActive
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.update
import kotlinx.coroutines.launch
import kotlinx.coroutines.supervisorScope
import kotlinx.coroutines.sync.Mutex
import kotlinx.coroutines.sync.Semaphore
import kotlinx.coroutines.sync.withLock
import kotlinx.coroutines.sync.withPermit
import kotlinx.coroutines.withContext
import kotlinx.coroutines.withTimeoutOrNull
import kotlin.time.Duration
import kotlin.time.Duration.Companion.hours
import kotlin.time.Duration.Companion.minutes
import kotlin.time.TimeMark
import kotlin.time.TimeSource

/**
 * Episode lists as the installed add-ons number them, for remapping episodes between the add-on's
 * numbering and a tracking provider's own (Trakt's absolute seasons, MDBList's TMDB seasons).
 * The seam the mapping services depend on; [AddonEpisodeListService] is the production source.
 */
internal interface AddonEpisodeListSource {
    suspend fun episodes(contentId: String, contentType: String): List<EpisodeMappingEntry>

    /**
     * Identifies the metadata source the lists come from: changes when the enabled add-ons or the
     * metadata language change, so a mapping built on an older list can be told apart.
     */
    fun generation(): Any
}

/**
 * Upstream NuvioTV facf25ec3 (PR #4439): the add-on episode-list fetch that used to be private to
 * `TraktEpisodeMappingService`, shared so Trakt and MDBList remap against one cache. Behaviour is
 * the Trakt service's: the first add-on that serves the show (`series`, then `tv`; the raw id, then
 * a `tmdb:`/`trakt:` prefix stripped), a 3.5 s budget per attempt, specials dropped, and one
 * in-flight fetch per show.
 */
internal object AddonEpisodeListService : AddonEpisodeListSource {
    private const val FETCH_TIMEOUT_MS = 3_500L

    private val cache = AddonEpisodeListCache(
        fetch = { contentId, contentType, refresh -> fetchAddonEpisodes(contentId, contentType, refresh) },
        generation = {
            // The enabled add-ons that can serve metadata, in order, plus the explicit invalidations
            // (TMDB language or enrichment changes, which re-title the add-on's episodes).
            val addons = AddonRepository.uiState.value.addons.asSequence()
                .filter { it.enabled }
                .map { it.manifestUrl }
                .joinToString("|")
            addons to invalidations
        },
    )
    private var invalidations = 0L

    var fetchCalls: Long
        get() = cache.fetchCalls
        set(value) { cache.fetchCalls = value }
    var fetchMisses: Long
        get() = cache.fetchMisses
        set(value) { cache.fetchMisses = value }

    /**
     * Pre-fetches add-on episode data for [contentIds] so that later lookups hit the cache.
     * Limits concurrency to [concurrency]; a show that fails to load is skipped.
     */
    suspend fun prefetch(contentIds: List<String>, concurrency: Int = 8) = cache.prefetch(contentIds, concurrency)

    override suspend fun episodes(contentId: String, contentType: String): List<EpisodeMappingEntry> =
        cache.episodes(contentId, contentType)

    override fun generation(): Any = cache.generation()

    /** Drops every cached list; lists fetched before this call no longer count as current. */
    fun invalidate() {
        invalidations++
        cache.clear()
    }

    fun clearCache() = invalidate()

    /** [refresh]: the cached list aged out, so the meta behind it is fetched again too (Codex r3 #3). */
    private suspend fun fetchAddonEpisodes(contentId: String, contentType: String, refresh: Boolean): List<EpisodeMappingEntry> {
        val typeCandidates = buildList {
            val normalized = contentType.lowercase()
            if (normalized.isNotBlank()) add(normalized)
            if (normalized in listOf("series", "tv")) {
                add("series")
                add("tv")
            }
        }.distinct()
        if (typeCandidates.isEmpty()) return emptyList()

        val idCandidates = buildList {
            add(contentId)
            if (contentId.startsWith("tmdb:")) add(contentId.substringAfter(':'))
            if (contentId.startsWith("trakt:")) add(contentId.substringAfter(':'))
        }.distinct()

        for (type in typeCandidates) {
            for (candidateId in idCandidates) {
                val meta = withTimeoutOrNull(FETCH_TIMEOUT_MS) {
                    if (refresh) MetaDetailsRepository.refetch(type = type, id = candidateId)
                    else MetaDetailsRepository.fetch(type = type, id = candidateId)
                } ?: continue
                val episodes = meta.videos.toEpisodeMappingEntries()
                if (episodes.isNotEmpty()) return episodes
            }
        }
        return emptyList()
    }

    private fun List<MetaVideo>.toEpisodeMappingEntries(): List<EpisodeMappingEntry> =
        asSequence()
            .mapNotNull { video ->
                val season = video.season ?: return@mapNotNull null
                val episode = video.episode ?: return@mapNotNull null
                if (season <= 0) return@mapNotNull null
                EpisodeMappingEntry(
                    season = season,
                    episode = episode,
                    title = video.title.takeIf { it.isNotBlank() },
                    videoId = video.id.takeIf { it.isNotBlank() },
                    airDate = video.released?.trim()?.take(10)?.takeIf { it.length == 10 },
                )
            }
            .distinctBy { it.videoId ?: "${it.season}:${it.episode}" }
            .sortedWith(compareBy(EpisodeMappingEntry::season, EpisodeMappingEntry::episode))
            .toList()
}

/**
 * The cache and in-flight dedup behind [AddonEpisodeListService], separate so tests can drive it
 * with a fake [fetch]. One fetch per show and generation at a time: later callers under the same
 * generation await the owner's result; when the owner is cancelled, or the generation moved while
 * it ran, they fetch for themselves instead of inheriting an outcome that is not theirs (Codex r1
 * #5, r2 #3). A list is kept for [listTtl] (so an airing show's new season is seen) and an empty
 * one — the add-on had nothing, or the attempts timed out while the metadata providers were still
 * starting — only for [emptyResultTtl] (Codex r1 #6, r2 #8). Lists carry the [generation] they
 * were fetched under and a tag that no longer matches is a miss (Codex r1 #3). The cache itself is
 * an immutable map swapped atomically, so clearing needs no lock (Codex r2 #7).
 */
internal class AddonEpisodeListCache(
    /** `refresh` is true when a list this cache held has aged out: the source must not answer from its own cache. */
    private val fetch: suspend (contentId: String, contentType: String, refresh: Boolean) -> List<EpisodeMappingEntry>,
    private val generation: () -> Any,
    private val emptyResultTtl: Duration = 5.minutes,
    private val listTtl: Duration = 6.hours,
    private val timeSource: TimeSource = TimeSource.Monotonic,
) : AddonEpisodeListSource {
    private val log = Logger.withTag("AddonEpisodeList")

    private class Cached(val episodes: List<EpisodeMappingEntry>, val generation: Any, val fetchedAt: TimeMark)
    /** A fetch's result and the generation it was made under; a receiver uses it only while that is current. */
    private class Outcome(val episodes: List<EpisodeMappingEntry>, val generation: Any)

    private val cache = MutableStateFlow<Map<String, Cached>>(emptyMap())
    private val inFlightMutex = Mutex()
    // In-flight dedup, keyed by show, type and generation: prevents multiple concurrent coroutines
    // from fetching the same show's addon episodes simultaneously.
    private val inFlight = mutableMapOf<String, CompletableDeferred<Outcome>>()

    var fetchCalls = 0L
    var fetchMisses = 0L

    suspend fun prefetch(contentIds: List<String>, concurrency: Int = 8) {
        val unique = contentIds.distinct()
        if (unique.isEmpty()) return
        val semaphore = Semaphore(concurrency)
        supervisorScope {
            unique.forEach { contentId ->
                launch {
                    try {
                        semaphore.withPermit { episodes(contentId, "series") }
                    } catch (error: CancellationException) {
                        throw error
                    } catch (_: Exception) {
                        // Individual prefetch failures are non-fatal. The mapping phase
                        // will retry or proceed without cached data for this show.
                    }
                }
            }
        }
    }

    override fun generation(): Any = generation.invoke()

    override suspend fun episodes(contentId: String, contentType: String): List<EpisodeMappingEntry> {
        fetchCalls++
        val cacheKey = cacheKey(contentId, contentType)
        repeat(MAX_ATTEMPTS) {
            currentCoroutineContext().ensureActive()
            val currentGeneration = generation()
            current(cacheKey, currentGeneration)?.let { return it }

            val flightKey = "$cacheKey|$currentGeneration"
            val deferred = CompletableDeferred<Outcome>()
            val (existing, refresh) = inFlightMutex.withLock {
                current(cacheKey, currentGeneration)?.let { return it }
                val flight = inFlight[flightKey] ?: run {
                    inFlight[flightKey] = deferred
                    null
                }
                flight to (cache.value[cacheKey]?.episodes?.isNotEmpty() == true)
            }
            if (existing != null) {
                val outcome = try {
                    existing.await()
                } catch (_: CancellationException) {
                    currentCoroutineContext().ensureActive()
                    return@repeat
                } catch (_: Exception) {
                    return emptyList()
                }
                // Checked where it is used, not where it was produced (Codex r2 #3, r3 #5).
                if (outcome.generation == generation()) return outcome.episodes
                return@repeat
            }

            fetchMisses++
            val outcome = try {
                val episodes = fetch(contentId, contentType, refresh)
                // Published under the mutex, so a generation change is either before this check
                // (the list is not kept) or after it (the receivers' own check rejects it).
                inFlightMutex.withLock {
                    if (generation() == currentGeneration) {
                        val fetched = Cached(episodes, currentGeneration, timeSource.markNow())
                        cache.update { it + (cacheKey to fetched) }
                    }
                }
                Outcome(episodes, currentGeneration).also(deferred::complete)
            } catch (error: CancellationException) {
                deferred.cancel(error)
                throw error
            } catch (error: Exception) {
                log.w { "addon episodes failed for $contentId ($contentType): ${error.message}" }
                deferred.completeExceptionally(error)
                return emptyList()
            } finally {
                withContext(NonCancellable) {
                    inFlightMutex.withLock { if (inFlight[flightKey] === deferred) inFlight.remove(flightKey) }
                }
            }
            if (outcome.generation == generation()) return outcome.episodes
            // The add-ons or the metadata language changed while the list loaded: fetch it again.
        }
        return emptyList()
    }

    fun clear() {
        cache.value = emptyMap()
    }

    private fun current(cacheKey: String, generation: Any): List<EpisodeMappingEntry>? {
        val cached = cache.value[cacheKey] ?: return null
        if (cached.generation != generation) return null
        val ttl = if (cached.episodes.isEmpty()) emptyResultTtl else listTtl
        if (cached.fetchedAt.elapsedNow() >= ttl) return null
        return cached.episodes
    }

    private fun cacheKey(contentId: String, contentType: String): String =
        "${contentType.trim().lowercase()}|${contentId.trim()}"

    private companion object {
        /** Fetches that straddle a generation change are retried this often before giving up. */
        const val MAX_ATTEMPTS = 3
    }
}
