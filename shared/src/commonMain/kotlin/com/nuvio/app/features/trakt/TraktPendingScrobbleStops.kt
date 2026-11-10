package com.nuvio.app.features.trakt

import kotlin.concurrent.Volatile
import kotlin.math.abs
import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.sync.Mutex
import kotlinx.coroutines.sync.withLock
import kotlinx.serialization.Serializable
import kotlinx.serialization.builtins.ListSerializer
import kotlinx.serialization.json.Json

/*
 * BUG-220: a write-ahead queue for Trakt `/scrobble/stop`.
 *
 * With Watch Progress Source = Trakt the read side hides every local row Trakt can represent
 * (`WatchProgressSourceProjection`), so after a relaunch a resume position exists only if the
 * session's single `/scrobble/stop` reached Trakt. That request used to be fire-and-forget: no
 * auth yet, a profile change mid-flight, a 5xx after the retries, being offline, or the app being
 * killed before it landed all dropped it silently.
 *
 * Now every stop is persisted BEFORE it is sent, deleted once Trakt answers 2xx/409 (or rejects it
 * for good), and replayed later when it did not land: at profile selection (every launch enters
 * through it) and whenever Trakt auth becomes available. Only stops are ever replayed, never
 * starts. Before replaying, the drain reads what Trakt holds now (`/sync/playback`, and
 * `/sync/history` since the stop was queued) and drops an entry Trakt already has, or that newer
 * activity elsewhere supersedes, so a replay can neither add a duplicate play nor overwrite newer
 * progress. BUG-231: a session that never sends its stop at all (a crash, a force-quit) is covered
 * by a PROVISIONAL stop: while a session plays, its position is written here every
 * [TraktScrobbleStopOutbox.provisionalIntervalMs]; the clean stop supersedes it, and after a kill
 * the next launch's drain sends it like any other pending stop, behind the same checks.
 * The reads are lazy (playback once, history at most once per kind, each when the first
 * entry needs it): an entry that cannot be checked is never sent, and the drain stops there, but
 * entries before the failed read may already have been sent. Entries are bounded per profile and by age (24 h at or above the watched threshold,
 * 48 h below it).
 */

/** Trakt marks an item watched at or above this progress; a stop there adds a history play. */
const val TRAKT_WATCHED_PROGRESS = 80f

/** Serializable snapshot of a [TraktScrobbleItem] (the sealed item itself is not serializable). */
@Serializable
data class TraktPendingScrobbleItem(
    val kind: String,
    val title: String? = null,
    val year: Int? = null,
    val trakt: Int? = null,
    val imdb: String? = null,
    val tmdb: Int? = null,
    val slug: String? = null,
    val season: Int? = null,
    val number: Int? = null,
    val episodeTitle: String? = null,
) {
    fun toScrobbleItem(): TraktScrobbleItem? {
        val ids = TraktExternalIds(trakt = trakt, imdb = imdb, tmdb = tmdb, slug = slug)
        if (!ids.hasAnyId()) return null
        return when (kind) {
            KIND_MOVIE -> TraktScrobbleItem.Movie(title = title, year = year, ids = ids)
            KIND_EPISODE -> TraktScrobbleItem.Episode(
                showTitle = title,
                showYear = year,
                showIds = ids,
                season = season ?: return null,
                number = number ?: return null,
                episodeTitle = episodeTitle,
            )
            else -> null
        }
    }

    /**
     * Whether [remote] (a Trakt playback or history row) is this item: same kind, any shared id
     * (for an episode, the show's ids), and for an episode the same season and number.
     */
    fun matches(remote: TraktRemoteProgress): Boolean {
        if (remote.kind != kind) return false
        val ids = remote.ids
        val sameId = (trakt != null && trakt == ids.trakt) ||
            (!imdb.isNullOrBlank() && imdb.equals(ids.imdb, ignoreCase = true)) ||
            (tmdb != null && tmdb == ids.tmdb) ||
            (!slug.isNullOrBlank() && slug.equals(ids.slug, ignoreCase = true))
        if (!sameId) return false
        return kind == KIND_MOVIE || (season == remote.season && number == remote.number)
    }

    companion object {
        const val KIND_MOVIE = "movie"
        const val KIND_EPISODE = "episode"

        fun from(item: TraktScrobbleItem): TraktPendingScrobbleItem = when (item) {
            is TraktScrobbleItem.Movie -> TraktPendingScrobbleItem(
                kind = KIND_MOVIE,
                title = item.title,
                year = item.year,
                trakt = item.ids.trakt,
                imdb = item.ids.imdb,
                tmdb = item.ids.tmdb,
                slug = item.ids.slug,
            )
            is TraktScrobbleItem.Episode -> TraktPendingScrobbleItem(
                kind = KIND_EPISODE,
                title = item.showTitle,
                year = item.showYear,
                trakt = item.showIds.trakt,
                imdb = item.showIds.imdb,
                tmdb = item.showIds.tmdb,
                slug = item.showIds.slug,
                season = item.season,
                number = item.number,
                episodeTitle = item.episodeTitle,
            )
        }
    }
}

