package com.nuvio.app.features.search

import kotlinx.serialization.json.Json

/// C4: the persisted shape of `discover_genre_by_catalog`, a JSON object of catalog key to genre.
internal object DiscoverGenreMap {
    private val json = Json { ignoreUnknownKeys = true }

    fun decode(raw: String?): Map<String, String> =
        raw?.takeIf { it.isNotBlank() }
            ?.let { runCatching { json.decodeFromString<Map<String, String>>(it) }.getOrNull() }
            .orEmpty()

    fun encode(map: Map<String, String>): String = json.encodeToString(map)

    fun with(raw: String?, catalogKey: String, genre: String?): String {
        val updated = decode(raw).toMutableMap()
        if (genre == null) updated.remove(catalogKey) else updated[catalogKey] = genre
        return encode(updated)
    }
}
