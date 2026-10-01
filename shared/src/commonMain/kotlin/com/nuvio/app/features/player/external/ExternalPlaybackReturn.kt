package com.nuvio.app.features.player.external

import co.touchlab.kermit.Logger
import com.nuvio.app.features.watchprogress.WatchProgressPlaybackSession
import io.ktor.http.Url
import kotlinx.atomicfu.locks.SynchronizedObject
import kotlinx.atomicfu.locks.synchronized
import kotlinx.serialization.decodeFromString
import kotlinx.serialization.encodeToString
import kotlinx.serialization.json.Json
import kotlin.uuid.ExperimentalUuidApi
import kotlin.uuid.Uuid

/**
 * The external-player return flow (upstream `99ced26a`'s `InfusePlaybackCallbacks`, ported into
 * `shared/` and generalised for tvOS):
 *
 * 1. [prepare] persists a fresh [ExternalPlaybackSession] before the player is opened; the caller
 *    builds the callback URLs with [ExternalPlaybackCallbacks.build] from the returned id and
 *    passes them on the `ExternalPlayerPlaybackRequest`.
 * 2. If opening the player fails, [cancelLaunch] drops the session.
 * 3. The player opens `<scheme>://external-player/<playerId>/<sessionId>/success?lastPlayedUrl=…&position=<seconds>`
 *    (or `/error`); the app hands that URL to [handleUrl].
 *
 * Every function is non-suspend and never throws, so Swift can call them directly. The progress
 * write itself is synchronous (`WatchProgressRepository.upsertPlaybackProgress` does not
 * suspend); only the tracker STOP scrobble runs in the background.
 */
object ExternalPlaybackReturn {
    @OptIn(ExperimentalUuidApi::class)
    private val handler = ExternalPlaybackReturnHandler(
        load = ExternalPlaybackSessionStorage::load,
        save = ExternalPlaybackSessionStorage::save,
        clear = ExternalPlaybackSessionStorage::clear,
        existingDurationMs = ::activeProfileProgressDurationMs,
        record = { session, positionSec -> recordExternalPlaybackProgress(session, positionSec) },
        newSessionId = { Uuid.random().toString() },
    )

    /**
     * Persists (replacing any earlier one) and returns the session for a launch. [durationMs] is
     * used when positive; otherwise the duration of the progress entry already stored for the
     * video, if any. An unknown duration still records the position, it only skips the tracker
     * scrobble and cannot mark the title watched.
     */
    fun prepare(
        playerId: String,
        sourceUrl: String,
        playbackSession: WatchProgressPlaybackSession,
        durationMs: Long?,
    ): ExternalPlaybackSession = handler.prepare(
        playerId = playerId,
        sourceUrl = sourceUrl,
        playbackSession = playbackSession,
        durationMs = durationMs,
    )

    /** Drops the pending session, whichever it is (the player could not be opened). */
    fun cancelLaunch() {
        handler.cancelLaunch()
    }

    /**
     * Drops the pending session only if it is still [sessionId]'s: a late open-failure report for
     * an earlier launch cannot clear a newer launch's session (upstream's `cancelLaunch(url)`).
     */
    fun cancelLaunch(sessionId: String) {
        handler.cancelLaunch(sessionId)
    }

    /** [cancelLaunch] for the session whose success callback URL is [callbackUrl]. */
    internal fun cancelLaunchForCallbackUrl(callbackUrl: String) {
        handler.cancelLaunchForCallbackUrl(callbackUrl)
    }

    /**
     * Returns true when [url] was the pending session's callback and has been consumed: `success`
     * records the position ([recordExternalPlaybackProgress]) and clears the session, `error`
     * clears it. Returns false, leaving any pending session untouched, for anything else: another
     * scheme (compared case-insensitively) or host, a different player or session id, a
     * `lastPlayedUrl` that is not the launched source (compared leniently, see
     * [sameSourceUrl]), or a missing/invalid `position` (finite, non-negative seconds; a
     * fraction such as `1234.5` is fine).
     */
    fun handleUrl(url: String, scheme: String): Boolean = handler.handleUrl(url, scheme)
}

