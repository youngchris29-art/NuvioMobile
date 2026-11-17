package com.nuvio.app.features.player

import com.nuvio.app.features.streams.StreamItem
import kotlinx.coroutines.test.runTest
import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertFalse
import kotlin.test.assertNull
import kotlin.test.assertSame
import kotlin.test.assertTrue

class PlayerSourceFallbackRunTest {
    private val sources = (1..4).map { index ->
        StreamItem(name = "Source $index", url = "https://example.com/source-$index.mkv", addonName = "Test", addonId = "test")
    }
    private val expired = PlayerSourceResolveAttempt.Failed("expired")

    @Test
    fun aSourceThatResolvesPlaysWithoutAFallback() = runTest {
        val run = run(outcomes = mapOf(sources[0] to resolved(sources[0])))
        assertEquals("Source 1", run.resolved)
        assertEquals(0, run.tried.attempts)
        assertEquals(setOfNotNull(sources[0].playerSourceIdentityKey()), run.tried.keys)
    }

    @Test
    fun anExpiredDebridResultFallsBackToTheNextSource() = runTest {
        val run = run(outcomes = mapOf(sources[0] to expired, sources[1] to resolved(sources[1])))
        assertEquals("Source 2", run.resolved)
        assertNull(run.failure)
        assertEquals(1, run.tried.attempts)
        assertEquals(sources.take(2).mapNotNull { it.playerSourceIdentityKey() }.toSet(), run.tried.keys)
    }

    @Test
    fun theConfiguredNumberOfFurtherSourcesIsTheLimit() = runTest {
        val run = run(outcomes = sources.associateWith { expired }, maxSources = 2)
        assertNull(run.resolved)
        assertEquals("expired", run.failure)
        assertEquals(2, run.tried.attempts)
    }

    @Test
    fun withTheFallbackOffOnlyTheFirstSourceIsTried() = runTest {
        val run = run(outcomes = mapOf(sources[0] to PlayerSourceResolveAttempt.Failed("not cached")), maxSources = 0)
        assertNull(run.resolved)
        assertEquals("not cached", run.failure)
        assertEquals(0, run.tried.attempts)
    }

    @Test
    fun theWalkHandsTheFailedSourceAndItsKeyToThePicker() {
        val walk = PlayerSourceFallbackWalk(sources[0], maxSources = 3)
        var seenFailed: StreamItem? = null
        var seenKeys: Set<String> = emptySet()
        val next = walk.failed { failed, keys ->
            seenFailed = failed
            seenKeys = keys
            sources[1]
        }
        assertSame(sources[0], seenFailed)
        assertTrue(sources[0].playerSourceIdentityKey()!! in seenKeys)
        assertSame(sources[1], next)
        assertSame(sources[1], walk.candidate)
        assertEquals(1, walk.attempts)
    }

    @Test
    fun aPickerWithNothingLeftEndsTheWalkWithoutCountingAnAttempt() {
        val walk = PlayerSourceFallbackWalk(sources[0], maxSources = 3)
        val next = walk.failed { _, _ -> null }
        assertNull(next)
        assertEquals(0, walk.attempts)
        assertEquals(setOfNotNull(sources[0].playerSourceIdentityKey()), walk.tried.keys)
    }

    @Test
    fun theWalkStopsAskingThePickerOnceTheLimitIsReached() {
        val walk = PlayerSourceFallbackWalk(sources[0], maxSources = 1)
        assertSame(sources[1], walk.failed { _, _ -> sources[1] })
        var asked = false
        val next = walk.failed { _, _ ->
            asked = true
            sources[2]
        }
        assertNull(next)
        assertFalse(asked)
        assertEquals(1, walk.attempts)
        assertEquals(sources.take(2).mapNotNull { it.playerSourceIdentityKey() }.toSet(), walk.tried.keys)
    }

    @Test
    fun exclusionDropsTriedKeys() {
        val key0 = sources[0].playerSourceIdentityKey()!!
        assertTrue(PlayerSourceFallback.isExcluded(sources[0], setOf(key0), null, null))
        assertFalse(PlayerSourceFallback.isExcluded(sources[1], setOf(key0), null, null))
    }

    @Test
    fun exclusionDropsOtherCopiesOfTheFailedTorrentFromTheSameAddon() {
        val first = StreamItem(infoHash = "ABC", fileIdx = 1, addonName = "A", addonId = "a")
        val sameAddonCopy = StreamItem(infoHash = "ABC", fileIdx = 2, addonName = "A", addonId = "a")
        val otherAddonCopy = StreamItem(infoHash = "ABC", fileIdx = 2, addonName = "B", addonId = "b")
        val tried = setOfNotNull(first.playerSourceIdentityKey())
        assertTrue(PlayerSourceFallback.isExcluded(sameAddonCopy, tried, failedAddonId = "a", failedInfoHash = "abc"))
        assertFalse(PlayerSourceFallback.isExcluded(otherAddonCopy, tried, failedAddonId = "a", failedInfoHash = "abc"))
        assertFalse(PlayerSourceFallback.isExcluded(sameAddonCopy, tried, failedAddonId = "a", failedInfoHash = null))
    }

    @Test
    fun identityKeyMovedUnchanged() {
        val torrent = StreamItem(infoHash = " AbC ", fileIdx = 2, addonName = "A", addonId = "a")
        assertEquals("torrent:abc:2", torrent.playerSourceIdentityKey())
        val direct = StreamItem(url = "https://example.com/a.mkv", addonName = "A", addonId = "a")
        assertEquals("url:https://example.com/a.mkv", direct.playerSourceIdentityKey())
    }

    @Test
    fun nextEpisodeLimitIsThree() {
        assertEquals(3, PlayerSourceFallback.DEFAULT_FURTHER_SOURCES)
        assertEquals(3, PlayerSourceFallback.nextEpisodeMaxFurtherSources(null))
    }

    private fun resolved(stream: StreamItem) = PlayerSourceResolveAttempt.Resolved(stream.name.orEmpty())

    /** Picks the first untried source, like the auto selection in first-stream mode. */
    private suspend fun run(
        outcomes: Map<StreamItem, PlayerSourceResolveAttempt<String, String>>,
        maxSources: Int = 3,
    ): PlayerSourceFallbackRun<String, String> = resolveWithSourceFallback(
        first = sources[0],
        maxSources = maxSources,
        resolve = { stream -> outcomes[stream] ?: error("${stream.name} was not expected to be tried") },
        nextCandidate = { _, triedKeys -> sources.firstOrNull { it.playerSourceIdentityKey() !in triedKeys } },
    )
}
