package com.nuvio.app.features.debrid

import com.nuvio.app.features.streams.StreamItem

/*
 * Fork-only Swift bridging for DirectDebridPlaybackResolver (same pattern as
 * `features/mdblist/MdbListAccountControllerBridging.kt`). A Kotlin exception crossing into Swift
 * from a suspend function WITHOUT `@Throws` aborts the process; with it, Swift gets a catchable
 * error (`try await DirectDebridPlaybackResolver.shared.resolveToPlayableStreamChecked(...)`).
 * The ObjC export drops default arguments, so a twin mirrors the full parameter list.
 */

/** [DirectDebridPlaybackResolver.resolveToPlayableStream], callable from Swift with `try await`. */
@Throws(Throwable::class)
suspend fun DirectDebridPlaybackResolver.resolveToPlayableStreamChecked(
    stream: StreamItem,
    season: Int?,
    episode: Int?,
): DirectDebridPlayableResult = resolveToPlayableStream(stream = stream, season = season, episode = episode)

/**
 * [DirectDebridPlaybackResolver.resolveToPlayableStream] with `forceRefresh = true`: skips the
 * resolver's 15 minute cache and asks the provider again. The in-player fallback uses it once per
 * source when a cached link expired before playback started (W4). Swift:
 * `try await DirectDebridPlaybackResolver.shared.resolveToPlayableStreamCheckedForce(stream:season:episode:)`.
 */
@Throws(Throwable::class)
suspend fun DirectDebridPlaybackResolver.resolveToPlayableStreamCheckedForce(
    stream: StreamItem,
    season: Int?,
    episode: Int?,
): DirectDebridPlayableResult =
    resolveToPlayableStream(stream = stream, season = season, episode = episode, forceRefresh = true)
