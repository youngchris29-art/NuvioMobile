package com.nuvio.app.features.details

fun selectHeroTrailer(trailers: List<MetaTrailer>): MetaTrailer? =
    selectHeroTrailer(trailers, preferredLanguage = null)

/**
 * BUG-63: same selection, but with the Metadata Language as a tie-breaker BELOW the
 * official/type tiers: preferred language > English > untagged > anything else. This is a
 * preference, not a filter — a title whose only trailer is English still plays it.
 *
 * Deliberately an OVERLOAD rather than a default parameter: Kotlin/Native exports no default
 * arguments, so a default would rename the Objective-C selector the tvOS app already calls
 * (`HeroTrailerSelectorKt.selectHeroTrailer(trailers:)` in `DetailViewModel.swift` /
 * `InlineTrailerCard.swift`). `preferredLanguage` accepts either a bare code (`fr`) or a TMDB
 * locale (`fr-FR`, `pt-BR`); only the base language is compared.
 */
fun selectHeroTrailer(trailers: List<MetaTrailer>, preferredLanguage: String?): MetaTrailer? {
    val preferredBase = preferredLanguage?.trim()?.substringBefore("-")?.lowercase()?.takeIf { it.isNotBlank() }
    return trailers
        .asSequence()
        .filter { it.isPlayableYouTubeTrailerCandidate() }
        .maxWithOrNull(
            compareBy<MetaTrailer>(
                { it.heroTrailerPriority() },
                { it.languagePriority(preferredBase) },
                { it.publishedAt.orEmpty() },
                { it.size ?: 0 },
                { it.name },
            ),
        )
}

private fun MetaTrailer.languagePriority(preferredBase: String?): Int {
    // No preference (the one-argument overload) → this tier is a constant, so the legacy
    // publishedAt/size/name ordering is preserved exactly.
    if (preferredBase == null) return 0
    val tag = language?.substringBefore("-")?.lowercase()
    return when {
        preferredBase != null && tag == preferredBase -> 3
        tag == "en" -> 2
        tag == null -> 1
        else -> 0
    }
}

fun MetaTrailer.youtubePlaybackUrl(): String =
    key.takeIf { it.startsWith("http://") || it.startsWith("https://") }
        ?: "https://www.youtube.com/watch?v=$key"

private fun MetaTrailer.isPlayableYouTubeTrailerCandidate(): Boolean =
    key.isNotBlank() && site.equals("YouTube", ignoreCase = true)

private fun MetaTrailer.heroTrailerPriority(): Int {
    val isSeriesTrailer = seasonNumber != null
    val isTrailerType = type.equals("Trailer", ignoreCase = true)
    return when {
        !isSeriesTrailer && isTrailerType && official -> 70
        !isSeriesTrailer && isTrailerType -> 60
        !isSeriesTrailer && official -> 50
        !isSeriesTrailer -> 40
        isTrailerType && official -> 30
        isTrailerType -> 20
        official -> 10
        else -> 0
    }
}
