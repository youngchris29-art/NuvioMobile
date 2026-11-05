package com.nuvio.app.features.watchprogress

import com.nuvio.app.features.details.MetaVideo
import com.nuvio.app.features.watched.WatchedItem
import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertFalse
import kotlin.test.assertNotEquals
import kotlin.test.assertNull
import kotlin.test.assertSame
import kotlin.test.assertTrue

/** FEAT-85 Up Next (based on erdist's patch, GitHub #11): seed selection, merge and dismissal in `ContinueWatchingNextUp.kt`. */
class ContinueWatchingNextUpTest {
    private val t0 = 1_700_000_000_000L

    private fun progress(
        seriesId: String,
        season: Int,
        episode: Int,
        at: Long,
        completed: Boolean,
        type: String = "series",
    ) = WatchProgressEntry(
        contentType = type,
        parentMetaId = seriesId,
        parentMetaType = type,
        videoId = "$seriesId:$season:$episode",
        title = seriesId,
        seasonNumber = season,
        episodeNumber = episode,
        lastPositionMs = if (completed) 3_000_000L else 600_000L,
        durationMs = 3_000_000L,
        lastUpdatedEpochMs = at,
        isCompleted = completed,
    )

    private fun watched(seriesId: String, season: Int, episode: Int, at: Long) = WatchedItem(
        id = seriesId,
        type = "series",
        name = seriesId,
        season = season,
        episode = episode,
        markedAtEpochMs = at,
    )

    private fun seeds(
        entries: List<WatchProgressEntry>,
        watched: List<WatchedItem> = emptyList(),
        dismissed: Set<String> = emptySet(),
        cutoff: Long? = null,
        dropped: Set<String> = emptySet(),
    ) = buildContinueWatchingNextUpSeeds(
        progressEntries = entries,
        watchedItems = watched,
        isProgressSeed = { it.shouldUseAsCompletedSeedForContinueWatching() },
        isDroppedShow = { it in dropped },
        recencyCutoffEpochMs = cutoff,
        preferFurthestEpisode = true,
        dismissedNextUpKeys = dismissed,
    )

    @Test
    fun finishedEpisodeSeedsItsSeries() {
        val result = seeds(listOf(progress("tt1", 1, 3, t0, completed = true)))
        assertEquals(listOf(ContinueWatchingNextUpSeed("series", "tt1", 1, 3, t0)), result)
    }

    @Test
    fun moviesAndSpecialsNeverSeed() {
        val result = seeds(
            listOf(
                progress("tt-movie", 1, 1, t0, completed = true, type = "movie"),
                progress("tt2", 0, 1, t0, completed = true),
            ),
        )
        assertTrue(result.isEmpty())
    }

    @Test
    fun newerInProgressEpisodeSuppressesTheSeries() {
        val result = seeds(
            listOf(
                progress("tt1", 1, 3, t0, completed = true),
                progress("tt1", 1, 4, t0 + 1_000, completed = false),
            ),
        )
        assertTrue(result.isEmpty())
    }

    @Test
    fun olderInProgressEpisodeDoesNotSuppress() {
        val result = seeds(
            listOf(
                progress("tt1", 1, 2, t0, completed = false),
                progress("tt1", 1, 3, t0 + 1_000, completed = true),
            ),
        )
        assertEquals(1, result.size)
    }

    @Test
    fun watchedHistorySeedsAndFurthestEpisodeWins() {
        val result = seeds(
            entries = listOf(progress("tt1", 1, 2, t0 + 5_000, completed = true)),
            watched = listOf(watched("tt1", 2, 1, t0)),
        )
        assertEquals(2, result.single().seasonNumber)
        assertEquals(1, result.single().episodeNumber)
    }

    @Test
    fun dismissedDroppedAndOutOfWindowSeriesAreSkipped() {
        val entries = listOf(
            progress("dismissed", 1, 1, t0, completed = true),
            progress("dropped", 1, 1, t0, completed = true),
            progress("old", 1, 1, t0 - 10_000, completed = true),
            progress("kept", 1, 1, t0, completed = true),
        )
        val result = seeds(
            entries = entries,
            dismissed = setOf(nextUpDismissKey("dismissed", 1, 1)),
            dropped = setOf("dropped"),
            cutoff = t0 - 1,
        )
        assertEquals(listOf("kept"), result.map { it.contentId })
    }

