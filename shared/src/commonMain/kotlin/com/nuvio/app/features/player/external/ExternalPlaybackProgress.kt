package com.nuvio.app.features.player.external

import co.touchlab.kermit.Logger
import com.nuvio.app.core.coroutines.uncaughtCoroutineLogger
import com.nuvio.app.features.player.PlayerPlaybackSnapshot
import com.nuvio.app.features.profiles.ProfileRepository
import com.nuvio.app.features.tracking.TrackingScrobbleAction
import com.nuvio.app.features.tracking.TrackingScrobbleCoordinator
import com.nuvio.app.features.tracking.TrackingScrobbleEvent
import com.nuvio.app.features.tracking.buildTrackingMediaReference
import com.nuvio.app.features.watching.domain.isShortPlaceholderDuration
import com.nuvio.app.features.watchprogress.WatchProgressPlaybackSession
import com.nuvio.app.features.watchprogress.WatchProgressRepository
import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.launch

private val log = Logger.withTag("ExternalPlayback")

private val externalPlaybackScope =
    CoroutineScope(SupervisorJob() + Dispatchers.Default + uncaughtCoroutineLogger("ExternalPlayback"))

/**
 * Records the position an external player reported back (upstream `99ced26a`'s
 * `recordExternalPlaybackProgress`, ported into `shared/` for tvOS).
 *
 * - Skipped when the position is not positive, or the known duration is a short
 *   placeholder/error clip ([isShortPlaceholderDuration]).
 * - Upserts through [WatchProgressRepository.upsertPlaybackProgress] with `isEnded = false` and
 *   `syncRemote = true`. An unknown duration is written as 0: the entry stays resumable and is
 *   never marked watched by the position alone.
 * - Sends a tracker STOP scrobble only when the duration is known.
 *
 * The duration is the session's own, else the duration of the progress entry already stored for
 * this video (the launch-time lookup upstream does, repeated here for a session that had none).
 *
 * Non-suspend and never throws (Swift calls it without `@Throws`): the scrobble is launched in
 * the background, failures are logged.
 */
fun recordExternalPlaybackProgress(session: ExternalPlaybackSession, positionSec: Double) {
    try {
        writeExternalPlaybackProgress(
            session = session,
            positionSec = positionSec,
            existingDurationMs = ::activeProfileProgressDurationMs,
            upsert = { playback, snapshot ->
                WatchProgressRepository.upsertPlaybackProgress(
                    session = playback,
                    snapshot = snapshot,
                    syncRemote = true,
                )
            },
            scrobbleStop = ::launchExternalPlaybackStopScrobble,
        )
    } catch (error: Exception) {
        log.e(error) { "Recording external playback progress failed" }
    }
}

internal data class ExternalPlaybackProgressPlan(
    val snapshot: PlayerPlaybackSnapshot,
    /** Null when the duration is unknown: no tracker scrobble then. */
    val stopScrobblePercent: Double?,
)

/** Pure decision half of [recordExternalPlaybackProgress]; null means "write nothing". */
internal fun planExternalPlaybackProgress(
    positionSec: Double,
    durationMs: Long?,
): ExternalPlaybackProgressPlan? {
    if (positionSec.isNaN() || positionSec.isInfinite() || positionSec <= 0.0) return null
    val positionMs = (positionSec * 1000.0).toLong()
    if (positionMs <= 0L) return null
    if (durationMs != null && isShortPlaceholderDuration(durationMs)) return null
    val knownDurationMs = durationMs?.takeIf { it > 0L }
    return ExternalPlaybackProgressPlan(
        snapshot = PlayerPlaybackSnapshot(
            isLoading = false,
            isPlaying = false,
            isEnded = false,
            durationMs = knownDurationMs ?: 0L,
            positionMs = positionMs,
        ),
        stopScrobblePercent = knownDurationMs?.let { duration ->
            (positionMs.toDouble() / duration.toDouble() * 100.0).coerceIn(0.0, 100.0)
        },
    )
}

/** [recordExternalPlaybackProgress] with its repository/tracker sinks injected (tests). */
internal fun writeExternalPlaybackProgress(
    session: ExternalPlaybackSession,
    positionSec: Double,
    existingDurationMs: (WatchProgressPlaybackSession) -> Long?,
    upsert: (WatchProgressPlaybackSession, PlayerPlaybackSnapshot) -> Unit,
    scrobbleStop: (profileId: Int, event: TrackingScrobbleEvent) -> Unit,
) {
    val playback = session.playbackSession
    val durationMs = session.durationMs?.takeIf { it > 0L }
        ?: existingDurationMs(playback)?.takeIf { it > 0L }
    val plan = planExternalPlaybackProgress(positionSec = positionSec, durationMs = durationMs) ?: return
    upsert(playback, plan.snapshot)
    val percent = plan.stopScrobblePercent ?: return
    val media = buildTrackingMediaReference(
        contentType = playback.parentMetaType,
        parentMetaId = playback.parentMetaId,
        videoId = playback.videoId,
        title = playback.title,
        seasonNumber = playback.seasonNumber,
        episodeNumber = playback.episodeNumber,
        episodeTitle = playback.episodeTitle,
    )
    if (!media.hasResolvableIdentity) return
    scrobbleStop(playback.profileId, TrackingScrobbleEvent(media = media, progressPercent = percent))
}

/**
 * Duration of the progress entry already stored for [playback]'s video, when [playback] belongs
 * to the active profile (the repository only holds the active profile's entries in memory).
 */
internal fun activeProfileProgressDurationMs(playback: WatchProgressPlaybackSession): Long? {
    if (playback.profileId != ProfileRepository.activeProfileId) return null
    return WatchProgressRepository.progressForVideo(
        videoId = playback.videoId,
        parentMetaId = playback.parentMetaId,
        seasonNumber = playback.seasonNumber,
        episodeNumber = playback.episodeNumber,
    )?.durationMs?.takeIf { it > 0L }
}

private fun launchExternalPlaybackStopScrobble(profileId: Int, event: TrackingScrobbleEvent) {
    externalPlaybackScope.launch {
        try {
            TrackingScrobbleCoordinator.scrobble(
                profileId = profileId,
                action = TrackingScrobbleAction.STOP,
                event = event,
            )
        } catch (error: CancellationException) {
            throw error
        } catch (error: Exception) {
            log.w(error) { "External playback STOP scrobble failed" }
        }
    }
}
