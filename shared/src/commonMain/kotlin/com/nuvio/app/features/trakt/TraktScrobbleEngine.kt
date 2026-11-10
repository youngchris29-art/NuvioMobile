package com.nuvio.app.features.trakt

import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Job
import kotlinx.coroutines.channels.Channel
import kotlinx.coroutines.delay
import kotlinx.coroutines.flow.Flow
import kotlinx.coroutines.flow.distinctUntilChanged
import kotlinx.coroutines.launch
import kotlinx.serialization.SerialName
import kotlinx.serialization.Serializable
import kotlinx.serialization.builtins.ListSerializer
import kotlinx.serialization.json.Json
import kotlin.concurrent.Volatile
import kotlin.math.abs

private const val TRAKT_API_BASE_URL = "https://api.trakt.tv"

/** A Trakt HTTP answer, as far as scrobbling needs it; null from the transport = it never arrived. */
data class TraktHttpReply(
    val status: Int,
    val statusText: String = "",
    val body: String = "",
    val url: String = "",
    val headers: Map<String, String> = emptyMap(),
)

/**
 * The scrobble request loop: [attempts] tries, transport failures and 5xx retried in place (502-504
 * after [overloadedRetryDelayMs], others after [retryDelayMs] × attempt). 2xx and 409 are SENT;
 * transport failures to the end are OFFLINE; any other status is classified.
 */
internal suspend fun runTraktScrobbleAttempts(
    attempts: Int,
    retryDelayMs: Long,
    overloadedRetryDelayMs: Long,
    sleep: suspend (Long) -> Unit,
    onReply: (TraktHttpReply) -> Unit = {},
    send: suspend (attempt: Int) -> TraktHttpReply?,
): TraktScrobbleDelivery {
    for (attempt in 1..attempts) {
        val reply = send(attempt)
        if (reply == null) {
            if (attempt < attempts) {
                sleep(retryDelayMs * attempt)
                continue
            }
            return TraktScrobbleDelivery.OFFLINE
        }
        onReply(reply)
        if (reply.status in 200..299 || reply.status == 409) return TraktScrobbleDelivery.SENT
        if (reply.status in 500..599 && attempt < attempts) {
            sleep(if (reply.status in 502..504) overloadedRetryDelayMs else retryDelayMs * attempt)
            continue
        }
        return classifyTraktScrobbleFailure(reply.status)
    }
    return TraktScrobbleDelivery.OFFLINE
}

/**
 * Trakt scrobbling behind [TraktScrobbleRepository], with every collaborator injected so the
 * request path, the write-ahead queue and the replay are unit tested (`TraktScrobbleEngineTest`).
 *
 * Live: `start` is sent once; `stop` goes through [TraktScrobbleStopOutbox.sendStop] (persisted
 * first, three attempts, dedupe, progress refresh on success). Replay: one attempt per entry, no
 * dedupe, entries checked against Trakt's playback/history first, one progress refresh at the end
 * and only when something was sent. Replays run on one worker (requests while it is busy collapse
 * into one), triggered at profile selection and by the auth watcher.
 */
