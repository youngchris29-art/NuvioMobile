package com.nuvio.app.features.trakt

import com.nuvio.app.core.account.AccountDataStores
import com.nuvio.app.core.account.AppleKeySpec
import com.nuvio.app.core.account.TRAKT_PENDING_SCROBBLE_STOPS_KEY
import com.nuvio.app.core.account.TRAKT_PENDING_SCROBBLE_STOPS_PREFERENCES
import kotlinx.coroutines.test.runTest
import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertFalse
import kotlin.test.assertNull
import kotlin.test.assertTrue

/** BUG-220: the write-ahead Trakt `/scrobble/stop` queue and its replay. */
class TraktPendingScrobbleStopsTest {

    private class FakeRemote(
        var slug: String? = null,
        var playback: List<TraktRemoteProgress>? = emptyList(),
        var plays: List<TraktRemoteProgress>? = emptyList(),
    ) : TraktReplayRemote {
        var playbackCalls = 0
        val playsCalls = mutableListOf<Pair<String, Long>>()
        var failPlaysFor: String? = null
        var refreshes = 0
        var slugAfterRefresh: String? = null

        override fun accountSlug(): String? = slug

        override suspend fun refreshAccount() {
            refreshes += 1
            slugAfterRefresh?.let { slug = it }
        }

        /** Runs while the drain is reading `/sync/playback`: what happens on the device meanwhile. */
        var onPlayback: (suspend () -> Unit)? = null

        override suspend fun playback(): List<TraktRemoteProgress>? {
            playbackCalls += 1
            onPlayback?.invoke()
            return playback
        }

        override suspend fun playsSince(kind: String, sinceMs: Long): List<TraktRemoteProgress>? {
            playsCalls += kind to sinceMs
            if (kind == failPlaysFor) return null
            return plays?.filter { it.kind == kind && it.atMs >= sinceMs }
        }
    }

    private class Harness(
        var nowMs: Long = 1_000_000_000L,
        var activeProfile: Int = 1,
        var connected: Boolean = true,
        var slug: String? = null,
        val storage: MutableMap<Int, String> = mutableMapOf(),
    ) {
        private var nextId = 0
        val logs = mutableListOf<String>()
        var onLoad: (() -> Unit)? = null
        val remote = FakeRemote()

        val queue = TraktPendingScrobbleStopQueue(
            load = { profileId -> storage[profileId].also { onLoad?.invoke() } },
            save = { profileId, payload -> storage[profileId] = payload },
            clear = { storage.remove(it) },
            now = { nowMs },
        )

        /** A fresh outbox over the same storage: what the next app launch sees. */
        fun outbox() = TraktScrobbleStopOutbox(
            queue = queue,
            activeProfileId = { activeProfile },
            isConnected = { connected },
            accountSlug = { slug },
            now = { nowMs },
            newId = { "id-${nextId++}" },
            log = { logs += it },
        )

        suspend fun pending(profileId: Int = 1) = queue.pending(profileId)
    }

    private suspend fun Harness.drain(
        outbox: TraktScrobbleStopOutbox,
        profileId: Int = 1,
        deliver: suspend (TraktScrobbleItem, Float) -> TraktScrobbleDelivery,
    ) = outbox.drain(profileId, remote, deliver)

    private fun movie(imdb: String = "tt0111161") =
        TraktScrobbleItem.Movie(title = "Film", year = 1994, ids = TraktExternalIds(imdb = imdb))

    private fun episode(season: Int = 1, number: Int = 2) = TraktScrobbleItem.Episode(
        showTitle = "Show",
        showYear = 2020,
        showIds = TraktExternalIds(imdb = "tt0903747", tmdb = 1396),
        season = season,
        number = number,
        episodeTitle = "Pilot",
    )

    // ── Write-ahead send ──────────────────────────────────────────────────────────────────

    @Test
    fun stopIsPersistedBeforeItIsSent() = runTest {
        val h = Harness()
        var pendingDuringSend: List<TraktPendingScrobbleStop>? = null
        h.outbox().sendStop(1, movie(), 2.4f) { _, _ ->
            pendingDuringSend = h.pending()
            TraktScrobbleDelivery.SENT
        }
        val seen = pendingDuringSend!!
        assertEquals(1, seen.size)
        assertEquals(movie().itemKey, seen.single().itemKey)
        assertEquals(2.4f, seen.single().progress)
        assertEquals(1, seen.single().profileId)
        assertEquals(h.nowMs, seen.single().createdAtMs)
    }

    @Test
    fun sentStopIsDeleted() = runTest {
        val h = Harness()
        h.outbox().sendStop(1, movie(), 40f) { _, _ -> TraktScrobbleDelivery.SENT }
        assertTrue(h.pending().isEmpty())
        assertNull(h.storage[1], "an empty queue removes the key")
    }

    @Test
    fun conflictAndDedupeDeleteTheEntry() = runTest {
        // 409 is folded into SENT by TraktScrobbleRepository.deliver (same branch as 2xx).
        val h = Harness()
        h.outbox().sendStop(1, movie(), 40f) { _, _ -> TraktScrobbleDelivery.SKIPPED }
        assertTrue(h.pending().isEmpty())
    }

    @Test
    fun serverErrorKeepsTheEntryAndCountsAnAttempt() = runTest {
        val h = Harness()
        h.outbox().sendStop(1, movie(), 40f) { _, _ -> TraktScrobbleDelivery.RETRYABLE }
        assertEquals(1, h.pending().single().attempts)
    }

