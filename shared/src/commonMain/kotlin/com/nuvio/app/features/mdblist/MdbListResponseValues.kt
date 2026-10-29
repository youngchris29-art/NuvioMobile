package com.nuvio.app.features.mdblist

import com.nuvio.app.core.util.daysInMonth
import com.nuvio.app.core.util.daysSinceEpoch
import com.nuvio.app.core.util.decimalAt
import com.nuvio.app.core.util.fractionMillisAt
import kotlin.time.Instant
import kotlinx.serialization.json.Json
import kotlinx.serialization.json.JsonArray
import kotlinx.serialization.json.JsonElement
import kotlinx.serialization.json.JsonNull
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.JsonPrimitive
import kotlinx.serialization.json.booleanOrNull
import kotlinx.serialization.json.contentOrNull

internal fun mdbListResponseElement(body: String): JsonElement =
    runCatching { Json.parseToJsonElement(body) }.getOrElse { throw MdbListDecodingException() }

internal fun JsonElement.objectValue(): JsonObject = this as? JsonObject ?: throw MdbListDecodingException()
internal fun JsonObject.objectValue(name: String): JsonObject? = when (val value = get(name)) {
    null, JsonNull -> null
    else -> value.objectValue()
}

internal fun JsonObject.arrayValue(name: String): JsonArray = when (val value = get(name)) {
    null, JsonNull -> JsonArray(emptyList())
    is JsonArray -> value
    else -> throw MdbListDecodingException()
}

internal fun JsonObject.text(vararg names: String): String? = names.firstNotNullOfOrNull { name ->
    (get(name) as? JsonPrimitive)?.contentOrNull?.trim()?.takeIf(String::isNotBlank)
}

internal fun JsonObject.number(vararg names: String): Long? = text(*names)?.toLongOrNull()
internal fun JsonObject.integer(vararg names: String): Int? = number(*names)
    ?.takeIf { it in Int.MIN_VALUE.toLong()..Int.MAX_VALUE.toLong() }?.toInt()
internal fun JsonObject.flag(name: String): Boolean? = (get(name) as? JsonPrimitive)?.booleanOrNull

private val MdbListLocalTimestamp = Regex(
    """^(\d{4}-\d{2}-\d{2}) (\d{2}:\d{2}:\d{2})(?:\.(\d{1,9}))?$""",
)

internal fun mdbListTimestamp(value: String): Long =
    parseMdbListTimestampFast(value) ?: parseMdbListTimestampSlow(value)

// The original chain, kept as the fallback so any input the fast path does not recognise behaves
// exactly as before (including the exceptions it raised).
private fun parseMdbListTimestampSlow(value: String): Long = runCatching { Instant.parse(value).toEpochMilliseconds() }
    .recoverCatching { Instant.parse(mdbListUtcInstant(value)).toEpochMilliseconds() }
    .getOrElse { throw MdbListDecodingException() }

/**
 * Fixed-position parser for the two shapes MDBList actually sends: `YYYY-MM-DDTHH:MM:SS[.f]Z` (or a
 * `±HH:MM` offset) and the zone-less `YYYY-MM-DD HH:MM:SS[.f]` read as UTC. Returns null for
 * anything else (lowercase separators, `+HHMM` offsets, leap seconds, bad calendar fields) so the
 * slow path decides. NuvioTV 07e041bee.
 */
