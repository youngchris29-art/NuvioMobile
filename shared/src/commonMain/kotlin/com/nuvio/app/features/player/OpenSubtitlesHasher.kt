package com.nuvio.app.features.player

import com.nuvio.app.features.addons.RawHttpResponse
import com.nuvio.app.features.addons.httpRequestRaw
import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.withTimeoutOrNull

/**
 * OpenSubtitles file hash of a remote video (upstream 1aacf178 / 843e9e77):
 * `fileSize + sum(first 64 KiB as LE uint64) + sum(last 64 KiB as LE uint64)`, mod 2^64,
 * printed as 16 lowercase hex digits.
 *
 * Two HTTP range GETs, no HEAD: the first range's `Content-Range` total gives the file size.
 * Returns null — never throws, except cancellation — when the server does not answer 206, the
 * file is under 128 KiB, a chunk is short, or the whole thing exceeds [DEFAULT_TIMEOUT_MS].
 *
 * @see <a href="https://trac.opensubtitles.org/projects/opensubtitles/wiki/HashSourceCodes">
 *     OpenSubtitles hash algorithm</a>
 */
internal object OpenSubtitlesHasher {
    const val CHUNK_SIZE = 65536
    const val DEFAULT_TIMEOUT_MS = 8_000L

    data class Result(val hash: String, val fileSize: Long)

    /** One HTTP GET; a seam so tests can stand in for the network. */
    fun interface RangeFetcher {
        suspend fun get(url: String, headers: Map<String, String>): RawHttpResponse
    }

    private val networkFetcher = RangeFetcher { url, headers ->
        httpRequestRaw(
            method = "GET",
            url = url,
            headers = headers,
            body = "",
            followRedirects = true,
            maxResponseBodyBytes = CHUNK_SIZE,
        )
    }

    suspend fun compute(
        url: String,
        headers: Map<String, String> = emptyMap(),
        timeoutMs: Long = DEFAULT_TIMEOUT_MS,
        fetcher: RangeFetcher = networkFetcher,
    ): Result? = try {
        withTimeoutOrNull(timeoutMs) { computeUnbounded(url, headers, fetcher) }
    } catch (e: CancellationException) {
        throw e
    } catch (_: Throwable) {
        null
    }

    private suspend fun computeUnbounded(
        url: String,
        headers: Map<String, String>,
        fetcher: RangeFetcher,
    ): Result? {
        val baseHeaders = headers.filterKeys {
            !it.equals("Range", ignoreCase = true) && !it.equals("Accept-Encoding", ignoreCase = true)
        } + ("Accept-Encoding" to "identity")

        val head = fetcher.get(url, baseHeaders + ("Range" to "bytes=0-${CHUNK_SIZE - 1}"))
        if (head.status != 206) return null
        val headRange = parseContentRange(head.header("content-range")) ?: return null
        if (headRange.start != 0L) return null
        val fileSize = headRange.total ?: return null
        if (fileSize < 2L * CHUNK_SIZE) return null
        val headBytes = head.bodyBytes.takeIf { it.size == CHUNK_SIZE } ?: return null

        val tailStart = fileSize - CHUNK_SIZE
        val tail = fetcher.get(url, baseHeaders + ("Range" to "bytes=$tailStart-${fileSize - 1}"))
        if (tail.status != 206) return null
        val tailRange = parseContentRange(tail.header("content-range"))
        if (tailRange != null && (tailRange.start != tailStart || (tailRange.total != null && tailRange.total != fileSize))) {
            return null
        }
        val tailBytes = tail.bodyBytes.takeIf { it.size == CHUNK_SIZE } ?: return null

        val hash = hashOf(fileSize, headBytes, tailBytes) ?: return null
        return Result(hash = hash, fileSize = fileSize)
    }

    /** The pure OpenSubtitles arithmetic. Null when the inputs can't describe a valid file. */
    fun hashOf(fileSize: Long, head: ByteArray, tail: ByteArray): String? {
        if (fileSize < 2L * CHUNK_SIZE || head.size != CHUNK_SIZE || tail.size != CHUNK_SIZE) return null
        val sum = fileSize + head.sumLittleEndianLongs() + tail.sumLittleEndianLongs()
        return sum.toULong().toString(16).padStart(16, '0')
    }

    data class ContentRange(val start: Long, val end: Long, val total: Long?)

    /** Parses `bytes START-END/TOTAL` (TOTAL may be `*`). Null when malformed. */
    fun parseContentRange(value: String?): ContentRange? {
        val trimmed = value?.trim() ?: return null
        if (!trimmed.startsWith("bytes", ignoreCase = true)) return null
        val spec = trimmed.substring(5).trim()
        val range = spec.substringBefore('/', "").trim()
        val totalText = spec.substringAfter('/', "").trim()
        if (range.isEmpty() || totalText.isEmpty()) return null
        val start = range.substringBefore('-', "").trim().toLongOrNull() ?: return null
        val end = range.substringAfter('-', "").trim().toLongOrNull() ?: return null
        if (start < 0 || end < start) return null
        val total = if (totalText == "*") null else (totalText.toLongOrNull() ?: return null)
        if (total != null && end >= total) return null
        return ContentRange(start = start, end = end, total = total)
    }

    private fun RawHttpResponse.header(name: String): String? =
        headers[name] ?: headers.entries.firstOrNull { it.key.equals(name, ignoreCase = true) }?.value

    private fun ByteArray.sumLittleEndianLongs(): Long {
        var sum = 0L
        var offset = 0
        while (offset + 8 <= size) {
            var value = 0L
            for (i in 0 until 8) {
                value = value or ((this[offset + i].toLong() and 0xFF) shl (i * 8))
            }
            sum += value
            offset += 8
        }
        return sum
    }
}
