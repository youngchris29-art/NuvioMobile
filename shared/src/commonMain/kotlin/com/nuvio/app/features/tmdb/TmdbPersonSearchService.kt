package com.nuvio.app.features.tmdb

import co.touchlab.kermit.Logger
import com.nuvio.app.features.addons.httpGetText
import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.sync.Mutex
import kotlinx.coroutines.sync.withLock
import kotlinx.coroutines.withContext
import kotlinx.serialization.SerialName
import kotlinx.serialization.Serializable
import kotlinx.serialization.json.Json

// Search & Discover batch 2026-10-06 (C3): TMDB people search for the Search page's People row.
// Cast and crew names live in TMDB, not in the add-on catalogs the rest of Search fans out to.

/// One person result. `tmdbId` arrives in Swift as Int32.
data class PersonPreview(
    val tmdbId: Int,
    val name: String,
    val profileUrl: String?,
    val knownForDepartment: String?,
    val knownFor: List<String>,
)

object TmdbPersonSearchService {
    private val log = Logger.withTag("TmdbPersonSearch")
    private val json = Json { ignoreUnknownKeys = true }

    private const val CACHE_LIMIT = 50
    private val cacheMutex = Mutex()
    private val cache = LinkedHashMap<String, List<PersonPreview>>()

    /// Test seam: replaces the HTTP GET so tests can count requests without a network.
    internal var httpGetForTest: (suspend (String) -> String)? = null

    /// Never throws (cancellation aside): any failure is an empty row.
    suspend fun searchPeople(query: String, limit: Int = 10): List<PersonPreview> =
        try {
            searchPeopleChecked(query, limit)
        } catch (error: CancellationException) {
            throw error
        } catch (error: Throwable) {
            log.w { "TMDB person search failed: ${error.message}" }
            emptyList()
        }

    /// Same as [searchPeople] but lets a network or decode failure propagate (Swift sees an NSError).
    @Throws(Throwable::class)
    suspend fun searchPeopleChecked(query: String, limit: Int): List<PersonPreview> =
        withContext(Dispatchers.Default) {
            val trimmed = query.trim()
            if (trimmed.isEmpty() || limit <= 0) return@withContext emptyList()
            val settings = TmdbSettingsRepository.snapshot()
            if (!settings.enabled) return@withContext emptyList()
            val apiKey = TmdbSettingsRepository.effectiveApiKey().takeIf(String::isNotBlank)
                ?: return@withContext emptyList()
            val language = normalizeTmdbLanguage(settings.language)
            val cacheKey = "${trimmed.lowercase()}|$language"

            val cached = cacheMutex.withLock {
                cache.remove(cacheKey)?.also { cache[cacheKey] = it }
            }
            if (cached != null) return@withContext cached.take(limit)

            val url = buildTmdbUrl(
                endpoint = "search/person",
                apiKey = apiKey,
                query = mapOf(
                    "query" to trimmed,
                    "language" to language,
                    "include_adult" to "false",
                ),
            )
            val body = (httpGetForTest ?: ::httpGetText)(url)
            val people = parsePersonSearch(body)

            cacheMutex.withLock {
                cache[cacheKey] = people
                while (cache.size > CACHE_LIMIT) {
                    cache.remove(cache.keys.first())
                }
            }
            people.take(limit)
        }

    internal fun clearCacheForTest() {
        cache.clear()
    }

    /// Decode seam. Drops results without a name; maps `known_for` to its titles (movies) or names (shows).
    internal fun parsePersonSearch(body: String): List<PersonPreview> =
        json.decodeFromString<TmdbPersonSearchResponse>(body).results.orEmpty().mapNotNull { result ->
            val name = result.name?.trim()?.takeIf(String::isNotEmpty) ?: return@mapNotNull null
            PersonPreview(
                tmdbId = result.id,
                name = name,
                profileUrl = tmdbImageUrl(result.profilePath, "w185"),
                knownForDepartment = result.knownForDepartment?.takeIf(String::isNotBlank),
                knownFor = result.knownFor.orEmpty().mapNotNull { item ->
                    (item.title ?: item.name)?.trim()?.takeIf(String::isNotEmpty)
                },
            )
        }
}

internal fun parsePersonSearch(json: String): List<PersonPreview> =
    TmdbPersonSearchService.parsePersonSearch(json)

@Serializable
private data class TmdbPersonSearchResponse(
    val results: List<TmdbPersonSearchResult>? = null,
)

@Serializable
private data class TmdbPersonSearchResult(
    val id: Int,
    val name: String? = null,
    @SerialName("profile_path") val profilePath: String? = null,
    @SerialName("known_for_department") val knownForDepartment: String? = null,
    @SerialName("known_for") val knownFor: List<TmdbPersonKnownFor>? = null,
)

@Serializable
private data class TmdbPersonKnownFor(
    val title: String? = null,
    val name: String? = null,
)