class TraktScrobbleEngine(
    private val activeProfileId: () -> Int,
    private val authorizedHeaders: suspend () -> Map<String, String>?,
    private val isAuthenticated: () -> Boolean,
    private val authenticatedChanges: () -> Flow<Boolean>,
    private val accountSlug: () -> String?,
    private val refreshAccount: suspend () -> Unit,
    private val http: suspend (method: String, url: String, body: String, headers: Map<String, String>) -> TraktHttpReply?,
    private val refreshProgress: suspend () -> Unit,
    val queue: TraktPendingScrobbleStopQueue,
    private val now: () -> Long,
    newId: () -> String,
    private val scope: CoroutineScope,
    private val appVersion: String?,
    private val parseIsoMs: (String) -> Long?,
    private val formatIsoMs: (Long) -> String,
    private val sleep: suspend (Long) -> Unit = { delay(it) },
    private val trace: (String) -> Unit = {},
    private val debug: (() -> String) -> Unit = {},
    private val warn: (String) -> Unit = {},
) {
    private data class ScrobbleStamp(
        val profileId: Int,
        val action: String,
        val itemKey: String,
        val progress: Float,
        val timestampMs: Long,
    )

    private val json = Json {
        ignoreUnknownKeys = true
        encodeDefaults = false
        explicitNulls = false
    }

    @Volatile
    private var lastScrobbleStamp: ScrobbleStamp? = null

    val outbox = TraktScrobbleStopOutbox(
        queue = queue,
        activeProfileId = activeProfileId,
        isConnected = { profileId -> activeProfileId() == profileId && isAuthenticated() },
        accountSlug = accountSlug,
        now = now,
        newId = newId,
        log = trace,
    )

    @Volatile
    private var authWatcher: Job? = null

    @Volatile
    private var replayWorker: Job? = null
    private val replayRequests = Channel<Int>(Channel.CONFLATED)

    suspend fun send(profileId: Int, action: String, item: TraktScrobbleItem, progressPercent: Float) {
        val clamped = progressPercent.coerceIn(0f, 100f)
        when (action) {
            // BUG-220: persisted before it is sent, replayed later if it does not land.
            "stop" -> outbox.sendStop(profileId, item, clamped) { stopItem, progress ->
                deliver(profileId, action, stopItem, progress, replay = false)
            }
            "start" -> {
                outbox.onSessionStarted(profileId, item.itemKey)
                deliver(profileId, action, item, clamped, replay = false)
            }
            else -> deliver(profileId, action, item, clamped, replay = false)
        }
    }

    /** BUG-231: the open session's position, kept as a provisional pending stop. Sends nothing. */
    suspend fun noteSessionProgress(profileId: Int, item: TraktScrobbleItem, progressPercent: Float): Boolean =
        outbox.noteSessionProgress(profileId, item, progressPercent.coerceIn(0f, 100f))

    /**
     * One scrobble request. A live stop retries in place; a replay sends once and leaves the retry
     * to the next drain. A live stop refreshes Trakt progress on success; a drain refreshes at its end.
     */
    private suspend fun deliver(
        profileId: Int,
        action: String,
        item: TraktScrobbleItem,
        clampedProgress: Float,
        replay: Boolean,
    ): TraktScrobbleDelivery {
        if (activeProfileId() != profileId) return TraktScrobbleDelivery.NOT_READY
        val headers = authorizedHeaders() ?: return TraktScrobbleDelivery.NOT_READY
        if (activeProfileId() != profileId) return TraktScrobbleDelivery.NOT_READY
        if (!replay && shouldSkip(profileId, action, item.itemKey, clampedProgress)) {
            return TraktScrobbleDelivery.SKIPPED
        }

        val url = "$TRAKT_API_BASE_URL/scrobble/$action"
        val requestBody = json.encodeToString(TraktScrobbleRequest.serializer(), buildRequestBody(item, clampedProgress))
        val requestHeaders = mapOf(
            "Accept" to "application/json",
            "Content-Type" to "application/json",
        ) + headers
        debug {
            "Trakt scrobble $action${if (replay) " (replay)" else ""} request\nurl=$url\n" +
                "headers=${requestHeaders.redactedForLogs().formatForLog()}\nbody=${requestBody.ifBlank { "<empty>" }}"
        }

        val attempts = if (action == "stop" && !replay) MAX_STOP_RETRIES + 1 else 1
        val result = runTraktScrobbleAttempts(
            attempts = attempts,
            retryDelayMs = RETRY_DELAY_MS,
            overloadedRetryDelayMs = OVERLOADED_RETRY_DELAY_MS,
            sleep = sleep,
            send = { attempt ->
                http("POST", url, requestBody, requestHeaders).also { reply ->
                    if (reply == null) warn("Trakt scrobble $action transport failure on attempt $attempt/$attempts")
                }
            },
            onReply = { reply ->
                debug {
                    "Trakt scrobble $action response\nstatus=${reply.status} ${reply.statusText.ifBlank { "<no-status-text>" }}\n" +
                        "url=${reply.url}\nheaders=${reply.headers.formatForLog()}\nbody=${reply.body.ifBlank { "<empty>" }}"
                }
                val line = if (reply.status in 200..299 || reply.status == 409) {
                    "Trakt scrobble $action status=${reply.status}${if (replay) " (replay)" else ""}"
                } else {
                    "Failed Trakt scrobble $action: HTTP ${reply.status} ${reply.statusText.ifBlank { "<no-status-text>" }}"
                }
                if (action == "stop") trace(line) else if (reply.status !in 200..299 && reply.status != 409) warn(line)
            },
        )
        if (result != TraktScrobbleDelivery.SENT) return result

        lastScrobbleStamp = ScrobbleStamp(
            profileId = profileId,
            action = action,
            itemKey = item.itemKey,
            progress = clampedProgress,
            timestampMs = now(),
        )
        if (action == "stop" && !replay) refreshProgress()
        return TraktScrobbleDelivery.SENT
    }

    private fun shouldSkip(profileId: Int, action: String, itemKey: String, progress: Float): Boolean {
        val last = lastScrobbleStamp ?: return false
        val isSameWindow = now() - last.timestampMs < MIN_SEND_INTERVAL_MS
        val isSameProfile = last.profileId == profileId
        val isSameAction = last.action == action
        val isSameItem = last.itemKey == itemKey
        val isNearProgress = abs(last.progress - progress) <= PROGRESS_WINDOW
        if (action == "stop" && last.action == "start" && isSameItem && isSameProfile) return false
        return isSameWindow && isSameProfile && isSameAction && isSameItem && isNearProgress
    }

    // ── Replay triggers ─────────────────────────────────────────────────────────────────────

    /**
     * Profile-selection hook: the launch drain. The first call arms the auth watcher, whose first
     * emission (the current auth state) covers this selection; later calls request a drain.
     */
    fun onProfileChanged(profileId: Int) {
        outbox.onProfileChanged()
        if (!armAuthWatcher()) requestReplay(profileId)
    }

    /** Queues a drain of the active profile's pending stops on the replay worker. */
    fun requestReplay(profileId: Int = activeProfileId()) {
        ensureReplayWorker()
        replayRequests.trySend(profileId)
    }

    /**
     * Arms the auth watcher once; true when this call armed it. The null-check-then-launch here and
     * in [ensureReplayWorker] can race (two callers arm two watchers or two workers); that is
     * harmless: every drain runs under the outbox's drain mutex, so the worst case is one extra,
     * serialised drain.
     */
    private fun armAuthWatcher(): Boolean {
        if (authWatcher != null) return false
        authWatcher = scope.launch {
            authenticatedChanges().distinctUntilChanged().collect { authenticated ->
                if (authenticated) requestReplay(activeProfileId())
            }
        }
        return true
    }

    private fun ensureReplayWorker() {
        if (replayWorker != null) return
        replayWorker = scope.launch {
            for (profileId in replayRequests) {
                // One failed drain must not end the worker, or no later request would ever run.
                try {
                    replay(profileId)
                } catch (error: CancellationException) {
                    throw error
                } catch (error: Throwable) {
                    trace("Trakt pending stop replay failed: ${error::class.simpleName}: ${error.message} (kept)")
                }
            }
        }
    }

    /** Drains [profileId]'s pending stops now (the worker's body; tests call it directly). */
    suspend fun replay(profileId: Int = activeProfileId()): TraktPendingStopDrainResult {
        if (activeProfileId() != profileId) return TraktPendingStopDrainResult()
        if (queue.pending(profileId).isEmpty()) return TraktPendingStopDrainResult()
        val headers = authorizedHeaders()
        if (headers == null) {
            trace("Trakt pending stop replay deferred: no Trakt auth for profile $profileId (kept)")
            return TraktPendingStopDrainResult(kept = queue.pending(profileId).size)
        }
        val result = outbox.drain(profileId, remote(headers)) { item, progress ->
            deliver(profileId, "stop", item, progress, replay = true)
        }
        trace(
            "Trakt pending stop replay done profile=$profileId sent=${result.sent} kept=${result.kept} " +
                "dropped=${result.dropped} superseded=${result.superseded}",
        )
        if (result.sent > 0) refreshProgress()
        return result
    }

    // ── Clearing ────────────────────────────────────────────────────────────────────────────

    /** Trakt disconnect: drops [profileId]'s queue under the queue lock. */
    suspend fun clearPendingStops(profileId: Int) = queue.clearProfile(profileId)

    /**
     * Non-suspending callers (profile removal): clears under the lock once any write already
     * holding it has finished, and bumps only that profile's generation.
     */
    fun clearPendingStopsAsync(profileId: Int) {
        scope.launch { queue.clearProfile(profileId) }
    }

    /**
     * Sign-out: the platform cleaner erases the keys (AccountDataStores); this marks every in-flight
     * queue write stale so none is written back, forgets session state, and clears every slot again
     * under the lock once any write already holding it has finished.
     */
    fun onAccountDataWiped(profileIds: Iterable<Int>) {
        queue.invalidate()
        lastScrobbleStamp = null
        scope.launch {
            outbox.reset()
            queue.wipeAll(profileIds)
        }
    }

    // ── Trakt reads for the replay pre-checks ───────────────────────────────────────────────

    private fun remote(headers: Map<String, String>): TraktReplayRemote = object : TraktReplayRemote {
        private val readHeaders = mapOf("Accept" to "application/json") + headers

        override fun accountSlug(): String? = this@TraktScrobbleEngine.accountSlug()

        override suspend fun refreshAccount() = this@TraktScrobbleEngine.refreshAccount()

        override suspend fun playback(): List<TraktRemoteProgress>? {
            val movies = get("$TRAKT_API_BASE_URL/sync/playback/movies") ?: return null
            val episodes = get("$TRAKT_API_BASE_URL/sync/playback/episodes") ?: return null
            return (movies + episodes).mapNotNull { row -> row.toRemote(row.pausedAt)?.copy(progress = row.progress) }
        }

        override suspend fun playsSince(kind: String, sinceMs: Long): List<TraktRemoteProgress>? {
            val type = if (kind == TraktPendingScrobbleItem.KIND_MOVIE) "movies" else "episodes"
            val startAt = formatIsoMs(sinceMs)
            val rows = get("$TRAKT_API_BASE_URL/sync/history/$type?start_at=$startAt&limit=$HISTORY_LIMIT") ?: return null
            return rows.mapNotNull { it.toRemote(it.watchedAt) }
        }

        private suspend fun get(url: String): List<PendingStopRemoteRow>? {
            val reply = http("GET", url, "", readHeaders) ?: return null
            if (reply.status !in 200..299) {
                trace("Trakt pending stop check failed: HTTP ${reply.status} for ${url.substringAfter(TRAKT_API_BASE_URL)}")
                return null
            }
            return runCatching { json.decodeFromString(ListSerializer(PendingStopRemoteRow.serializer()), reply.body) }
                .getOrNull()
        }

        private fun PendingStopRemoteRow.toRemote(at: String?): TraktRemoteProgress? {
            val atMs = at?.let(parseIsoMs) ?: return null
            movie?.ids?.let { ids ->
                return TraktRemoteProgress(kind = TraktPendingScrobbleItem.KIND_MOVIE, ids = ids, atMs = atMs)
            }
            val showIds = show?.ids ?: return null
            val episode = episode ?: return null
            return TraktRemoteProgress(
                kind = TraktPendingScrobbleItem.KIND_EPISODE,
                ids = showIds,
                season = episode.season,
                number = episode.number,
                atMs = atMs,
            )
        }
    }

    // ── Request body ────────────────────────────────────────────────────────────────────────

    private fun buildRequestBody(item: TraktScrobbleItem, clampedProgress: Float): TraktScrobbleRequest =
        when (item) {
            is TraktScrobbleItem.Movie -> TraktScrobbleRequest(
                movie = TraktMovieBody(title = item.title, year = item.year, ids = item.ids.toRequestBodyOrNull()),
                progress = clampedProgress,
                appVersion = appVersion,
            )
            is TraktScrobbleItem.Episode -> TraktScrobbleRequest(
                show = TraktShowBody(title = item.showTitle, year = item.showYear, ids = item.showIds.toRequestBodyOrNull()),
                episode = TraktEpisodeBody(title = item.episodeTitle, season = item.season, number = item.number),
                progress = clampedProgress,
                appVersion = appVersion,
            )
        }

    private fun TraktExternalIds.toRequestBodyOrNull(): TraktIdsBody? {
        if (trakt == null && imdb.isNullOrBlank() && tmdb == null) return null
        return TraktIdsBody(trakt = trakt, imdb = imdb, tmdb = tmdb)
    }

    private fun Map<String, String>.redactedForLogs(): Map<String, String> =
        entries.associate { (key, value) ->
            key to when {
                key.equals("authorization", ignoreCase = true) -> redactBearerValue(value)
                key.equals("trakt-api-key", ignoreCase = true) -> "<redacted>"
                else -> value
            }
        }

    private fun Map<String, String>.formatForLog(): String =
        entries
            .sortedBy { it.key.lowercase() }
            .joinToString(prefix = "{", postfix = "}") { (key, value) -> "$key=$value" }

    private fun redactBearerValue(value: String): String {
        val tokenPrefix = "Bearer "
        if (!value.startsWith(tokenPrefix, ignoreCase = true)) return "<redacted>"
        val token = value.removePrefix(tokenPrefix).trim()
        if (token.isBlank()) return "Bearer <redacted>"
        return "Bearer ${token.take(6)}...${token.takeLast(4)}"
    }

    companion object {
        const val MIN_SEND_INTERVAL_MS = 8_000L
        const val PROGRESS_WINDOW = 1.5f
        const val MAX_STOP_RETRIES = 2
        const val RETRY_DELAY_MS = 1_500L
        const val OVERLOADED_RETRY_DELAY_MS = 5_000L
        const val HISTORY_LIMIT = 100
    }
}

