package com.nuvio.app.features.player

import com.nuvio.app.features.addons.RawHttpResponse
import kotlinx.coroutines.delay
import kotlinx.coroutines.test.runTest
import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertNull

class OpenSubtitlesHasherTest {
    private val chunk = OpenSubtitlesHasher.CHUNK_SIZE

    // Deterministic chunks; expected values computed independently (Python struct '<Q' sums).
    private val head = ByteArray(chunk) { ((it * 7 + 3) and 0xFF).toByte() }
    private val tail = ByteArray(chunk) { ((it * 13 + 5) and 0xFF).toByte() }

    @Test
    fun zeroChunksHashToTheFileSize() {
        // The "breakdance.avi" sample's size (12909756); its real bytes aren't available here.
        assertEquals("0000000000c4fcbc", OpenSubtitlesHasher.hashOf(12_909_756L, ByteArray(chunk), ByteArray(chunk)))
    }

    @Test
    fun sumsLittleEndianWordsPlusSize() {
        assertEquals("20a01fa02064fcbc", OpenSubtitlesHasher.hashOf(12_909_756L, head, tail))
    }

    @Test
    fun sumWrapsModulo2To64() {
        val ones = ByteArray(chunk) { 0xFF.toByte() }
        assertEquals("00000000000fc000", OpenSubtitlesHasher.hashOf(1L shl 20, ones, ones))
    }

    @Test
    fun rejectsSmallFilesAndShortChunks() {
        assertNull(OpenSubtitlesHasher.hashOf(2L * chunk - 1, ByteArray(chunk), ByteArray(chunk)))
        assertNull(OpenSubtitlesHasher.hashOf(1_000_000L, ByteArray(chunk - 1), ByteArray(chunk)))
    }

    @Test
    fun parsesContentRange() {
        assertEquals(
            OpenSubtitlesHasher.ContentRange(0, 65535, 12_909_756L),
            OpenSubtitlesHasher.parseContentRange("bytes 0-65535/12909756"),
        )
        assertEquals(OpenSubtitlesHasher.ContentRange(5, 9, null), OpenSubtitlesHasher.parseContentRange("bytes 5-9/*"))
        assertNull(OpenSubtitlesHasher.parseContentRange(null))
        assertNull(OpenSubtitlesHasher.parseContentRange("bytes */12909756"))
        assertNull(OpenSubtitlesHasher.parseContentRange("bytes 9-5/100"))
        assertNull(OpenSubtitlesHasher.parseContentRange("bytes 0-100/100"))
        assertNull(OpenSubtitlesHasher.parseContentRange("items 0-1/2"))
    }

    private fun partial(start: Long, bytes: ByteArray, total: Long, status: Int = 206) = RawHttpResponse(
        status = status,
        statusText = "",
        url = "",
        body = "",
        headers = mapOf("content-range" to "bytes $start-${start + bytes.size - 1}/$total"),
        bodyBytes = bytes,
    )

    private class FakeServer(val respond: (range: String?) -> RawHttpResponse) : OpenSubtitlesHasher.RangeFetcher {
        val requests = mutableListOf<Map<String, String>>()
        override suspend fun get(url: String, headers: Map<String, String>): RawHttpResponse {
            requests += headers
            return respond(headers["Range"])
        }
    }

    @Test
    fun computesFromTwoRangeRequests() = runTest {
        val size = 12_909_756L
        val server = FakeServer { range ->
            if (range == "bytes=0-65535") partial(0, head, size) else partial(size - chunk, tail, size)
        }
        val result = OpenSubtitlesHasher.compute(
            url = "https://cdn.example.com/a.mkv",
            headers = mapOf("Referer" to "https://site", "range" to "bytes=1-2"),
            fetcher = server,
        )
        assertEquals(OpenSubtitlesHasher.Result("20a01fa02064fcbc", size), result)
        assertEquals(listOf("bytes=0-65535", "bytes=${size - chunk}-${size - 1}"), server.requests.map { it["Range"] })
        // Source headers are forwarded; a caller Range never leaks through.
        assertEquals("https://site", server.requests.first()["Referer"])
        assertNull(server.requests.first()["range"])
    }

    @Test
    fun returnsNullWhenServerIgnoresRange() = runTest {
        val server = FakeServer { partial(0, head, 12_909_756L, status = 200) }
        assertNull(OpenSubtitlesHasher.compute("https://cdn.example.com/a.mkv", fetcher = server))
    }

    @Test
    fun returnsNullForSmallFileOrShortChunkOrUnknownTotal() = runTest {
        assertNull(OpenSubtitlesHasher.compute("https://x/a", fetcher = FakeServer { partial(0, head, 2L * chunk - 1) }))
        val size = 1_000_000L
        assertNull(
            OpenSubtitlesHasher.compute("https://x/a", fetcher = FakeServer { range ->
                if (range == "bytes=0-65535") partial(0, head, size) else partial(size - chunk, tail.copyOf(chunk - 8), size)
            }),
        )
        assertNull(
            OpenSubtitlesHasher.compute("https://x/a", fetcher = FakeServer {
                RawHttpResponse(206, "", "", "", mapOf("content-range" to "bytes 0-65535/*"), head)
            }),
        )
    }

    @Test
    fun returnsNullOnErrorOrTimeout() = runTest {
        assertNull(OpenSubtitlesHasher.compute("https://x/a", fetcher = FakeServer { error("boom") }))
        val slow = OpenSubtitlesHasher.RangeFetcher { _, _ ->
            delay(60_000)
            partial(0, head, 1_000_000L)
        }
        assertNull(OpenSubtitlesHasher.compute("https://x/a", timeoutMs = 1_000, fetcher = slow))
    }
}
