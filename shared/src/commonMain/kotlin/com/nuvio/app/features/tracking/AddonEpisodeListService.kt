package com.nuvio.app.features.tracking

import co.touchlab.kermit.Logger
import com.nuvio.app.features.details.MetaDetailsRepository
import com.nuvio.app.features.details.MetaVideo
import com.nuvio.app.features.trakt.EpisodeMappingEntry
import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.CompletableDeferred
import kotlinx.coroutines.launch
import kotlinx.coroutines.supervisorScope
import kotlinx.coroutines.sync.Mutex
import kotlinx.coroutines.sync.Semaphore
import kotlinx.coroutines.sync.withLock
import kotlinx.coroutines.sync.withPermit
import kotlinx.coroutines.withTimeoutOrNull

/**
 * Episode lists as the installed add-ons number them, for remapping episodes between the add-on's
 * numbering and a tracking provider's own (Trakt's absolute seasons, MDBList's TMDB seasons).
 * The seam the mapping services depend on; [AddonEpisodeListService] is the production source.
 */
internal interface AddonEpisodeListSource {
    suspend fun episodes(contentId: String, contentType: String): List<EpisodeMappingEntry>
}

/**
 * Upstream NuvioTV facf25ec3 (PR #4439): the add-on episode-list fetch that used to be private to
 * `TraktEpisodeMappingService`, shared so Trakt and MDBList remap against one cache. Behaviour is
 * the Trakt service's: the first add-on that serves the show (`series`, then `tv`; the raw id, then
 * a `tmdb:`/`trakt:` prefix stripped), a 3.5 s budget per attempt, specials dropped, and one
 * in-flight fetch per show.
 */
internal object AddonEpisodeListService : AddonEpisodeListSource {
    private val log = Logger.withTag("AddonEpisodeList")
    private const val FETCH_TIMEOUT_MS = 3_500L

    private val cacheMutex = Mutex()
    private val episodesCache = mutableMapOf<String, List<EpisodeMappingEntry>>()
    // In-flight dedup: prevents multiple concurrent coroutines from fetching
    // the same show's addon episodes simultaneously.
    private val episodesInFlight = mutableMapOf<String, CompletableDeferred<List<EpisodeMappingEntry>>>()

    var fetchCalls = 0L
    var fetchMisses = 0L

    /**
     * Pre-fetches add-on episode data for [contentIds] so that later lookups hit the cache.
     * Limits concurrency to [concurrency]; a show that fails to load is skipped.
     */
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

    override suspend fun episodes(contentId: String, contentType: String): List<EpisodeMappingEntry> {
        fetchCalls++
        val cacheKey = cacheKey(contentId, contentType)

        // Fast path: cache hit
        cacheMutex.withLock {
            episodesCache[cacheKey]?.let { return it }
        }

        fetchMisses++
        // Dedup: if another coroutine is already fetching this show, await its result.
        val existingDeferred = cacheMutex.withLock { episodesInFlight[cacheKey] }
        if (existingDeferred != null) {
            return try { existingDeferred.await() } catch (_: Exception) { emptyList() }
        }

        // Register ourselves as the in-flight fetcher.
        val deferred = CompletableDeferred<List<EpisodeMappingEntry>>()
        val weOwn = cacheMutex.withLock {
            // Double-check: cache or another flight may have appeared while we waited.
            episodesCache[cacheKey]?.let { return it }
            if (episodesInFlight.containsKey(cacheKey)) {
                false
            } else {
                episodesInFlight[cacheKey] = deferred
                true
            }
        }
        if (!weOwn) {
            val other = cacheMutex.withLock { episodesInFlight[cacheKey] }
            return try { other?.await() ?: emptyList() } catch (_: Exception) { emptyList() }
        }

        return try {
            val episodes = fetchAddonEpisodes(contentId, contentType)
            cacheMutex.withLock { episodesCache[cacheKey] = episodes }
            deferred.complete(episodes)
            episodes
        } catch (e: Exception) {
            if (e is CancellationException) throw e
            log.w { "addon episodes failed for $contentId ($contentType): ${e.message}" }
            deferred.completeExceptionally(e)
            emptyList()
        } finally {
            cacheMutex.withLock { episodesInFlight.remove(cacheKey) }
        }
    }

    fun clearCache() {
        episodesCache.clear()
    }

    private fun cacheKey(contentId: String, contentType: String): String =
        "${contentType.trim().lowercase()}|${contentId.trim()}"

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
