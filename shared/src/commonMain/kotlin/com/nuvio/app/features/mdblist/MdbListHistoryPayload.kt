package com.nuvio.app.features.mdblist

import co.touchlab.kermit.Logger
import kotlinx.serialization.json.JsonArray
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.buildJsonObject
import kotlinx.serialization.json.put

internal data class MdbListHistoryChange(val target: MdbListMutationTarget, val watchedAt: String?)

private val log = Logger.withTag("MdbListHistory")

internal fun mdbListHistoryPayload(changes: List<MdbListHistoryChange>): String = buildJsonObject {
    val groups = changes.groupBy { change ->
        when {
            change.target.type == MdbListItemType.MOVIE -> "movies"
            change.target.type == MdbListItemType.EPISODE &&
                (change.target.episodeTmdbId != null || change.target.episodeTvdbId != null) -> "episodes"
            else -> "shows"
        }
    }
    groups.forEach { (group, items) ->
        put(group, JsonArray(items.map { change ->
            val target = change.target
            buildJsonObject {
                put("ids", if (group == "episodes") buildJsonObject {
                    target.episodeTmdbId?.let { put("tmdb", it) }
                    target.episodeTvdbId?.let { put("tvdb", it) }
                } else target.media.ids.requestIds())
                if (group == "shows" && target.type == MdbListItemType.EPISODE) {
                    put("seasons", JsonArray(listOf(buildJsonObject {
                        put("number", requireNotNull(target.season))
                        put("episodes", JsonArray(listOf(buildJsonObject {
                            put("number", requireNotNull(target.episode))
                            change.watchedAt?.let { put("watched_at", it) }
                        })))
                    })))
                } else change.watchedAt?.let { put("watched_at", it) }
            }
        }))
    }
}.toString()

internal data class MdbListHistoryReceipt(
    val confirmed: List<MdbListWatchedRecord>,
    val complete: Boolean,
    val needsSnapshot: Boolean,
    val notFoundCount: Int
)

internal fun decodeMdbListHistoryReceipt(
    body: String,
    changes: List<MdbListHistoryChange>,
    remove: Boolean
): MdbListHistoryReceipt {
    val payload = mdbListResponseElement(body).objectValue()
    val counts = payload.objectValue(if (remove) "deleted" else "updated")
        ?: (if (remove) payload.objectValue("removed") else null)
        ?: throw MdbListDecodingException()
    val failures = payload.objectValue("not_found")?.values.orEmpty().sumOf { value ->
        when (value) {
            is JsonArray -> value.size
            else -> value.toString().toIntOrNull()?.coerceAtLeast(0) ?: throw MdbListDecodingException()
        }
    }
    val errors = payload.arrayValue("errors").size
    val complete = failures == 0 && errors == 0 && changes.groupingBy { it.target.type }.eachCount().all { (type, requested) ->
        (counts.integer("${type.name.lowercase()}s") ?: 0) >= requested
    }
    // An echoed play MDBList reports in a shape or numbering the matcher cannot pair with a requested
    // target (an episode echoed in MDBList's own season numbering, a malformed row) is skipped, not a
    // failure: the write already succeeded (2xx with counts), so failing the whole mutation here would
    // leave the mark dirty forever. The skipped plays are logged, the counts decide confirmation as
    // they already do for receipts without plays, and a snapshot refresh reconciles MDBList's view.
    val echoed = if (remove) emptyList() else payload.arrayValue("plays").map { element ->
        try {
            decodePlay(element.objectValue(), changes)
        } catch (e: MdbListDecodingException) {
            // Malformed ids, timestamps or nesting inside one echoed play: skip that play alone.
            log.i { "Skipped an undecodable echoed MDBList play: keys=${(element as? JsonObject)?.keys?.sorted()}" }
            null
        }
    }
    val plays = echoed.filterNotNull()
    val skippedPlays = echoed.size - plays.size
    val confirmed = when {
        // Complete counts back every requested item, echoed or not: keep what paired, add the rest.
        complete && !remove -> plays + changes
            .filter { change -> change.target.type != MdbListItemType.SHOW && plays.none { change.target.matches(it) } }
            .map { it.target.watched(requireNotNull(it.watchedAt)) }
        else -> plays
    }
    val hasExpansion = changes.any { it.target.type == MdbListItemType.SHOW }
    return MdbListHistoryReceipt(
        confirmed = confirmed,
        complete = complete,
        needsSnapshot = !complete || hasExpansion || skippedPlays > 0 || confirmed.size != changes.size && !remove,
        notFoundCount = if (complete) 0 else maxOf(failures, errors, changes.size - confirmed.size, 1)
    )
}

/** The echoed play paired with the change that requested it, or null when MDBList's echo cannot be used. */
private fun decodePlay(row: JsonObject, changes: List<MdbListHistoryChange>): MdbListWatchedRecord? {
    val type = when (row.text("type")) {
        "movie" -> MdbListItemType.MOVIE
        "episode" -> MdbListItemType.EPISODE
        else -> return skipPlay(row, "unknown type")
    }
    val idsRow = if (type == MdbListItemType.MOVIE) row else row.objectValue("show") ?: return skipPlay(row, "episode without a show")
    val ids = decodeMdbListIds(idsRow)
    val season = if (type == MdbListItemType.EPISODE) row.integer("season")?.takeIf { it >= 0 } ?: return skipPlay(row, "episode without a season") else null
    val episode = if (type == MdbListItemType.EPISODE) row.integer("number", "episode")?.takeIf { it > 0 } ?: return skipPlay(row, "episode without a number") else null
    val watchedAt = row.timestamp("watched_at") ?: return skipPlay(row, "no watched_at")
    val record = MdbListWatchedRecord(
        type, MdbListMedia(ids), watchedAt, season, episode,
        episodeTmdbId = row.objectValue("ids")?.number("tmdb").takeIf { type == MdbListItemType.EPISODE },
        episodeTvdbId = row.objectValue("ids")?.number("tvdb").takeIf { type == MdbListItemType.EPISODE }
    )
    val requested = changes.firstOrNull { it.target.matches(record) }?.target
        ?: changes.firstOrNull { it.target.type == MdbListItemType.SHOW && it.target.media.ids.matches(ids) }?.target
        ?: return skipPlay(row, "matches no requested item")
    return record.copy(media = record.media.merged(requested.media), episodeTitle = requested.episodeTitle)
}

/** Logs an echoed play the receipt cannot use (ids, coordinates and key names only) and never throws. */
private fun skipPlay(row: JsonObject, reason: String): MdbListWatchedRecord? {
    log.i {
        val show = row["show"] as? JsonObject
        val ids = show?.get("ids") as? JsonObject
        "Skipped an echoed MDBList play ($reason): type=${row["type"]} " +
            "show=${ids?.get("imdb") ?: show?.get("imdb") ?: ids?.get("tmdb")?.let { "tmdb:$it" }} " +
            "season=${row["season"]} number=${row["number"] ?: row["episode"]} keys=${row.keys.sorted()}"
    }
    return null
}
