package com.nuvio.app.features.player.skip

enum class AutoSkipSegmentType(val storedValue: String) {
    INTRO("intro"),
    RECAP("recap"),
    OUTRO("outro"),
    MOVIE_CREDITS("movie-credits");

    companion object {
        fun fromStoredValue(value: String): AutoSkipSegmentType? =
            entries.firstOrNull { it.storedValue == value }

        fun fromSkipIntervalType(type: String): AutoSkipSegmentType? = when (type.trim().lowercase()) {
            "op", "opening", "mixed-op", "intro" -> INTRO
            "recap" -> RECAP
            "ed", "ending", "mixed-ed", "outro", "credits" -> OUTRO
            "movie-credits" -> MOVIE_CREDITS
            else -> null
        }
    }
}

fun SkipInterval.shouldAutoSkip(selectedTypes: Set<AutoSkipSegmentType>): Boolean =
    startTime.isFinite() && endTime.isFinite() && startTime >= 0 && endTime > startTime &&
        AutoSkipSegmentType.fromSkipIntervalType(type) in selectedTypes

fun List<SkipInterval>.intervalsAtSeekPositions(fromMs: Long, toMs: Long): List<SkipInterval> =
    filter { interval ->
        AutoSkipSegmentType.fromSkipIntervalType(interval.type) != null &&
            listOf(fromMs, toMs).any { position ->
                val seconds = position / 1000.0
                seconds >= interval.startTime && seconds < interval.endTime
            }
    }

/**
 * Swift-friendly variant of [shouldAutoSkip] (distinct name: overloads collide as ObjC selectors): Kotlin `Set<Enum>` is awkward to build from Swift,
 * so callers can pass the selected types as a plain list. Fork-local.
 */
fun SkipInterval.shouldAutoSkipForTypes(selectedTypes: List<AutoSkipSegmentType>): Boolean =
    shouldAutoSkip(selectedTypes.toSet())
