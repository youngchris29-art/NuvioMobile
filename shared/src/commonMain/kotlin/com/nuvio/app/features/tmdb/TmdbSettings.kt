package com.nuvio.app.features.tmdb

data class TmdbSettings(
    val enabled: Boolean = false,
    /**
     * Optional personal TMDB key (upstream df589078). Blank means "use the bundled
     * [TmdbConfig.API_KEY]" — read the key to call with through
     * [TmdbSettingsRepository.effectiveApiKey], never this field directly.
     */
    val apiKey: String = "",
    val language: String = "en",
    val useTrailers: Boolean = true,
    val useArtwork: Boolean = true,
    val useBasicInfo: Boolean = true,
    val useDetails: Boolean = true,
    val useReleaseDates: Boolean = false,
    val useCredits: Boolean = true,
    val useProductions: Boolean = true,
    val useNetworks: Boolean = true,
    val useEpisodes: Boolean = true,
    val useSeasonPosters: Boolean = true,
    val useMoreLikeThis: Boolean = true,
    val useCollections: Boolean = true,
)
