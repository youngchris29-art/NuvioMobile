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
import kotlinx.coroutines.launch
import kotlinx.coroutines.supervisorScope
import kotlinx.coroutines.sync.Mutex
import kotlinx.coroutines.sync.Semaphore
import kotlinx.coroutines.sync.withLock
import kotlinx.coroutines.sync.withPermit
import kotlinx.coroutines.withContext
import kotlinx.coroutines.withTimeoutOrNull
import kotlin.time.Duration
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
        fetch = { contentId, contentType -> fetchAddonEpisodes(contentId, contentType) },
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

    private suspend fun fetchAddonEpisodes(contentId: String, contentType: String): List<EpisodeMappingEntry> {
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
                    MetaDetailsRepository.fetch(type = type, id = candidateId)
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
                )
            }
            .distinctBy { it.videoId ?: "${it.season}:${it.episode}" }
            .sortedWith(compareBy(EpisodeMappingEntry::season, EpisodeMappingEntry::episode))
            .toList()
}

/**
 * The cache and in-flight dedup behind [AddonEpisodeListService], separate so tests can drive it
 * with a fake [fetch]. One fetch per show at a time: later callers await the owner's result, and
 * when the owner is cancelled they fetch themselves instead of reading its cancellation as a
 * result (Codex r1 #5). An empty list — the add-on had nothing, or the attempts timed out while the
 * metadata providers were still starting — is kept only for [emptyResultTtl], so the show is tried
 * again (Codex r1 #6). Lists are tagged with [generation] and a tag that no longer matches is a
 * miss (Codex r1 #3).
 */
internal class AddonEpisodeListCache(
    private val fetch: suspend (contentId: String, contentType: String) -> List<EpisodeMappingEntry>,
    private val generation: () -> Any,
    private val emptyResultTtl: Duration = 5.minutes,
    private val timeSource: TimeSource = TimeSource.Monotonic,
) : AddonEpisodeListSource {
    private val log = Logger.withTag("AddonEpisodeList")

    private class Cached(val episodes: List<EpisodeMappingEntry>, val generation: Any, val fetchedAt: TimeMark)

    private val cacheMutex = Mutex()
    private val episodesCache = mutableMapOf<String, Cached>()
    // In-flight dedup: prevents multiple concurrent coroutines from fetching
    // the same show's addon episodes simultaneously.
    private val episodesInFlight = mutableMapOf<String, CompletableDeferred<List<EpisodeMappingEntry>>>()

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
        val currentGeneration = generation()

        while (true) {
            currentCoroutineContext().ensureActive()
            // Fast path: a current cache entry.
            cacheMutex.withLock { current(cacheKey, currentGeneration)?.let { return it } }

            // Dedup: if another coroutine is already fetching this show, await its result; when
            // that fetch is cancelled, try again as the owner instead of inheriting its outcome.
            val deferred = CompletableDeferred<List<EpisodeMappingEntry>>()
            val existing = cacheMutex.withLock {
                current(cacheKey, currentGeneration)?.let { return it }
                episodesInFlight[cacheKey] ?: run {
                    episodesInFlight[cacheKey] = deferred
                    null
                }
            }
            if (existing != null) {
                try {
                    return existing.await()
                } catch (error: CancellationException) {
                    currentCoroutineContext().ensureActive()
                    continue
                } catch (_: Exception) {
                    return emptyList()
                }
            }

            fetchMisses++
            return try {
                val episodes = fetch(contentId, contentType)
                cacheMutex.withLock {
                    episodesCache[cacheKey] = Cached(episodes, currentGeneration, timeSource.markNow())
                }
                deferred.complete(episodes)
                episodes
            } catch (error: CancellationException) {
                deferred.cancel(error)
                throw error
            } catch (error: Exception) {
                log.w { "addon episodes failed for $contentId ($contentType): ${error.message}" }
                deferred.completeExceptionally(error)
                emptyList()
            } finally {
                withContext(NonCancellable) {
                    cacheMutex.withLock {
                        if (episodesInFlight[cacheKey] === deferred) episodesInFlight.remove(cacheKey)
                    }
                }
            }
        }
    }

    fun clear() {
        episodesCache.clear()
    }

    private fun current(cacheKey: String, generation: Any): List<EpisodeMappingEntry>? {
        val cached = episodesCache[cacheKey] ?: return null
        if (cached.generation != generation) {
            episodesCache.remove(cacheKey)
            return null
        }
        if (cached.episodes.isEmpty() && cached.fetchedAt.elapsedNow() >= emptyResultTtl) {
            episodesCache.remove(cacheKey)
            return null
        }
        return cached.episodes
    }

    private fun cacheKey(contentId: String, contentType: String): String =
        "${contentType.trim().lowercase()}|${contentId.trim()}"
}
