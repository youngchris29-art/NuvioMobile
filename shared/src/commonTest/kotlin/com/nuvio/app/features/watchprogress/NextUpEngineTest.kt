package com.nuvio.app.features.watchprogress

import com.nuvio.app.features.details.MetaDetails
import com.nuvio.app.features.details.MetaVideo
import com.nuvio.app.features.tracking.WatchProgressSource
import com.nuvio.app.features.watched.WatchedItem
import kotlinx.coroutines.CompletableDeferred
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.ExperimentalCoroutinesApi
import kotlinx.coroutines.async
import kotlinx.coroutines.test.advanceTimeBy
import kotlinx.coroutines.test.runCurrent
import kotlinx.coroutines.test.runTest
import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertFalse
import kotlin.test.assertTrue

/**
 * FEAT-85 (review round 2 P3-3): the stateful Up Next engine with its outside world faked —
 * the result cache and its unaired recheck, the generation guard, stage-1 reuse, the removal
 * order and the Trakt mark seeds.
 */
@OptIn(ExperimentalCoroutinesApi::class)
class NextUpEngineTest {
    private val t0 = 1_700_000_000_000L

    private class Fakes {
        var fetches = 0
        val metaById = mutableMapOf<String, MetaDetails>()
        val refetches = mutableListOf<String>()
        var gate: CompletableDeferred<Unit>? = null
    }

    private fun engine(fakes: Fakes, scope: CoroutineScope) = NextUpEngine(
        fetchMeta = { _, id ->
            fakes.fetches += 1
            fakes.gate?.await()
            fakes.metaById[id]
        },
        prepareEntries = { entries, _ -> entries },
        isDroppedShow = { false },
        recencyCutoffEpochMs = { null },
        refetchEpisodeProgress = { contentId -> fakes.refetches += contentId },
        refetchScope = scope,
    )

    private fun series(id: String, vararg released: String) = MetaDetails(
        id = id,
        type = "series",
        name = id,
        videos = released.mapIndexed { index, date ->
            MetaVideo(id = "$id:1:${index + 1}", title = "E${index + 1}", released = date, season = 1, episode = index + 1)
        },
    )

    private fun progress(id: String, episode: Int, at: Long, completed: Boolean, position: Long? = null) =
        WatchProgressEntry(
            contentType = "series",
            parentMetaId = id,
            parentMetaType = "series",
            videoId = "$id:1:$episode",
            title = id,
            seasonNumber = 1,
            episodeNumber = episode,
            lastPositionMs = position ?: if (completed) 3_000_000L else 600_000L,
            durationMs = 3_000_000L,
            lastUpdatedEpochMs = at,
            isCompleted = completed,
        )

    private fun inputs(
        entries: List<WatchProgressEntry>,
        now: Long = t0,
        source: WatchProgressSource = WatchProgressSource.NUVIO_SYNC,
        history: List<WatchedItem> = emptyList(),
        dismissed: Set<String> = emptySet(),
        profileId: Int = 1,
        showUnaired: Boolean = true,
    ) = NextUpInputs(
        profileId = profileId,
        source = source,
        preferFurthestEpisode = true,
        showUnairedNextUp = showUnaired,
        dismissedNextUpKeys = dismissed,
        nowEpochMs = now,
        todayIsoDate = "2026-10-23",
        entries = entries,
        historyItems = history,
        isProgressSeed = { entry, _ -> entry.shouldUseAsCompletedSeedForContinueWatching() },
    )

    private val aired = "2020-01-01"

    @Test
    fun resolvesTheNextEpisodeOnceAndReusesIt() = runTest {
        val fakes = Fakes().apply { metaById["tt1"] = series("tt1", aired, aired, aired, aired) }
        val engine = engine(fakes, this)
        val entries = listOf(progress("tt1", 3, t0, completed = true))

        val first = engine.resolve({ inputs(entries) }, limit = 20)
        assertEquals(listOf("tt1:1:4"), first.map { it.videoId })
        assertTrue(first.single().isContinueWatchingNextUp)
        assertEquals(0L, first.single().lastPositionMs)

        assertEquals(first, engine.resolve({ inputs(entries) }, limit = 20))
        assertEquals(1, fakes.fetches)
    }