    @Test
    fun offlineAndNoAuthKeepTheEntryWithoutCountingAnAttempt() = runTest {
        val h = Harness()
        h.outbox().sendStop(1, movie("tt1"), 40f) { _, _ -> TraktScrobbleDelivery.OFFLINE }
        h.outbox().sendStop(1, movie("tt2"), 40f) { _, _ -> TraktScrobbleDelivery.NOT_READY }
        val pending = h.pending()
        assertEquals(2, pending.size)
        assertTrue(pending.all { it.attempts == 0 })
    }

    @Test
    fun rejectedStopIsDropped() = runTest {
        val h = Harness()
        h.outbox().sendStop(1, movie(), 40f) { _, _ -> TraktScrobbleDelivery.REJECTED }
        assertTrue(h.pending().isEmpty())
    }

    @Test
    fun httpFailureClassification() {
        listOf(500, 502, 503, 504, 401, 403, 408, 420, 423, 429).forEach {
            assertEquals(TraktScrobbleDelivery.RETRYABLE, classifyTraktScrobbleFailure(it), "HTTP $it")
        }
        listOf(400, 404, 405, 422).forEach {
            assertEquals(TraktScrobbleDelivery.REJECTED, classifyTraktScrobbleFailure(it), "HTTP $it")
        }
    }

    @Test
    fun noConnectedAccountOrBelowOnePercentIsSentButNeverQueued() = runTest {
        val h = Harness(connected = false)
        var sends = 0
        h.outbox().sendStop(1, movie("tt1"), 40f) { _, _ -> sends++; TraktScrobbleDelivery.NOT_READY }
        h.connected = true
        h.outbox().sendStop(1, movie("tt2"), 0.5f) { _, _ -> sends++; TraktScrobbleDelivery.OFFLINE }
        assertEquals(2, sends)
        assertTrue(h.pending().isEmpty())
    }

    // ── Replay ────────────────────────────────────────────────────────────────────────────

    @Test
    fun drainAtLaunchReplaysWhatTheLastRunLeftBehind() = runTest {
        val h = Harness()
        // Run 1: the app is killed before the request lands (OFFLINE stands in for "never answered").
        h.outbox().sendStop(1, episode(), 2.4f) { _, _ -> TraktScrobbleDelivery.OFFLINE }
        assertEquals(1, h.pending().size)

        // Run 2: a fresh outbox over the same storage drains at profile selection.
        val replayed = mutableListOf<Pair<TraktScrobbleItem, Float>>()
        val result = h.drain(h.outbox(), 1) { item, progress ->
            replayed += item to progress
            TraktScrobbleDelivery.SENT
        }
        assertEquals(listOf<Pair<TraktScrobbleItem, Float>>(episode() to 2.4f), replayed)
        assertEquals(TraktPendingStopDrainResult(sent = 1, kept = 0, dropped = 0, superseded = 0), result)
        assertTrue(h.pending().isEmpty())
    }

    @Test
    fun drainStopsAtTheFirstOfflineEntryAndKeepsTheRest() = runTest {
        val h = Harness()
        h.outbox().sendStop(1, movie("tt1"), 10f) { _, _ -> TraktScrobbleDelivery.OFFLINE }
        h.nowMs += 1
        h.outbox().sendStop(1, movie("tt2"), 20f) { _, _ -> TraktScrobbleDelivery.OFFLINE }
        var calls = 0
        val result = h.drain(h.outbox(), 1) { _, _ -> calls++; TraktScrobbleDelivery.OFFLINE }
        assertEquals(1, calls, "offline: no point sending the rest")
        assertEquals(2, result.kept)
        assertTrue(h.pending().all { it.attempts == 0 })
    }

    @Test
    fun drainDropsAnEntryAfterTheMaximumHttpFailures() = runTest {
        val h = Harness()
        val outbox = h.outbox()
        outbox.sendStop(1, movie(), 40f) { _, _ -> TraktScrobbleDelivery.RETRYABLE } // attempt 1
        repeat(outbox.maxReplayAttempts - 2) {
            h.drain(outbox, 1) { _, _ -> TraktScrobbleDelivery.RETRYABLE }
        }
        assertEquals(outbox.maxReplayAttempts - 1, h.pending().single().attempts)
        val last = h.drain(outbox, 1) { _, _ -> TraktScrobbleDelivery.RETRYABLE }
        assertEquals(1, last.dropped)
        assertTrue(h.pending().isEmpty())
    }

    @Test
    fun drainLeavesTheItemOfTheOpenSessionAlone() = runTest {
        val h = Harness()
        h.outbox().sendStop(1, movie(), 40f) { _, _ -> TraktScrobbleDelivery.OFFLINE }
        val outbox = h.outbox()
        outbox.onSessionStarted(1, movie().itemKey)
        var calls = 0
        h.drain(outbox, 1) { _, _ -> calls++; TraktScrobbleDelivery.SENT }
        assertEquals(0, calls, "a replay must not end the session that is playing")
        assertEquals(1, h.pending().size)
    }

    @Test
    fun newerStopSupersedesTheOlderEntryForTheSameItem() = runTest {
        val h = Harness()
        val outbox = h.outbox()
        outbox.sendStop(1, movie(), 10f) { _, _ -> TraktScrobbleDelivery.OFFLINE }
        h.nowMs += 60_000
        outbox.sendStop(1, movie(), 35f) { _, _ -> TraktScrobbleDelivery.OFFLINE }
        assertEquals(listOf(35f), h.pending().map { it.progress })
    }

