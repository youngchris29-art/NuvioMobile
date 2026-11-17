package com.nuvio.app.features.streams

import kotlinx.coroutines.Job
import kotlinx.coroutines.launch
import kotlinx.coroutines.test.TestScope
import kotlinx.coroutines.test.runCurrent
import kotlinx.coroutines.test.runTest
import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertFalse
import kotlin.test.assertTrue

/**
 * W4 spec 4.2: the session store's races as scripted event sequences (S1-S14, plus the
 * interleavings found while porting, S15-S18). Each consumer is a collector of
 * [StreamSearchSessionStore.search]; add-on answers are released by hand through gates; the clock
 * is a plain variable.
 */
class StreamSearchSessionScenarioTest {
    private val fetcher = ScriptedSearchFetcher()
    private var clock = 0L

    private class Consumer(val received: MutableList<StreamLoadCompletion>, val job: Job) {
        /** "<add-on>:<stream labels>" per completion, in arrival order. */
        val labels: List<String>
            get() = received.map { completion ->
                when (completion) {
                    is StreamLoadCompletion.Addon ->
                        "${completion.group.addonName}:${completion.group.streams.joinToString(",") { it.name.orEmpty() }}"
                    is StreamLoadCompletion.PluginScraper ->
                        "${completion.addonId}:${completion.streams.joinToString(",") { it.name.orEmpty() }}"
                }
            }
    }

    private fun TestScope.store() = StreamSearchSessionStore(fetcher, now = { clock }, scope = backgroundScope)

    private fun TestScope.consume(
        store: StreamSearchSessionStore,
        targets: StreamSearchTargets = SearchFixtures.targets(),
        profileId: Int = 1,
        forceRefresh: Boolean = false,
    ): Consumer {
        val received = mutableListOf<StreamLoadCompletion>()
        val job = backgroundScope.launch { store.search(profileId, targets, forceRefresh).collect { received += it } }
        runCurrent()
        return Consumer(received, job)
    }

    private fun answer(addonName: String, label: String): Result<List<StreamItem>> =
        Result.success(listOf(SearchFixtures.stream(SearchFixtures.target(addonName).addonId, label)))

    @Test
    fun s1LateConsumerGetsTheArrivedResultsAsReplayThenTheRest() = runTest {
        val store = store()
        val gateA = fetcher.hold("a")
        val gateB = fetcher.hold("b")
        val first = consume(store)
        gateA.complete(answer("a", "a1"))
        runCurrent()
        val second = consume(store)
        assertEquals(listOf("a:a1"), second.labels, "the answer that already arrived is replayed at once")
        gateB.complete(answer("b", "b1"))
        runCurrent()

        assertEquals(listOf("a:a1", "b:b1"), first.labels)
        assertEquals(listOf("a:a1", "b:b1"), second.labels)
        assertEquals(1, fetcher.fetchCount("a"))
        assertEquals(1, fetcher.fetchCount("b"))
        assertTrue(first.job.isCompleted && second.job.isCompleted)
    }

    @Test
    fun s2FinishedSearchIsReusedWithinFifteenMinutes() = runTest {
        val store = store()
        consume(store)
        clock += 14 * MINUTE
        val late = consume(store)

        assertEquals(1, store.startedCount)
        assertEquals(2, fetcher.addonFetches.size)
        assertEquals(2, late.received.size)
        assertTrue(late.job.isCompleted)
    }

    @Test
    fun s3FinishedSearchExpiresAtFifteenMinutes() = runTest {
        val store = store()
        consume(store)
        clock += 15 * MINUTE
        consume(store)

        assertEquals(2, store.startedCount)
        assertEquals(2, fetcher.fetchCount("a"))
    }

    @Test
    fun s4ForcedRefreshEndsTheOldConsumerAndKeepsTheLateOldAnswerOut() = runTest {
        val store = store()
        fetcher.gatesIgnoreCancellation = true
        val oldA = fetcher.hold("a")
        val oldB = fetcher.hold("b")
        val first = consume(store)
        val refreshed = consume(store, forceRefresh = true)

        assertTrue(first.job.isCompleted, "the dropped search's consumer completes")
        oldA.complete(answer("a", "late"))
        oldB.complete(answer("b", "late"))
        runCurrent()

        assertEquals(emptyList(), first.labels)
        assertEquals(listOf("a:a-tt1:1:1", "b:b-tt1:1:1"), refreshed.labels)
        assertEquals(2, fetcher.fetchCount("a"))
        assertEquals(1, store.heldKeys().size)
    }

