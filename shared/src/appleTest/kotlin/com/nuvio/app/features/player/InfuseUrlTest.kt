package com.nuvio.app.features.player

import kotlin.test.Test
import kotlin.test.assertEquals

/** Issue #19: the Infuse launch URL carries the resume position the picker resolved. */
class InfuseUrlTest {

    private fun request(resumePositionMs: Long) = ExternalPlayerPlaybackRequest(
        sourceUrl = "https://cdn.example.com/movie.mkv",
        title = "Movie",
        resumePositionMs = resumePositionMs,
    )

    private fun position(url: String): String =
        url.substringAfter('?').split('&').first { it.substringBefore('=') == "position" }.substringAfter('=')

    @Test
    fun sendsTheResumePositionInWholeSeconds() {
        val url = buildInfuseUrl(request(resumePositionMs = 2_400_900L))
        assertEquals(true, url.startsWith("infuse://x-callback-url/play?url="))
        assertEquals("2400", position(url))
    }

    @Test
    fun sendsZeroFromTheStartAndForANegativePosition() {
        assertEquals("0", position(buildInfuseUrl(request(resumePositionMs = 0L))))
        assertEquals("0", position(buildInfuseUrl(request(resumePositionMs = -5_000L))))
    }
}
