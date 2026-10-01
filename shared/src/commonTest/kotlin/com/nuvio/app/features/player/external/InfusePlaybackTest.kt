package com.nuvio.app.features.player.external

import com.nuvio.app.features.watchprogress.WatchProgressPlaybackSession
import io.ktor.http.Url
import io.ktor.http.encodeURLParameter
import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertFalse
import kotlin.test.assertNotNull
import kotlin.test.assertNull
import kotlin.test.assertTrue

/**
 * Ported from upstream `99ced26a` (`composeApp/.../InfusePlaybackTest.kt`) onto the generalised
 * `ExternalPlaybackReturnHandler`. Adaptations: the session is recorded (and cleared) inside
 * `handleUrl` instead of surfacing as a pending UI result, so "result" assertions read the
 * injected `record` sink; the Infuse launch-URL builder lives in `appleMain` (not reachable from
 * `commonTest`), so the launch-encoding case checks the callback URLs it is fed instead.
 */
class InfusePlaybackTest {
    private var stored: String? = null
    private val recorded = mutableListOf<Pair<ExternalPlaybackSession, Double>>()
    private var nextId = 0
    private var storedDurationMs: Long? = null

    private fun handler() = ExternalPlaybackReturnHandler(
        load = { stored },
        save = { stored = it },
        clear = { stored = null },
        existingDurationMs = { storedDurationMs },
        record = { session, positionSec -> recorded += session to positionSec },
        newSessionId = { "session-${++nextId}" },
    )

    private val source = "https://example.com/video.mkv?token=a+b&name=Episode%205#part"
    private val playback = WatchProgressPlaybackSession(
        profileId = 2, contentType = "series", parentMetaId = "tt123", parentMetaType = "series",
        videoId = "tt123:2:5", title = "Series", seasonNumber = 2, episodeNumber = 5,
    )

    private fun ExternalPlaybackReturnHandler.launch(
        durationMs: Long? = 3_600_000L,
        playerId: String = "infuse",
    ): ExternalPlaybackSession = prepare(
        playerId = playerId,
        sourceUrl = source,
        playbackSession = playback,
        durationMs = durationMs,
    )

    private fun successUrl(
        session: ExternalPlaybackSession,
        seconds: String,
        lastPlayed: String = source,
        scheme: String = "nuvio",
    ): String {
        val (success, _) = ExternalPlaybackCallbacks.build(scheme, session.playerId, session.id)
        return "$success?lastPlayedUrl=${lastPlayed.encodeURLParameter()}&position=${seconds.encodeURLParameter()}"
    }

    private fun errorUrl(session: ExternalPlaybackSession, scheme: String = "nuvio"): String =
        ExternalPlaybackCallbacks.build(scheme, session.playerId, session.id).second +
            "?errorCode=100&errorMessage=Unsupported"

    @Test
    fun callbackUrlsSurviveTheLaunchQueryEncoding() {
        val (success, error) = ExternalPlaybackCallbacks.build("nuvio", "infuse", "session-1")
        assertEquals("nuvio://external-player/infuse/session-1/success", success)
        assertEquals("nuvio://external-player/infuse/session-1/error", error)
        val launch = Url(
            "infuse://x-callback-url/play?url=${source.encodeURLParameter()}" +
                "&x-success=${success.encodeURLParameter()}&x-error=${error.encodeURLParameter()}",
        )
        assertEquals(source, launch.parameters["url"])
        assertEquals(success, launch.parameters["x-success"])
        assertEquals(error, launch.parameters["x-error"])
    }

    @Test
    fun returnedPositionRetainsVideoAndProfileAfterAppRestart() {
        val session = handler().launch()
        val restored = handler()
        assertTrue(restored.handleUrl(successUrl(session, "1800"), "nuvio"))
        val (recordedSession, positionSec) = recorded.single()
        assertEquals(1800.0, positionSec)
        assertEquals(3_600_000L, recordedSession.durationMs)
        assertEquals(playback, recordedSession.playbackSession)
        assertEquals(2, recordedSession.playbackSession.profileId)
        assertEquals(source, recordedSession.sourceUrl)
        assertNull(stored)
    }

    @Test
    fun unknownDurationFallsBackToTheStoredProgressDurationAtLaunch() {
        storedDurationMs = 2_700_000L
        assertEquals(2_700_000L, handler().launch(durationMs = null).durationMs)
        assertEquals(2_700_000L, handler().launch(durationMs = 0L).durationMs)
        assertEquals(3_600_000L, handler().launch(durationMs = 3_600_000L).durationMs)
        storedDurationMs = null
        assertNull(handler().launch(durationMs = null).durationMs)
    }

    @Test
    fun handledCallbackClearsTheSessionSoAReplayIsIgnored() {
        val callbacks = handler()
        val session = callbacks.launch()
        assertNotNull(handler().pendingSession())
        assertTrue(callbacks.handleUrl(successUrl(session, "2400"), "nuvio"))
        assertNull(stored)
        assertFalse(handler().handleUrl(successUrl(session, "2400"), "nuvio"))
        assertEquals(1, recorded.size)
    }

    @Test
    fun staleCallbacksCannotUpdateAnotherLaunchEvenWithSameStream() {
        val callbacks = handler()
        val first = callbacks.launch()
        val second = callbacks.launch()
        assertFalse(callbacks.handleUrl(successUrl(first, "1200"), "nuvio"))
        assertTrue(recorded.isEmpty())
        assertEquals(second.id, callbacks.pendingSession()?.id)
        assertTrue(callbacks.handleUrl(successUrl(second, "1800"), "nuvio"))
        assertEquals(second.id, recorded.single().first.id)
        assertEquals(1800.0, recorded.single().second)
    }