    @Test
    fun anUnairedEpisodeIsDroppedUntilItsReleaseInstantThenShown() = runTest {
        val releaseAt = parseReleaseDateToEpochMs("2026-10-24T01:00:00.000Z")!!
        val fakes = Fakes().apply { metaById["tt1"] = series("tt1", aired, aired, aired, "2026-10-24T01:00:00.000Z") }
        val engine = engine(fakes, this)
        val entries = listOf(progress("tt1", 3, t0, completed = true))

        // 20:00 EDT on the 23rd: not out yet, and the "no card" is cached only until 01:00Z.
        assertTrue(engine.resolve({ inputs(entries, now = releaseAt - 3_600_000L) }, 20).isEmpty())
        assertTrue(engine.resolve({ inputs(entries, now = releaseAt - 60_000L) }, 20).isEmpty())
        assertEquals(1, fakes.fetches)

        // The first refresh after the instant resolves again, the same local day.
        val after = engine.resolve({ inputs(entries, now = releaseAt + 1_000L) }, 20)
        assertEquals(listOf("tt1:1:4"), after.map { it.videoId })
        assertEquals(2, fakes.fetches)
    }

    @Test
    fun aDateOnlyReleaseFlipsAtTheParsedInstantInAnyZone() = runTest {
        val releaseAt = parseReleaseDateToEpochMs("2026-10-24")!!
        val fakes = Fakes().apply { metaById["tt1"] = series("tt1", aired, aired, aired, "2026-10-24") }
        val engine = engine(fakes, this)
        val entries = listOf(progress("tt1", 3, t0, completed = true))

        assertTrue(engine.resolve({ inputs(entries, now = releaseAt - 1L) }, 20).isEmpty())
        assertEquals(listOf("tt1:1:4"), engine.resolve({ inputs(entries, now = releaseAt) }, 20).map { it.videoId })
    }

    @Test
    fun aResetDuringARefreshKeepsItsResultsOut() = runTest {
        val fakes = Fakes().apply {
            metaById["tt1"] = series("tt1", aired, aired, aired, aired)
            gate = CompletableDeferred()
        }
        val engine = engine(fakes, this)
        val entries = listOf(progress("tt1", 3, t0, completed = true))

        val inFlight = async { engine.resolve({ inputs(entries, profileId = 1) }, 20) }
        runCurrent()
        assertEquals(1, fakes.fetches)
        engine.reset() // profile switch while the fetch is out
        fakes.gate!!.complete(Unit)

        assertTrue(inFlight.await().isEmpty())
        assertTrue(engine.dismissKeysSnapshot().isEmpty())
        // Nothing was cached: the next refresh, for the SAME profile (a different one could never
        // hit the old key anyway), fetches again.
        fakes.gate = null
        assertEquals(listOf("tt1:1:4"), engine.resolve({ inputs(entries, profileId = 1) }, 20).map { it.videoId })
        assertEquals(2, fakes.fetches)
    }

    @Test
    fun stageOneIsReusedUntilWhatItReadsChanges() = runTest {
        val fakes = Fakes().apply { metaById["tt1"] = series("tt1", aired, aired, aired, aired, aired) }
        val engine = engine(fakes, this)
        val done = progress("tt1", 3, t0, completed = true)
        val playing = progress("tt1", 4, t0 - 10_000L, completed = false)

        engine.resolve({ inputs(listOf(done, playing)) }, 20)
        assertEquals(1, engine.stageOneBuilds)
        // A playback save: position and time move, nothing else.
        val saved = playing.copy(lastPositionMs = 900_000L, lastUpdatedEpochMs = t0 - 5_000L)
        engine.resolve({ inputs(listOf(done, saved)) }, 20)
        assertEquals(1, engine.stageOneBuilds)
        // The episode finishes: rebuilt.
        engine.resolve({ inputs(listOf(done, progress("tt1", 4, t0 + 1_000L, completed = true))) }, 20)
        assertEquals(2, engine.stageOneBuilds)

        // Under Trakt the key carries the minute (its playback seed rule is time-bound)...
        val traktEntries = listOf(done)
        engine.resolve({ inputs(traktEntries, source = WatchProgressSource.TRAKT, now = t0) }, 20)
        assertEquals(3, engine.stageOneBuilds)
        engine.resolve({ inputs(traktEntries, source = WatchProgressSource.TRAKT, now = t0 + 1_000L) }, 20)
        assertEquals(3, engine.stageOneBuilds)
        engine.resolve({ inputs(traktEntries, source = WatchProgressSource.TRAKT, now = t0 + 61_000L) }, 20)
        assertEquals(4, engine.stageOneBuilds)
        // ...and elsewhere it does not.
        engine.resolve({ inputs(traktEntries, now = t0) }, 20)
        assertEquals(5, engine.stageOneBuilds)
        engine.resolve({ inputs(traktEntries, now = t0 + 600_000L) }, 20)
        assertEquals(5, engine.stageOneBuilds)
    }