    @Test
    fun inProgressTieWithTheCompletionSuppressesTheSeries() {
        val result = seeds(
            listOf(
                progress("tt1", 1, 3, t0, completed = true),
                progress("tt1", 1, 4, t0, completed = false),
            ),
        )
        assertTrue(result.isEmpty())
    }

    @Test
    fun latestMarkedEpisodeWinsWhenFurthestIsOff() {
        val result = buildContinueWatchingNextUpSeeds(
            progressEntries = listOf(progress("tt1", 1, 2, t0 + 5_000, completed = true)),
            watchedItems = listOf(watched("tt1", 2, 1, t0)),
            isProgressSeed = { it.shouldUseAsCompletedSeedForContinueWatching() },
            isDroppedShow = { false },
            recencyCutoffEpochMs = null,
            preferFurthestEpisode = false,
            dismissedNextUpKeys = emptySet(),
        )
        assertEquals(ContinueWatchingNextUpSeed("series", "tt1", 1, 2, t0 + 5_000), result.single())
    }

    @Test
    fun aDismissalOnlyHidesTheSeedEpisodeItWasMadeFor() {
        // The phone keys a dismissal by the finished episode; finishing the next one brings the
        // series back (a new seed, a new key).
        val result = seeds(
            entries = listOf(
                progress("tt1", 1, 3, t0, completed = true),
                progress("tt1", 1, 4, t0 + 1_000, completed = true),
            ),
            dismissed = setOf(nextUpDismissKey("tt1", 1, 3)),
        )
        assertEquals(4, result.single().episodeNumber)
    }

    @Test
    fun seedsAreMostRecentFirstAndCapped() {
        val entries = (1..5).map { index -> progress("tt$index", 1, 1, t0 + index, completed = true) }
        val result = buildContinueWatchingNextUpSeeds(
            progressEntries = entries,
            watchedItems = emptyList(),
            isProgressSeed = { it.shouldUseAsCompletedSeedForContinueWatching() },
            isDroppedShow = { false },
            recencyCutoffEpochMs = null,
            preferFurthestEpisode = true,
            dismissedNextUpKeys = emptySet(),
            limit = 3,
        )
        assertEquals(listOf("tt5", "tt4", "tt3"), result.map { it.contentId })
    }

    @Test
    fun theProviderSeedRuleIsHonoured() {
        val result = buildContinueWatchingNextUpSeeds(
            progressEntries = listOf(progress("tt1", 1, 3, t0, completed = true)),
            watchedItems = emptyList(),
            isProgressSeed = { false },
            isDroppedShow = { false },
            recencyCutoffEpochMs = null,
            preferFurthestEpisode = true,
            dismissedNextUpKeys = emptySet(),
        )
        assertTrue(result.isEmpty())
    }

    @Test
    fun mergeKeepsTheMoreRecentCardPerSeries() {
        // "a": an episode abandoned before a later one was finished, so its next-up is newer and
        // wins (mobile's rule). "c": the next-up is older than the in-progress card, which stays.
        val inProgress = listOf(
            progress("c", 1, 5, t0 + 7_000, completed = false),
            progress("a", 1, 2, t0, completed = false),
        )
        val nextUp = listOf(
            progress("a", 1, 4, t0 + 5_000, completed = false).copy(source = WatchProgressSourceNextUp),
            progress("b", 2, 1, t0 + 9_000, completed = false).copy(source = WatchProgressSourceNextUp),
            progress("c", 1, 4, t0 + 1_000, completed = false).copy(source = WatchProgressSourceNextUp),
        )
        val merged = mergeContinueWatchingWithNextUp(inProgress, nextUp)
        assertEquals(listOf("b:2:1", "c:1:5", "a:1:4"), merged.map { it.videoId })
        assertTrue(merged.first().isContinueWatchingNextUp)
        assertFalse(merged[1].isContinueWatchingNextUp)
    }

