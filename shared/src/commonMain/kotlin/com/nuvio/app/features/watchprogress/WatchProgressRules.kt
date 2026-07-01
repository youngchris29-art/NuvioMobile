package com.nuvio.app.features.watchprogress

import com.nuvio.app.features.watching.domain.DefaultContinueWatchingLimit
import com.nuvio.app.features.watching.domain.WatchingContentRef
import com.nuvio.app.features.watching.domain.WatchingProgressRecord
import com.nuvio.app.features.watching.domain.continueWatchingProgressEntries
import com.nuvio.app.features.watching.domain.isProgressComplete
import com.nuvio.app.features.watching.domain.resumeProgressForSeries
import com.nuvio.app.features.watching.domain.shouldStoreProgress
import kotlinx.serialization.Serializable
import kotlinx.serialization.decodeFromString
import kotlinx.serialization.encodeToString
import kotlinx.serialization.json.Json

internal const val ContinueWatchingLimit = DefaultContinueWatchingLimit

@Serializable
data class StoredWatchProgressPayload(
    val entries: List<WatchProgressEntry> = emptyList(),
    val lastSuccessfulPushEpochMs: Long = 0L,
    val deltaCursorEventId: Long = 0L,
    val deltaInitialized: Boolean = false,
)

object WatchProgressCodec {
    private val json = Json {
        ignoreUnknownKeys = true
        encodeDefaults = true
    }

    fun decodeEntries(payload: String): List<WatchProgressEntry> =
        decodePayload(payload).entries

    fun decodePayload(payload: String): StoredWatchProgressPayload =
        runCatching {
            json.decodeFromString<StoredWatchProgressPayload>(payload).let { storedPayload ->
                storedPayload.copy(
                    entries = storedPayload.entries.map(WatchProgressEntry::normalizedCompletion),
                )
            }
        }.getOrDefault(StoredWatchProgressPayload())

    fun encodeEntries(entries: Collection<WatchProgressEntry>): String =
        encodePayload(
            entries = entries,
            lastSuccessfulPushEpochMs = 0L,
            deltaCursorEventId = 0L,
            deltaInitialized = false,
        )

    fun encodePayload(
        entries: Collection<WatchProgressEntry>,
        lastSuccessfulPushEpochMs: Long,
        deltaCursorEventId: Long,
        deltaInitialized: Boolean,
    ): String =
        json.encodeToString(
            StoredWatchProgressPayload(
                entries = entries.toList().sortedByDescending { it.lastUpdatedEpochMs },
                lastSuccessfulPushEpochMs = lastSuccessfulPushEpochMs,
                deltaCursorEventId = deltaCursorEventId,
                deltaInitialized = deltaInitialized,
            ),
        )
}

fun shouldStoreWatchProgress(
    positionMs: Long,
    durationMs: Long,
): Boolean = shouldStoreProgress(positionMs = positionMs, durationMs = durationMs)

fun isWatchProgressComplete(
    positionMs: Long,
    durationMs: Long,
    isEnded: Boolean,
): Boolean = isProgressComplete(
    positionMs = positionMs,
    durationMs = durationMs,
    isEnded = isEnded,
)

fun List<WatchProgressEntry>. resumeEntryForSeries(metaId: String): WatchProgressEntry? =
    firstOrNull { entry -> entry.parentMetaId == metaId }?.let { seed ->
        resumeProgressForSeries(
            content = WatchingContentRef(type = seed.parentMetaType, id = metaId),
            progressRecords = map(WatchProgressEntry::toDomainProgressRecord),
        )?.let { record ->
            firstOrNull { entry -> entry.videoId == record.videoId }
        }
    }

fun List<WatchProgressEntry>. continueWatchingEntries(
    limit: Int = ContinueWatchingLimit,
): List<WatchProgressEntry> {
    val inProgressEntries = filter { entry -> entry.shouldTreatAsInProgressForContinueWatching() }
    val domainEntries = continueWatchingProgressEntries(
        progressRecords = inProgressEntries.map(WatchProgressEntry::toDomainProgressRecord),
        limit = limit,
    )
    val ids = domainEntries.map { record -> record.videoId }.toSet()
    return inProgressEntries.filter { entry -> entry.videoId in ids }
        .sortedByDescending { it.lastUpdatedEpochMs }
}

fun WatchProgressEntry.shouldTreatAsInProgressForContinueWatching(): Boolean {
    val entry = normalizedCompletion()
    if (entry.isEffectivelyCompleted) return false

    val hasStartedPlayback = entry.lastPositionMs > 0L ||
        entry.normalizedProgressPercent?.let { it > 0f } == true
    if (!hasStartedPlayback) return false

    return entry.source != WatchProgressSourceTraktHistory &&
        entry.source != WatchProgressSourceTraktShowProgress
}

fun WatchProgressEntry.shouldUseAsCompletedSeedForContinueWatching(): Boolean {
    val entry = normalizedCompletion()
    if (isMalformedNextUpSeedContentId(entry.parentMetaId)) return false
    if (!entry.isEffectivelyCompleted) return false
    if (entry.source != WatchProgressSourceTraktPlayback) return true

    val explicitPercent = entry.normalizedProgressPercent ?: return false
    return explicitPercent >= WatchProgressTraktPlaybackNextUpSeedPercentThreshold
}

fun shouldCascadeCompletedProgressToWatchedHistory(
    entry: WatchProgressEntry,
    isUsingTraktProgress: Boolean,
): Boolean = !isUsingTraktProgress && entry.normalizedCompletion().isCompleted

fun String?. isSeriesTypeForContinueWatching(): Boolean =
    equals("series", ignoreCase = true) || equals("tv", ignoreCase = true)

fun isMalformedNextUpSeedContentId(contentId: String?): Boolean {
    val trimmed = contentId?.trim().orEmpty()
    if (trimmed.isEmpty()) return true
    return when (trimmed.lowercase()) {
        "tmdb", "imdb", "trakt", "tmdb:", "imdb:", "trakt:" -> true
        else -> false
    }
}

private fun WatchProgressEntry.toDomainProgressRecord(): WatchingProgressRecord =
    normalizedCompletion().let { entry ->
        WatchingProgressRecord(
        content = WatchingContentRef(
            type = entry.parentMetaType,
            id = entry.parentMetaId,
        ),
        videoId = entry.videoId,
        seasonNumber = entry.seasonNumber,
        episodeNumber = entry.episodeNumber,
        lastUpdatedEpochMs = entry.lastUpdatedEpochMs,
        lastPositionMs = entry.lastPositionMs,
        isCompleted = entry.isCompleted,
        episodeTitle = entry.episodeTitle,
        episodeThumbnail = entry.episodeThumbnail,
    )
    }
