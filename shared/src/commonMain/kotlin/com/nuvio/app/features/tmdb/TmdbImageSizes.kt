package com.nuvio.app.features.tmdb

/**
 * I1 (Steven beta.19-rc1 verdict, 2026-10-03; tracker BUG-134): TMDB rendition per artwork role.
 *
 * Posters are w780 so a lifted Large card is not upscaled on a 4K Apple TV (w500 is 500 px wide,
 * a Large card is drawn about 360 pt = 720 px wide at 2x, plus the focus lift). Title logos stay
 * w500 in the data on purpose: the Home hero fetches them inside its 400 ms swap deadline and its
 * 1.5 s launch deadline, so a bigger file in the data would slow the hero. tvOS asks for
 * `original` at draw time instead (`ArtworkURLUpgrade`, role `.logo`), outside those deadlines.
 */
object TmdbImageSizes {
    const val POSTER = "w780"
    const val BACKDROP = "w1280"
    const val LOGO = "w500"
    const val PROFILE = "w500"
}

/** The one place a TMDB image URL is built; `TmdbMetadataService` and `TmdbCollectionSourceResolver` delegate here. */
internal fun tmdbImageUrl(path: String?, size: String): String? {
    val clean = path?.trim()?.takeIf(String::isNotBlank) ?: return null
    return "https://image.tmdb.org/t/p/$size$clean"
}