/**
 * One persisted stop. [attempts] counts HTTP failures only (being offline is not the entry's
 * fault). [accountSlug] is the Trakt user the stop was meant for, when known; a replay into a
 * different account drops it.
 */
@Serializable
data class TraktPendingScrobbleStop(
    val id: String,
    val profileId: Int,
    val itemKey: String,
    val item: TraktPendingScrobbleItem,
    val progress: Float,
    val createdAtMs: Long,
    val attempts: Int = 0,
    val accountSlug: String? = null,
    /** BUG-231: written while the session was still playing (no stop was ever sent for it). */
    val provisional: Boolean = false,
)

/**
 * A row Trakt holds now: a paused playback ([atMs] = `paused_at`, [progress] its percentage) or a
 * history play (`watched_at`, no progress).
 */
data class TraktRemoteProgress(
    val kind: String,
    val ids: TraktExternalIds,
    val season: Int? = null,
    val number: Int? = null,
    val atMs: Long,
    val progress: Float? = null,
)

/**
 * The persisted per-profile list. Every mutation is a fresh read-modify-write under one mutex that
 * touches only entries still present, and is not written back when a wipe of its profile
 * ([clearProfile]) or of every profile ([invalidate], [wipeAll]) happened since it read: a sign-out
 * wipe or a disconnect clear that lands mid-drain is never resurrected. Generations are kept per
 * profile (bumped under the lock) plus one global one (bumped by a sign-out, possibly outside the
 * lock), so clearing one profile never discards another profile's write.
 */
