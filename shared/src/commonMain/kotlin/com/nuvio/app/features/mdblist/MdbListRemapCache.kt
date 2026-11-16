package com.nuvio.app.features.mdblist

import kotlin.concurrent.Volatile

/**
 * Upstream 9c2d09027: the last list built from a projection and a [MdbListEpisodeMappingService.remapped]
 * map, handed out again while both are the same instances. K/N-safe: one immutable triple swapped
 * through a volatile reference, no shared mutable map; two threads racing on a miss both build and
 * the later write wins, which only costs a rebuild.
 */
internal class MdbListRemapCache<T> {
    @Volatile
    private var last: Triple<MdbListProgressProjection, Map<String, MdbListEpisodeMapping>, T>? = null

    fun get(
        projection: MdbListProgressProjection,
        mappings: Map<String, MdbListEpisodeMapping>,
        build: () -> T,
    ): T {
        last?.let { (cachedProjection, cachedMappings, value) ->
            if (cachedProjection === projection && cachedMappings === mappings) return value
        }
        return build().also { last = Triple(projection, mappings, it) }
    }
}