    @Test
    fun drainSkipsAnEntrySupersededWhileItRan() = runTest {
        val h = Harness()
        h.outbox().sendStop(1, movie("tt1"), 10f) { _, _ -> TraktScrobbleDelivery.OFFLINE }
        h.nowMs += 1
        h.outbox().sendStop(1, movie("tt2"), 20f) { _, _ -> TraktScrobbleDelivery.OFFLINE }
        val outbox = h.outbox()
        val sent = mutableListOf<String>()
        h.drain(outbox, 1) { item, _ ->
            sent += item.itemKey
            // While the first replay is in flight, a live stop for tt2 supersedes its old entry.
            if (item.itemKey == movie("tt1").itemKey) {
                h.queue.enqueue(
                    TraktPendingScrobbleStop(
                        id = "live",
                        profileId = 1,
                        itemKey = movie("tt2").itemKey,
                        item = TraktPendingScrobbleItem.from(movie("tt2")),
                        progress = 50f,
                        createdAtMs = h.nowMs + 1,
                    ),
                )
            }
            TraktScrobbleDelivery.SENT
        }
        assertEquals(listOf(movie("tt1").itemKey), sent, "the stale 20 % stop must not be replayed")
        assertEquals(listOf("live"), h.pending().map { it.id })
    }

    // ── Bounds ────────────────────────────────────────────────────────────────────────────

    @Test
    fun queueKeepsOnlyTheNewestEntriesPerProfile() = runTest {
        val h = Harness()
        val outbox = h.outbox()
        val total = h.queue.maxPerProfile + 3
        for (index in 0 until total) {
            h.nowMs += 1
            outbox.sendStop(1, movie("tt$index"), 10f) { _, _ -> TraktScrobbleDelivery.OFFLINE }
        }
        val pending = h.pending()
        assertEquals(h.queue.maxPerProfile, pending.size)
        assertEquals(movie("tt3").itemKey, pending.first().itemKey, "the oldest three were dropped")
        assertEquals(movie("tt${total - 1}").itemKey, pending.last().itemKey)
    }

    @Test
    fun pausedEntriesOlderThan48HoursAreNeverReplayed() = runTest {
        val h = Harness()
        h.outbox().sendStop(1, movie(), 40f) { _, _ -> TraktScrobbleDelivery.OFFLINE }
        h.nowMs += h.queue.maxPausedAgeMs + 1
        var calls = 0
        h.drain(h.outbox(), 1) { _, _ -> calls++; TraktScrobbleDelivery.SENT }
        assertEquals(0, calls)
        assertNull(h.storage[1], "the expired entry is pruned from storage")
    }

    @Test
    fun undecodablePayloadIsDiscarded() = runTest {
        val h = Harness()
        h.storage[1] = "{not json"
        assertTrue(h.pending().isEmpty())
        assertNull(h.storage[1])
    }

    // ── Profile scoping ───────────────────────────────────────────────────────────────────

    @Test
    fun stopsAreKeptUnderTheProfileThatPlayedThem() = runTest {
        val h = Harness()
        h.outbox().sendStop(1, movie("tt1"), 10f) { _, _ -> TraktScrobbleDelivery.OFFLINE }
        h.activeProfile = 2
        h.outbox().sendStop(2, movie("tt2"), 20f) { _, _ -> TraktScrobbleDelivery.OFFLINE }
        assertEquals(listOf(movie("tt1").itemKey), h.pending(1).map { it.itemKey })
        assertEquals(listOf(movie("tt2").itemKey), h.pending(2).map { it.itemKey })
    }

    @Test
    fun drainOnlyRunsForTheActiveProfile() = runTest {
        val h = Harness()
        h.outbox().sendStop(1, movie(), 10f) { _, _ -> TraktScrobbleDelivery.OFFLINE }
        h.activeProfile = 2
        var calls = 0
        h.drain(h.outbox(), 1) { _, _ -> calls++; TraktScrobbleDelivery.SENT }
        h.drain(h.outbox(), 2) { _, _ -> calls++; TraktScrobbleDelivery.SENT }
        assertEquals(0, calls)
        assertEquals(1, h.pending(1).size)
    }

    @Test
    fun drainStopsWhenTheProfileChangesMidway() = runTest {
        val h = Harness()
        h.outbox().sendStop(1, movie("tt1"), 10f) { _, _ -> TraktScrobbleDelivery.OFFLINE }
        h.nowMs += 1
        h.outbox().sendStop(1, movie("tt2"), 20f) { _, _ -> TraktScrobbleDelivery.OFFLINE }
        var calls = 0
        h.drain(h.outbox(), 1) { _, _ ->
            calls++
            h.activeProfile = 2
            TraktScrobbleDelivery.SENT
        }
        assertEquals(1, calls)
        assertEquals(listOf(movie("tt2").itemKey), h.pending(1).map { it.itemKey })
    }

    // ── Sign-out wipe / disconnect ────────────────────────────────────────────────────────

    @Test
    fun accountWipeRegistryListsThePendingStopStore() {
        val store = AccountDataStores.all.single { it.name == "TraktPendingScrobbleStopStorage" }
        assertEquals(TRAKT_PENDING_SCROBBLE_STOPS_PREFERENCES, store.androidPreferences)
        assertTrue(AppleKeySpec.ProfileScoped(TRAKT_PENDING_SCROBBLE_STOPS_KEY) in store.appleKeys)
        assertTrue(TRAKT_PENDING_SCROBBLE_STOPS_KEY in AccountDataStores.appleProfileScopedBases())
        assertTrue(TRAKT_PENDING_SCROBBLE_STOPS_PREFERENCES in AccountDataStores.androidPreferenceNames())
    }