    @Test
    fun s4bAnswerRecordedAfterTheDropIsNeverEmittedToAConsumerStillCatchingUp() = runTest {
        // Found while porting: the drop marks the session complete, but a fetch already past its
        // last suspension still records its answer. The consumer, resumed after both, would read
        // that answer together with the end and emit it, unless a dropped session takes no more.
        val store = store()
        fetcher.gatesIgnoreCancellation = true
        val gate = fetcher.hold("a")
        fetcher.hold("b")
        val first = consume(store)
        gate.complete(answer("a", "late"))
        store.clear()
        runCurrent()

        assertTrue(first.job.isCompleted)
        assertEquals(emptyList(), first.labels)
    }

    @Test
    fun s5AnotherDebridAccountForTheSameEpisodeDropsTheOldSearch() = runTest {
        val store = store()
        fetcher.hold("a")
        val onFirstAccount = consume(store, SearchFixtures.targets(debrid = "torbox:1"))
        val onSecondAccount = consume(store, SearchFixtures.targets(debrid = "torbox:2"))

        assertTrue(onFirstAccount.job.isCompleted)
        assertEquals(2, store.startedCount)
        assertEquals(listOf(SearchFixtures.targets(debrid = "torbox:2").key(1)), store.heldKeys())
        assertTrue(onSecondAccount.job.isCompleted)
    }

    @Test
    fun s6AnotherProfileDropsEveryOtherProfilesSearch() = runTest {
        val store = store()
        fetcher.hold("a")
        val profileOne = consume(store, SearchFixtures.targets(videoId = "tt9"), profileId = 1)
        consume(store, SearchFixtures.targets(videoId = "tt8"), profileId = 2)

        assertTrue(profileOne.job.isCompleted)
        assertEquals(listOf(2), store.heldKeys().map { it.profileId })
    }

    @Test
    fun s7SearchWhereEveryAddonFailedIsNotKept() = runTest {
        val store = store()
        fetcher.answer = { Result.failure(IllegalStateException("offline")) }
        val first = consume(store)

        assertEquals(2, first.received.size)
        assertTrue(first.received.all { (it as StreamLoadCompletion.Addon).group.error == "offline" })
        assertEquals(emptyList(), store.heldKeys())
        consume(store)
        assertEquals(2, fetcher.fetchCount("a"))
    }

    @Test
    fun s8SearchHoldingAnUnknownCacheAnswerIsReusedForOneMinuteOnly() = runTest {
        val store = store()
        fetcher.cacheCheck = { group ->
            if (group.addonName != "a") group else group.copy(
                streams = group.streams.map {
                    it.copy(debridCacheStatus = StreamDebridCacheStatus("torbox", "TorBox", StreamDebridCacheState.UNKNOWN))
                },
            )
        }
        consume(store)
        clock += 59_000
        consume(store)
        assertEquals(1, store.startedCount, "within a minute the search is replayed")
        clock += 2_000
        consume(store)
        assertEquals(2, store.startedCount, "after a minute the next screen checks again")
    }

    @Test
    fun s8bWithoutAnUnknownAnswerTheFifteenMinuteRuleApplies() = runTest {
        val store = store()
        consume(store)
        clock += 61_000
        consume(store)
        assertEquals(1, store.startedCount)
    }

    @Test
    fun s9ConsumerThatStopsCollectingDoesNotStopTheSearch() = runTest {
        val store = store()
        val gateB = fetcher.hold("b")
        val first = consume(store)
        first.job.cancel()
        runCurrent()
        gateB.complete(answer("b", "b1"))
        runCurrent()
        val second = consume(store)

        assertEquals(1, store.startedCount)
        assertEquals(1, fetcher.fetchCount("b"))
        assertEquals(listOf("a:a-tt1:1:1", "b:b1"), second.labels)
        assertTrue(second.job.isCompleted)
    }

