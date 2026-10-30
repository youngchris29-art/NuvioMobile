package com.nuvio.app.features.library

import com.nuvio.app.features.tracking.TrackingLibrarySnapshot
import com.nuvio.app.features.tracking.TrackingLibraryTab
import com.nuvio.app.features.tracking.TrackingLibraryTabKind
import com.nuvio.app.features.tracking.TrackingProviderId
import com.nuvio.app.features.watchprogress.WatchProgressEntry
import com.nuvio.app.features.watchprogress.WatchProgressSourceNextUp
import kotlinx.coroutines.flow.Flow
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.first
import kotlinx.coroutines.flow.toList
import kotlinx.coroutines.launch
import kotlinx.coroutines.test.UnconfinedTestDispatcher
import kotlinx.coroutines.flow.flowOf
import kotlinx.coroutines.test.runTest
import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertTrue

/** FEAT-89: the Library tab's Resume Watching and Watchlist rows. */
class LibraryProviderRowsTest {
    private val trakt = TrackingProviderId.TRAKT
    private val simkl = TrackingProviderId.SIMKL

    private fun movieProgress(id: String, at: Long) = WatchProgressEntry(
        contentType = "movie",
        parentMetaId = id,
        parentMetaType = "movie",
        videoId = id,
        title = id,
        lastPositionMs = 600_000L,
        durationMs = 6_000_000L,
        lastUpdatedEpochMs = at,
    )

    private fun episodeProgress(seriesId: String, season: Int, episode: Int, at: Long) = WatchProgressEntry(
        contentType = "series",
        parentMetaId = seriesId,
        parentMetaType = "series",
        videoId = "$seriesId:$season:$episode",
        title = seriesId,
        seasonNumber = season,
        episodeNumber = episode,
        lastPositionMs = 600_000L,
        durationMs = 3_000_000L,
        lastUpdatedEpochMs = at,
    )

    private fun nextUp(seriesId: String, season: Int?, episode: Int?, at: Long) = WatchProgressEntry(
        contentType = "series",
        parentMetaId = seriesId,
        parentMetaType = "series",
        videoId = if (season != null && episode != null) "$seriesId:$season:$episode" else "",
        title = seriesId,
        seasonNumber = season,
        episodeNumber = episode,
        lastPositionMs = 0L,
        durationMs = 0L,
        lastUpdatedEpochMs = at,
        source = WatchProgressSourceNextUp,
    )

    private fun item(
        id: String,
        type: String = "movie",
        addedAt: Long,
        imdbId: String? = null,
        tmdbId: Int? = null,
        provider: TrackingProviderId? = null,
    ) = LibraryItem(
        id = id,
        type = type,
        name = id,
        imdbId = imdbId,
        tmdbId = tmdbId,
        trackingProviderId = provider?.storageId,
        savedAtEpochMs = addedAt,
    )

    private fun watchlist(provider: TrackingProviderId, vararg items: LibraryItem) =
        LibraryProviderWatchlist(providerId = provider, items = items.toList())

    @Test
    fun noConnectedProviderMeansNoRows() {
        val rows = buildLibraryProviderRows(
            connectedProviderIds = emptySet(),
            inProgress = listOf(movieProgress("tt1", at = 10)),
            nextUp = listOf(nextUp("tt2", 1, 2, at = 20)),
            watchlists = listOf(watchlist(trakt, item("tt3", addedAt = 5))),
        )
        assertTrue(rows.isEmpty)
    }

    @Test
    fun mdbListAloneDoesNotTurnTheRowsOn() {
        val rows = buildLibraryProviderRows(
            connectedProviderIds = setOf(TrackingProviderId.MDBLIST),
            inProgress = listOf(movieProgress("tt1", at = 10)),
            nextUp = emptyList(),
            watchlists = listOf(watchlist(TrackingProviderId.MDBLIST, item("tt3", addedAt = 5))),
        )
        assertEquals(LibraryProviderRows(), rows)
    }

    @Test
    fun oneProviderGivesResumeWatchingAndItsWatchlist() {
        val rows = buildLibraryProviderRows(
            connectedProviderIds = setOf(trakt),
            inProgress = listOf(movieProgress("tt-movie", at = 30)),
            nextUp = listOf(nextUp("tt-show", 2, 5, at = 40)),
            watchlists = listOf(
                watchlist(trakt, item("tt-a", addedAt = 200), item("tt-b", type = "series", addedAt = 100)),
            ),
        )
        assertEquals(listOf("tt-show:2:5", "tt-movie"), rows.resumeWatching.map { it.videoId })
        assertEquals(listOf("tt-a", "tt-b"), rows.watchlist.map { it.id })
    }

