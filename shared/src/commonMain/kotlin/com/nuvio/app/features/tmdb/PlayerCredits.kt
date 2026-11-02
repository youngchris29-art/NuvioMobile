package com.nuvio.app.features.tmdb

import co.touchlab.kermit.Logger
import com.nuvio.app.features.addons.httpGetText
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.async
import kotlinx.coroutines.coroutineScope
import kotlinx.coroutines.sync.Mutex
import kotlinx.coroutines.sync.withLock
import kotlinx.coroutines.withContext
import kotlinx.serialization.SerialName
import kotlinx.serialization.Serializable
import kotlinx.serialization.json.Json

// Cast and crew for the player's Cast pill (Insights, 2026-11-01). Engine-independent: keyed on
// what is playing (TMDB movie, or TMDB show + season + episode), never on the stream. Every TMDB
// request built here carries only the API key, TMDB / IMDb / TVDB ids and the language — never a
// stream URL or a stream's request headers.

/** What the Cast pill is about: a TMDB movie, or a TMDB show with an optional season + episode. */
data class PlayerCreditsIdentity(
    /** "movie" or "tv". */
    val mediaType: String,
    val tmdbId: Int,
    val season: Int? = null,
    val episode: Int? = null,
) {
    /** True for an episode identity (show + season + episode), the only shape with episode credits. */
    val isEpisode: Boolean get() = mediaType == "tv" && season != null && episode != null

    /** Stable key for caches and the Swift loader's "same identity → no reload" check. */
    val key: String
        get() = if (isEpisode) "tv:$tmdbId:s$season:e$episode" else "$mediaType:$tmdbId"

    companion object
}

/** The first, pure step of resolving a playback's identity (see [PlayerCreditsIdentity.parse]). */
sealed class PlayerCreditsIdentityParse {
    /** The id already is a TMDB id. */
    data class Resolved(val identity: PlayerCreditsIdentity) : PlayerCreditsIdentityParse()

    /** An IMDb (`tt…`) or TVDB (`tvdb:…`) id that TMDB's `find/` has to map first. */
    data class NeedsLookup(
        val mediaType: String,
        /** "imdb_id" or "tvdb_id" (TMDB's `external_source` values). */
        val externalSource: String,
        val externalId: String,
        val season: Int?,
        val episode: Int?,
    ) : PlayerCreditsIdentityParse()

    /** Nothing TMDB can map (kitsu, add-on private ids, blank): the Cast pill stays hidden. */
    data object Unsupported : PlayerCreditsIdentityParse()
}

/** One card in the Cast pill. */
data class PlayerCreditPerson(
    /** TMDB person id (opens the compact actor view). */
    val personId: Int,
    val name: String,
    /** Character for cast; job(s) for crew, joined ("Director, Writer"). Null when unknown. */
    val role: String?,
    /** Full headshot URL, or null. */
    val photoUrl: String?,
    val isCrew: Boolean,
    /** True for an episode's guest star. */
    val isGuest: Boolean = false,
)

/** Cast first (billing order, guests after regulars), then key crew. */
data class PlayerCredits(
    val identityKey: String,
    val cast: List<PlayerCreditPerson>,
    val crew: List<PlayerCreditPerson>,
) {
    val people: List<PlayerCreditPerson> get() = cast + crew
    fun isEmpty(): Boolean = cast.isEmpty() && crew.isEmpty()
}

/** One poster in the compact actor view's display-only known-for row. */
data class PlayerKnownForTitle(
    val id: String,
    val title: String,
    val posterUrl: String?,
)

/** The compact actor view's data. */
data class PlayerPersonSummary(
    val personId: Int,
    val name: String,
    val biography: String?,
    val birthday: String?,
    val deathday: String?,
    val placeOfBirth: String?,
    val profilePhotoUrl: String?,
    val knownForDepartment: String?,
    val knownFor: List<PlayerKnownForTitle>,
)

private val imdbIdRegex = Regex("^tt\\d+$", RegexOption.IGNORE_CASE)

private fun normalizePlayerCreditsMediaType(contentType: String): String? =
    when (contentType.trim().lowercase()) {
        "movie", "film" -> "movie"
        "series", "tv", "show", "tvshow" -> "tv"
        else -> null
    }