    @Test
    fun wipedStorageIsNotWrittenBackByAnInFlightDrain() = runTest {
        val h = Harness()
        h.outbox().sendStop(1, movie(), 10f) { _, _ -> TraktScrobbleDelivery.OFFLINE }
        h.drain(h.outbox(), 1) { _, _ ->
            h.storage.clear() // the sign-out wipe lands while the replay is in flight
            TraktScrobbleDelivery.RETRYABLE
        }
        assertTrue(h.storage.isEmpty(), "recording the failed attempt must not resurrect the entry")
    }

    @Test
    fun platformStorageIsAddressedPerProfileAndClears() {
        val profileA = 7
        val profileB = 8
        try {
            TraktPendingScrobbleStopStorage.save(profileA, "a")
            TraktPendingScrobbleStopStorage.save(profileB, "b")
            assertEquals("a", TraktPendingScrobbleStopStorage.load(profileA))
            assertEquals("b", TraktPendingScrobbleStopStorage.load(profileB))
            TraktPendingScrobbleStopStorage.clear(profileA)
            assertNull(TraktPendingScrobbleStopStorage.load(profileA))
            assertEquals("b", TraktPendingScrobbleStopStorage.load(profileB))
        } finally {
            TraktPendingScrobbleStopStorage.clear(profileA)
            TraktPendingScrobbleStopStorage.clear(profileB)
        }
    }

    @Test
    fun itemSnapshotRoundTripsBothKinds() {
        assertEquals(movie(), TraktPendingScrobbleItem.from(movie()).toScrobbleItem())
        assertEquals(episode(3, 4), TraktPendingScrobbleItem.from(episode(3, 4)).toScrobbleItem())
        assertNull(TraktPendingScrobbleItem(kind = "movie").toScrobbleItem(), "no ids, never replayed")
    }

    // ── Review round 1 (P2-1, P2-2, P3-3..P3-6) ───────────────────────────────────────────

    private fun moviePlay(imdb: String, atMs: Long) =
        TraktRemoteProgress(kind = "movie", ids = TraktExternalIds(imdb = imdb, tmdb = 999), atMs = atMs)

    private fun episodePlay(season: Int, number: Int, atMs: Long) = TraktRemoteProgress(
        kind = "episode",
        ids = TraktExternalIds(tmdb = 1396),
        season = season,
        number = number,
        atMs = atMs,
    )

    private suspend fun Harness.queueOffline(item: TraktScrobbleItem, progress: Float, outbox: TraktScrobbleStopOutbox = outbox()) {
        outbox.sendStop(1, item, progress) { _, _ -> TraktScrobbleDelivery.OFFLINE }
    }

    @Test
    fun watchedReplayIsSkippedWhenTraktAlreadyHasAPlaySinceItWasQueued() = runTest {
        val h = Harness()
        h.queueOffline(movie(), 92f)
        val queuedAt = h.nowMs
        h.nowMs += 60 * 60 * 1000
        h.remote.plays = listOf(moviePlay("tt0111161", atMs = queuedAt + 2_000)) // the lost live stop landed
        var calls = 0
        val result = h.drain(h.outbox()) { _, _ -> calls++; TraktScrobbleDelivery.SENT }
        assertEquals(0, calls, "a second play must never be added")
        assertEquals(1, result.superseded)
        assertTrue(h.pending().isEmpty())
        assertEquals("movie", h.remote.playsCalls.single().first)
        assertEquals(0, h.remote.playbackCalls, "a watched entry only needs the history")
    }

    @Test
    fun watchedReplayGoesAheadWhenTheOnlyPlayIsOlder() = runTest {
        val h = Harness()
        h.queueOffline(movie(), 92f)
        h.remote.plays = listOf(moviePlay("tt0111161", atMs = h.nowMs - 3L * 24 * 60 * 60 * 1000))
        var calls = 0
        h.drain(h.outbox()) { _, _ -> calls++; TraktScrobbleDelivery.SENT }
        assertEquals(1, calls)
    }

    @Test
    fun watchedEntriesExpireAfter24HoursPausedAfter48() = runTest {
        val h = Harness()
        h.queueOffline(movie("tt1"), 85f)
        h.queueOffline(movie("tt2"), 40f)
        h.nowMs += 24L * 60 * 60 * 1000 + 1
        assertEquals(listOf(movie("tt2").itemKey), h.pending().map { it.itemKey })
        h.nowMs += 24L * 60 * 60 * 1000
        assertTrue(h.pending().isEmpty())
    }

    @Test
    fun pausedReplayIsSkippedWhenTraktHoldsNewerProgress() = runTest {
        val h = Harness()
        h.queueOffline(episode(1, 2), 30f)
        h.remote.playback = listOf(episodePlay(1, 2, atMs = h.nowMs + 3_600_000)) // another device, later
        var calls = 0
        val result = h.drain(h.outbox()) { _, _ -> calls++; TraktScrobbleDelivery.SENT }
        assertEquals(0, calls)
        assertEquals(1, result.superseded)
    }

    @Test
    fun pausedReplayOverwritesOnlyOlderTraktProgress() = runTest {
        val h = Harness()
        h.queueOffline(episode(1, 2), 30f)
        h.remote.playback = listOf(
            episodePlay(1, 2, atMs = h.nowMs - 5L * 60 * 60 * 1000),
            episodePlay(1, 3, atMs = h.nowMs + 3_600_000), // a different episode does not count
        )
        var calls = 0
        h.drain(h.outbox()) { _, _ -> calls++; TraktScrobbleDelivery.SENT }
        assertEquals(1, calls)
    }