    @Test
    fun aDisconnectedProvidersWatchlistIsLeftOut() {
        val rows = buildLibraryProviderRows(
            connectedProviderIds = setOf(simkl),
            inProgress = emptyList(),
            nextUp = emptyList(),
            watchlists = listOf(
                watchlist(trakt, item("tt-trakt", addedAt = 300)),
                watchlist(simkl, item("tt-simkl", addedAt = 100)),
            ),
        )
        assertEquals(listOf("tt-simkl"), rows.watchlist.map { it.id })
    }

    @Test
    fun twoProvidersWithOverlappingItemsAreDeduplicated() {
        val rows = buildLibraryProviderRows(
            connectedProviderIds = setOf(trakt, simkl),
            inProgress = emptyList(),
            nextUp = emptyList(),
            watchlists = listOf(
                watchlist(
                    trakt,
                    // Same content id on both providers.
                    item("tt100", addedAt = 50, provider = trakt),
                    // Simkl resolved this one to a TMDB id; the IMDb id ties them.
                    item("tt200", type = "series", addedAt = 400, imdbId = "tt200", tmdbId = 77, provider = trakt),
                    item("tt300", addedAt = 10, provider = trakt),
                ),
                watchlist(
                    simkl,
                    item("tt100", addedAt = 300, provider = simkl),
                    item("tmdb:77", type = "series", addedAt = 100, imdbId = "tt200", provider = simkl),
                    // Same id as Trakt's movie, other kind: the row keys cards by id, so the
                    // older copy (Trakt's) leaves the row (review r1).
                    item("tt300", type = "series", addedAt = 20, provider = simkl),
                ),
            ),
        )
        assertEquals(
            listOf("tt200" to "trakt", "tt100" to "simkl", "tt300" to "simkl"),
            rows.watchlist.map { it.id to it.trackingProviderId },
        )
    }

    @Test
    fun aTmdbIdNamingAMovieAndAShowKeepsOnlyTheNewer() {
        val merged = mergeLibraryWatchlists(
            listOf(
                watchlist(trakt, item("tmdb:603", type = "movie", addedAt = 10)),
                watchlist(simkl, item("tmdb:603", type = "series", addedAt = 20)),
            ),
        )
        assertEquals(listOf("tmdb:603" to "series"), merged.map { it.id to it.type })
    }

    @Test
    fun sharedTmdbNumbersOfDifferentKindsWithDistinctIdsBothStay() {
        val merged = mergeLibraryWatchlists(
            listOf(
                watchlist(trakt, item("tt1", type = "movie", addedAt = 10, tmdbId = 5)),
                watchlist(simkl, item("tt2", type = "series", addedAt = 20, tmdbId = 5)),
            ),
        )
        assertEquals(listOf("tt2", "tt1"), merged.map { it.id })
    }

    @Test
    fun theSameTitleAddedAtTheSameMomentKeepsTheTraktCopy() {
        val merged = mergeLibraryWatchlists(
            listOf(
                watchlist(simkl, item("tt7", addedAt = 100, provider = simkl)),
                watchlist(trakt, item("tt7", addedAt = 100, provider = trakt)),
            ),
        )
        assertEquals(listOf("trakt"), merged.map { it.trackingProviderId })
    }

    @Test
    fun typeSpellingsAreNormalisedBeforeMatching() {
        val shows = mergeLibraryWatchlists(
            listOf(
                watchlist(trakt, item("tt8", type = "show", addedAt = 30, imdbId = "tt8")),
                watchlist(simkl, item("tmdb:80", type = "tv", addedAt = 20, imdbId = "tt8")),
            ),
        )
        assertEquals(listOf("tt8"), shows.map { it.id })
        val movies = mergeLibraryWatchlists(
            listOf(
                watchlist(trakt, item("tt9", type = "film", addedAt = 30, tmdbId = 90)),
                watchlist(simkl, item("tmdb:90", type = "movie", addedAt = 20)),
            ),
        )
        assertEquals(listOf("tt9"), movies.map { it.id })
    }

