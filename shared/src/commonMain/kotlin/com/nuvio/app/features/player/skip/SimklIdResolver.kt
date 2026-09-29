package com.nuvio.app.features.player.skip

import com.nuvio.app.features.addons.httpGetText
import com.nuvio.app.features.simkl.buildSimklApiUrl
import com.nuvio.app.features.simkl.SimklConfig
import kotlinx.coroutines.CancellationException
import kotlinx.serialization.json.Json
import kotlinx.serialization.json.JsonArray
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.JsonPrimitive
import kotlinx.serialization.json.int
import kotlinx.serialization.json.intOrNull
import kotlinx.serialization.json.jsonArray
import kotlinx.serialization.json.jsonObject
import kotlinx.serialization.json.jsonPrimitive
import kotlinx.serialization.json.long
import kotlinx.serialization.json.longOrNull

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
    /// Parent Simkl id → its `mapped_tvdb_seasons` siblings (upstream aa748fa8).
    private val animeSeasonCache = HashMap<Long, List<AnimeSeasonEntry>>()

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
                val resolved = try {
                    resolveDetails(candidate)
                } catch (e: CancellationException) {
                    throw e
                } catch (_: Exception) {
                    null
                } ?: continue
                if (first == null) first = resolved
                if (!scanForSeason) break
                if (resolved.tvdbSeason == season) { chosen = resolved; break }
            }
            (chosen ?: first)?.also { idsCache[cacheKey] = it }
        } catch (e: CancellationException) {
            throw e
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

        return resolveDetails(simklId, mediaType)
    }

    /// Simkl id + API media type ("anime"/"tv"/"movies") → full ids. Shares [detailsCache] with the
    /// search-result overload, so a sibling season found via [resolveIdsForImdbEpisode] that was
    /// already fetched as a `/search/id` candidate costs no extra request. Upstream aa748fa8's
    /// `resolveIdsBySimklId` is folded in here instead of adding `"simkl:$id"` keys to [idsCache].
    private suspend fun resolveDetails(simklId: Long, mediaType: String): ResolvedIds {
        detailsCache[simklId]?.let { return it }

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
        } catch (e: CancellationException) {
            throw e
        } catch (_: Exception) {
            emptyList()
        }
    }

    suspend fun resolveEpisodeTvdb(source: String, id: String, episode: Int): Pair<Int, Int>? {
        val ids = resolveIds(source, id) ?: return null
        val entry = getEpisodeMapping(ids.simklId, ids.type).firstOrNull { it.animeEpisode == episode }
        return entry?.let { it.tvdbSeason to it.tvdbEpisode }
    }

    /**
     * Upstream aa748fa8: given an IMDB id and a TVDB-space season/episode, resolve the anime ids
     * (MAL/AniList/Kitsu) of the Simkl entry that owns THAT season.
     *
     * First pass is the fork's season-aware [resolveIds] (scans `/search/id` candidates for a
     * `season` match). Simkl's IMDB search commonly returns only the one canonical entry, though,
     * so when the chosen anime entry still maps to a different TVDB season this asks the entry for
     * `extended=full_anime_seasons` and follows `mapped_tvdb_seasons` to the sibling entry. Any
     * failure, or no sibling for [season], falls back to the first-pass result.
     *
     * Fork deviation: a TVDB season split across several anime entries (split-cour) yields more
     * than one sibling for [season]; each candidate's (cached) episode mapping is consulted and the
     * one containing ([season], [episode]) wins, else the first sibling. The final episode remap
     * still happens in [SkipIntroRepository] via [getEpisodeMapping] / [animeEpisodeFor].
     */
    suspend fun resolveIdsForImdbEpisode(
        imdbId: String,
        season: Int?,
        episode: Int,
    ): ResolvedIds? {
        val base = resolveIds("imdb", imdbId, season) ?: return null
        if (season == null || base.type != "anime") return base
        if (base.tvdbSeason == season &&
            !shouldLookForSibling(base.type, base.tvdbSeason, season, getEpisodeMapping(base.simklId, base.type), episode)
        ) return base

        val siblingSimklId = resolveSeasonSimklId(base.simklId, base.type, season, episode)
        if (siblingSimklId == null || siblingSimklId == base.simklId) return base
        return try {
            resolveDetails(siblingSimklId, base.type)
        } catch (e: CancellationException) {
            throw e
        } catch (_: Exception) {
            base
        }
    }

    private suspend fun resolveSeasonSimklId(
        parentSimklId: Long,
        type: String,
        tvdbSeason: Int,
        episode: Int,
    ): Long? {
        animeSeasonCache[parentSimklId]?.let { return pickSibling(it, type, tvdbSeason, episode) }
        if (SimklConfig.CLIENT_ID.isBlank()) return null

        return try {
            val text = httpGetText(
                buildSimklApiUrl("/$type/$parentSimklId", mapOf("extended" to "full_anime_seasons"))
            )
            val details = json.parseToJsonElement(text) as? JsonObject ?: return null
            val seasons = parseAnimeSeasonEntries(details)
            animeSeasonCache[parentSimklId] = seasons
            pickSibling(seasons, type, tvdbSeason, episode)
        } catch (e: CancellationException) {
            throw e
        } catch (_: Exception) {
            null
        }
    }

    /// Single candidate: no extra request. Several (split-cour): fetch each candidate's episode
    /// mapping (cached) and let [selectSiblingByEpisode] choose.
    private suspend fun pickSibling(
        seasons: List<AnimeSeasonEntry>,
        type: String,
        tvdbSeason: Int,
        episode: Int,
    ): Long? {
        val candidates = seasons.filter { it.tvdbSeason == tvdbSeason }
        if (candidates.size <= 1) return candidates.firstOrNull()?.simklId
        val withMappings = candidates.map { it to getEpisodeMapping(it.simklId, type) }
        return selectSiblingByEpisode(withMappings, tvdbSeason, episode)
    }

    /// Pure: among sibling candidates for one TVDB season, the first whose episode mapping contains
    /// ([tvdbSeason], [episode]); the first candidate when none does; null when there are none.
    internal fun selectSiblingByEpisode(
        candidates: List<Pair<AnimeSeasonEntry, List<EpisodeMapping>>>,
        tvdbSeason: Int,
        episode: Int,
    ): Long? =
        (candidates.firstOrNull { (_, mapping) ->
            mapping.any { it.tvdbSeason == tvdbSeason && it.tvdbEpisode == episode }
        } ?: candidates.firstOrNull())?.first?.simklId

    internal data class AnimeSeasonEntry(val simklId: Long, val tvdbSeason: Int)

    /// Pure: `mapped_tvdb_seasons` of a `full_anime_seasons` details response → (simklId, tvdbSeason)
    /// pairs. Malformed entries are skipped individually rather than failing the whole list.
    internal fun parseAnimeSeasonEntries(details: JsonObject): List<AnimeSeasonEntry> {
        val seasonsArray = details["mapped_tvdb_seasons"] as? JsonArray ?: return emptyList()
        return seasonsArray.mapNotNull { element ->
            val obj = element as? JsonObject ?: return@mapNotNull null
            val simklId = (obj["simkl_id"] as? JsonPrimitive)?.longOrNull?.takeIf { it > 0 }
                ?: return@mapNotNull null
            val mappedSeason = (obj["tvdb_season"] as? JsonPrimitive)?.intOrNull?.takeIf { it > 0 }
                ?: return@mapNotNull null
            AnimeSeasonEntry(simklId, mappedSeason)
        }
    }

    /// Pure: whether the first-pass entry may be the wrong split-cour half. Only anime entries whose
    /// TVDB season matches the request AND whose non-empty episode mapping lacks ([season], [episode])
    /// warrant a sibling lookup; an empty/unavailable mapping or non-anime type stays put.
    internal fun shouldLookForSibling(
        type: String,
        baseTvdbSeason: Int?,
        season: Int,
        mapping: List<EpisodeMapping>,
        episode: Int,
    ): Boolean {
        if (type != "anime" || baseTvdbSeason != season) return false
        if (mapping.isEmpty()) return false
        return mapping.none { it.tvdbSeason == season && it.tvdbEpisode == episode }
    }

    /// Pure: the sibling entry that owns [tvdbSeason], or null.
    internal fun selectSiblingSimklId(seasons: List<AnimeSeasonEntry>, tvdbSeason: Int): Long? =
        seasons.firstOrNull { it.tvdbSeason == tvdbSeason }?.simklId

    /// Pure: TVDB season/episode → the anime entry's own episode number; the TVDB [episode] when
    /// the entry has no mapping for it (upstream aa748fa8's fallback).
    internal fun animeEpisodeFor(mapping: List<EpisodeMapping>, season: Int, episode: Int): Int =
        mapping.firstOrNull { it.tvdbSeason == season && it.tvdbEpisode == episode }?.animeEpisode
            ?: episode

    fun clearCache() {
        idsCache.clear()
        detailsCache.clear()
        episodeCache.clear()
        animeSeasonCache.clear()
    }
}
