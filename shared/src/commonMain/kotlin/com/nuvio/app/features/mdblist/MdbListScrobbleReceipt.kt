package com.nuvio.app.features.mdblist

import com.nuvio.app.features.tracking.TrackingScrobbleAction
import kotlin.time.Instant
import io.ktor.http.fromHttpToGmtDate

internal data class MdbListScrobbleReceipt(
    val target: MdbListMutationTarget,
    val action: TrackingScrobbleAction,
    val progress: Float,
    val timestamp: String,
    val playbackId: Long?
) {
    val isWatched: Boolean
        get() = action != TrackingScrobbleAction.START && progress >= MdbListProgressProjection.COMPLETION_PERCENT
}

internal fun decodeMdbListScrobbleReceipt(
    response: MdbListHttpResponse,
    target: MdbListMutationTarget,
    action: TrackingScrobbleAction,
    nowEpochMs: Long
): MdbListScrobbleReceipt {
    val body = mdbListResponseElement(response.body).objectValue()
    val acceptedActions = if (action == TrackingScrobbleAction.START) setOf("start") else setOf("pause", "stop", "scrobble")
    if (body.text("action") !in acceptedActions) throw MdbListDecodingException()
    val progress = body.text("progress")?.toFloatOrNull()?.takeIf { it.isFinite() && it in 0f..100f }
        ?: throw MdbListDecodingException()
    val episode = body.objectValue("episode")
    val parent = body.objectValue(if (target.type == MdbListItemType.MOVIE) "movie" else "show")
        ?: episode?.objectValue("show")
    val media = parent?.let(::decodeMdbListMedia)?.also {
        if (!it.ids.matches(target.media.ids)) throw MdbListDecodingException()
    }?.merged(target.media) ?: target.media
    val resolved = target.copy(
        media = media,
        season = episode?.integer("season") ?: target.season,
        episode = episode?.integer("number", "episode") ?: target.episode,
        episodeTitle = episode?.text("title", "name") ?: target.episodeTitle,
        episodeTmdbId = episode?.objectValue("ids")?.number("tmdb", "tmdbid") ?: target.episodeTmdbId,
        episodeTvdbId = episode?.objectValue("ids")?.number("tvdb", "tvdbid") ?: target.episodeTvdbId
    )
    if (resolved.type == MdbListItemType.EPISODE && (resolved.season == null || resolved.season < 0 ||
        resolved.episode == null || resolved.episode < 1)) throw MdbListDecodingException()
    val timestamp = body.timestamp("watched_at", "paused_at")
        ?: body.timestamp("started_at").takeIf { action == TrackingScrobbleAction.START }
        ?: response.header("Date")?.let {
        runCatching { Instant.fromEpochMilliseconds(it.fromHttpToGmtDate().timestamp).toString() }.getOrNull()
    } ?: Instant.fromEpochMilliseconds(nowEpochMs).toString()
    return MdbListScrobbleReceipt(resolved, action, progress, timestamp, body.number("id")?.takeIf { it > 0 })
}

/**
 * Applies a scrobble to the snapshot. A START or an incomplete STOP/PAUSE only touches the playback
 * list: [watched] stays the same instance and only playback is de-duplicated, so the caller can
 * tell playback-only changes apart by identity and update the projection incrementally. A
 * completed scrobble rewrites history and keeps the full normalisation. [mediaIndex] (the
 * published projection's) saves rebuilding the lookup from the whole history; null scans instead.
 */
internal fun MdbListSyncSnapshot.applyScrobble(
    receipt: MdbListScrobbleReceipt,
    mediaIndex: MdbListMediaIndex? = null,
): MdbListSyncSnapshot {
    val target = receipt.target
    val remainingPlayback = if (playback.any(target::matches)) playback.filterNot(target::matches) else playback
    if (receipt.action == TrackingScrobbleAction.START) {
        return if (remainingPlayback === playback) this else copy(playback = remainingPlayback)
    }
    if (!receipt.isWatched) {
        val newSession = MdbListPlayback(
            id = receipt.playbackId ?: this.playback.firstOrNull(target::matches)?.id,
            type = target.type,
            media = resolveMediaForPlayback(target.type, target.media, mediaIndex),
            progress = receipt.progress,
            updatedAt = receipt.timestamp,
            season = target.season,
            episode = target.episode,
            episodeTitle = target.episodeTitle,
            episodeTmdbId = target.episodeTmdbId,
            episodeTvdbId = target.episodeTvdbId
        )
        val normalizedPlayback = (remainingPlayback + newSession)
            .groupBy { it.id?.let { id -> "id:$id" } ?: "${it.type}:${it.media.ids.key}:${it.season}:${it.episode}" }
            .map { (_, records) -> records.maxBy { mdbListTimestamp(it.updatedAt) } }
        return copy(watched = this.watched, playback = normalizedPlayback)
    }
    val watched = this.watched.filterNot(target::matches) + target.watched(receipt.timestamp)
    return copy(watched = watched, playback = remainingPlayback).normalizeMedia()
}

private fun MdbListSyncSnapshot.resolveMediaForPlayback(
    type: MdbListItemType,
    media: MdbListMedia,
    mediaIndex: MdbListMediaIndex?,
): MdbListMedia {
    val aliases = media.ids.aliases()
    if (aliases.isEmpty()) return media
    val isMovie = type == MdbListItemType.MOVIE
    var merged = mediaIndex?.resolveMedia(type, media) ?: run {
        var acc = media
        watched.forEach { record ->
            if ((record.type == MdbListItemType.MOVIE) == isMovie && record.media.ids.aliases().any { it in aliases }) {
                acc = acc.merged(record.media)
            }
        }
        acc
    }
    playback.forEach { record ->
        if ((record.type == MdbListItemType.MOVIE) == isMovie && record.media.ids.aliases().any { it in aliases }) {
            merged = merged.merged(record.media)
        }
    }
    return merged
}
