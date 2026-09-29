package com.nuvio.app.features.player.skip

import com.nuvio.app.features.watching.domain.isShortPlaceholderDuration

/** Skip-interval types that mean "end credits" for episodes (upstream `PlayerNextEpisodeRules`). */
internal val OUTRO_SEGMENT_TYPES = setOf("outro", "ed", "mixed-ed")

/**
 * Fork-local, pure extraction of upstream `77ce8a73`'s "Delay next-episode card until post-credits
 * scene ends" rule (`PlayerNextEpisodeRules.shouldShowNextEpisodeCard` / `findFollowingPostCreditsScene`).
 *
 * Returns the playback position (ms) before which the next-episode card must NOT trigger because a
 * post-credits scene is still to play, or `null` when there is no hold (no outro data, no scene, or
 * unusable duration) and the caller's own threshold logic applies unchanged.
 *
 * When a scene exists the hold is `max(sceneEndMs, userThresholdMs)`: the card appears once the scene
 * is over AND the user's configured trigger point has been reached. Callers should treat it as
 * "show the card at positionMs >= hold" while it is non-null.
 */
fun nextEpisodeHoldUntilMs(
    intervals: List<SkipInterval>,
    durationMs: Long,
    thresholdMode: NextEpisodeThresholdMode,
    thresholdPercent: Float,
    thresholdMinutesBeforeEnd: Float,
): Long? {
    if (durationMs <= 0L || isShortPlaceholderDuration(durationMs)) return null
    val latestOutro = intervals.filter { it.type in OUTRO_SEGMENT_TYPES }.maxByOrNull { it.endTime } ?: return null
    val scene = latestOutro.findFollowingPostCreditsScene(intervals, durationMs) ?: return null
    val sceneEndMs = (scene.endTime * 1_000.0).toLong().coerceAtMost(durationMs)
    val userTriggerMs = userThresholdPositionMs(durationMs, thresholdMode, thresholdPercent, thresholdMinutesBeforeEnd)
    return maxOf(sceneEndMs, userTriggerMs)
}

private fun SkipInterval.findFollowingPostCreditsScene(
    intervals: List<SkipInterval>,
    durationMs: Long,
): SkipInterval? {
    if (type !in OUTRO_SEGMENT_TYPES) return null
    val explicit = intervals.filter {
        it.type.trim().lowercase() == "post-credits" &&
            it.startTime.isFinite() && it.endTime.isFinite() &&
            it.startTime >= endTime && it.endTime > it.startTime &&
            (durationMs <= 0L || it.startTime * 1000.0 < durationMs)
    }.minByOrNull { it.startTime }
    if (explicit != null) return explicit
    // Fork: upstream 77ce8a73 also invents a "post-credits" scene from the outro end to the end of
    // the video when more than ~5 s remain. On tvOS that made the hold the full duration for nearly
    // every anime episode (ending theme + next-episode preview), so the up-next countdown only
    // started at the very end and the user's threshold setting was ignored. The hold now applies
    // only to an explicit provider-reported `post-credits` interval; skip targets
    // (InternalSkipAction.kt) keep upstream's behaviour.
    return null
}

private fun userThresholdPositionMs(
    durationMs: Long,
    thresholdMode: NextEpisodeThresholdMode,
    thresholdPercent: Float,
    thresholdMinutesBeforeEnd: Float,
): Long = when (thresholdMode) {
    NextEpisodeThresholdMode.PERCENTAGE -> {
        val clampedPercent = thresholdPercent.coerceIn(97f, 100f)
        kotlin.math.ceil(durationMs * (clampedPercent / 100.0)).toLong()
    }
    NextEpisodeThresholdMode.MINUTES_BEFORE_END -> {
        val clampedMinutes = thresholdMinutesBeforeEnd.coerceIn(0f, 3.5f)
        durationMs - (clampedMinutes * 60_000f).toLong()
    }
}