    @Test
    fun s10ThirteenthSearchEvictsTheOldestEvenWhileRunning() = runTest {
        val store = store()
        fetcher.hold("a")
        val oldest = consume(store, SearchFixtures.targets(videoId = "tt0"))
        repeat(12) { index -> consume(store, SearchFixtures.targets(videoId = "tt${index + 1}")) }

        assertTrue(oldest.job.isCompleted, "the evicted search's consumer completes")
        val held = store.heldKeys()
        assertEquals(StreamSearchSessionStore.MAX_SESSIONS, held.size)
        assertFalse(held.any { it.videoId == "tt0" })
    }

    @Test
    fun s11FirstAndSecondBug74PassAreDifferentSearches() = runTest {
        val store = store()
        consume(store, SearchFixtures.targets(videoId = "tmdb:1", requestId = "tmdb:1"))
        consume(store, SearchFixtures.targets(videoId = "tmdb:1", requestId = "tt1"))

        assertEquals(2, store.startedCount)
        assertEquals(listOf("a@tmdb:1", "b@tmdb:1", "a@tt1", "b@tt1"), fetcher.addonFetches)
    }

    @Test
    fun s12CacheCheckRunsOncePerAddonGroupForAllConsumers() = runTest {
        val store = store()
        val gateA = fetcher.hold("a")
        val first = consume(store)
        val second = consume(store)
        gateA.complete(answer("a", "a1"))
        runCurrent()
        consume(store)

        assertEquals(2, fetcher.cacheChecks)
        assertEquals(first.received, second.received)
    }

    @Test
    fun s13ThrowingCacheCheckDeliversTheGroupUncheckedAndShortensReuse() = runTest {
        val store = store()
        fetcher.cacheCheck = { group -> if (group.addonName == "a") throw IllegalStateException("checkcached 500") else group }
        val first = consume(store)

        assertEquals(listOf("a:a-tt1:1:1", "b:b-tt1:1:1"), first.labels)
        assertTrue(first.received.all { completion ->
            (completion as StreamLoadCompletion.Addon).group.streams.all { it.debridCacheStatus == null }
        })
        clock += 61_000
        consume(store)
        assertEquals(2, store.startedCount, "a search kept unchecked is re-run after a minute")
    }

    @Test
    fun s14ClearEndsEveryConsumerAndTheNextAskFetchesAgain() = runTest {
        val store = store()
        fetcher.hold("a")
        val first = consume(store)
        store.clear()
        runCurrent()

        assertTrue(first.job.isCompleted)
        assertEquals(emptyList(), store.heldKeys())
        consume(store)
        assertEquals(2, fetcher.fetchCount("a"))
    }

    @Test
    fun s15RunningSearchNeverExpiresWhileItRuns() = runTest {
        val store = store()
        val gateA = fetcher.hold("a")
        consume(store)
        clock += 20 * MINUTE
        val joiner = consume(store)
        gateA.complete(answer("a", "a1"))
        runCurrent()

        assertEquals(1, store.startedCount)
        assertEquals(listOf("b:b-tt1:1:1", "a:a1"), joiner.labels)
    }

    @Test
    fun s16LateAnswerOfAnEvictedSearchReachesNoConsumer() = runTest {
        val store = store()
        fetcher.gatesIgnoreCancellation = true
        val gate = fetcher.hold("a")
        val oldest = consume(store, SearchFixtures.targets(videoId = "tt0"))
        repeat(12) { index -> consume(store, SearchFixtures.targets(videoId = "tt${index + 1}")) }
        gate.complete(answer("a", "late"))
        runCurrent()

        assertEquals(listOf("b:b-tt0"), oldest.labels)
        // Asked again, the evicted episode is a fresh search; the late answer is not in it.
        val again = consume(store, SearchFixtures.targets(videoId = "tt0"))
        assertEquals(listOf("a:a-tt0", "b:b-tt0"), again.labels)
    }

    @Test
    fun s17PluginScrapersRunOncePerSearchAndReplayInOrder() = runTest {
        val store = store()
        val plugins = listOf(PluginProviderGroup("plugin:p", "P", listOf(SearchFixtures.scraper("s1"), SearchFixtures.scraper("s2"))))
        val first = consume(store, SearchFixtures.targets(addons = emptyList(), plugins = plugins))
        val second = consume(store, SearchFixtures.targets(addons = emptyList(), plugins = plugins))

        assertEquals(2, fetcher.scraperRuns)
        assertEquals(listOf("plugin:p:s1", "plugin:p:s2"), first.labels)
        assertEquals(first.labels, second.labels)
    }