    @Test
    fun pausedReplayIsSkippedWhenTheItemWasFinishedElsewhereSince() = runTest {
        val h = Harness()
        h.queueOffline(episode(1, 2), 30f)
        h.remote.playback = emptyList()
        h.remote.plays = listOf(episodePlay(1, 2, atMs = h.nowMs + 600_000))
        var calls = 0
        h.drain(h.outbox()) { _, _ -> calls++; TraktScrobbleDelivery.SENT }
        assertEquals(0, calls)
        assertTrue(h.pending().isEmpty())
    }

    @Test
    fun pausedReplayGoesAheadWhenTraktHasNothing() = runTest {
        val h = Harness()
        h.queueOffline(episode(1, 2), 30f)
        var calls = 0
        h.drain(h.outbox()) { _, _ -> calls++; TraktScrobbleDelivery.SENT }
        assertEquals(1, calls)
        assertEquals("episode", h.remote.playsCalls.single().first)
    }

    // ── BUG-231: provisional stops (a session killed before it could send its stop) ────────

    @Test
    fun aKilledSessionLeavesItsLastPositionForTheNextLaunch() = runTest {
        val h = Harness()
        // Run 1: the session starts, plays, and the app is killed. No stop is ever sent.
        val run1 = h.outbox()
        run1.onSessionStarted(1, episode().itemKey)
        assertTrue(run1.noteSessionProgress(1, episode(), 4f))
        h.nowMs += 60_000
        assertTrue(run1.noteSessionProgress(1, episode(), 9.5f))
        val left = h.pending().single()
        assertEquals(9.5f, left.progress)
        assertTrue(left.provisional)
        assertEquals(h.nowMs, left.createdAtMs)

        // Run 2: the launch drain sends it like any other pending stop.
        val replayed = mutableListOf<Pair<TraktScrobbleItem, Float>>()
        val result = h.drain(h.outbox()) { item, progress ->
            replayed += item to progress
            TraktScrobbleDelivery.SENT
        }
        assertEquals(listOf<Pair<TraktScrobbleItem, Float>>(episode() to 9.5f), replayed)
        assertEquals(1, result.sent)
        assertTrue(h.pending().isEmpty())
    }

    @Test
    fun provisionalWritesAreThrottledPerSession() = runTest {
        val h = Harness()
        val outbox = h.outbox()
        outbox.onSessionStarted(1, movie().itemKey)
        assertTrue(outbox.noteSessionProgress(1, movie(), 5f))
        h.nowMs += TraktScrobbleStopOutbox.DEFAULT_PROVISIONAL_INTERVAL_MS - 1
        assertFalse(outbox.noteSessionProgress(1, movie(), 6f))
        assertEquals(5f, h.pending().single().progress)
        h.nowMs += 1
        assertTrue(outbox.noteSessionProgress(1, movie(), 6.5f))
        assertEquals(6.5f, h.pending().single().progress, "one entry per item, the newest position")
    }

    @Test
    fun provisionalWritesNeedAnOpenSessionAConnectedAccountAndOnePercent() = runTest {
        val h = Harness()
        val outbox = h.outbox()
        assertFalse(outbox.noteSessionProgress(1, movie(), 20f), "no session was started")
        outbox.onSessionStarted(1, movie().itemKey)
        assertFalse(outbox.noteSessionProgress(1, movie("tt2"), 20f), "another item than the open session")
        assertFalse(outbox.noteSessionProgress(2, movie(), 20f), "another profile than the open session")
        assertFalse(outbox.noteSessionProgress(1, movie(), 0.5f), "Trakt rejects a stop below 1 %")
        h.connected = false
        assertFalse(outbox.noteSessionProgress(1, movie(), 20f), "no Trakt account connected")
        assertTrue(h.pending().isEmpty())
    }

    @Test
    fun theCleanStopReplacesTheProvisionalEntry() = runTest {
        val h = Harness()
        val outbox = h.outbox()
        outbox.onSessionStarted(1, movie().itemKey)
        outbox.noteSessionProgress(1, movie(), 30f)
        h.nowMs += 5_000
        var pendingDuringSend: List<TraktPendingScrobbleStop>? = null
        outbox.sendStop(1, movie(), 31f) { _, _ ->
            pendingDuringSend = h.pending()
            TraktScrobbleDelivery.SENT
        }
        val during = pendingDuringSend!!.single()
        assertEquals(31f, during.progress)
        assertFalse(during.provisional)
        assertTrue(h.pending().isEmpty(), "a stop that landed leaves nothing to replay")
        // The session is closed: a late progress tick writes nothing.
        assertFalse(outbox.noteSessionProgress(1, movie(), 31f))
        assertTrue(h.pending().isEmpty())
    }

    @Test
    fun aStopBelowOnePercentDropsTheProvisionalEntryButKeepsARealPendingStop() = runTest {
        val h = Harness()
        // A real stop for another item is waiting (it failed offline earlier).
        h.queueOffline(movie("tt-older"), 40f)
        val outbox = h.outbox()
        // A stream that turned out to be live or a placeholder: it closes at 0 %.
        outbox.onSessionStarted(1, movie().itemKey)
        outbox.noteSessionProgress(1, movie(), 12f)
        assertEquals(2, h.pending().size)
        outbox.sendStop(1, movie(), 0f) { _, _ -> TraktScrobbleDelivery.REJECTED }
        val left = h.pending().single()
        assertEquals(movie("tt-older").itemKey, left.itemKey)
        assertFalse(left.provisional)
    }

