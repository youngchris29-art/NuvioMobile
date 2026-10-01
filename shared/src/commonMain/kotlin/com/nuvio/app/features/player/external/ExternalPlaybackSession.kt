package com.nuvio.app.features.player.external

import com.nuvio.app.features.watchprogress.WatchProgressPlaybackSession
import kotlinx.serialization.Serializable

/**
 * One hand-off to an external player that can call back with the playback position (Infuse's
 * `x-success` / `x-error`). Ported from upstream `99ced26a`'s `InfusePlaybackSession`
 * (composeApp-only there), generalised for tvOS: [playerId] is part of the callback path, so the
 * same flow serves any x-callback player, not only Infuse.
 *
 * [playbackSession] carries its own `profileId`, so the return is recorded against the profile
 * that launched the player even if the active profile changed in between.
 */
@Serializable
data class ExternalPlaybackSession(
    val id: String,
    val playerId: String,
    val sourceUrl: String,
    val playbackSession: WatchProgressPlaybackSession,
    val durationMs: Long?,
)