    @Test
    fun s18ThrowingFetcherYieldsAFailedGroupNotAFailedSearch() = runTest {
        val store = store()
        fetcher.answer = { target -> if (target.addonName == "a") throw IllegalStateException() else Result.success(emptyList()) }
        val first = consume(store)

        val failed = first.received.map { (it as StreamLoadCompletion.Addon).group }.single { it.addonName == "a" }
        assertTrue(!failed.error.isNullOrBlank(), "a message-less failure still reads as an error")
        assertTrue(first.job.isCompleted)
    }

    @Test
    fun s19AccountChangeWhileAFetchIsInFlightKeepsItsResultOffBothAccounts() = runTest {
        // Review r1 (finding 5): a search checks with the account it started under, and a search of
        // another account drops it, so an answer still in flight is kept under neither key.
        val store = store()
        fetcher.gatesIgnoreCancellation = true
        val gate = fetcher.hold("a")
        val onA = consume(store, SearchFixtures.targets(debrid = "torbox:A", account = SearchFixtures.torbox("keyA")))
        assertEquals(listOf<String?>("keyA"), fetcher.checkedWith, "b answered at once and was checked with A")
        consume(store, SearchFixtures.targets(videoId = "tt2:1:1", debrid = "torbox:B", account = SearchFixtures.torbox("keyB")))

        assertTrue(onA.job.isCompleted, "the switch drops account A's search, any episode")
        gate.complete(answer("a", "late"))
        runCurrent()
        // The late answer is checked with its own search's account, never B's, and then not kept.
        assertEquals(listOf<String?>("keyA", "keyB", "keyB", "keyA"), fetcher.checkedWith)
        assertEquals(listOf("torbox:B"), store.heldKeys().map { it.debridConfiguration })

        val backOnA = consume(store, SearchFixtures.targets(debrid = "torbox:A", account = SearchFixtures.torbox("keyA")))
        assertEquals(3, store.startedCount, "switching back to A searches again")
        assertEquals(listOf("a:a-tt1:1:1", "b:b-tt1:1:1"), backOnA.labels)
        assertEquals(listOf<String?>("keyA", "keyA"), fetcher.checkedWith.takeLast(2))
    }

    @Test
    fun s20SearchStartedRightAfterTheWipeNeverJoinsTheOutgoingOne() = runTest {
        // Review r1 (finding 6): the wipe invalidates at its call, before any scheduler turn.
        val store = store()
        fetcher.gatesIgnoreCancellation = true
        val gate = fetcher.hold("a")
        val outgoing = consume(store)
        store.clear()
        assertEquals(emptyList(), store.heldKeys(), "nothing is held once clear returns")
        val incoming = consume(store)
        gate.complete(answer("a", "outgoing"))
        runCurrent()

        assertEquals(2, store.startedCount)
        assertTrue(outgoing.job.isCompleted)
        assertEquals(listOf("a:a-tt1:1:1", "b:b-tt1:1:1"), incoming.labels, "fresh answers only, none of the outgoing search")
    }

    @Test
    fun s21WipeNeverReachesASearchStartedAfterIt() = runTest {
        val store = store()
        StreamSearchSessions.installForTesting(store)
        try {
            consume(store)
            StreamSearchSessions.clear()
            assertEquals(emptyList(), store.heldKeys())
            val gate = fetcher.hold("a")
            val incoming = consume(store)
            // Every queued task runs here: an asynchronous wipe would land now and cancel it.
            runCurrent()
            gate.complete(answer("a", "a1"))
            runCurrent()

            assertEquals(listOf("b:b-tt1:1:1", "a:a1"), incoming.labels)
            assertEquals(1, store.heldKeys().size)
        } finally {
            StreamSearchSessions.resetForTesting()
        }
    }

    @Test
    fun s22IsHeldFollowsTheStoreRules() = runTest {
        // Review r1 (finding 3): the repositories' repeat check asks this, so it must follow expiry.
        val store = store()
        val key = SearchFixtures.targets().key(1)
        assertFalse(store.isHeld(key))
        val gate = fetcher.hold("a")
        consume(store)
        assertTrue(store.isHeld(key), "a running search is held")
        gate.complete(answer("a", "a1"))
        runCurrent()
        clock += 15 * MINUTE - 1
        assertTrue(store.isHeld(key))
        clock += 1
        assertFalse(store.isHeld(key), "expired")
    }