    @Test
    fun aStopBelowOnePercentKeepsAnEarlierKilledSessionsEntry() = runTest {
        // Review r1 P3-2. Run 1 is killed at 50 %; its entry waits (the launch drain was deferred).
        val h = Harness()
        val run1 = h.outbox()
        run1.onSessionStarted(1, movie().itemKey)
        run1.noteSessionProgress(1, movie(), 50f)
        // Run 2: the viewer opens the same film (it starts at 0, Trakt never got the 50 %) and
        // backs out at once.
        val run2 = h.outbox()
        run2.onSessionStarted(1, movie().itemKey)
        assertFalse(run2.noteSessionProgress(1, movie(), 0.2f))
        run2.sendStop(1, movie(), 0.2f) { _, _ -> TraktScrobbleDelivery.REJECTED }
        val left = h.pending().single()
        assertEquals(50f, left.progress, "the killed session's position is not run 2's to drop")
        var replayed = 0f
        h.drain(run2) { _, progress -> replayed = progress; TraktScrobbleDelivery.SENT }
        assertEquals(50f, replayed)
    }

    @Test
    fun aSessionThatTurnsOutLiveDropsWhatItWrote() = runTest {
        // Review r1 P3-4: the players report 0 once a stream reads live or as a placeholder clip.
        val h = Harness()
        val outbox = h.outbox()
        outbox.onSessionStarted(1, movie().itemKey)
        assertTrue(outbox.noteSessionProgress(1, movie(), 3f))
        assertEquals(1, h.pending().size)
        assertFalse(outbox.noteSessionProgress(1, movie(), 0f))
        assertTrue(h.pending().isEmpty(), "a crash from here must leave nothing to replay")
        // If it reads as a film again, the next position is written at once (no throttle carry-over).
        assertTrue(outbox.noteSessionProgress(1, movie(), 4f))
        assertEquals(4f, h.pending().single().progress)
    }

    @Test
    fun aNewSessionOfTheSameItemSupersedesTheKilledSessionsEntry() = runTest {
        val h = Harness()
        val run1 = h.outbox()
        run1.onSessionStarted(1, movie().itemKey)
        run1.noteSessionProgress(1, movie(), 50f)
        val run2 = h.outbox()
        run2.onSessionStarted(1, movie().itemKey)
        h.nowMs += 120_000
        assertTrue(run2.noteSessionProgress(1, movie(), 12f))
        assertEquals(12f, h.pending().single().progress, "one entry per item, the newer session's")
    }

    @Test
    fun aDrainThatReadTraktWhileTheSessionStoppedDoesNotSendTheProvisionalEntry() = runTest {
        // Review r1 P3-3: the clean stop supersedes the provisional entry while the drain is
        // reading Trakt for it.
        val h = Harness()
        val run1 = h.outbox()
        run1.onSessionStarted(1, movie().itemKey)
        run1.noteSessionProgress(1, movie(), 30f)
        // Next launch: the same film is opened again and stopped while the drain reads Trakt.
        val run2 = h.outbox()
        var replays = 0
        h.remote.onPlayback = {
            run2.onSessionStarted(1, movie().itemKey)
            run2.sendStop(1, movie(), 35f) { _, _ -> TraktScrobbleDelivery.SENT }
        }
        h.drain(run2) { _, _ -> replays++; TraktScrobbleDelivery.SENT }
        assertEquals(0, replays, "the 30 % entry was superseded by the 35 % stop that landed")
        assertTrue(h.pending().isEmpty())
    }

    @Test
    fun theDrainLeavesThePlayingSessionsProvisionalEntryAlone() = runTest {
        val h = Harness()
        val outbox = h.outbox()
        outbox.onSessionStarted(1, movie().itemKey)
        outbox.noteSessionProgress(1, movie(), 25f)
        var calls = 0
        h.drain(outbox) { _, _ -> calls++; TraktScrobbleDelivery.SENT }
        assertEquals(0, calls, "a replay must not end the session that is playing")
        assertEquals(1, h.pending().size)
    }

    @Test
    fun aKilledSessionFinishedElsewhereSinceIsNotReplayed() = runTest {
        val h = Harness()
        val run1 = h.outbox()
        run1.onSessionStarted(1, episode(1, 2).itemKey)
        run1.noteSessionProgress(1, episode(1, 2), 30f)
        // Before the next launch the episode is finished on another device.
        h.remote.playback = emptyList()
        h.remote.plays = listOf(episodePlay(1, 2, atMs = h.nowMs + 600_000))
        var calls = 0
        val result = h.drain(h.outbox()) { _, _ -> calls++; TraktScrobbleDelivery.SENT }
        assertEquals(0, calls)
        assertEquals(1, result.superseded)
        assertTrue(h.pending().isEmpty())
    }

    @Test
    fun aKilledSessionResumedElsewhereSinceIsNotReplayed() = runTest {
        val h = Harness()
        val run1 = h.outbox()
        run1.onSessionStarted(1, movie().itemKey)
        run1.noteSessionProgress(1, movie(), 30f)
        // Another device paused the film further in, after the kill.
        h.remote.playback = listOf(
            TraktRemoteProgress(
                kind = "movie",
                ids = TraktExternalIds(imdb = "tt0111161"),
                atMs = h.nowMs + 3_600_000,
                progress = 55f,
            ),
        )
        var calls = 0
        h.drain(h.outbox()) { _, _ -> calls++; TraktScrobbleDelivery.SENT }
        assertEquals(0, calls)
        assertTrue(h.pending().isEmpty())
    }

