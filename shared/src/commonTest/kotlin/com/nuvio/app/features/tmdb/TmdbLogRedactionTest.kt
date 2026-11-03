package com.nuvio.app.features.tmdb

import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertFalse
import kotlin.test.assertTrue

class TmdbLogRedactionTest {
    @Test
    fun ktorTimeoutMessageLosesTheKeyButKeepsOtherParams() {
        val out = TmdbLogRedaction.redact(
            "Request timeout has expired [url=https://api.themoviedb.org/3/movie/1?api_key=abc123&language=en-US, request_timeout=10000 ms]",
        )
        assertTrue(out.contains("api_key=<redacted>"))
        assertFalse(out.contains("abc123"))
        assertTrue(out.contains("language=en-US"))
        assertTrue(out.contains("request_timeout=10000 ms]"))
    }

    @Test
    fun upperCaseKeyIsRedacted() {
        val out = TmdbLogRedaction.redact("failed https://x/3/a?API_KEY=SeCrEt&page=2")
        assertFalse(out.contains("SeCrEt"))
        assertTrue(out.contains("api_key=<redacted>"))
        assertTrue(out.contains("page=2"))
    }

    @Test
    fun everyOccurrenceIsRedacted() {
        val out = TmdbLogRedaction.redact("a?api_key=one&x=1 then b?api_key=two)")
        assertFalse(out.contains("one"))
        assertFalse(out.contains("two"))
        assertEquals(2, Regex("api_key=<redacted>").findAll(out).count())
    }

    @Test
    fun messageWithoutKeyIsUnchanged() {
        val msg = "Connection refused: https://api.themoviedb.org/3/movie/1?language=en-US"
        assertEquals(msg, TmdbLogRedaction.redact(msg))
    }

    @Test
    fun nullMessageBecomesNullText() {
        assertEquals("null", TmdbLogRedaction.redact(null))
    }

    @Test
    fun describeNamesTheClassAndNeverTheKey() {
        val out = TmdbLogRedaction.describe(
            IllegalStateException("timeout [url=https://api.themoviedb.org/3/x?api_key=abc123&page=1]"),
        )
        assertTrue(out.startsWith("IllegalStateException: "))
        assertFalse(out.contains("abc123"))
        assertTrue(out.contains("api_key=<redacted>"))
    }
}