    @Test
    fun aTmdbOnlyIdMatchesTheSameTmdbIdElsewhere() {
        val merged = mergeLibraryWatchlists(
            listOf(
                watchlist(trakt, item("tt9", type = "series", addedAt = 5, tmdbId = 42)),
                watchlist(simkl, item("tmdb:42", type = "series", addedAt = 9)),
            ),
        )
        assertEquals(listOf("tmdb:42"), merged.map { it.id })
    }

    @Test
    fun watchlistIsMostRecentlyAddedFirstWithTraktWinningATie() {
        val rows = buildLibraryProviderRows(
            connectedProviderIds = setOf(trakt, simkl),
            inProgress = emptyList(),
            nextUp = emptyList(),
            watchlists = listOf(
                watchlist(simkl, item("s-old", addedAt = 10), item("s-tie", addedAt = 50), item("s-new", addedAt = 90)),
                watchlist(trakt, item("t-tie", addedAt = 50), item("t-mid", addedAt = 70)),
            ),
        )
        assertEquals(listOf("s-new", "t-mid", "t-tie", "s-tie", "s-old"), rows.watchlist.map { it.id })
    }

    @Test
    fun theCapCountsTitlesAfterCrossProviderDedupe() {
        val rows = buildLibraryProviderRows(
            connectedProviderIds = setOf(trakt, simkl),
            inProgress = emptyList(),
            nextUp = emptyList(),
            watchlists = listOf(
                watchlist(trakt, item("tt1", addedAt = 50), item("tt2", addedAt = 40), item("tt3", addedAt = 30)),
                watchlist(simkl, item("tt1", addedAt = 49), item("tt2", addedAt = 39), item("tt4", addedAt = 20)),
            ),
            watchlistLimit = 3,
        )
        assertEquals(listOf("tt1", "tt2", "tt3"), rows.watchlist.map { it.id })
    }

    @Test
    fun watchlistIsCappedAtTheRowLimit() {
        val items = (1..5).map { item("tt$it", addedAt = it.toLong()) }.toTypedArray()
        val rows = buildLibraryProviderRows(
            connectedProviderIds = setOf(trakt),
            inProgress = emptyList(),
            nextUp = emptyList(),
            watchlists = listOf(watchlist(trakt, *items)),
            watchlistLimit = 3,
        )
        assertEquals(listOf("tt5", "tt4", "tt3"), rows.watchlist.map { it.id })
    }

    @Test
    fun resumeWatchingIsMostRecentFirstWithOneCardPerSeries() {
        val rows = buildLibraryProviderRows(
            connectedProviderIds = setOf(simkl),
            inProgress = listOf(
                movieProgress("m1", at = 100),
                // Abandoned half way, older than the next-up of the same series: the next-up wins.
                episodeProgress("show-a", 1, 2, at = 50),
                episodeProgress("show-b", 3, 1, at = 300),
            ),
            nextUp = listOf(
                nextUp("show-a", 1, 4, at = 200),
                // Older than show-b's in-progress episode: the in-progress card stays.
                nextUp("show-b", 2, 9, at = 250),
            ),
            watchlists = emptyList(),
        )
        assertEquals(listOf("show-b:3:1", "show-a:1:4", "m1"), rows.resumeWatching.map { it.videoId })
    }

    @Test
    fun aShowWhoseNextEpisodeIsUnknownGetsNoUpNextCard() {
        val rows = buildLibraryProviderRows(
            connectedProviderIds = setOf(trakt),
            inProgress = listOf(episodeProgress("show-c", 1, 3, at = 10)),
            nextUp = listOf(
                // Finished series with no known next episode: no card at all.
                nextUp("show-unknown", season = null, episode = null, at = 500),
                // A newer next-up without an episode must not hide show-c's in-progress card.
                nextUp("show-c", season = null, episode = null, at = 400),
            ),
            watchlists = emptyList(),
        )
        assertEquals(listOf("show-c:1:3"), rows.resumeWatching.map { it.videoId })
    }