    private companion object {
        const val MINUTE = 60_000L
    }

    // MARK: Stage B review finding 6: plugin changes

    @Test
    fun pluginRefreshDropsPluginSessions() = runTest {
        val store = store()
        val plugins = listOf(PluginProviderGroup("plugin:p", "P", listOf(SearchFixtures.scraper("s1"))))
        consume(store, SearchFixtures.targets(plugins = plugins))
        assertEquals(1, store.heldKeys().size)
        store.dropPluginSessions()
        assertTrue(store.heldKeys().isEmpty())
        consume(store, SearchFixtures.targets(plugins = plugins))
        assertEquals(2, store.startedCount, "the next ask runs the refreshed scraper")
    }

    @Test
    fun addonOnlySessionsSurviveAPluginRefresh() = runTest {
        val store = store()
        consume(store, SearchFixtures.targets(videoId = "tt1:1:1"))
        val plugins = listOf(PluginProviderGroup("plugin:p", "P", listOf(SearchFixtures.scraper("s1"))))
        consume(store, SearchFixtures.targets(videoId = "tt2:1:1", plugins = plugins))
        assertEquals(2, store.heldKeys().size)
        store.dropPluginSessions()
        assertEquals(listOf("tt1:1:1"), store.heldKeys().map { it.videoId })
        consume(store, SearchFixtures.targets(videoId = "tt1:1:1"))
        assertEquals(2, store.startedCount, "the add-on-only search is still reused")
    }

    @Test
    fun aRunningPluginSearchIsCancelledByTheDrop() = runTest {
        val store = store()
        fetcher.hold("a")
        val plugins = listOf(PluginProviderGroup("plugin:p", "P", listOf(SearchFixtures.scraper("s1"))))
        val consumer = consume(store, SearchFixtures.targets(plugins = plugins))
        assertTrue(!consumer.job.isCompleted)
        store.dropPluginSessions()
        runCurrent()
        assertTrue(consumer.job.isCompleted, "its consumer completes")
    }

    // MARK: Stage B review r6 finding 3: targets prepared before a plugin refresh

    private fun pluginTargets(generation: Long, videoId: String = "tt1:1:1") = StreamSearchTargets(
        type = "series",
        videoId = videoId,
        season = 1,
        episode = 1,
        streamAddons = listOf(SearchFixtures.target("a", videoId)),
        pluginProviderGroups = listOf(PluginProviderGroup("plugin:p", "P", listOf(SearchFixtures.scraper("s1")))),
        debrid = StreamSearchDebrid("none", null),
        pluginGeneration = generation,
    )

    @Test
    fun searchPreparedBeforeAPluginRefreshIsNeverJoinedAfterIt() = runTest {
        val store = store()
        val stale = pluginTargets(store.pluginGeneration())   // read before the refresh, used after it
        store.dropPluginSessions()                            // the refresh
        consume(store, stale)                                 // the suspended builder resumes
        val fresh = consume(store, pluginTargets(store.pluginGeneration()))
        assertEquals(2, store.startedCount, "the search built after the refresh runs the new scrapers")
        assertTrue(fresh.received.isNotEmpty())
        assertEquals(1, store.heldKeys().size, "the stale search of the same episode was dropped by the current one")
        assertEquals(store.pluginGeneration(), 1L)
    }

    @Test
    fun addonOnlyKeysIgnoreThePluginGeneration() = runTest {
        val store = store()
        val before = SearchFixtures.targets()
        store.dropPluginSessions()
        assertEquals(before.key(1), SearchFixtures.targets().key(1))
        val withPlugins = pluginTargets(0)
        assertTrue(withPlugins.key(1) != pluginTargets(1).key(1), "a plugin search is keyed by its generation")
    }

    @Test
    fun currentSearchDropsTheStaleSameEpisodeSession() = runTest {
        val store = store()
        val staleConsumer = run {
            val stale = pluginTargets(store.pluginGeneration())
            fetcher.hold("a")
            store.dropPluginSessions()
            consume(store, stale)
        }
        assertTrue(!staleConsumer.job.isCompleted)
        consume(store, pluginTargets(store.pluginGeneration()))
        runCurrent()
        assertTrue(staleConsumer.job.isCompleted, "the stale search is cancelled; its consumer completes")
    }
}