fun PlayerCreditsIdentity.Companion.parse(
    contentType: String,
    parentMetaId: String,
    season: Int?,
    episode: Int?,
): PlayerCreditsIdentityParse {
    val hasEpisodeCoordinates = season != null && episode != null && season >= 0 && episode >= 1
    // Anime add-ons (contentType "anime") play episodes of a TMDB show: with valid episode
    // coordinates the id maps like a series. Coordinate-less anime stays Unsupported (no way to
    // tell a film from a show).
    val mediaType = when {
        contentType.trim().equals("anime", ignoreCase = true) && hasEpisodeCoordinates -> "tv"
        else -> normalizePlayerCreditsMediaType(contentType)
    } ?: return PlayerCreditsIdentityParse.Unsupported
    val keepEpisode = mediaType == "tv" && hasEpisodeCoordinates
    val resolvedSeason = if (keepEpisode) season else null
    val resolvedEpisode = if (keepEpisode) episode else null

    var id = parentMetaId.trim()
    if (id.startsWith("movie:", ignoreCase = true)) id = id.substring("movie:".length)
    else if (id.startsWith("series:", ignoreCase = true)) id = id.substring("series:".length)
    id = id.trim()
    if (id.isEmpty()) return PlayerCreditsIdentityParse.Unsupported

    fun resolved(digits: String): PlayerCreditsIdentityParse {
        val tmdbId = digits.takeIf { it.isNotEmpty() && it.length <= 9 && it.all(Char::isDigit) }
            ?.toIntOrNull()?.takeIf { it > 0 }
            ?: return PlayerCreditsIdentityParse.Unsupported
        return PlayerCreditsIdentityParse.Resolved(
            PlayerCreditsIdentity(mediaType, tmdbId, resolvedSeason, resolvedEpisode),
        )
    }

    return when {
        id.startsWith("tmdb:", ignoreCase = true) ->
            resolved(id.substring("tmdb:".length).substringBefore(':').trim())
        id.startsWith("tvdb:", ignoreCase = true) -> {
            val tvdb = id.substring("tvdb:".length).substringBefore(':').trim()
            if (tvdb.isNotEmpty() && tvdb.all(Char::isDigit)) {
                PlayerCreditsIdentityParse.NeedsLookup(mediaType, "tvdb_id", tvdb, resolvedSeason, resolvedEpisode)
            } else {
                PlayerCreditsIdentityParse.Unsupported
            }
        }
        else -> {
            val first = id.substringBefore(':').trim()
            when {
                imdbIdRegex.matches(first) ->
                    PlayerCreditsIdentityParse.NeedsLookup(mediaType, "imdb_id", first, resolvedSeason, resolvedEpisode)
                first.isNotEmpty() && first.all(Char::isDigit) -> resolved(first)
                else -> PlayerCreditsIdentityParse.Unsupported
            }
        }
    }
}

// ─── Pure ordering ───

internal data class CreditCastInput(
    val id: Int?,
    val name: String?,
    val character: String?,
    val profilePath: String?,
    val order: Int?,
)

internal data class CreditCrewInput(
    val id: Int?,
    val name: String?,
    val jobs: List<String>,
    val profilePath: String?,
)

private const val CREDITS_CAST_CAP = 20
private const val CREDITS_CREW_CAP = 8
private const val CREDITS_PRODUCER_CAP = 2

/** Priority rank of a key job (lower = earlier); null when the job is not a key job. */
private fun keyJobRank(job: String): Int? = when (job.trim().lowercase()) {
    "director" -> 0
    "creator" -> 1
    "writer", "screenplay", "teleplay", "story", "novel" -> 2
    "original music composer", "music" -> 3
    "director of photography" -> 4
    "producer", "executive producer" -> 5
    else -> null
}

private const val PRODUCER_RANK = 5

