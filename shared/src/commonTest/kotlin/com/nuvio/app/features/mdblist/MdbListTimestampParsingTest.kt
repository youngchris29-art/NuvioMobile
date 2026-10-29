package com.nuvio.app.features.mdblist

import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertFailsWith
import kotlin.test.assertFalse
import kotlin.test.assertTrue

class MdbListTimestampParsingTest {
    @Test
    fun `zulu timestamps parse to exact epoch milliseconds`() {
        assertEquals(0L, mdbListTimestamp("1970-01-01T00:00:00Z"))
        assertEquals(1_738_517_302_000L, mdbListTimestamp("2025-02-02T17:28:22Z"))
        assertEquals(1_738_517_302_500L, mdbListTimestamp("2025-02-02T17:28:22.5Z"))
        assertEquals(1_738_517_302_123L, mdbListTimestamp("2025-02-02T17:28:22.123Z"))
        assertEquals(1_738_517_302_123L, mdbListTimestamp("2025-02-02T17:28:22.123456789Z"))
        assertEquals(951_782_400_000L, mdbListTimestamp("2000-02-29T00:00:00Z"))
        assertEquals(-62_135_596_800_000L, mdbListTimestamp("0001-01-01T00:00:00Z"))
    }

    @Test
    fun `offset timestamps are normalised to utc`() {
        assertEquals(1_738_517_302_000L - 2 * 3_600_000L, mdbListTimestamp("2025-02-02T17:28:22+02:00"))
        assertEquals(1_738_517_302_000L + (5 * 60 + 30) * 60_000L, mdbListTimestamp("2025-02-02T17:28:22-05:30"))
        assertEquals(1_738_517_302_250L, mdbListTimestamp("2025-02-02T17:28:22.250+00:00"))
        assertEquals(1_738_517_302_000L - 18 * 3_600_000L, mdbListTimestamp("2025-02-02T17:28:22+18:00"))
    }

    @Test
    fun `space separated timestamps are read as utc`() {
        assertEquals(1_738_517_302_000L, mdbListTimestamp("2025-02-02 17:28:22"))
        assertEquals(1_738_517_302_000L, mdbListTimestamp("2025-02-02 17:28:22.000000"))
        assertEquals(1_738_517_302_987L, mdbListTimestamp("2025-02-02 17:28:22.987654321"))
    }

    @Test
    fun `fraction is truncated to milliseconds`() {
        assertEquals(mdbListTimestamp("2025-02-02T17:28:22.123Z"), mdbListTimestamp("2025-02-02T17:28:22.123999Z"))
        assertEquals(mdbListTimestamp("2025-02-02T17:28:22.500Z"), mdbListTimestamp("2025-02-02T17:28:22.5Z"))
    }

    @Test
    fun `unsupported values still fail loudly`() {
        listOf(
            "",
            "yesterday",
            "2025-02-02",
            "2025-02-02T17:28:22",
            "2025-02-02T17:28:22Z ",
            "02/02/2025 17:28:22",
            "2025-02-30T17:28:22Z",
            "2025-02-02 17:28:22Z",
            "2025-02-02 17:28:22+02:00",
            "2025-02-02 17:28:22.",
            "2025-02-02T24:00:00Z",
            "2025-13-02T17:28:22Z",
        ).forEach { value ->
            assertFailsWith<MdbListDecodingException>(value) { mdbListTimestamp(value) }
        }
    }

    @Test
    fun `values the fast path declines still reach the original chain`() {
        // Leading/trailing whitespace on the zone-less form was trimmed before the regex; keep it.
        assertEquals(1_738_517_302_000L, mdbListTimestamp(" 2025-02-02 17:28:22 "))
    }

    @Test
    fun `imdb id validation matches tt followed by digits`() {
        assertTrue("tt12345".isMdbListImdbId())
        assertFalse("tt".isMdbListImdbId())
        assertFalse("tt12a".isMdbListImdbId())
        assertFalse("tt-123".isMdbListImdbId())
        assertFalse("12345".isMdbListImdbId())
        assertFalse("tt 123".isMdbListImdbId())
        assertFalse("TT123".isMdbListImdbId())
    }
}