internal class ExternalPlaybackReturnHandler(
    private val load: () -> String?,
    private val save: (String) -> Unit,
    private val clear: () -> Unit,
    private val existingDurationMs: (WatchProgressPlaybackSession) -> Long?,
    private val record: (ExternalPlaybackSession, Double) -> Unit,
    private val newSessionId: () -> String,
) {
    private val json = Json { ignoreUnknownKeys = true }
    private val lock = SynchronizedObject()

    fun pendingSession(): ExternalPlaybackSession? = synchronized(lock) { storedSessionLocked() }

    fun prepare(
        playerId: String,
        sourceUrl: String,
        playbackSession: WatchProgressPlaybackSession,
        durationMs: Long?,
    ): ExternalPlaybackSession {
        val resolvedDurationMs = durationMs?.takeIf { it > 0L }
            ?: runCatching { existingDurationMs(playbackSession) }
                .onFailure { error -> log.w(error) { "Stored duration lookup failed" } }
                .getOrNull()
                ?.takeIf { it > 0L }
        val session = ExternalPlaybackSession(
            id = newSessionId(),
            playerId = playerId.trim(),
            sourceUrl = sourceUrl,
            playbackSession = playbackSession,
            durationMs = resolvedDurationMs,
        )
        synchronized(lock) { save(json.encodeToString(session)) }
        return session
    }

    fun cancelLaunch() {
        synchronized(lock) { clear() }
    }

    fun cancelLaunch(sessionId: String) {
        synchronized(lock) {
            if (storedSessionLocked()?.id == sessionId) clear()
        }
    }

    fun cancelLaunchForCallbackUrl(callbackUrl: String) {
        val sessionId = runCatching { Url(callbackUrl.trim()) }.getOrNull()
            ?.pathSegments
            ?.filter(String::isNotEmpty)
            ?.getOrNull(1)
            ?: return
        cancelLaunch(sessionId)
    }

    fun handleUrl(url: String, scheme: String): Boolean {
        val claim = claimCallback(url, scheme) ?: return false
        val positionSec = claim.positionSec ?: return true
        try {
            record(claim.session, positionSec)
        } catch (error: Exception) {
            log.e(error) { "Recording the external player's returned position failed" }
        }
        return true
    }

    private class Claim(val session: ExternalPlaybackSession, val positionSec: Double?)

    /** Parses [url] and, if it is the pending session's callback, clears the session. */
    private fun claimCallback(url: String, scheme: String): Claim? {
        val expectedScheme = scheme.trim()
        if (expectedScheme.isEmpty()) return null
        val parsed = runCatching { Url(url.trim()) }.getOrNull() ?: return null
        if (!parsed.protocol.name.equals(expectedScheme, ignoreCase = true)) return null
        if (!parsed.host.equals(ExternalPlaybackCallbacks.HOST, ignoreCase = true)) return null
        val path = parsed.pathSegments.filter(String::isNotEmpty)
        if (path.size != 3) return null
        val playerId = path[0]
        val sessionId = path[1]
        val outcome = path[2]
        val positionSec: Double? = when (outcome) {
            ExternalPlaybackCallbacks.SUCCESS -> parsed.parameters["position"]
                ?.trim()
                ?.toDoubleOrNull()
                ?.takeIf { it.isFinite() && it >= 0.0 && it <= MAX_POSITION_SECONDS }
                ?: return null
            ExternalPlaybackCallbacks.ERROR -> null
            else -> return null
        }
        val lastPlayedUrl = parsed.parameters["lastPlayedUrl"]
        return synchronized(lock) {
            storedSessionLocked()
                ?.takeIf { session ->
                    session.id == sessionId &&
                        session.playerId.equals(playerId, ignoreCase = true) &&
                        (positionSec == null || sameSourceUrl(lastPlayedUrl, session.sourceUrl))
                }
                ?.let { session ->
                    clear()
                    Claim(session = session, positionSec = positionSec)
                }
        }
    }

    private fun storedSessionLocked(): ExternalPlaybackSession? = load()?.let { payload ->
        runCatching { json.decodeFromString<ExternalPlaybackSession>(payload) }.getOrNull()
    }

    private companion object {
        val log = Logger.withTag("ExternalPlaybackReturn")

        /** Upper bound for a returned position: `seconds * 1000` must still fit a `Long`. */
        val MAX_POSITION_SECONDS: Double = (Long.MAX_VALUE / 1000L).toDouble()
    }
}

/**
 * Whether the `lastPlayedUrl` an external player returned is the [launchedUrl] it was given.
 *
 * Ktor has already percent-decoded the callback's query parameters (with `+` read as a space), so
 * the returned value is compared against the raw launched URL, which still carries its own
 * encodings. A player may echo the URL back with `+`, `%2B` or `%20` swapped for each other (a
 * literal plus in a token, a space in a title), or with lower-case escape digits. None of that
 * changes which stream was launched, so both sides are reduced to one form first: escape digits
 * upper-cased, and `+`, `%2B`, `%20` and a space all folded to a single space. Everything else
 * is compared exactly; the session id (not this check) is what ties a callback to its launch.
 */
internal fun sameSourceUrl(returnedUrl: String?, launchedUrl: String): Boolean =
    returnedUrl != null &&
        normalizeSourceUrlForComparison(returnedUrl) == normalizeSourceUrlForComparison(launchedUrl)

private val percentEscape = Regex("%[0-9a-fA-F]{2}")

private fun normalizeSourceUrlForComparison(url: String): String =
    percentEscape.replace(url.trim()) { match -> match.value.uppercase() }
        .replace("%2B", " ")
        .replace("%20", " ")
        .replace('+', ' ')
