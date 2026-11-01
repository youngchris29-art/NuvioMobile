package com.nuvio.app.features.tmdb

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

// TODO(insights wave 1a): implementations. Contract only below — signatures are fixed.

fun PlayerCreditsIdentity.Companion.parse(
    contentType: String,
    parentMetaId: String,
    season: Int?,
    episode: Int?,
): PlayerCreditsIdentityParse = PlayerCreditsIdentityParse.Unsupported

object PlayerCreditsService {
    /** Parse + `find/` lookup (IMDb through [TmdbService.ensureTmdbId], TVDB through `find/`). */
    suspend fun resolveIdentity(
        contentType: String,
        parentMetaId: String,
        season: Int?,
        episode: Int?,
    ): PlayerCreditsIdentity? = null

    /** Episode credits (cast, guests, crew) with the show's aggregate credits as the fallback. */
    suspend fun fetchCredits(identity: PlayerCreditsIdentity): PlayerCredits? = null

    suspend fun fetchPersonSummary(personId: Int): PlayerPersonSummary? = null

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
}