    @Test
    fun watchlistItemsReadOnlyTheWatchlistSections() {
        val watch = item("tt-w", addedAt = 1)
        val personal = item("tt-p", addedAt = 2)
        val snapshot = TrackingLibrarySnapshot(
            sections = listOf(
                LibrarySection(type = "trakt:watchlist", displayTitle = "Watchlist", items = listOf(watch)),
                LibrarySection(type = "trakt:list:1", displayTitle = "Faves", items = listOf(personal)),
            ),
            tabs = listOf(
                TrackingLibraryTab("trakt:watchlist", "Watchlist", trakt, TrackingLibraryTabKind.WATCHLIST),
                TrackingLibraryTab("trakt:list:1", "Faves", trakt, TrackingLibraryTabKind.PERSONAL),
            ),
        )
        assertEquals(listOf(watch), snapshot.watchlistItems())
    }

    @Test
    fun watchlistRowSectionCarriesNoSeeAll() {
        val section = libraryWatchlistRowSection(title = "Watchlist", items = listOf(item("tt1", addedAt = 1)))
        assertEquals(LIBRARY_WATCHLIST_ROW_KEY, section.key)
        assertEquals("Watchlist", section.title)
        assertEquals(listOf("tt1"), section.items.map { it.id })
        assertEquals(false, section.hasMore)
    }

    @Test
    fun theFlowObservesNothingUntilAProviderConnects() = runTest {
        val connected = MutableStateFlow<Set<TrackingProviderId>>(setOf(TrackingProviderId.MDBLIST))
        var resumeSubscriptions = 0
        val watchlistRequests = mutableListOf<Set<TrackingProviderId>>()
        val resume: () -> Flow<Pair<List<WatchProgressEntry>, List<WatchProgressEntry>>> = {
            resumeSubscriptions += 1
            flowOf(listOf(movieProgress("tt1", at = 10)) to emptyList())
        }
        val lists: (Set<TrackingProviderId>) -> Flow<List<LibraryProviderWatchlist>> = { ids ->
            watchlistRequests += ids
            flowOf(listOf(watchlist(trakt, item("tt2", addedAt = 1))))
        }
        val flow = libraryProviderRowsFlow(connected, resume, lists)

        assertEquals(LibraryProviderRows(), flow.first())
        assertEquals(0, resumeSubscriptions)
        assertTrue(watchlistRequests.isEmpty())

        connected.value = setOf(trakt, TrackingProviderId.MDBLIST)
        val rows = flow.first()
        assertEquals(listOf("tt1"), rows.resumeWatching.map { it.videoId })
        assertEquals(listOf("tt2"), rows.watchlist.map { it.id })
        assertEquals(listOf(setOf(trakt)), watchlistRequests)
    }

    @Test
    fun theFlowGoesBackToNoRowsOnDisconnect() = runTest {
        val connected = MutableStateFlow<Set<TrackingProviderId>>(setOf(simkl))
        val emissions = mutableListOf<LibraryProviderRows>()
        val job = launch(UnconfinedTestDispatcher(testScheduler)) {
            libraryProviderRowsFlow(
                connectedProviderIds = connected,
                resumeInputs = { flowOf(listOf(movieProgress("tt1", at = 10)) to emptyList()) },
                watchlists = { flowOf(listOf(watchlist(simkl, item("tt2", addedAt = 1)))) },
            ).toList(emissions)
        }
        connected.value = emptySet()
        job.cancel()
        assertEquals(2, emissions.size)
        assertTrue(!emissions[0].isEmpty)
        assertEquals(LibraryProviderRows(), emissions[1])
    }

    @Test
    fun aSubscriptionNeverRefreshesTheActiveLibrarySource() {
        val throttle = LibraryRowsRefreshThrottle(intervalMs = 1_000L)
        assertEquals(
            listOf(simkl),
            throttle.refreshTargets(listOf(trakt, simkl), activeSource = trakt, profileId = 1, nowEpochMs = 0L),
        )
        // Trakt stays the source: still never refreshed by the rows, however much time passes.
        assertEquals(
            listOf(simkl),
            throttle.refreshTargets(listOf(trakt, simkl), activeSource = trakt, profileId = 1, nowEpochMs = 5_000L),
        )
    }

    @Test
    fun aSecondSubscriptionWithinTheWindowDoesNotRefreshTraktAgain() {
        val throttle = LibraryRowsRefreshThrottle(intervalMs = 1_000L)
        assertEquals(listOf(trakt), throttle.refreshTargets(listOf(trakt), null, profileId = 1, nowEpochMs = 100L))
        assertEquals(emptyList(), throttle.refreshTargets(listOf(trakt), null, profileId = 1, nowEpochMs = 900L))
        // Another profile has its own clock.
        assertEquals(listOf(trakt), throttle.refreshTargets(listOf(trakt), null, profileId = 2, nowEpochMs = 900L))
        // Once the window has passed, the next subscription refreshes again.
        assertEquals(listOf(trakt), throttle.refreshTargets(listOf(trakt), null, profileId = 1, nowEpochMs = 1_100L))
    }