internal fun buildPlayerCredits(
    identityKey: String,
    cast: List<CreditCastInput>,
    guests: List<CreditCastInput>,
    crew: List<CreditCrewInput>,
): PlayerCredits {
    val seen = mutableSetOf<Int>()
    val people = mutableListOf<PlayerCreditPerson>()

    fun addAll(inputs: List<CreditCastInput>, isGuest: Boolean) {
        for (input in inputs.sortedBy { it.order ?: Int.MAX_VALUE }) {
            if (people.size >= CREDITS_CAST_CAP) return
            val id = input.id ?: continue
            val name = input.name?.trim()?.takeIf(String::isNotBlank) ?: continue
            if (!seen.add(id)) continue
            people += PlayerCreditPerson(
                personId = id,
                name = name,
                role = input.character?.trim()?.takeIf(String::isNotBlank),
                photoUrl = tmdbImageUrl(input.profilePath, TmdbImageSizes.PROFILE),
                isCrew = false,
                isGuest = isGuest,
            )
        }
    }
    addAll(cast, isGuest = false)
    // Guests keep their given order (the episode endpoint already lists them by billing).
    addAll(guests, isGuest = true)

    // One entry per person, with key jobs ranked.
    class Acc(val id: Int, var name: String, var photo: String?, val jobs: MutableList<String> = mutableListOf())
    val byId = linkedMapOf<Int, Acc>()
    for (input in crew) {
        val id = input.id ?: continue
        val name = input.name?.trim()?.takeIf(String::isNotBlank) ?: continue
        val acc = byId.getOrPut(id) { Acc(id, name, input.profilePath) }
        if (acc.photo == null) acc.photo = input.profilePath
        for (job in input.jobs) {
            val clean = job.trim()
            if (keyJobRank(clean) == null) continue
            if (acc.jobs.none { it.equals(clean, ignoreCase = true) }) acc.jobs += clean
        }
    }
    val withJobs = byId.values.filter { it.jobs.isNotEmpty() }.toMutableList()

    // Producer cap: only the first two people holding a producer job keep it.
    var producerPeople = 0
    for (acc in withJobs) {
        if (acc.jobs.any { keyJobRank(it) == PRODUCER_RANK }) {
            if (producerPeople < CREDITS_PRODUCER_CAP) {
                producerPeople++
            } else {
                acc.jobs.removeAll { keyJobRank(it) == PRODUCER_RANK }
            }
        }
    }

    val crewCards = withJobs
        .filter { it.jobs.isNotEmpty() }
        .onEach { acc -> acc.jobs.sortBy { keyJobRank(it) } }
        .sortedBy { acc -> keyJobRank(acc.jobs.first()) }
        .take(CREDITS_CREW_CAP)
        .map { acc ->
            PlayerCreditPerson(
                personId = acc.id,
                name = acc.name,
                role = acc.jobs.joinToString(", "),
                photoUrl = tmdbImageUrl(acc.photo, TmdbImageSizes.PROFILE),
                isCrew = true,
            )
        }

    return PlayerCredits(identityKey = identityKey, cast = people, crew = crewCards)
}

internal fun selectKnownFor(
    credits: List<KnownForCandidate>,
): List<PlayerKnownForTitle> {
    val seen = mutableSetOf<String>()
    return credits
        .sortedByDescending { it.voteCount }
        .filter { seen.add(it.id) }
        .take(10)
        .map { PlayerKnownForTitle(id = it.id, title = it.title, posterUrl = tmdbImageUrl(it.posterPath, TmdbImageSizes.POSTER)) }
}

internal data class KnownForCandidate(
    val id: String,
    val title: String,
    val posterPath: String?,
    val voteCount: Int,
)

// ─── DTOs ───

@Serializable
private data class CreditsCastDto(
    val id: Int? = null,
    val name: String? = null,
    val character: String? = null,
    @SerialName("profile_path") val profilePath: String? = null,
    val order: Int? = null,
    val roles: List<CreditsRoleDto> = emptyList(),
) {
    fun toInput() = CreditCastInput(
        id = id,
        name = name,
        character = character?.takeIf(String::isNotBlank) ?: roles.firstOrNull()?.character,
        profilePath = profilePath,
        order = order,
    )
}

@Serializable
private data class CreditsRoleDto(val character: String? = null)

@Serializable
private data class CreditsJobDto(val job: String? = null)

@Serializable
private data class CreditsCrewDto(
    val id: Int? = null,
    val name: String? = null,
    val job: String? = null,
    val department: String? = null,
    val jobs: List<CreditsJobDto> = emptyList(),
    @SerialName("profile_path") val profilePath: String? = null,
) {
    fun toInput() = CreditCrewInput(
        id = id,
        name = name,
        jobs = (listOfNotNull(job) + jobs.mapNotNull { it.job }),
        profilePath = profilePath,
    )
}