    @Test
    fun aProvisionalEntryFromBeforeTheFieldExistedDecodesAsARealStop() = runTest {
        val h = Harness()
        h.queueOffline(movie(), 40f)
        assertFalse(h.pending().single().provisional)
        assertFalse(h.storage[1]!!.contains("provisional"), "the default is not written, so older builds read the payload")
    }

    @Test
    fun anUnreadableTraktStateKeepsEverything() = runTest {
        val h = Harness()
        h.queueOffline(movie("tt1"), 30f)
        h.remote.playback = null
        var calls = 0
        val result = h.drain(h.outbox()) { _, _ -> calls++; TraktScrobbleDelivery.SENT }
        assertEquals(0, calls)
        assertEquals(1, result.kept)
        assertEquals(0, h.pending().single().attempts)
    }

    @Test
    fun traktStateIsReadOncePerDrain() = runTest {
        val h = Harness()
        h.queueOffline(movie("tt1"), 30f)
        h.nowMs += 1
        h.queueOffline(movie("tt2"), 30f)
        h.drain(h.outbox()) { _, _ -> TraktScrobbleDelivery.SENT }
        assertEquals(1, h.remote.playbackCalls)
        assertEquals(1, h.remote.playsCalls.size)
        assertEquals(h.pending().size, 0)
    }

    @Test
    fun aStopQueuedForAnotherTraktAccountIsDropped() = runTest {
        val h = Harness(slug = "alice")
        h.queueOffline(movie(), 30f)
        assertEquals("alice", h.pending().single().accountSlug)
        h.remote.slug = "bob"
        var calls = 0
        val result = h.drain(h.outbox()) { _, _ -> calls++; TraktScrobbleDelivery.SENT }
        assertEquals(0, calls)
        assertEquals(1, result.dropped)
        assertTrue(h.pending().isEmpty())
    }

    @Test
    fun theSameAccountReplaysAndAnUnknownAccountWaits() = runTest {
        val h = Harness(slug = "alice")
        h.queueOffline(movie(), 30f)
        h.remote.slug = null
        var calls = 0
        h.drain(h.outbox()) { _, _ -> calls++; TraktScrobbleDelivery.SENT }
        assertEquals(0, calls, "user settings not fetched yet: wait")
        assertEquals(1, h.pending().size)
        h.remote.slug = "Alice"
        h.drain(h.outbox()) { _, _ -> calls++; TraktScrobbleDelivery.SENT }
        assertEquals(1, calls)
    }

    @Test
    fun aDrainDuringALiveSendLeavesTheInFlightEntryAlone() = runTest {
        val h = Harness()
        val outbox = h.outbox()
        var replayed = 0
        outbox.sendStop(1, movie(), 40f) { _, _ ->
            // The live send is mid-retry when a drain runs (auth flip, profile re-selection).
            h.drain(outbox) { _, _ -> replayed++; TraktScrobbleDelivery.SENT }
            TraktScrobbleDelivery.SENT
        }
        assertEquals(0, replayed, "the same stop must not be sent twice")
        assertTrue(h.pending().isEmpty())
    }

    @Test
    fun aRetryableFailureDoesNotBlockTheNextEntry() = runTest {
        val h = Harness()
        h.queueOffline(movie("tt1"), 30f)
        h.nowMs += 1
        h.queueOffline(movie("tt2"), 30f)
        val sent = mutableListOf<String>()
        val result = h.drain(h.outbox()) { item, _ ->
            sent += item.itemKey
            if (item.itemKey == movie("tt1").itemKey) TraktScrobbleDelivery.RETRYABLE else TraktScrobbleDelivery.SENT
        }
        assertEquals(listOf(movie("tt1").itemKey, movie("tt2").itemKey), sent)
        assertEquals(1, result.sent)
        assertEquals(listOf(movie("tt1").itemKey), h.pending().map { it.itemKey })
    }

    @Test
    fun noAuthStopsTheDrain() = runTest {
        val h = Harness()
        h.queueOffline(movie("tt1"), 30f)
        h.nowMs += 1
        h.queueOffline(movie("tt2"), 30f)
        var calls = 0
        h.drain(h.outbox()) { _, _ -> calls++; TraktScrobbleDelivery.NOT_READY }
        assertEquals(1, calls)
        assertEquals(2, h.pending().size)
    }

    @Test
    fun aWipeDuringAMutationIsNotWrittenBack() = runTest {
        val h = Harness()
        h.queueOffline(movie(), 30f)
        val id = h.pending().single().id
        // The platform sign-out wipe lands while recordFailedAttempt is between read and write.
        h.onLoad = {
            h.onLoad = null
            h.queue.invalidate()
            h.storage.clear()
        }
        h.queue.recordFailedAttempt(1, id, maxAttempts = 5)
        assertTrue(h.storage.isEmpty())
    }

    @Test
    fun clearProfileAndWipeAllEraseUnderTheLock() = runTest {
        val h = Harness()
        h.queueOffline(movie("tt1"), 30f)
        h.activeProfile = 2
        h.outbox().sendStop(2, movie("tt2"), 30f) { _, _ -> TraktScrobbleDelivery.OFFLINE }
        h.queue.clearProfile(1)
        assertNull(h.storage[1])
        assertEquals(1, h.pending(2).size)
        h.queue.wipeAll(1..6)
        assertTrue(h.storage.isEmpty())
    }