class TraktPendingScrobbleStopQueue(
    private val load: (profileId: Int) -> String?,
    private val save: (profileId: Int, payload: String) -> Unit,
    private val clear: (profileId: Int) -> Unit,
    private val now: () -> Long,
    val maxPerProfile: Int = DEFAULT_MAX_PER_PROFILE,
    val maxWatchedAgeMs: Long = DEFAULT_MAX_WATCHED_AGE_MS,
    val maxPausedAgeMs: Long = DEFAULT_MAX_PAUSED_AGE_MS,
) {
    private val mutex = Mutex()
    private val serializer = ListSerializer(TraktPendingScrobbleStop.serializer())

    @Volatile
    private var globalGeneration = 0L

    // Guarded by [mutex].
    private val profileGenerations = mutableMapOf<Int, Long>()

    /**
     * Marks every profile's in-flight mutation stale without taking the lock (the platform sign-out
     * wipe erases the keys itself, outside this queue). The caller then runs [wipeAll] as well.
     */
    fun invalidate() {
        globalGeneration += 1
    }

    private fun generationOf(profileId: Int): Pair<Long, Long> =
        globalGeneration to (profileGenerations[profileId] ?: 0L)

    fun maxAgeFor(progress: Float): Long =
        if (progress >= TRAKT_WATCHED_PROGRESS) maxWatchedAgeMs else maxPausedAgeMs

    /**
     * Persists [stop]. An older entry for the same item and profile is superseded (a replayed old
     * stop must never overwrite a newer position); expired entries are pruned; at most
     * [maxPerProfile] newest entries are kept.
     */
    suspend fun enqueue(stop: TraktPendingScrobbleStop) = mutate(stop.profileId) { stored ->
        val kept = prune(stored.filterNot { it.itemKey == stop.itemKey })
        (kept + stop).sortedBy { it.createdAtMs }.takeLast(maxPerProfile)
    }

    /** The profile's live entries, oldest first. Persists the pruning when anything expired. */
    suspend fun pending(profileId: Int): List<TraktPendingScrobbleStop> = mutex.withLock {
        val gen = generationOf(profileId)
        val stored = read(profileId)
        val pruned = prune(stored).sortedBy { it.createdAtMs }
        if (pruned.size != stored.size && gen == generationOf(profileId)) write(profileId, pruned)
        pruned
    }

    suspend fun contains(profileId: Int, id: String): Boolean = mutex.withLock {
        read(profileId).any { it.id == id }
    }

    suspend fun remove(profileId: Int, id: String) = mutate(profileId) { stored ->
        stored.filterNot { it.id == id }.takeIf { it.size != stored.size }
    }

    /** Drops [itemKey]'s provisional entry, if any; a real pending stop for the item is kept. */
    suspend fun removeProvisional(profileId: Int, itemKey: String) = mutate(profileId) { stored ->
        stored.filterNot { it.provisional && it.itemKey == itemKey }.takeIf { it.size != stored.size }
    }

    /** Counts one HTTP failure; drops the entry once it reaches [maxAttempts]. True when kept. */
    suspend fun recordFailedAttempt(profileId: Int, id: String, maxAttempts: Int): Boolean {
        var kept = false
        mutate(profileId) { stored ->
            val entry = stored.firstOrNull { it.id == id } ?: return@mutate null
            val attempts = entry.attempts + 1
            kept = attempts < maxAttempts
            if (kept) {
                stored.map { if (it.id == id) it.copy(attempts = attempts) else it }
            } else {
                stored.filterNot { it.id == id }
            }
        }
        return kept
    }

    /** Erases [profileId]'s queue under the lock and marks in-flight mutations stale. */
    suspend fun clearProfile(profileId: Int) = mutex.withLock {
        profileGenerations[profileId] = (profileGenerations[profileId] ?: 0L) + 1
        clear(profileId)
    }

    /** [clearProfile] for every profile slot (sign-out). */
    suspend fun wipeAll(profileIds: Iterable<Int>) = mutex.withLock {
        globalGeneration += 1
        profileIds.forEach(clear)
    }

    private suspend fun mutate(
        profileId: Int,
        block: (List<TraktPendingScrobbleStop>) -> List<TraktPendingScrobbleStop>?,
    ) = mutex.withLock {
        val gen = generationOf(profileId)
        val updated = block(read(profileId)) ?: return@withLock
        if (gen == generationOf(profileId)) write(profileId, updated)
    }

    private fun prune(entries: List<TraktPendingScrobbleStop>): List<TraktPendingScrobbleStop> {
        val nowMs = now()
        return entries.filter { nowMs - it.createdAtMs <= maxAgeFor(it.progress) }
    }

    private fun read(profileId: Int): List<TraktPendingScrobbleStop> {
        val raw = load(profileId)?.takeIf(String::isNotBlank) ?: return emptyList()
        return try {
            json.decodeFromString(serializer, raw).filter { it.profileId == profileId }
        } catch (error: CancellationException) {
            throw error
        } catch (_: Exception) {
            // An undecodable payload can never be replayed; drop it rather than fail forever.
            clear(profileId)
            emptyList()
        }
    }

    private fun write(profileId: Int, entries: List<TraktPendingScrobbleStop>) {
        if (entries.isEmpty()) clear(profileId) else save(profileId, json.encodeToString(serializer, entries))
    }

    companion object {
        const val DEFAULT_MAX_PER_PROFILE = 10
        const val DEFAULT_MAX_WATCHED_AGE_MS = 24L * 60 * 60 * 1000
        const val DEFAULT_MAX_PAUSED_AGE_MS = 48L * 60 * 60 * 1000
        private val json = Json { ignoreUnknownKeys = true }
    }
}

