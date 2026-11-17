package com.nuvio.app.features.player

import com.nuvio.app.features.streams.StreamItem
import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertFalse
import kotlin.test.assertNull
import kotlin.test.assertTrue

/** Review r2: the same-add-on copy rule holds for every failure of the walk, not only the last. */
class PlayerSourceFallbackFailedTorrentsTest {
    private val hashA = "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"
    private val hashB = "bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb"

    private fun torrent(addon: String, hash: String, fileIdx: Int?) = StreamItem(
        name = "$addon-$hash-$fileIdx",
        infoHash = hash,
        fileIdx = fileIdx,
        addonName = addon,
        addonId = "addon:$addon",
    )

    private fun link(addon: String, n: Int) = StreamItem(
        name = "$addon-link-$n",
        url = "https://cdn.example.com/$addon/$n.mkv",
        addonName = addon,
        addonId = "addon:$addon",
    )

    /** Picks the first source of [pool] the shared rule allows, after [failed]. */
    private fun pick(pool: List<StreamItem>) = { failed: StreamItem, tried: Set<String> ->
        pool.firstOrNull { !PlayerSourceFallback.isExcluded(it, tried, failed.addonId, failed.p2pInfoHash) }
    }

    @Test
    fun anEarlierFailedTorrentsOtherCopyIsNotPickedAfterALaterFailure() {
        val copy1 = torrent("x", hashA, 0)
        val other = torrent("y", hashB, 0)
        val copy2 = torrent("x", hashA, null)
        val fallback = link("z", 1)
        val walk = PlayerSourceFallbackWalk(copy1, maxSources = 5)

        assertEquals(other, walk.failed(pick(listOf(other, copy2, fallback))))
        assertEquals(fallback, walk.failed(pick(listOf(copy2, fallback))), "x's other copy of the failed torrent is skipped")
    }

    @Test
    fun theSameTorrentFromAnotherAddonStaysACandidate() {
        val fromX = torrent("x", hashA, 0)
        val fromY = torrent("y", hashA, 0)
        val walk = PlayerSourceFallbackWalk(fromX, maxSources = 3)
        assertEquals(fromY, walk.failed(pick(listOf(fromY))))
        val tried = PlayerSourceFallbackTried.None.includingFailed(fromX)
        assertFalse(PlayerSourceFallback.isExcludedAfter(fromY, tried, null))
        assertTrue(PlayerSourceFallback.isExcludedAfter(torrent("x", hashA, 4), tried, null))
    }

    @Test
    fun aSourceWithoutAnInfoHashRecordsNoTorrentFailure() {
        val first = link("x", 1)
        val tried = PlayerSourceFallbackTried.None.includingFailed(first)
        assertEquals(PlayerSourceFallbackTried.None.including(first), tried)
        assertTrue(tried.contains(first))
        assertFalse(PlayerSourceFallback.isExcludedAfter(link("x", 2), tried, null))
    }

    @Test
    fun aSourceOnlyTriedIsNotAFailedTorrent() {
        // Started and replaced for another reason: plain `including` keeps upstream's rule (its
        // other copies stay candidates once a later failure is the last one).
        val replaced = torrent("x", hashA, 0)
        val tried = PlayerSourceFallbackTried.None.including(replaced)
        assertTrue(tried.contains(replaced))
        assertFalse(PlayerSourceFallback.isExcludedAfter(torrent("x", hashA, 1), tried, null))
        assertTrue(PlayerSourceFallback.isExcludedAfter(torrent("x", hashA, 1), tried, replaced), "the last failure still counts")
    }

    @Test
    fun theBudgetCountsAsBefore() {
        val pool = listOf(link("a", 1), link("a", 2), link("a", 3), link("a", 4))
        val walk = PlayerSourceFallbackWalk(torrent("x", hashA, 0), maxSources = 2)
        assertEquals(pool[0], walk.failed(pick(pool)))
        assertEquals(pool[1], walk.failed(pick(pool)))
        assertNull(walk.failed(pick(pool)))
        assertEquals(2, walk.attempts)
        assertEquals(2, walk.tried.attempts)
    }

    @Test
    fun theSeededWalkCarriesFailedTorrentsFromUpNextIntoThePlayer() {
        val upNextFailed = torrent("x", hashA, 0)
        val upNextPlayed = link("y", 1)
        val upNext = PlayerSourceFallbackWalk(upNextFailed, maxSources = 3)
        assertEquals(upNextPlayed, upNext.failed(pick(listOf(upNextPlayed))))
        val handedOver = upNext.resolved()

        // In the player the played source fails; x's other copy of the torrent that failed in Up
        // Next is still excluded.
        val player = PlayerSourceFallbackWalk(upNextPlayed, maxSources = 3, alreadyTried = handedOver)
        val otherCopy = torrent("x", hashA, null)
        val fresh = link("z", 1)
        assertEquals(fresh, player.failed(pick(listOf(otherCopy, fresh))))
        assertEquals(2, player.attempts)
    }
}