    @Test
    fun mismatchedVideoAndInvalidPositionsAreIgnored() {
        val callbacks = handler()
        val session = callbacks.launch()
        assertFalse(callbacks.handleUrl(successUrl(session, "1200", "https://example.com/other.mkv"), "nuvio"))
        assertTrue(recorded.isEmpty())
        listOf("-1", "NaN", "1.5", "9223372036854775807", "").forEach { position ->
            assertFalse(callbacks.handleUrl(successUrl(session, position), "nuvio"), position)
            assertTrue(recorded.isEmpty(), position)
        }
        assertFalse(callbacks.handleUrl(successUrl(session, "1200").substringBefore("&position="), "nuvio"))
        assertNotNull(callbacks.pendingSession())
        // Zero is a valid report; the recorder (not the parser) decides it writes nothing.
        assertTrue(callbacks.handleUrl(successUrl(session, "0"), "nuvio"))
        assertEquals(0.0, recorded.single().second)
        assertNull(stored)
    }

    @Test
    fun errorDoesNotProducePlaybackProgress() {
        val callbacks = handler()
        val session = callbacks.launch()
        assertTrue(callbacks.handleUrl(errorUrl(session), "nuvio"))
        assertTrue(recorded.isEmpty())
        assertNull(stored)
    }

    @Test
    fun duplicateCallbackCannotOverwriteRecordedProgress() {
        val callbacks = handler()
        val session = callbacks.launch()
        assertTrue(callbacks.handleUrl(successUrl(session, "1800"), "nuvio"))
        assertFalse(callbacks.handleUrl(successUrl(session, "2000"), "nuvio"))
        assertEquals(1800.0, recorded.single().second)
    }

    @Test
    fun failedLaunchClearsOnlyItsOwnPendingSession() {
        val callbacks = handler()
        val first = callbacks.launch()
        val second = callbacks.launch()
        callbacks.cancelLaunch(first.id)
        assertNotNull(stored)
        callbacks.cancelLaunchForCallbackUrl(ExternalPlaybackCallbacks.build("nuvio", "infuse", first.id).first)
        assertNotNull(stored)
        callbacks.cancelLaunchForCallbackUrl(ExternalPlaybackCallbacks.build("nuvio", "infuse", second.id).first)
        assertNull(stored)
        val third = callbacks.launch()
        callbacks.cancelLaunch(third.id)
        assertNull(stored)
        callbacks.launch()
        callbacks.cancelLaunch()
        assertNull(stored)
    }

    @Test
    fun unrelatedLinksAndCorruptStoredSessionsDoNotProduceResults() {
        val callbacks = handler()
        assertFalse(callbacks.handleUrl("nuvio://meta?type=movie&id=tt123", "nuvio"))
        assertFalse(callbacks.handleUrl("https://external-player/infuse/session-1/success?position=1", "nuvio"))
        assertFalse(callbacks.handleUrl("not a url", "nuvio"))
        stored = "invalid json"
        assertNull(callbacks.pendingSession())
        assertFalse(callbacks.handleUrl("nuvio://external-player/infuse/session-1/success?position=1", "nuvio"))
        assertEquals("invalid json", stored)
        assertTrue(recorded.isEmpty())
    }

    @Test
    fun schemeIsComparedCaseInsensitively() {
        val callbacks = handler()
        val session = callbacks.launch()
        assertFalse(callbacks.handleUrl(successUrl(session, "1800", scheme = "nuvio"), "NuvioTV"))
        assertTrue(recorded.isEmpty())
        assertTrue(callbacks.handleUrl(successUrl(session, "1800", scheme = "NuvioTV"), "nuviotv"))
        assertEquals(1800.0, recorded.single().second)
        val next = callbacks.launch()
        assertTrue(callbacks.handleUrl(errorUrl(next, scheme = "nuviotv"), "NuvioTV"))
        assertNull(stored)
    }

    @Test
    fun playerIdIsPartOfTheCallbackPath() {
        val callbacks = handler()
        val session = callbacks.launch(playerId = "vidhub")
        val (success, error) = ExternalPlaybackCallbacks.build("nuvio", session.playerId, session.id)
        assertEquals("nuvio://external-player/vidhub/${session.id}/success", success)
        assertEquals("nuvio://external-player/vidhub/${session.id}/error", error)
        val infusePath = "nuvio://external-player/infuse/${session.id}/success" +
            "?lastPlayedUrl=${source.encodeURLParameter()}&position=1800"
        assertFalse(callbacks.handleUrl(infusePath, "nuvio"))
        assertNotNull(stored)
        assertTrue(recorded.isEmpty())
        assertTrue(callbacks.handleUrl(successUrl(session, "1800"), "nuvio"))
        assertEquals("vidhub", recorded.single().first.playerId)
    }

    @Test
    fun sessionStorageRoundTrips() {
        ExternalPlaybackSessionStorage.clear()
        try {
            assertNull(ExternalPlaybackSessionStorage.load())
            ExternalPlaybackSessionStorage.save("{\"id\":\"x\"}")
            assertEquals("{\"id\":\"x\"}", ExternalPlaybackSessionStorage.load())
            ExternalPlaybackSessionStorage.clear()
            assertNull(ExternalPlaybackSessionStorage.load())
        } finally {
            ExternalPlaybackSessionStorage.clear()
        }
    }
}
