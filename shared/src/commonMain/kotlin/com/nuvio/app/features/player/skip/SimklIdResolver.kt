package com.nuvio.app.features.player.skip

import com.nuvio.app.features.addons.httpGetText
import com.nuvio.app.features.simkl.buildSimklApiUrl
import com.nuvio.app.features.simkl.SimklConfig
import kotlinx.serialization.json.Json
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.int
import kotlinx.serialization.json.jsonArray
import kotlinx.serialization.json.jsonObject
import kotlinx.serialization.json.jsonPrimitive
import kotlinx.serialization.json.long

internal object SimklIdResolver {

    private val json = Json { ignoreUnknownKeys = true; isLenient = true }

    data class ResolvedIds(
        val simklId: Long,
        val type: String,
        val mal: String? = null,
        val anilist: String? = null,
        val kitsu: String? = null,
        val imdb: String? = null,
        val tvdbSeason: Int? = null
    )

    data class EpisodeMapping(
        val animeEpisode: Int,
        val tvdbSeason: Int,
        val tvdbEpisode: Int
    )

    private val idsCache = HashMap<String, ResolvedIds?>()
    private val detailsCache = HashMap<Long, ResolvedIds>()
    private val episodeCache = HashMap<Long, List<EpisodeMapping>>()

    // Codex r3: upstream hand-rolled "client_id=…&app-name=…&app-version=1.0"; the fork's existing
    // buildSimklApiUrl URL-encodes every parameter and supplies the real app version instead.

    /// Fork deviation from upstream f212242a (Codex r2): an IMDb series can map to SEVERAL Simkl anime
    /// entries (one per season). Upstream always took `results[0]`, so later seasons queried AniSkip /
    /// Anime-Skip with season 1's MAL/AniList ids — the same season-awareness the removed ARM path had
    /// (`entries[season - 1]`). When [season] is given and more than one entry matches, prefer the
    /// entry whose Simkl `season` equals it; otherwise fall back to the first result as upstream does.
    suspend fun resolveIds(source: String, id: String, season: Int? = null): ResolvedIds? {
        val cacheKey = "$source:$id:${season ?: ""}"
        idsCache[cacheKey]?.let { return it }
        if (SimklConfig.CLIENT_ID.isBlank()) return null

        return try {
            val searchText = httpGetText(buildSimklApiUrl("/search/id", mapOf(source to id)))
            val results = json.parseToJsonElement(searchText).jsonArray
            if (results.isEmpty()) return null
            val candidates = results.mapNotNull { it as? JsonObject }
            val scanForSeason = season != null && candidates.size > 1
            // Codex r4: one candidate's details call failing must not sink the whole lookup —
            // resolve per candidate, keep the first that succeeds as the fallback, and keep scanning.
            var first: ResolvedIds? = null
            var chosen: ResolvedIds? = null
            for (candidate in candidates) {
                val resolved = runCatching { resolveDetails(candidate) }.getOrNull() ?: continue
                if (first == null) first = resolved
                if (!scanForSeason) break
                if (resolved.tvdbSeason == season) { chosen = resolved; break }
            }
            (chosen ?: first)?.also { idsCache[cacheKey] = it }
        } catch (_: Exception) {
            null
        }
    }

    /// Search-result entry → full ids via `/{type}/{simklId}?extended=full`; cached per Simkl id so a
    /// multi-season scan (see [resolveIds]) fetches each candidate at most once per process.
    private suspend fun resolveDetails(result: JsonObject): ResolvedIds? {
        val simklId = result["ids"]?.jsonObject?.get("simkl")?.jsonPrimitive?.long ?: return null
        detailsCache[simklId]?.let { return it }

        val type = result["type"]?.jsonPrimitive?.content ?: "anime"
        val mediaType = when (type) {
            "movie" -> "movies"
            "show" -> "tv"
            else -> "anime"
        }

        val detailsText = httpGetText(buildSimklApiUrl("/$mediaType/$simklId", mapOf("extended" to "full")))
        val details = json.parseToJsonElement(detailsText).jsonObject
        val ids = details["ids"]?.jsonObject

        return ResolvedIds(
            simklId = simklId,
            type = mediaType,
            mal = ids?.get("mal")?.jsonPrimitive?.content?.takeIf { it.isNotBlank() },
            anilist = ids?.get("anilist")?.jsonPrimitive?.content?.takeIf { it.isNotBlank() },
            kitsu = ids?.get("kitsu")?.jsonPrimitive?.content?.takeIf { it.isNotBlank() },
            imdb = ids?.get("imdb")?.jsonPrimitive?.content?.takeIf { it.isNotBlank() },
            tvdbSeason = details["season"]?.jsonPrimitive?.int?.takeIf { it > 0 }
        ).also { detailsCache[simklId] = it }
    }

    suspend fun getEpisodeMapping(simklId: Long, type: String = "anime"): List<EpisodeMapping> {
        episodeCache[simklId]?.let { return it }
        if (SimklConfig.CLIENT_ID.isBlank()) return emptyList()

        return try {
            val text = httpGetText(buildSimklApiUrl("/$type/episodes/$simklId"))
            val episodes = json.parseToJsonElement(text).jsonArray
            val mapping = mutableListOf<EpisodeMapping>()
            for (ep in episodes) {
                val obj = ep.jsonObject
                val epNum = obj["episode"]?.jsonPrimitive?.int ?: continue
                val tvdb = obj["tvdb"]?.jsonObject ?: continue
                val tvdbSeason = tvdb["season"]?.jsonPrimitive?.int ?: continue
                val tvdbEpisode = tvdb["episode"]?.jsonPrimitive?.int ?: continue
                if (epNum > 0 && tvdbSeason > 0 && tvdbEpisode > 0) {
                    mapping.add(EpisodeMapping(epNum, tvdbSeason, tvdbEpisode))
                }
            }
            mapping.also { episodeCache[simklId] = it }
        } catch (_: Exception) {
            emptyList()
        }
    }

    suspend fun resolveEpisodeTvdb(source: String, id: String, episode: Int): Pair<Int, Int>? {
        val ids = resolveIds(source, id) ?: return null
        val entry = getEpisodeMapping(ids.simklId, ids.type).firstOrNull { it.animeEpisode == episode }
        return entry?.let { it.tvdbSeason to it.tvdbEpisode }
    }

    fun clearCache() {
        idsCache.clear()
        detailsCache.clear()
        episodeCache.clear()
    }
}