    @Test
    fun droppingAndRestoringASeasonReResolvesTheCachedNextUp() = runTest {
        // Codex r14 on the MDBList remap: the seed's exclusions are part of stage 1 and of the resolve key.
        val fakes = Fakes().apply { metaById["tt1"] = series("tt1", aired, aired, aired, aired, aired, aired) }
        val engine = engine(fakes, this)
        val done = progress("tt1", 3, t0, completed = true)

        assertEquals(listOf("tt1:1:4"), engine.resolve({ inputs(listOf(done)) }, 20).map { it.videoId })
        assertEquals(1, fakes.fetches)
        // The provider's dropped season now covers S1E4: the cached answer is not reused.
        val dropped = done.copy(excludedNextUpEpisodeKeys = setOf(nextUpEpisodeKey(1, 4)))
        assertEquals(listOf("tt1:1:5"), engine.resolve({ inputs(listOf(dropped)) }, 20).map { it.videoId })
        assertEquals(2, engine.stageOneBuilds)
        assertEquals(2, fakes.fetches)
        // Restored: S1E4 again, resolved afresh rather than from the dropped answer.
        assertEquals(listOf("tt1:1:4"), engine.resolve({ inputs(listOf(done)) }, 20).map { it.videoId })
        assertEquals(3, engine.stageOneBuilds)
        // A whole dropped season behaves the same way.
        val wholeSeason = done.copy(excludedNextUpSeasons = setOf(1))
        assertEquals(emptyList(), engine.resolve({ inputs(listOf(wholeSeason)) }, 20).map { it.videoId })
    }

    @Test
    fun removingAProgressCardDismissesTheUncoveredUpNextBeforeClearing() = runTest {
        val engine = engine(Fakes(), this)
        val e4 = progress("tt1", 4, t0 + 1_000L, completed = false)
        val entries = listOf(progress("tt1", 3, t0, completed = true), e4)
        val calls = mutableListOf<String>()

        engine.removeFromContinueWatching(
            entry = e4,
            inputs = { inputs(entries) },
            addDismissedKey = { key -> calls += "dismiss $key" },
            clearProgress = { card -> calls += "clear ${card.videoId}" },
        )
        assertEquals(listOf("dismiss ${nextUpDismissKey("tt1", 1, 3)}", "clear tt1:1:4"), calls)
    }

    @Test
    fun removingAnUpNextCardOnlyDismissesIt() = runTest {
        val fakes = Fakes().apply { metaById["tt1"] = series("tt1", aired, aired, aired, aired) }
        val engine = engine(fakes, this)
        val entries = listOf(progress("tt1", 3, t0, completed = true))
        val card = engine.resolve({ inputs(entries) }, 20).single()
        val calls = mutableListOf<String>()

        engine.removeFromContinueWatching(
            entry = card,
            inputs = { inputs(entries) },
            addDismissedKey = { key -> calls += "dismiss $key" },
            clearProgress = { removed -> calls += "clear ${removed.videoId}" },
        )
        assertEquals(listOf("dismiss ${nextUpDismissKey("tt1", 1, 3)}"), calls)
    }

    @Test
    fun aMarkIsRecordedOnlyUnderTraktAndRefetchesOnceAfterTheDelay() = runTest {
        val fakes = Fakes()
        val engine = engine(fakes, this)
        val card = progress("tt1", 4, t0, completed = false).copy(source = WatchProgressSourceNextUp)

        assertFalse(engine.noteMarkedWatched(card, WatchProgressSource.NUVIO_SYNC, 1, t0) { true })
        advanceTimeBy(ContinueWatchingNextUpTraktRefetchDelayMs + 1)
        assertTrue(fakes.refetches.isEmpty())

        assertTrue(engine.noteMarkedWatched(card, WatchProgressSource.TRAKT, 1, t0) { true })
        runCurrent()
        assertTrue(fakes.refetches.isEmpty(), "no immediate refetch (it raced the history push)")
        advanceTimeBy(ContinueWatchingNextUpTraktRefetchDelayMs + 1)
        assertEquals(listOf("tt1"), fakes.refetches)

        // A source or profile change in between cancels the refetch.
        assertTrue(engine.noteMarkedWatched(card, WatchProgressSource.TRAKT, 1, t0) { false })
        advanceTimeBy(ContinueWatchingNextUpTraktRefetchDelayMs + 1)
        assertEquals(listOf("tt1"), fakes.refetches)
    }