    @Test
    fun mergeTieKeepsTheInProgressCard() {
        val inProgress = listOf(progress("a", 1, 2, t0, completed = false))
        val nextUp = listOf(progress("a", 1, 3, t0, completed = false).copy(source = WatchProgressSourceNextUp))
        assertEquals(listOf("a:1:2"), mergeContinueWatchingWithNextUp(inProgress, nextUp).map { it.videoId })
    }

    @Test
    fun mergeWithNothingToAddReturnsTheSameList() {
        val inProgress = listOf(progress("a", 1, 2, t0, completed = false))
        assertSame(inProgress, mergeContinueWatchingWithNextUp(inProgress, emptyList()))
    }

    @Test
    fun withoutDismissedDropsOnlyDismissedNextUpCards() {
        val nextUpA = progress("a", 1, 4, t0, completed = false).copy(source = WatchProgressSourceNextUp)
        val nextUpB = progress("b", 2, 1, t0, completed = false).copy(source = WatchProgressSourceNextUp)
        val inProgressC = progress("c", 1, 1, t0, completed = false)
        val keys = mapOf(
            nextUpA.videoId to nextUpDismissKey("a", 1, 3),
            nextUpB.videoId to nextUpDismissKey("b", 1, 10),
            // A progress card that happens to share a key is never dropped by this filter.
            inProgressC.videoId to nextUpDismissKey("c", 1, 1),
        )
        val result = withoutDismissedNextUp(
            entries = listOf(nextUpA, nextUpB, inProgressC),
            dismissKeyByVideoId = keys,
            dismissedNextUpKeys = setOf(nextUpDismissKey("a", 1, 3), nextUpDismissKey("c", 1, 1)),
        )
        assertEquals(listOf(nextUpB.videoId, inProgressC.videoId), result.map { it.videoId })
    }

    @Test
    fun seedCandidatesCarryTheEntrysExclusionsIntoTheirKey() {
        // Codex r13: Home cached S1E25 after S1E24; the user drops TMDB season 2 and S1E25 is now excluded.
        val before = progress("tt1", 1, 24, t0, completed = true)
        val after = before.copy(excludedNextUpSeasons = setOf(2), excludedNextUpEpisodeKeys = (25..30).map { "1:$it" }.toSet())
        val seedBefore = buildNextUpSeedCandidates(listOf(before), emptyList(), { true }, preferFurthestEpisode = true).single()
        val seedAfter = buildNextUpSeedCandidates(listOf(after), emptyList(), { true }, preferFurthestEpisode = true).single()
        assertEquals(seedBefore.copy(exclusionsFingerprint = seedAfter.exclusionsFingerprint), seedAfter)
        assertNotEquals(
            nextUpResolveKey(seedBefore, 1, "MDBLIST", true, false, "2026-10-23"),
            nextUpResolveKey(seedAfter, 1, "MDBLIST", true, false, "2026-10-23"),
        )
    }

    @Test
    fun resolveKeyChangesWithEveryInputThatChangesTheAnswer() {
        val seed = ContinueWatchingNextUpSeed("series", "tt1", 1, 3, t0)
        val base = nextUpResolveKey(seed, 1, "NUVIO_SYNC", preferFurthestEpisode = true, showUnairedNextUp = true, todayIsoDate = "2026-10-23")
        val variants = listOf(
            nextUpResolveKey(seed.copy(episodeNumber = 4), 1, "NUVIO_SYNC", true, true, "2026-10-23"),
            nextUpResolveKey(seed.copy(contentId = "tt2"), 1, "NUVIO_SYNC", true, true, "2026-10-23"),
            nextUpResolveKey(seed, 1, "TRAKT", true, true, "2026-10-23"),
            nextUpResolveKey(seed, 1, "NUVIO_SYNC", false, true, "2026-10-23"),
            nextUpResolveKey(seed, 1, "NUVIO_SYNC", true, false, "2026-10-23"),
            nextUpResolveKey(seed, 1, "NUVIO_SYNC", true, true, "2026-10-24"),
            nextUpResolveKey(seed, 2, "NUVIO_SYNC", true, true, "2026-10-23"),
            // Codex r13 on the MDBList remap: a dropped season or episode changes the answer too.
            nextUpResolveKey(seed.copy(exclusionsFingerprint = nextUpExclusionsFingerprint(setOf(2), emptySet())), 1, "NUVIO_SYNC", true, true, "2026-10-23"),
            nextUpResolveKey(seed.copy(exclusionsFingerprint = nextUpExclusionsFingerprint(emptySet(), setOf("1:25"))), 1, "NUVIO_SYNC", true, true, "2026-10-23"),
        )
        variants.forEach { assertNotEquals(base, it) }
        assertNotEquals(
            nextUpResolveKey(seed.copy(exclusionsFingerprint = nextUpExclusionsFingerprint(setOf(2), emptySet())), 1, "NUVIO_SYNC", true, true, "2026-10-23"),
            nextUpResolveKey(seed.copy(exclusionsFingerprint = nextUpExclusionsFingerprint(emptySet(), setOf("1:25"))), 1, "NUVIO_SYNC", true, true, "2026-10-23"),
        )
        // Re-finishing the same episode later re-dates the card but does not refetch it.
        assertEquals(base, nextUpResolveKey(seed.copy(markedAtEpochMs = t0 + 1), 1, "NUVIO_SYNC", true, true, "2026-10-23"))
    }

