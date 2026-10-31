package com.nuvio.app.features.player

/**
 * A chapter of the playing file, as its container lists it (upstream `PlayerChapters.kt`, without
 * the Compose annotation). tvOS builds these from its transport chapters for
 * [ChapterSkipIntervals.fromChapters].
 */
data class PlayerChapter(
    val startMs: Long,
    val title: String?,
)

/**
 * Sorted, one per start time, and only when there are at least two: a lone chapter (often a
 * single "Chapter 1" at 0) has nothing to skip to. Upstream `PlayerChapters.normalize`; a
 * top-level function here because a Kotlin `PlayerChapters` object would clash with the Swift
 * enum of that name.
 */
internal fun normalizePlayerChapters(chapters: List<PlayerChapter>): List<PlayerChapter> {
    val sorted = chapters
        .filter { it.startMs >= 0L }
        .sortedBy { it.startMs }
        .distinctBy { it.startMs }
    return if (sorted.size < 2) emptyList() else sorted
}