    @Test
    fun underTraktAMarkMovesUpNextOnAndAnUnmarkMovesItBack() = runTest {
        val fakes = Fakes().apply { metaById["tt1"] = series("tt1", aired, aired, aired, aired, aired) }
        val engine = engine(fakes, this)
        // Trakt still says E3 is the last one finished.
        val entries = listOf(progress("tt1", 3, t0, completed = true))
        val trakt = { now: Long -> inputs(entries, source = WatchProgressSource.TRAKT, now = now) }

        val card = engine.resolve({ trakt(t0 + 1_000L) }, 20).single()
        assertEquals("tt1:1:4", card.videoId)

        engine.noteMarkedWatched(card, WatchProgressSource.TRAKT, 1, t0 + 2_000L) { true }
        assertEquals(listOf("tt1:1:5"), engine.resolve({ trakt(t0 + 3_000L) }, 20).map { it.videoId })

        engine.onUnmarkedWatched(listOf(WatchedItem(id = "tt1", type = "series", name = "tt1", season = 1, episode = 4, markedAtEpochMs = 0L)))
        assertEquals(listOf("tt1:1:4"), engine.resolve({ trakt(t0 + 4_000L) }, 20).map { it.videoId })
    }

    @Test
    fun withUnairedNextUpOffTheNoCardIsRecheckedAtTheNextRelease() = runTest {
        // "Show unaired next up" OFF: seriesPrimaryAction itself returns nothing for E4, so the air
        // check never runs. The "no card" must still be reused only until E4's release instant.
        // (seriesPrimaryAction reads the real clock, hence a far-future date: this checks the
        // recheck, not the card that follows it.)
        val releaseAt = parseReleaseDateToEpochMs("2099-06-01T01:00:00.000Z")!!
        val fakes = Fakes().apply { metaById["tt1"] = series("tt1", aired, aired, aired, "2099-06-01T01:00:00.000Z") }
        val engine = engine(fakes, this)
        val entries = listOf(progress("tt1", 3, t0, completed = true))
        val off = { now: Long -> inputs(entries, now = now, showUnaired = false) }

        assertTrue(engine.resolve({ off(t0) }, 20).isEmpty())
        assertTrue(engine.resolve({ off(t0 + 60_000L) }, 20).isEmpty())
        assertEquals(1, fakes.fetches, "the no-card verdict is reused before the release")
        engine.resolve({ off(releaseAt + 1_000L) }, 20)
        assertEquals(2, fakes.fetches, "and resolved again once the release instant has passed")
    }

    @Test
    fun withUnairedNextUpOffAnAiredNextEpisodeStillGetsItsCard() = runTest {
        val fakes = Fakes().apply { metaById["tt1"] = series("tt1", aired, aired, aired, aired) }
        val engine = engine(fakes, this)
        val entries = listOf(progress("tt1", 3, t0, completed = true))
        assertEquals(listOf("tt1:1:4"), engine.resolve({ inputs(entries, showUnaired = false) }, 20).map { it.videoId })
    }

    @Test
    fun aRefreshQueuedBehindASlowOneReadsItsInputsAfterAReset() = runTest {
        val fakes = Fakes().apply {
            metaById["tt1"] = series("tt1", aired, aired, aired, aired)
            metaById["tt2"] = series("tt2", aired, aired, aired, aired)
            gate = CompletableDeferred()
        }
        val engine = engine(fakes, this)
        var activeProfile = 1
        val readFor = mutableListOf<Int>()
        // What the repositories would say at the moment the refresh reads them.
        val current = {
            readFor += activeProfile
            val id = if (activeProfile == 1) "tt1" else "tt2"
            inputs(listOf(progress(id, 3, t0, completed = true)), profileId = activeProfile)
        }

        val slow = async { engine.resolve(current, 20) }
        runCurrent() // profile 1's refresh is out fetching
        val queued = async { engine.resolve(current, 20) }
        runCurrent() // waiting on the refresh lock
        assertEquals(listOf(1), readFor, "the queued refresh has not read its inputs yet")

        engine.reset()
        activeProfile = 2
        fakes.gate!!.complete(Unit)

        assertTrue(slow.await().isEmpty(), "profile 1's late result is dropped")
        assertEquals(listOf("tt2:1:4"), queued.await().map { it.videoId })
        assertEquals(listOf(1, 2), readFor)
        // Only profile 2's card left a dismiss key behind.
        assertEquals(setOf("tt2:1:4"), engine.dismissKeysSnapshot().keys)
    }
}