    @Test
    fun unairedEpisodesAreDroppedUnderTheCurrentPolicy() {
        assertEquals(UnairedNextUpPolicy.Drop, ContinueWatchingUnairedNextUpPolicy)
        assertTrue(keepNextUpEpisode(isReleased = true, policy = UnairedNextUpPolicy.Drop))
        assertFalse(keepNextUpEpisode(isReleased = false, policy = UnairedNextUpPolicy.Drop))
        // The flip Christian may choose later keeps the card (to be labelled "Airs <date>").
        assertTrue(keepNextUpEpisode(isReleased = false, policy = UnairedNextUpPolicy.LabelAirDate))
    }

    @Test
    fun nextUpVideoMatchesBySeasonEpisodeThenPlaybackId() {
        val videos = listOf(
            MetaVideo(id = "tt1:1:4", title = "Four", released = "2026-01-01", season = 1, episode = 4),
            MetaVideo(id = "addon-ep-5", title = "Five", released = "2099-01-01", season = 1, episode = 5),
        )
        assertEquals("Four", nextUpVideoFor(videos, "tt1", 1, 4, "ignored")?.title)
        assertEquals("Five", nextUpVideoFor(videos, "tt1", null, null, "addon-ep-5")?.title)
        assertEquals("Four", nextUpVideoFor(videos, "tt1", null, null, "tt1:1:4")?.title)
        assertNull(nextUpVideoFor(videos, "tt1", 2, 1, "tt1:2:1"))
    }

    @Test
    fun removingAnInProgressCardNamesTheUpNextItWouldUncover() {
        // E3 finished, E4 half watched after it: Remove on E4 must dismiss the E3 seed (Up Next E4).
        val entries = listOf(
            progress("tt1", 1, 3, t0, completed = true),
            progress("tt1", 1, 4, t0 + 1_000, completed = false),
            progress("other", 1, 9, t0 + 2_000, completed = true),
        )
        val seed = nextUpSeedAfterRemoval(
            progressEntries = entries,
            watchedItems = emptyList(),
            contentId = "tt1",
            removedVideoId = "tt1:1:4",
            isProgressSeed = { it.shouldUseAsCompletedSeedForContinueWatching() },
            preferFurthestEpisode = true,
        )
        assertEquals(ContinueWatchingNextUpSeed("series", "tt1", 1, 3, t0), seed)
    }

    @Test
    fun removingWithNothingFinishedDismissesNothing() {
        val seed = nextUpSeedAfterRemoval(
            progressEntries = listOf(progress("tt1", 1, 1, t0, completed = false)),
            watchedItems = emptyList(),
            contentId = "tt1",
            removedVideoId = "tt1:1:1",
            isProgressSeed = { it.shouldUseAsCompletedSeedForContinueWatching() },
            preferFurthestEpisode = true,
        )
        assertNull(seed)
    }

