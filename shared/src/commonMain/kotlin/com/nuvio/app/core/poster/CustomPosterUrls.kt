package com.nuvio.app.core.poster

import com.nuvio.app.features.home.PosterShape

/**
 * Fork-local (tvOS) helper: resolves the custom poster URL for a bare content id, for surfaces
 * whose model type carries no raw-URL fields (e.g. tvOS Continue Watching). Uses the same
 * resolver and the same content-type / shape rules as [withCustomPosterUrl] on `MetaPreview`,
 * so results match the overlay exactly.
 */
object CustomPosterUrls {
    /**
     * Returns the resolved custom URL, or null when no pattern applies to [screen]
     * (blank pattern, screen disabled, unsupported id type, non-poster shape for a pattern
     * without `{shape}`).
     */
    fun resolve(
        contentId: String,
        contentType: String,
        shape: PosterShape,
        screen: CustomPosterScreen,
    ): String? = resolveWithPattern(
        pattern = CustomPosterUrlRepository.patternForScreen(screen),
        contentId = contentId,
        contentType = contentType,
        shape = shape,
    )

    /** Pure form of [resolve] for an explicit pattern (no repository/storage access). */
    fun resolveWithPattern(
        pattern: String,
        contentId: String,
        contentType: String,
        shape: PosterShape,
    ): String? {
        if (pattern.isBlank()) return null
        val supportsShape = "{shape}" in pattern
        if (!supportsShape && shape != PosterShape.Poster) return null
        val type = if (contentType.equals("movie", ignoreCase = true)) "movie" else "series"
        return CustomPosterUrlResolver.resolve(
            pattern = pattern,
            ids = CustomPosterUrlResolver.extractIds(contentId),
            type = type,
            shape = when {
                !supportsShape -> "poster"
                shape == PosterShape.Landscape -> "landscape"
                shape == PosterShape.Square -> "square"
                else -> "poster"
            },
        )
    }
}