/** What one `/scrobble/stop` attempt came to, as far as the queue is concerned. */
enum class TraktScrobbleDelivery {
    /** 2xx or 409 (already scrobbled): delete the entry. */
    SENT,

    /** Deduped against an identical stop that was just delivered: delete the entry. */
    SKIPPED,

    /** No Trakt auth for the profile yet, or the profile is no longer active: keep, stop draining. */
    NOT_READY,

    /** Transport failure (offline, timeout): keep without counting an attempt; stop draining. */
    OFFLINE,

    /** 5xx, 401/403/408/420/423/429: keep and count an attempt; the drain moves on to the next entry. */
    RETRYABLE,

    /** Any other 4xx (400, 404, 422 below 1 %): the request can never succeed; delete it. */
    REJECTED,
}

/** Maps a non-success HTTP status to [TraktScrobbleDelivery.RETRYABLE] or [TraktScrobbleDelivery.REJECTED]. */
fun classifyTraktScrobbleFailure(status: Int): TraktScrobbleDelivery = when (status) {
    in 500..599, 401, 403, 408, 420, 423, 429 -> TraktScrobbleDelivery.RETRYABLE
    else -> TraktScrobbleDelivery.REJECTED
}

/**
 * What a drain reads from Trakt before replaying. Each fetch returns null when it failed; the
 * entry that needed it is never sent, and the drain stops there (entries before it may already
 * have been sent: reads are lazy, see the file header).
 */
interface TraktReplayRemote {
    /** The connected Trakt account's slug, or null when it is not known yet. */
    fun accountSlug(): String?

    /** Fetches the account's user settings (and so its slug); called at most once per drain. */
    suspend fun refreshAccount()

    /** Every paused playback Trakt holds now (`/sync/playback`). */
    suspend fun playback(): List<TraktRemoteProgress>?

    /** History plays of [kind] watched at or after [sinceMs] (`/sync/history/{movies|episodes}`). */
    suspend fun playsSince(kind: String, sinceMs: Long): List<TraktRemoteProgress>?
}

data class TraktPendingStopDrainResult(
    val sent: Int = 0,
    val kept: Int = 0,
    val dropped: Int = 0,
    val superseded: Int = 0,
)

/**
 * The write-ahead send and the replay, free of HTTP and singletons so it is unit tested
 * (`TraktPendingScrobbleStopsTest`). `deliver` is `TraktScrobbleEngine`'s request code.
 */
