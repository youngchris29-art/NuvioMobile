package com.nuvio.app.features.player

import com.nuvio.app.features.streams.StreamItem

/*
 * Fork-only Swift bridging for [PlayerSourceFallbackCandidates] (W4; same pattern as
 * `features/debrid/DirectDebridResolverBridging.kt`). A Kotlin exception crossing into Swift from
 * a suspend function WITHOUT `@Throws` aborts the process; with it, Swift gets a catchable error.
 * The ObjC export drops default arguments, so every parameter is spelled out.
 */

/**
 * [PlayerSourceFallbackCandidates.load], callable from Swift as
 * `try await PlayerSourceFallbackCandidates.shared.loadChecked(type:videoId:season:episode:timeoutMs:)`
 * (`season` / `episode` are `KotlinInt?`, `timeoutMs` an `Int64`). A throw means "no candidates".
 */
@Throws(Throwable::class)
suspend fun PlayerSourceFallbackCandidates.loadChecked(
    type: String,
    videoId: String,
    season: Int?,
    episode: Int?,
    timeoutMs: Long,
): List<StreamItem> = load(type = type, videoId = videoId, season = season, episode = episode, timeoutMs = timeoutMs)