private fun parseMdbListTimestampFast(text: String): Long? {
    val length = text.length
    if (length < MDBLIST_TIMESTAMP_MIN_LENGTH) return null
    if (text[4] != '-' || text[7] != '-' || text[13] != ':' || text[16] != ':') return null
    val separator = text[10]
    if (separator != ' ' && separator != 'T') return null
    val year = decimalAt(text, 0, 4)
    val month = decimalAt(text, 5, 2)
    val day = decimalAt(text, 8, 2)
    val hour = decimalAt(text, 11, 2)
    val minute = decimalAt(text, 14, 2)
    val second = decimalAt(text, 17, 2)
    if (year < 1 || month !in 1..12 || day < 1) return null
    if (hour !in 0..23 || minute !in 0..59 || second !in 0..59) return null
    if (day > daysInMonth(year, month)) return null
    var index = MDBLIST_TIMESTAMP_MIN_LENGTH
    var millis = 0
    if (index < length && text[index] == '.') {
        val fractionStart = index + 1
        var fractionEnd = fractionStart
        while (fractionEnd < length && text[fractionEnd] in '0'..'9') fractionEnd++
        if (fractionEnd - fractionStart !in 1..9) return null
        millis = fractionMillisAt(text, fractionStart, fractionEnd)
        if (millis < 0) return null
        index = fractionEnd
    }
    val offsetSeconds = when {
        index == length -> if (separator == ' ') 0L else return null
        separator == ' ' -> return null
        text[index] == 'Z' -> {
            if (index != length - 1) return null
            0L
        }
        text[index] == '+' || text[index] == '-' -> {
            if (length - index != 6 || text[index + 3] != ':') return null
            val zoneHour = decimalAt(text, index + 1, 2)
            val zoneMinute = decimalAt(text, index + 4, 2)
            if (zoneHour < 0 || zoneMinute < 0 || zoneMinute > 59) return null
            if (zoneHour > 18 || (zoneHour == 18 && zoneMinute != 0)) return null
            val magnitude = zoneHour * 3_600L + zoneMinute * 60L
            if (text[index] == '-') -magnitude else magnitude
        }
        else -> return null
    }
    val localSeconds = daysSinceEpoch(year, month, day) * 86_400L + hour * 3_600L + minute * 60L + second
    return (localSeconds - offsetSeconds) * 1_000L + millis
}

private const val MDBLIST_TIMESTAMP_MIN_LENGTH = 19

internal fun String.isMdbListImdbId(): Boolean {
    if (length < 3 || this[0] != 't' || this[1] != 't') return false
    for (index in 2 until length) {
        if (this[index] !in '0'..'9') return false
    }
    return true
}

private fun mdbListUtcInstant(value: String): String {
    val match = MdbListLocalTimestamp.matchEntire(value.trim()) ?: throw MdbListDecodingException()
    val fraction = match.groupValues[3]
    val fractionPart = if (fraction.isEmpty()) "" else ".${fraction.padEnd(9, '0')}"
    return "${match.groupValues[1]}T${match.groupValues[2]}${fractionPart}Z"
}

internal fun JsonObject.timestamp(vararg names: String): String? = text(*names)?.also(::mdbListTimestamp)

internal fun decodeMdbListIds(value: JsonObject): MdbListIds {
    val ids = value.objectValue("ids") ?: value
    return MdbListIds(
        imdb = ids.text("imdb", "imdbid")?.takeIf(String::isMdbListImdbId),
        tmdb = ids.number("tmdb", "tmdbid")?.takeIf { it > 0L },
        tvdb = ids.number("tvdb", "tvdbid")?.takeIf { it > 0L },
        trakt = ids.number("trakt", "traktid")?.takeIf { it > 0L },
        mdblist = ids.text("mdblist")
    ).also { it.key }
}

internal fun decodeMdbListMedia(value: JsonObject): MdbListMedia = MdbListMedia(
    ids = decodeMdbListIds(value),
    title = value.text("title", "name"),
    year = value.integer("year"),
    poster = mdbListImageUrl(value.text("poster"), "w500"),
    backdrop = mdbListImageUrl(value.text("backdrop", "background"), "w1280"),
    runtimeMinutes = value.number("runtime")?.takeIf { it in 1..Int.MAX_VALUE }?.toInt()
)

internal fun mdbListImageUrl(value: String?, size: String): String? = when {
    value == null -> null
    value.startsWith("https://") || value.startsWith("http://") -> value
    value.startsWith('/') && !value.startsWith("//") -> "https://image.tmdb.org/t/p/$size$value"
    else -> null
}

internal fun <T> mdbListPage(value: JsonObject, items: List<T>): MdbListPage<T> {
    val pagination = value.objectValue("pagination") ?: value
    val cursor = pagination.text("next_cursor")
    val offset = pagination.number("offset")
    val limit = pagination.number("limit")
    val total = pagination.number("total")
    val hasMore = pagination.flag("has_more") ?: if (offset != null && limit != null && total != null) {
        offset + limit < total
    } else false
    val nextOffset = if (hasMore == true && cursor == null) {
        if (offset == null || offset < 0L || limit == null || limit < 1L || offset + limit > Int.MAX_VALUE) {
            throw MdbListDecodingException()
        }
        (offset + limit).toInt()
    } else null
    return MdbListPage(items, cursor, nextOffset, value.timestamp("server_time"))
}