@Serializable
private data class CreditsResponseDto(
    val cast: List<CreditsCastDto> = emptyList(),
    @SerialName("guest_stars") val guestStars: List<CreditsCastDto> = emptyList(),
    val crew: List<CreditsCrewDto> = emptyList(),
)

@Serializable
private data class PersonDto(
    val id: Int? = null,
    val name: String? = null,
    val biography: String? = null,
    val birthday: String? = null,
    val deathday: String? = null,
    @SerialName("place_of_birth") val placeOfBirth: String? = null,
    @SerialName("profile_path") val profilePath: String? = null,
    @SerialName("known_for_department") val knownForDepartment: String? = null,
)

@Serializable
private data class PersonCreditDto(
    val id: Int = 0,
    @SerialName("media_type") val mediaType: String? = null,
    val title: String? = null,
    val name: String? = null,
    @SerialName("poster_path") val posterPath: String? = null,
    @SerialName("vote_count") val voteCount: Int? = null,
) {
    fun toCandidate(): KnownForCandidate? {
        val type = mediaType?.takeIf { it == "movie" || it == "tv" } ?: return null
        if (id <= 0) return null
        val label = (title ?: name)?.trim()?.takeIf(String::isNotBlank) ?: return null
        return KnownForCandidate("$type:$id", label, posterPath, voteCount ?: 0)
    }
}

@Serializable
private data class PersonCombinedCreditsDto(
    val cast: List<PersonCreditDto> = emptyList(),
    val crew: List<PersonCreditDto> = emptyList(),
)

// ─── Service ───

/**
 * The key the Cast pill calls TMDB with: the personal key, else the bundled one (same rule as
 * [TmdbSettingsRepository.effectiveApiKey]); null when neither exists.
 * Independent of the TMDB Enrichment toggles by design: "Show cast in player" fetches credits even
 * when [TmdbSettings.enabled] or [TmdbSettings.useCredits] is off.
 */
internal fun playerCreditsApiKey(settings: TmdbSettings): String? =
    settings.apiKey.ifBlank { TmdbConfig.API_KEY }.takeIf { it.isNotBlank() }

object PlayerCreditsService {
    private val log = Logger.withTag("PlayerCredits")
    private val json = Json { ignoreUnknownKeys = true }
    private val cacheMutex = Mutex()
    private val creditsCache = linkedMapOf<String, PlayerCredits>()
    private val personCache = linkedMapOf<String, PlayerPersonSummary>()

    /** Parse + `find/` lookup (IMDb through [TmdbService.ensureTmdbId], TVDB through `find/`). */
    suspend fun resolveIdentity(
        contentType: String,
        parentMetaId: String,
        season: Int?,
        episode: Int?,
    ): PlayerCreditsIdentity? = when (val parsed = PlayerCreditsIdentity.parse(contentType, parentMetaId, season, episode)) {
        is PlayerCreditsIdentityParse.Resolved -> parsed.identity
        is PlayerCreditsIdentityParse.Unsupported -> null
        is PlayerCreditsIdentityParse.NeedsLookup -> {
            val tmdbId = if (parsed.externalSource == "tvdb_id") {
                TmdbService.tvdbToTmdb(parsed.externalId, parsed.mediaType)
            } else {
                TmdbService.ensureTmdbId(parsed.externalId, parsed.mediaType)
            }?.toIntOrNull()?.takeIf { it > 0 }
            tmdbId?.let { PlayerCreditsIdentity(parsed.mediaType, it, parsed.season, parsed.episode) }
        }
    }