    @Test
    fun simklIsPassedToItsOwnGateOnEverySubscription() {
        val throttle = LibraryRowsRefreshThrottle(intervalMs = 1_000L)
        assertEquals(listOf(simkl), throttle.refreshTargets(listOf(simkl), null, profileId = 1, nowEpochMs = 100L))
        assertEquals(listOf(simkl), throttle.refreshTargets(listOf(simkl), null, profileId = 1, nowEpochMs = 200L))
        // Except as the Library source, which LibraryRepository refreshes.
        assertEquals(emptyList(), throttle.refreshTargets(listOf(simkl), simkl, profileId = 1, nowEpochMs = 300L))
    }

    @Test
    fun aFailedPullIsRetriedOnTheNextSubscription() {
        val throttle = LibraryRowsRefreshThrottle(intervalMs = 1_000L)
        assertEquals(listOf(trakt), throttle.refreshTargets(listOf(trakt), null, profileId = 1, nowEpochMs = 100L))
        // The pull failed (offline, a Trakt 5xx): the entry goes, so the next visit tries again.
        throttle.forget(profileId = 1, providerId = trakt)
        assertEquals(listOf(trakt), throttle.refreshTargets(listOf(trakt), null, profileId = 1, nowEpochMs = 200L))
        // That one worked: back inside the window.
        assertEquals(emptyList(), throttle.refreshTargets(listOf(trakt), null, profileId = 1, nowEpochMs = 300L))
    }

    @Test
    fun disconnectAndReconnectInsideTheWindowRefreshesTraktAgain() {
        val throttle = LibraryRowsRefreshThrottle(intervalMs = 1_000L)
        assertEquals(listOf(trakt), throttle.refreshTargets(listOf(trakt, simkl), simkl, profileId = 1, nowEpochMs = 100L))
        assertEquals(emptyList(), throttle.refreshTargets(listOf(trakt, simkl), simkl, profileId = 1, nowEpochMs = 150L))
        // Trakt signs out and back in; Simkl (the Library source) stays connected.
        throttle.retainConnected(setOf(simkl))
        throttle.retainConnected(setOf(trakt, simkl))
        assertEquals(listOf(trakt), throttle.refreshTargets(listOf(trakt, simkl), simkl, profileId = 1, nowEpochMs = 200L))
    }

    @Test
    fun traktWithNoSnapshotIsRefreshedInsideTheWindow() {
        val throttle = LibraryRowsRefreshThrottle(intervalMs = 1_000L)
        assertEquals(listOf(trakt), throttle.refreshTargets(listOf(trakt), null, profileId = 1, nowEpochMs = 100L))
        assertEquals(
            listOf(trakt),
            throttle.refreshTargets(listOf(trakt), null, profileId = 1, nowEpochMs = 200L, unloaded = listOf(trakt)),
        )
    }

    @Test
    fun theFlowReportsEachConnectedSet() = runTest {
        val connected = MutableStateFlow<Set<TrackingProviderId>>(setOf(trakt, simkl))
        val reported = mutableListOf<Set<TrackingProviderId>>()
        val job = launch(UnconfinedTestDispatcher(testScheduler)) {
            libraryProviderRowsFlow(
                connectedProviderIds = connected,
                resumeInputs = { flowOf(emptyList<WatchProgressEntry>() to emptyList()) },
                watchlists = { flowOf(emptyList()) },
                onConnectedChanged = { reported += it },
            ).collect {}
        }
        connected.value = setOf(trakt, TrackingProviderId.MDBLIST)
        connected.value = emptySet()
        job.cancel()
        assertEquals(listOf(setOf(trakt, simkl), setOf(trakt), emptySet()), reported)
    }

    @Test
    fun aLocalOrMdbListSourceLeavesBothProvidersToTheRows() {
        val throttle = LibraryRowsRefreshThrottle()
        assertEquals(
            listOf(trakt, simkl),
            throttle.refreshTargets(listOf(trakt, simkl), activeSource = TrackingProviderId.MDBLIST, profileId = 1, nowEpochMs = 0L),
        )
    }
}
