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