@Serializable
private data class PendingStopRemoteRow(
    @SerialName("paused_at") val pausedAt: String? = null,
    @SerialName("watched_at") val watchedAt: String? = null,
    @SerialName("progress") val progress: Float? = null,
    @SerialName("movie") val movie: PendingStopRemoteMedia? = null,
    @SerialName("show") val show: PendingStopRemoteMedia? = null,
    @SerialName("episode") val episode: PendingStopRemoteEpisode? = null,
)

@Serializable
private data class PendingStopRemoteMedia(
    @SerialName("ids") val ids: TraktExternalIds? = null,
)

@Serializable
private data class PendingStopRemoteEpisode(
    @SerialName("season") val season: Int? = null,
    @SerialName("number") val number: Int? = null,
)

@Serializable
private data class TraktScrobbleRequest(
    @SerialName("movie") val movie: TraktMovieBody? = null,
    @SerialName("show") val show: TraktShowBody? = null,
    @SerialName("episode") val episode: TraktEpisodeBody? = null,
    @SerialName("progress") val progress: Float,
    @SerialName("app_version") val appVersion: String? = null,
)

@Serializable
private data class TraktMovieBody(
    @SerialName("title") val title: String? = null,
    @SerialName("year") val year: Int? = null,
    @SerialName("ids") val ids: TraktIdsBody? = null,
)

@Serializable
private data class TraktShowBody(
    @SerialName("title") val title: String? = null,
    @SerialName("year") val year: Int? = null,
    @SerialName("ids") val ids: TraktIdsBody? = null,
)

@Serializable
private data class TraktEpisodeBody(
    @SerialName("title") val title: String? = null,
    @SerialName("season") val season: Int? = null,
    @SerialName("number") val number: Int? = null,
)

@Serializable
private data class TraktIdsBody(
    @SerialName("trakt") val trakt: Int? = null,
    @SerialName("imdb") val imdb: String? = null,
    @SerialName("tmdb") val tmdb: Int? = null,
)