    @Test
    fun remoteRowsMatchByAnySharedIdAndEpisodeNumber() {
        val m = TraktPendingScrobbleItem.from(movie("tt0111161"))
        assertTrue(m.matches(moviePlay("TT0111161", 0)))
        assertTrue(!m.matches(moviePlay("tt9", 0)))
        val e = TraktPendingScrobbleItem.from(episode(2, 5))
        assertTrue(e.matches(episodePlay(2, 5, 0)))
        assertTrue(!e.matches(episodePlay(2, 6, 0)))
        assertTrue(!e.matches(moviePlay("tt0903747", 0)), "kind must match")
    }

    // ── Review round 2 (P3-a, P3-b, P3-c, P3-f) ───────────────────────────────────────────

    private fun pausedRow(progress: Float?, atMs: Long) = TraktRemoteProgress(
        kind = "movie",
        ids = TraktExternalIds(imdb = "tt0111161"),
        atMs = atMs,
        progress = progress,
    )

    private suspend fun Harness.replayCount(): Int {
        var calls = 0
        drain(outbox()) { _, _ -> calls++; TraktScrobbleDelivery.SENT }
        return calls
    }

    @Test
    fun anEarlierOwnStopOnTraktDoesNotHideTheFinalOne() = runTest {
        val h = Harness()
        val firstStopLandedAt = h.nowMs
        h.nowMs += 8 * 60 * 1000 // the final 30 % stop fails 8 min after a 20 % stop landed
        h.queueOffline(movie(), 30f)
        h.remote.playback = listOf(pausedRow(progress = 20f, atMs = firstStopLandedAt))
        assertEquals(1, h.replayCount(), "inside the old 10-min slack, but older and at another position")
    }

    @Test
    fun aPausedRowAtTheSamePositionIsOurOwnStop() = runTest {
        val h = Harness()
        h.queueOffline(movie(), 30f)
        // The live stop landed (answer lost); Trakt's paused_at may even read earlier (clock skew).
        h.remote.playback = listOf(pausedRow(progress = 30.6f, atMs = h.nowMs - 120_000))
        assertEquals(0, h.replayCount())
        assertTrue(h.pending().isEmpty())
    }

    @Test
    fun aLaterPausedRowAtAnotherPositionIsNewer() = runTest {
        val h = Harness()
        h.queueOffline(movie(), 30f)
        h.remote.playback = listOf(pausedRow(progress = 55f, atMs = h.nowMs + 1))
        assertEquals(0, h.replayCount())
        assertTrue(h.pending().isEmpty())
    }

    @Test
    fun aRowPausedJustBeforeTheEntryIsNotNewer() = runTest {
        val h = Harness()
        h.queueOffline(movie(), 30f)
        h.remote.playback = listOf(pausedRow(progress = 55f, atMs = h.nowMs - 5 * 60 * 1000))
        assertEquals(1, h.replayCount(), "no slack on the paused comparison")
    }

    @Test
    fun aStalePausedRowWithALaterPlayDoesNotBringResumeBack() = runTest {
        val h = Harness()
        h.queueOffline(movie(), 30f)
        h.remote.playback = listOf(pausedRow(progress = 10f, atMs = h.nowMs - 60 * 60 * 1000))
        h.remote.plays = listOf(moviePlay("tt0111161", atMs = h.nowMs + 30 * 60 * 1000))
        assertEquals(0, h.replayCount())
        assertTrue(h.pending().isEmpty())
    }

    @Test
    fun aSendFollowedByAReadFailureKeepsTheRest() = runTest {
        val h = Harness()
        h.queueOffline(movie(), 30f)
        h.nowMs += 1
        h.queueOffline(episode(1, 2), 30f)
        h.remote.failPlaysFor = "episode"
        val sent = mutableListOf<String>()
        val result = h.drain(h.outbox()) { item, _ -> sent += item.itemKey; TraktScrobbleDelivery.SENT }
        assertEquals(listOf(movie().itemKey), sent, "the movie was checked and sent before the episode read failed")
        assertEquals(1, result.sent)
        assertEquals(1, result.kept)
        assertEquals(listOf(episode(1, 2).itemKey), h.pending().map { it.itemKey })
    }

    @Test
    fun anUnknownAccountIsFetchedOnceBeforeWaiting() = runTest {
        val h = Harness(slug = "alice")
        h.queueOffline(movie("tt1"), 30f)
        h.nowMs += 1
        h.queueOffline(movie("tt2"), 30f)
        h.remote.slug = null
        h.remote.slugAfterRefresh = "alice"
        assertEquals(2, h.replayCount())
        assertEquals(1, h.remote.refreshes)

        h.queueOffline(movie("tt3"), 30f)
        h.remote.slug = null
        h.remote.slugAfterRefresh = null
        assertEquals(0, h.replayCount(), "still unknown after the fetch: wait")
        assertEquals(2, h.remote.refreshes)
        assertEquals(1, h.pending().size)
    }

    @Test
    fun clearingOneProfileKeepsAnotherProfilesQueue() = runTest {
        val h = Harness()
        h.queueOffline(movie("tt1"), 30f)
        h.activeProfile = 2
        h.outbox().sendStop(2, movie("tt2"), 30f) { _, _ -> TraktScrobbleDelivery.OFFLINE }
        h.queue.clearProfile(2)
        h.activeProfile = 1
        h.nowMs += 1
        h.queueOffline(movie("tt3"), 30f)
        assertEquals(2, h.pending(1).size, "profile 1 writes are not discarded by profile 2's clear")
        assertTrue(h.pending(2).isEmpty())
    }
}