class TraktScrobbleStopOutbox(
    private val queue: TraktPendingScrobbleStopQueue,
    private val activeProfileId: () -> Int,
    private val isConnected: (profileId: Int) -> Boolean,
    private val accountSlug: () -> String?,
    private val now: () -> Long,
    private val newId: () -> String,
    private val log: (String) -> Unit = {},
    val maxReplayAttempts: Int = DEFAULT_MAX_REPLAY_ATTEMPTS,
    /** Tolerance for device/Trakt clock skew when comparing Trakt timestamps with [TraktPendingScrobbleStop.createdAtMs]. */
    val clockSlackMs: Long = DEFAULT_CLOCK_SLACK_MS,
    /** BUG-231: the least time between two provisional writes of one session. */
    val provisionalIntervalMs: Long = DEFAULT_PROVISIONAL_INTERVAL_MS,
) {
    private val drainMutex = Mutex()
    // Orders a session's provisional writes against its closing stop: a write that was already
    // under way when the stop arrives finishes first, so it can never supersede the stop's entry.
    private val sessionMutex = Mutex()

    // Guarded by [sessionMutex]: the session of the last provisional write and when it was made.
    private var lastProvisional: Triple<Int, String, Long>? = null
    private val inFlightMutex = Mutex()
    private val inFlight = mutableSetOf<String>()

    // The item a live `start` opened and no `stop` closed yet: the drain leaves its old entry
    // alone so a replay cannot end the session that is playing right now.
    @Volatile
    private var openSession: Pair<Int, String>? = null

    fun onSessionStarted(profileId: Int, itemKey: String) {
        openSession = profileId to itemKey
    }

    /**
     * BUG-231: the open session's position right now. Persists it as a provisional stop, at most
     * once per [provisionalIntervalMs], so a session that is killed before it can send its stop
     * still leaves one for the next launch to replay. Nothing is sent here. Ignored for anything
     * but the open session, below 1 % (Trakt rejects it) and without a connected account, exactly
     * as [sendStop] never queues those. The drain leaves the open session's entry alone, so it is
     * replayed only once that session is gone. True when an entry was written.
     */
    suspend fun noteSessionProgress(profileId: Int, item: TraktScrobbleItem, progress: Float): Boolean =
        sessionMutex.withLock {
            val session = profileId to item.itemKey
            if (openSession != session) return@withLock false
            if (progress < MIN_QUEUED_PROGRESS || !isConnected(profileId)) return@withLock false
            val nowMs = now()
            val last = lastProvisional
            if (last != null && last.first == profileId && last.second == item.itemKey &&
                nowMs >= last.third && nowMs - last.third < provisionalIntervalMs
            ) {
                return@withLock false
            }
            queue.enqueue(
                TraktPendingScrobbleStop(
                    id = newId(),
                    profileId = profileId,
                    itemKey = item.itemKey,
                    item = TraktPendingScrobbleItem.from(item),
                    progress = progress,
                    createdAtMs = nowMs,
                    accountSlug = accountSlug(),
                    provisional = true,
                ),
            )
            lastProvisional = Triple(profileId, item.itemKey, nowMs)
            true
        }

    fun onProfileChanged() {
        openSession = null
    }

    /**
     * Persists the stop, then sends it. Only sent, never queued: a profile with no Trakt account
     * connected (queueing would replay its viewing into whatever account is connected next), and
     * stops below 1 %, which Trakt rejects (422) and which exist to close the "watching" session,
     * something a later replay cannot do. While the live send runs (with its in-place retries) the
     * entry is in flight, and a drain leaves it alone.
     */
    suspend fun sendStop(
        profileId: Int,
        item: TraktScrobbleItem,
        progress: Float,
        deliver: suspend (TraktScrobbleItem, Float) -> TraktScrobbleDelivery,
    ): TraktScrobbleDelivery {
        val entry = sessionMutex.withLock {
            if (openSession == (profileId to item.itemKey)) openSession = null
            lastProvisional = null
            if (progress < MIN_QUEUED_PROGRESS || !isConnected(profileId)) {
                // BUG-231: this stop is the session's real end; its provisional position (the
                // placeholder or live stream that closes at 0 % included) must not be replayed.
                queue.removeProvisional(profileId, item.itemKey)
                return@withLock null
            }
            val stop = TraktPendingScrobbleStop(
                id = newId(),
                profileId = profileId,
                itemKey = item.itemKey,
                item = TraktPendingScrobbleItem.from(item),
                progress = progress,
                createdAtMs = now(),
                accountSlug = accountSlug(),
            )
            inFlightMutex.withLock { inFlight += stop.id }
            // Supersedes the session's provisional entry (same item).
            queue.enqueue(stop)
            stop
        } ?: return deliver(item, progress)
        try {
            log("Trakt pending stop queued id=${entry.id} profile=$profileId item=${entry.itemKey} progress=${formatProgress(progress)}")
            val result = deliver(item, progress)
            resolve(entry, result, replay = false)
            return result
        } finally {
            inFlightMutex.withLock { inFlight -= entry.id }
        }
    }

    /**
     * Replays [profileId]'s pending stops, oldest first, while that profile stays active. Each
     * entry is first checked against what Trakt holds now ([remote]); an entry Trakt already has,
     * or that newer activity supersedes, is dropped without a request. An entry that cannot be
     * checked is never sent. A RETRYABLE failure moves on to the next entry; OFFLINE, NOT_READY or a
     * failed check stops the drain.
     */
    suspend fun drain(
        profileId: Int,
        remote: TraktReplayRemote,
        deliver: suspend (TraktScrobbleItem, Float) -> TraktScrobbleDelivery,
    ): TraktPendingStopDrainResult {
        if (activeProfileId() != profileId) return TraktPendingStopDrainResult()
        return drainMutex.withLock {
            var sent = 0
            var dropped = 0
            var superseded = 0
            val entries = queue.pending(profileId)
            if (entries.isEmpty()) return@withLock TraktPendingStopDrainResult()
            log("Trakt pending stop replay: ${entries.size} pending for profile $profileId")
            val checks = RemoteChecks(remote, sinceMs = entries.minOf { it.createdAtMs } - clockSlackMs)
            var accountRefreshed = false
            for (entry in entries) {
                if (activeProfileId() != profileId) break
                if (openSession == (profileId to entry.itemKey)) continue
                if (inFlightMutex.withLock { entry.id in inFlight }) continue
                // A live stop for the same item may have superseded this entry since the snapshot.
                if (!queue.contains(profileId, entry.id)) continue
                val item = entry.item.toScrobbleItem()
                if (item == null) {
                    queue.remove(profileId, entry.id)
                    dropped += 1
                    continue
                }
                entry.accountSlug?.let { expected ->
                    var current = remote.accountSlug()
                    if (current == null && !accountRefreshed) {
                        // The settings fetch at connect time may have failed: try once per drain.
                        accountRefreshed = true
                        remote.refreshAccount()
                        current = remote.accountSlug()
                    }
                    if (current == null) {
                        log("Trakt pending stop replay deferred id=${entry.id}: Trakt account not known yet (kept)")
                        return@withLock result(profileId, sent, dropped, superseded)
                    }
                    if (!current.equals(expected, ignoreCase = true)) {
                        queue.remove(profileId, entry.id)
                        log("Trakt pending stop replay dropped id=${entry.id}: queued for another Trakt account")
                        dropped += 1
                        continue
                    }
                }
                when (val verdict = checks.verdict(entry)) {
                    Verdict.UNKNOWN -> {
                        log("Trakt pending stop replay deferred id=${entry.id}: Trakt state could not be read (kept)")
                        return@withLock result(profileId, sent, dropped, superseded)
                    }
                    Verdict.ALREADY_PLAYED, Verdict.ALREADY_PAUSED, Verdict.NEWER_ON_TRAKT -> {
                        queue.remove(profileId, entry.id)
                        log("Trakt pending stop replay skipped id=${entry.id}: ${verdict.reason} (removed)")
                        superseded += 1
                        continue
                    }
                    Verdict.REPLAY -> Unit
                }
                val result = deliver(item, entry.progress)
                when (resolve(entry, result, replay = true)) {
                    Resolution.REMOVED_SENT -> sent += 1
                    Resolution.REMOVED_DROPPED -> dropped += 1
                    Resolution.KEPT -> Unit
                }
                if (result == TraktScrobbleDelivery.NOT_READY || result == TraktScrobbleDelivery.OFFLINE) break
            }
            result(profileId, sent, dropped, superseded)
        }
    }

    private suspend fun result(profileId: Int, sent: Int, dropped: Int, superseded: Int) =
        TraktPendingStopDrainResult(
            sent = sent,
            kept = queue.pending(profileId).size,
            dropped = dropped,
            superseded = superseded,
        )

    /** Forgets in-memory session state (sign-out). */
    suspend fun reset() {
        openSession = null
        sessionMutex.withLock { lastProvisional = null }
        inFlightMutex.withLock { inFlight.clear() }
    }

    private enum class Verdict(val reason: String) {
        REPLAY("replay"),
        ALREADY_PLAYED("Trakt already has a play since it was queued"),
        ALREADY_PAUSED("Trakt already holds this position"),
        NEWER_ON_TRAKT("Trakt holds newer progress"),
        UNKNOWN("unknown"),
    }

    /** One drain's reads of Trakt, each fetched at most once and only when an entry needs it. */
    private inner class RemoteChecks(private val remote: TraktReplayRemote, private val sinceMs: Long) {
        private var playbackLoaded = false
        private var playback: List<TraktRemoteProgress>? = null
        private val plays = mutableMapOf<String, List<TraktRemoteProgress>?>()

        private suspend fun playback(): List<TraktRemoteProgress>? {
            if (!playbackLoaded) {
                playback = remote.playback()
                playbackLoaded = true
            }
            return playback
        }

        private suspend fun plays(kind: String): List<TraktRemoteProgress>? =
            if (kind in plays) plays[kind] else remote.playsSince(kind, sinceMs).also { plays[kind] = it }

        suspend fun verdict(entry: TraktPendingScrobbleStop): Verdict {
            val since = entry.createdAtMs - clockSlackMs
            if (entry.progress >= TRAKT_WATCHED_PROGRESS) {
                // A watched stop that reached Trakt (response lost) left a play: never add a second.
                val history = plays(entry.item.kind) ?: return Verdict.UNKNOWN
                return if (history.any { entry.item.matches(it) && it.atMs >= since }) Verdict.ALREADY_PLAYED else Verdict.REPLAY
            }
            val current = playback() ?: return Verdict.UNKNOWN
            val paused = current.filter(entry.item::matches).maxByOrNull { it.atMs }
            if (paused != null) {
                val pausedProgress = paused.progress
                // Ours: the stop landed and only its answer was lost (any timestamp, any clock skew).
                if (pausedProgress != null && abs(pausedProgress - entry.progress) <= SAME_POSITION_PERCENT) {
                    return Verdict.ALREADY_PAUSED
                }
                // Newer: paused after this stop was queued (no slack) at a different position, i.e.
                // another device. An earlier own stop (20 % landed, the final 30 % failed minutes
                // later) is older than createdAtMs and does not count.
                if (paused.atMs > entry.createdAtMs) return Verdict.NEWER_ON_TRAKT
            }
            // No newer paused row: finished elsewhere since (a newer play) means the position is
            // stale, and a stale paused row must not bring Resume back either.
            val history = plays(entry.item.kind) ?: return Verdict.UNKNOWN
            return if (history.any { entry.item.matches(it) && it.atMs >= since }) Verdict.ALREADY_PLAYED else Verdict.REPLAY
        }
    }

    private enum class Resolution { REMOVED_SENT, REMOVED_DROPPED, KEPT }

    private suspend fun resolve(
        entry: TraktPendingScrobbleStop,
        result: TraktScrobbleDelivery,
        replay: Boolean,
    ): Resolution {
        val stage = if (replay) "replayed" else "live"
        return when (result) {
            TraktScrobbleDelivery.SENT, TraktScrobbleDelivery.SKIPPED -> {
                queue.remove(entry.profileId, entry.id)
                log("Trakt pending stop $stage ok id=${entry.id} result=$result (removed)")
                Resolution.REMOVED_SENT
            }
            TraktScrobbleDelivery.REJECTED -> {
                queue.remove(entry.profileId, entry.id)
                log("Trakt pending stop $stage rejected id=${entry.id} (dropped)")
                Resolution.REMOVED_DROPPED
            }
            TraktScrobbleDelivery.NOT_READY, TraktScrobbleDelivery.OFFLINE -> {
                log("Trakt pending stop $stage deferred id=${entry.id} result=$result (kept)")
                Resolution.KEPT
            }
            TraktScrobbleDelivery.RETRYABLE -> {
                val kept = queue.recordFailedAttempt(entry.profileId, entry.id, maxReplayAttempts)
                log("Trakt pending stop $stage failed id=${entry.id} (${if (kept) "kept" else "dropped after $maxReplayAttempts attempts"})")
                if (kept) Resolution.KEPT else Resolution.REMOVED_DROPPED
            }
        }
    }

    private fun formatProgress(progress: Float): String {
        val tenths = (progress * 10).toInt()
        return "${tenths / 10}.${tenths % 10}%"
    }

    companion object {
        const val DEFAULT_MAX_REPLAY_ATTEMPTS = 5
        const val MIN_QUEUED_PROGRESS = 1f
        const val DEFAULT_CLOCK_SLACK_MS = 10L * 60 * 1000
        const val DEFAULT_PROVISIONAL_INTERVAL_MS = 30L * 1000

        /** A Trakt paused row within this many percentage points of an entry is the entry itself. */
        const val SAME_POSITION_PERCENT = 1f
    }
}