    /** Episode credits (cast, guests, crew) with the show's aggregate credits as the fallback. */
    suspend fun fetchCredits(identity: PlayerCreditsIdentity): PlayerCredits? = withContext(Dispatchers.Default) {
        val settings = TmdbSettingsRepository.snapshot()
        val apiKey = playerCreditsApiKey(settings) ?: return@withContext null
        val language = normalizeTmdbLanguage(settings.language)
        val cacheKey = identity.key + ":" + language
        cacheMutex.withLock { creditsCache[cacheKey] }?.let { return@withContext it }

        val query = mapOf("language" to language)
        val response: CreditsResponseDto? = when {
            identity.mediaType == "movie" ->
                fetch("movie/${identity.tmdbId}/credits", apiKey, query)
            identity.isEpisode -> {
                val episodeResponse = fetch<CreditsResponseDto>(
                    "tv/${identity.tmdbId}/season/${identity.season}/episode/${identity.episode}/credits",
                    apiKey,
                    query,
                )
                if (episodeResponse == null ||
                    (episodeResponse.cast.isEmpty() && episodeResponse.guestStars.isEmpty() && episodeResponse.crew.isEmpty())
                ) {
                    fetch("tv/${identity.tmdbId}/aggregate_credits", apiKey, query)
                } else {
                    episodeResponse
                }
            }
            else -> fetch("tv/${identity.tmdbId}/aggregate_credits", apiKey, query)
        }
        response ?: return@withContext null

        val credits = buildPlayerCredits(
            identityKey = identity.key,
            cast = response.cast.map { it.toInput() },
            guests = response.guestStars.map { it.toInput() },
            crew = response.crew.map { it.toInput() },
        )
        cacheMutex.withLock { creditsCache[cacheKey] = credits }
        credits
    }

    suspend fun fetchPersonSummary(personId: Int): PlayerPersonSummary? = withContext(Dispatchers.Default) {
        val settings = TmdbSettingsRepository.snapshot()
        val apiKey = playerCreditsApiKey(settings) ?: return@withContext null
        val language = normalizeTmdbLanguage(settings.language)
        val cacheKey = "$personId:$language"
        cacheMutex.withLock { personCache[cacheKey] }?.let { return@withContext it }

        val query = mapOf("language" to language)
        val (person, combined) = coroutineScope {
            val personDeferred = async { fetch<PersonDto>("person/$personId", apiKey, query) }
            val creditsDeferred = async { fetch<PersonCombinedCreditsDto>("person/$personId/combined_credits", apiKey, query) }
            personDeferred.await() to creditsDeferred.await()
        }
        person ?: return@withContext null
        val name = person.name?.trim()?.takeIf(String::isNotBlank) ?: return@withContext null

        val department = person.knownForDepartment?.trim()?.takeIf(String::isNotBlank)
        val source = if (department == null || department.equals("Acting", ignoreCase = true)) {
            combined?.cast.orEmpty()
        } else {
            combined?.crew.orEmpty()
        }
        val summary = PlayerPersonSummary(
            personId = person.id ?: personId,
            name = name,
            biography = person.biography?.trim()?.takeIf(String::isNotBlank),
            birthday = person.birthday?.takeIf(String::isNotBlank),
            deathday = person.deathday?.takeIf(String::isNotBlank),
            placeOfBirth = person.placeOfBirth?.takeIf(String::isNotBlank),
            profilePhotoUrl = tmdbImageUrl(person.profilePath, TmdbImageSizes.PROFILE),
            knownForDepartment = department,
            knownFor = selectKnownFor(source.mapNotNull { it.toCandidate() }),
        )
        cacheMutex.withLock { personCache[cacheKey] = summary }
        summary
    }

    /** Swift entry point: resolve + fetch in one call; null = nothing to show. */
    @Throws(Throwable::class)
    suspend fun fetchCreditsForPlaybackChecked(
        contentType: String,
        parentMetaId: String,
        season: Int?,
        episode: Int?,
    ): PlayerCredits? = resolveIdentity(contentType, parentMetaId, season, episode)?.let { fetchCredits(it) }

    @Throws(Throwable::class)
    suspend fun fetchPersonSummaryChecked(personId: Int): PlayerPersonSummary? = fetchPersonSummary(personId)

    private suspend inline fun <reified T> fetch(
        endpoint: String,
        apiKey: String,
        query: Map<String, String>,
    ): T? {
        val url = buildTmdbUrl(endpoint = endpoint, apiKey = apiKey, query = query)
        return runCatching { json.decodeFromString<T>(httpGetText(url)) }
            .onFailure { log.w { "TMDB request failed for $endpoint: ${it.message}" } }
            .getOrNull()
    }
}