    @Test
    fun removingUsesWatchedHistoryToo() {
        val seed = nextUpSeedAfterRemoval(
            progressEntries = listOf(progress("tt1", 1, 4, t0 + 1_000, completed = false)),
            watchedItems = listOf(watched("tt1", 1, 3, t0), watched("tt9", 2, 2, t0)),
            contentId = "tt1",
            removedVideoId = "tt1:1:4",
            isProgressSeed = { it.shouldUseAsCompletedSeedForContinueWatching() },
            preferFurthestEpisode = true,
        )
        assertEquals(3, seed?.episodeNumber)
        assertEquals("tt1", seed?.contentId)
    }

    @Test
    fun recentMarksAreScopedToTheProfileAndTheWindow() {
        val marks = listOf(
            RecentNextUpMark(1, watched("tt1", 1, 4, t0)),
            RecentNextUpMark(2, watched("tt2", 1, 1, t0)),
            RecentNextUpMark(1, watched("tt3", 1, 1, t0 - ContinueWatchingNextUpTraktMarkWindowMs - 1)),
        )
        val active = activeRecentNextUpMarks(marks, profileId = 1, nowEpochMs = t0 + 1_000)
        assertEquals(listOf("tt1"), active.map { it.id })
    }

    @Test
    fun aRecentMarkSeedsTheNextEpisodeWhenHistoryIsOff() {
        // Under Trakt the only "history" is the recent mark: E4 marked from its Up Next card makes
        // E4 the seed although Trakt's progress still says E3.
        val result = seeds(
            entries = listOf(progress("tt1", 1, 3, t0, completed = true)),
            watched = activeRecentNextUpMarks(listOf(RecentNextUpMark(1, watched("tt1", 1, 4, t0 + 5_000))), 1, t0 + 6_000),
        )
        assertEquals(4, result.single().episodeNumber)
    }

    @Test
    fun progressSignatureIgnoresPlaybackPositionOnly() {
        val playing = progress("tt1", 1, 4, t0, completed = false)
        val later = playing.copy(lastPositionMs = 900_000L, lastUpdatedEpochMs = t0 + 10_000)
        assertEquals(nextUpProgressSignature(listOf(playing)), nextUpProgressSignature(listOf(later)))
    }

    @Test
    fun progressSignatureChangesWhenARowFinishesAppearsOrGoes() {
        val playing = progress("tt1", 1, 4, t0, completed = false)
        val base = nextUpProgressSignature(listOf(playing))
        assertNotEquals(base, nextUpProgressSignature(listOf(progress("tt1", 1, 4, t0 + 1, completed = true))))
        assertNotEquals(base, nextUpProgressSignature(listOf(playing, progress("tt2", 1, 1, t0, completed = false))))
        assertNotEquals(base, nextUpProgressSignature(emptyList()))
        // A finished row re-finished later moves its seed time, so the signature moves too.
        val done = progress("tt1", 1, 3, t0, completed = true)
        assertNotEquals(nextUpProgressSignature(listOf(done)), nextUpProgressSignature(listOf(done.copy(lastUpdatedEpochMs = t0 + 1))))
    }

    @Test
    fun theTwoStagesMatchTheOneCallSeedBuilder() {
        val entries = listOf(
            progress("a", 1, 3, t0, completed = true),
            progress("b", 2, 2, t0 + 1_000, completed = true),
            progress("c", 1, 1, t0 + 2_000, completed = true),
            progress("c", 1, 2, t0 + 3_000, completed = false),
        )
        val dismissed = setOf(nextUpDismissKey("a", 1, 3))
        val oneCall = seeds(entries = entries, dismissed = dismissed, dropped = setOf("b"))
        val staged = filterNextUpSeedCandidates(
            candidates = buildNextUpSeedCandidates(entries, emptyList(), { it.shouldUseAsCompletedSeedForContinueWatching() }, true),
            isDroppedShow = { it == "b" },
            recencyCutoffEpochMs = null,
            dismissedNextUpKeys = dismissed,
        )
        assertEquals(oneCall, staged)
        assertTrue(staged.isEmpty())
    }

