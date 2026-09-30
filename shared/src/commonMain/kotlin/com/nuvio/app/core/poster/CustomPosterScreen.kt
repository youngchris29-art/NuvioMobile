package com.nuvio.app.core.poster

enum class CustomPosterScreen(val key: String) {
    /** Home catalog rows */
    HOME("home"),
    /** Continue Watching and Upcoming sections */
    CONTINUE_WATCHING("continue_watching"),
    /** Collection / folder detail screens */
    COLLECTIONS("collections"),
    /** Library screen */
    LIBRARY("library"),
    /** Search results */
    SEARCH("search"),
    /** Detail screen (recommendations, collection items, person credits) */
    DETAILS("details");

    companion object {
        /** All screens enabled — the default state. */
        val ALL: Set<CustomPosterScreen> = entries.toSet()

        /**
         * Wire/storage sentinel meaning "custom posters enabled on NO screen". An empty set cannot be
         * stored because null/empty already means [ALL] (mobile clients rely on that). Older builds
         * read this key as an unknown screen, i.e. an empty set, so it is compatible.
         */
        const val NONE_KEY = "none"

        /** Deserialize from stored key strings. Returns [ALL] if the set is null or empty;
         *  `{"none"}` maps to an empty set (unknown keys are dropped). */
        fun fromKeys(keys: Set<String>?): Set<CustomPosterScreen> {
            if (keys.isNullOrEmpty()) return ALL
            return keys.mapNotNull { key -> entries.find { it.key == key } }.toSet()
        }

        /** Serialize to storable key strings. */
        fun toKeys(screens: Set<CustomPosterScreen>): Set<String> =
            if (screens.isEmpty()) setOf(NONE_KEY) else screens.map { it.key }.toSet()
    }
}
