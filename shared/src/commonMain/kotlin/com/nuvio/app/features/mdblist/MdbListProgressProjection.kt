package com.nuvio.app.features.mdblist

import com.nuvio.app.features.tracking.parseTrackingExternalIds
import com.nuvio.app.features.trakt.EpisodeMappingEntry
import com.nuvio.app.features.watched.WatchedItem
import com.nuvio.app.features.watched.watchedItemKeys
import com.nuvio.app.features.watchprogress.WatchProgressEntry
import com.nuvio.app.features.watchprogress.buildPlaybackVideoId

/**
 * Read model derived from an [MdbListSyncSnapshot]. A scrobble only rewrites the playback list, so
 * [withUpdatedPlayback] rebuilds just the playback-derived parts (progress, show siblings, and
 * the dropped-show lookup when the media index learned new aliases) and shares everything derived
 * from the watched history and the dropped list with the previous projection (NuvioTV 63719770f,
 * 82886dac9). The result is observably the same as `MdbListProgressProjection(snapshot)` for the
 * snapshot that carries [newPlayback]; `MdbListProgressProjectionIncrementalTest` pins that.
 */
internal class MdbListProgressProjection private constructor(
    private val baseIndex: MdbListMediaIndex,
    internal val mediaIndex: MdbListMediaIndex,
    private val dropped: List<MdbListDroppedRecord>,
    private val droppedById: Map<String, List<Int?>>,
    private val historyByKey: Map<String, MdbListWatchedRecord>,
    private val watched: List<MdbListWatchedRecord>,
    val watchedItems: List<WatchedItem>,
    val watchedKeys: Set<String>,
    val hiddenContentIds: Set<String>,
    private val watchedShowIdSiblings: Map<String, Set<String>>,
    val showIdSiblings: Map<String, Set<String>>,
    val progress: List<WatchProgressEntry>,
    val nextUpSeeds: List<WatchProgressEntry>,
) {
    fun withUpdatedPlayback(newPlayback: List<MdbListPlayback>): MdbListProgressProjection {
        // Always layered on the watched-only base so aliases taught by a session that has since
        // been removed (START, clear) do not linger in the index.
        val newIndex = baseIndex.withPlayback(newPlayback)
        val rebuiltDropped = if (newIndex === mediaIndex || dropped.isEmpty()) droppedById else buildDroppedById(dropped, newIndex)
        val droppedChanged = rebuiltDropped != droppedById
        val newDroppedById = if (droppedChanged) rebuiltDropped else droppedById
        return MdbListProgressProjection(
            baseIndex = baseIndex,
            mediaIndex = newIndex,
            dropped = dropped,
            droppedById = newDroppedById,
            historyByKey = historyByKey,
            watched = watched,
            watchedItems = watchedItems,
            watchedKeys = watchedKeys,
            hiddenContentIds = if (droppedChanged) hiddenContentIdsOf(newDroppedById) else hiddenContentIds,
            watchedShowIdSiblings = watchedShowIdSiblings,
            showIdSiblings = buildShowIdSiblings(watchedShowIdSiblings, newPlayback),
            progress = buildProgress(newPlayback, historyByKey, newDroppedById),
            nextUpSeeds = if (droppedChanged) buildNextUpSeeds(watched, newDroppedById) else nextUpSeeds,
        )
    }

    fun isHidden(contentId: String, season: Int? = null): Boolean = isDropped(droppedById, contentId, season)

    fun canonicalContentId(contentId: String): String? =
        runCatching {
            val ids = parseTrackingExternalIds(contentId).toMdbListIds() ?: return null
            mediaIndex.resolve(MdbListItemType.SHOW, ids).ids.contentId
        }.getOrNull()

    /** The TMDB show id MDBList reported for [contentId], when the history or playback holds one. */
    fun tmdbShowId(contentId: String): Long? = showIds(contentId)?.tmdb

    /** Every id MDBList files the show behind [contentId] under, merged with [contentId]'s own. */
    fun showAliases(contentId: String): Set<String> = showIds(contentId)?.aliases().orEmpty()

    private fun showIds(contentId: String): MdbListIds? =
        parseTrackingExternalIds(contentId).toMdbListIds()?.let { mediaIndex.resolve(MdbListItemType.SHOW, it).ids }

    // ── Add-on numbering (upstream facf25ec3) ──────────────────────────────────────────────────
    // MDBList numbers episodes as TMDB does; the add-on an episode plays from may split the show
    // into seasons differently. These views hand out the projection's episode rows in the add-on's
    // numbering through [mappingFor], the mapping already resolved for a show (null: unresolved
    // or no remap needed, so the row keeps its numbers).

    /** [progress] and [nextUpSeeds] with each episode moved to the add-on's numbering. */
    fun entriesInAddonNumbering(mappingFor: (contentId: String) -> MdbListEpisodeMapping?): List<WatchProgressEntry> =
        (progress + nextUpSeeds).map { entry ->
            val season = entry.seasonNumber ?: return@map entry
            val episode = entry.episodeNumber ?: return@map entry
            val addon = mappingFor(entry.parentMetaId)?.toAddon(season, episode) ?: return@map entry
            entry.withAddonEpisode(addon)
        }

    /** [watchedItems] with each episode moved to the add-on's numbering. */
    fun watchedItemsInAddonNumbering(mappingFor: (contentId: String) -> MdbListEpisodeMapping?): List<WatchedItem> =
        watchedItems.map { item ->
            val season = item.season ?: return@map item
            val episode = item.episode ?: return@map item
            val addon = mappingFor(item.id)?.toAddon(season, episode) ?: return@map item
            item.copy(
                season = addon.season,
                episode = addon.episode,
                videoId = addon.videoId ?: buildPlaybackVideoId(item.id, addon.season, addon.episode),
            )
        }

    /**
     * [watchedKeys] with every remapped show's episode keys in the add-on's numbering. The TMDB
     * keys of a remapped show are dropped, not kept: TMDB S1E35 would otherwise tick the add-on's
     * own S1E35, a different episode.
     */
    fun watchedKeysInAddonNumbering(mappingFor: (contentId: String) -> MdbListEpisodeMapping?): Set<String> {
        val remapped = watched.asSequence()
            .filter { it.type == MdbListItemType.EPISODE && it.season != null && it.episode != null }
            .mapNotNull { record -> mappingFor(record.media.ids.contentId)?.takeIf { it.remaps }?.let { record to it } }
            .toList()
        if (remapped.isEmpty()) return watchedKeys
        val keys = linkedSetOf<String>()
        val remappedRecords = remapped.mapTo(HashSet()) { it.first }
        for (record in watched) {
            if (record.type !in setOf(MdbListItemType.MOVIE, MdbListItemType.EPISODE)) continue
            if (record in remappedRecords) continue
            record.media.ids.aliases().flatMapTo(keys) { id ->
                watchedItemKeys(record.type.contentType, id, record.season, record.episode)
            }
        }
        for ((record, mapping) in remapped) {
            val addon = mapping.toAddon(record.season!!, record.episode!!) ?: continue
            record.media.ids.aliases().flatMapTo(keys) { id ->
                watchedItemKeys(record.type.contentType, id, addon.season, addon.episode)
            }
        }
        return keys
    }

    companion object {
        const val COMPLETION_PERCENT = 80f
        val Empty = MdbListProgressProjection(MdbListSyncSnapshot(0))

        operator fun invoke(snapshot: MdbListSyncSnapshot): MdbListProgressProjection {
            val baseIndex = MdbListMediaIndex.watchedOnly(snapshot.watched)
            val mediaIndex = baseIndex.withPlayback(snapshot.playback)
            val droppedById = buildDroppedById(snapshot.dropped, mediaIndex)
            val historyByKey = snapshot.watched.associateBy(MdbListWatchedRecord::key)
            val watchedItems = snapshot.watched.filter { it.type in setOf(MdbListItemType.MOVIE, MdbListItemType.EPISODE) }
                .map { record ->
                    WatchedItem(
                        id = record.media.ids.contentId,
                        type = record.type.contentType,
                        name = record.media.title ?: record.media.ids.contentId,
                        season = record.season,
                        episode = record.episode,
                        videoId = videoId(record.media, record.season, record.episode),
                        markedAtEpochMs = mdbListTimestamp(record.watchedAt),
                        poster = record.media.poster,
                        releaseInfo = record.media.year?.toString(),
                        trackingProviderId = "mdblist",
                        trackingProviderItemId = record.media.ids.mdblist?.let { "mdblist:$it" },
                        trackingSourceUrl = record.media.sourceUrl(record.type),
                    )
                }.sortedByDescending(WatchedItem::markedAtEpochMs)
            val watchedKeys = snapshot.watched.flatMapTo(linkedSetOf()) { record ->
                if (record.type !in setOf(MdbListItemType.MOVIE, MdbListItemType.EPISODE)) emptySet()
                else record.media.ids.aliases().flatMap { id ->
                    watchedItemKeys(record.type.contentType, id, record.season, record.episode)
                }
            }
            val watchedShowIdSiblings = buildMap<String, Set<String>> {
                for (record in snapshot.watched) {
                    if (record.type == MdbListItemType.MOVIE) continue
                    val aliases = record.media.ids.aliases()
                    for (alias in aliases) put(alias, aliases)
                }
            }
            return MdbListProgressProjection(
                baseIndex = baseIndex,
                mediaIndex = mediaIndex,
                dropped = snapshot.dropped,
                droppedById = droppedById,
                historyByKey = historyByKey,
                watched = snapshot.watched,
                watchedItems = watchedItems,
                watchedKeys = watchedKeys,
                hiddenContentIds = hiddenContentIdsOf(droppedById),
                watchedShowIdSiblings = watchedShowIdSiblings,
                showIdSiblings = buildShowIdSiblings(watchedShowIdSiblings, snapshot.playback),
                progress = buildProgress(snapshot.playback, historyByKey, droppedById),
                nextUpSeeds = buildNextUpSeeds(snapshot.watched, droppedById),
            )
        }

        private fun buildDroppedById(
            dropped: List<MdbListDroppedRecord>,
            mediaIndex: MdbListMediaIndex,
        ): Map<String, List<Int?>> = dropped.flatMap { record ->
            mediaIndex.resolve(MdbListItemType.SHOW, record.ids).ids.aliases().map { it to record.season }
        }.groupBy({ it.first }, { it.second })

        private fun hiddenContentIdsOf(droppedById: Map<String, List<Int?>>): Set<String> =
            droppedById.filterValues { null in it }.keys

        private fun isDropped(droppedById: Map<String, List<Int?>>, contentId: String, season: Int? = null): Boolean =
            droppedById[contentId]?.any { it == null || (season != null && it == season) } == true

        // Later entries win, so a playback session's alias set overrides a watched record's for the
        // same alias, exactly as the original `(watched + playback).flatMap { ... }.toMap()`.
        private fun buildShowIdSiblings(
            watchedShowIdSiblings: Map<String, Set<String>>,
            playback: List<MdbListPlayback>,
        ): Map<String, Set<String>> {
            if (playback.none { it.type != MdbListItemType.MOVIE }) return watchedShowIdSiblings
            return watchedShowIdSiblings.toMutableMap().apply {
                for (session in playback) {
                    if (session.type == MdbListItemType.MOVIE) continue
                    val aliases = session.media.ids.aliases()
                    for (alias in aliases) put(alias, aliases)
                }
            }
        }

        private fun buildProgress(
            playback: List<MdbListPlayback>,
            historyByKey: Map<String, MdbListWatchedRecord>,
            droppedById: Map<String, List<Int?>>,
        ): List<WatchProgressEntry> = playback.filter { session ->
            val watched = historyByKey["${session.type}:${session.media.ids.key}:${session.season ?: -1}:${session.episode ?: -1}"]
            session.progress < COMPLETION_PERCENT && !isDropped(droppedById, session.media.ids.contentId, session.season) &&
                (watched == null || mdbListTimestamp(session.updatedAt) > mdbListTimestamp(watched.watchedAt))
        }.map { session ->
            entry(session.type, session.media, session.season, session.episode, session.episodeTitle,
                session.progress, session.updatedAt, session.runtimeMinutes, "mdblist_playback", droppedById)
        }.groupBy { Triple(it.parentMetaId, it.seasonNumber, it.episodeNumber) }
            .map { (_, entries) -> entries.maxBy(WatchProgressEntry::lastUpdatedEpochMs) }
            .sortedByDescending(WatchProgressEntry::lastUpdatedEpochMs)

        private fun buildNextUpSeeds(
            watched: List<MdbListWatchedRecord>,
            droppedById: Map<String, List<Int?>>,
        ): List<WatchProgressEntry> = watched.filter { record ->
            record.type == MdbListItemType.EPISODE && record.season != null && record.season > 0 &&
                !isDropped(droppedById, record.media.ids.contentId)
        }.map { record ->
            entry(record.type, record.media, record.season, record.episode, record.episodeTitle,
                100f, record.watchedAt, null, "mdblist_history", droppedById)
        }

        private fun entry(
            type: MdbListItemType,
            media: MdbListMedia,
            season: Int?,
            episode: Int?,
            episodeTitle: String?,
            percent: Float,
            timestamp: String,
            runtime: Int?,
            source: String,
            droppedById: Map<String, List<Int?>>,
        ): WatchProgressEntry {
            val duration = (runtime ?: media.runtimeMinutes ?: 0).toLong() * 60_000L
            return WatchProgressEntry(
                contentType = type.contentType,
                parentMetaId = media.ids.contentId,
                parentMetaType = type.contentType,
                title = media.title ?: media.ids.contentId,
                poster = media.poster,
                background = media.backdrop,
                videoId = videoId(media, season, episode),
                seasonNumber = season,
                episodeNumber = episode,
                episodeTitle = episodeTitle,
                lastPositionMs = (duration * percent.toDouble() / 100.0).toLong(),
                durationMs = duration,
                lastUpdatedEpochMs = mdbListTimestamp(timestamp),
                progressPercent = percent,
                isCompleted = percent >= COMPLETION_PERCENT,
                source = source,
                trackingProviderId = "mdblist",
                trackingProviderItemId = media.ids.mdblist?.let { "mdblist:$it" },
                trackingSourceUrl = media.sourceUrl(type),
                excludedNextUpSeasons = droppedById[media.ids.contentId].orEmpty().filterNotNull().toSet(),
            )
        }

        private fun videoId(media: MdbListMedia, season: Int?, episode: Int?): String =
            com.nuvio.app.features.watchprogress.buildPlaybackVideoId(media.ids.contentId, season, episode)
    }
}

/** [this] moved to the add-on's episode [addon]; the video id follows so local playback rows match. */
internal fun WatchProgressEntry.withAddonEpisode(addon: EpisodeMappingEntry): WatchProgressEntry = copy(
    seasonNumber = addon.season,
    episodeNumber = addon.episode,
    videoId = addon.videoId ?: buildPlaybackVideoId(parentMetaId, addon.season, addon.episode),
    episodeTitle = episodeTitle ?: addon.title,
)

internal val MdbListItemType.contentType: String
    get() = if (this == MdbListItemType.MOVIE) "movie" else "series"

private val MdbListSlug = Regex("[A-Za-z0-9_-]+")

internal fun MdbListMedia.sourceUrl(type: MdbListItemType): String? =
    ids.mdblist?.takeIf { it.matches(MdbListSlug) }
        ?.let { "https://mdblist.com/${if (type == MdbListItemType.MOVIE) "movie" else "show"}/$it" }