    @Test
    fun airCheckUsesTheReleaseInstantAndRechecksAtIt() {
        // A weekly show out at 01:00Z on the 24th, which is the evening of the 23rd in New York:
        // before it, no card and a recheck at the instant; after it, a card.
        val releaseAt = parseReleaseDateToEpochMs("2026-10-24T01:00:00.000Z")!!
        assertEquals(
            NextUpAirCheck(keep = false, recheckAtEpochMs = releaseAt),
            nextUpAirCheck("2026-10-24T01:00:00.000Z", nowEpochMs = releaseAt - 3_600_000L),
        )
        assertEquals(
            NextUpAirCheck(keep = true, recheckAtEpochMs = null),
            nextUpAirCheck("2026-10-24T01:00:00.000Z", nowEpochMs = releaseAt + 1_000L),
        )
    }

    @Test
    fun airCheckOnADateOnlyReleaseRechecksAtTheParsedInstantNotTheNextDay() {
        // Whatever zone the test runs in, the verdict flips at the instant the shared parser gives
        // the date, not at the next local midnight.
        val releaseAt = parseReleaseDateToEpochMs("2026-10-24")!!
        assertEquals(releaseAt, nextUpAirCheck("2026-10-24", nowEpochMs = releaseAt - 1).recheckAtEpochMs)
        assertFalse(nextUpAirCheck("2026-10-24", nowEpochMs = releaseAt - 1).keep)
        assertTrue(nextUpAirCheck("2026-10-24", nowEpochMs = releaseAt).keep)
    }

    @Test
    fun airCheckTreatsAnUnknownDateAsAiredAndKeepsUnderLabelPolicy() {
        assertEquals(NextUpAirCheck(true, null), nextUpAirCheck(null, nowEpochMs = t0))
        assertEquals(NextUpAirCheck(true, null), nextUpAirCheck("soon", nowEpochMs = t0))
        val releaseAt = parseReleaseDateToEpochMs("2099-01-01T00:00:00.000Z")!!
        assertEquals(
            NextUpAirCheck(keep = true, recheckAtEpochMs = releaseAt),
            nextUpAirCheck("2099-01-01T00:00:00.000Z", nowEpochMs = t0, policy = UnairedNextUpPolicy.LabelAirDate),
        )
    }

    @Test
    fun anUnmarkDropsTheMatchingMarkSeeds() {
        val marks = listOf(
            RecentNextUpMark(1, watched("tt1", 1, 4, t0)),
            RecentNextUpMark(1, watched("tt1", 1, 5, t0)),
            RecentNextUpMark(1, watched("tt2", 1, 1, t0)),
        )
        assertEquals(
            listOf("tt1:5", "tt2:1"),
            withoutUnmarkedNextUpMarks(marks, listOf(watched("tt1", 1, 4, t0))).map { "${it.item.id}:${it.item.episode}" },
        )
        // A whole-show unmark (no season/episode) drops every mark for that show.
        val wholeShow = WatchedItem(id = "tt1", type = "series", name = "tt1", markedAtEpochMs = 0L)
        assertEquals(listOf("tt2"), withoutUnmarkedNextUpMarks(marks, listOf(wholeShow)).map { it.item.id })
    }

    @Test
    fun nextFutureReleaseAfterSeedLooksOnlyAheadOfTheSeedAndInTheFuture() {
        val past = "2020-01-01T00:00:00.000Z"
        val soon = "2099-01-01T00:00:00.000Z"
        val later = "2099-02-01T00:00:00.000Z"
        val videos = listOf(
            MetaVideo(id = "s1e2", title = "", released = later, season = 1, episode = 2), // before the seed
            MetaVideo(id = "s1e4", title = "", released = past, season = 1, episode = 4),
            MetaVideo(id = "s1e5", title = "", released = later, season = 1, episode = 5),
            MetaVideo(id = "s2e1", title = "", released = soon, season = 2, episode = 1),
            MetaVideo(id = "sp", title = "", released = "2098-01-01T00:00:00.000Z", season = 0, episode = 1), // special
            MetaVideo(id = "undated", title = "", released = null, season = 1, episode = 6),
        )
        assertEquals(parseReleaseDateToEpochMs(soon), nextFutureReleaseAfterSeed(videos, 1, 3, t0))
        assertNull(nextFutureReleaseAfterSeed(videos.take(2), 1, 3, t0))
    }
}
