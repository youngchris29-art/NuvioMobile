package com.nuvio.app.features.streams

/**
 * Platform seam for how far the user's stream sort / filter preferences reach.
 *
 * [filtersApplyToAllStreams] is `true` when the debrid sort, minimum-resolution, Dolby Vision, HDR
 * and Cached Sources Only settings apply to every add-on's and plugin's streams, not just the
 * managed debrid ones. tvOS sets true at bootstrap (`installTvOsSharedProviders`); mobile keeps
 * debrid-only presentation, so the default stays `false` and mobile behaviour does not change.
 *
 * Read at stream-load time by `StreamsRepository` / `PlayerStreamsRepository` and passed on as
 * `DebridStreamPresentation.apply(..., allStreams = filtersApplyToAllStreams)`.
 */
object StreamPresentationPlatform {
    var filtersApplyToAllStreams: Boolean = false
}
