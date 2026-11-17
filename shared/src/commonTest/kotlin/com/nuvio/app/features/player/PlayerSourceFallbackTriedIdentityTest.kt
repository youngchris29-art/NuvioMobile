package com.nuvio.app.features.player

import com.nuvio.app.features.streams.StreamItem
import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertFalse
import kotlin.test.assertNotEquals
import kotlin.test.assertTrue

/** Review r1 (finding 4): the walk's tried identity tells add-ons apart for the same torrent. */
class PlayerSourceFallbackTriedIdentityTest {
    private val hash = "0123456789abcdef0123456789abcdef01234567"

    private fun torrent(addon: String, fileIdx: Int = 0, label: String = "$addon-$fileIdx") = StreamItem(
        name = label,
        infoHash = hash,
        fileIdx = fileIdx,
        addonName = addon,
        addonId = "addon:$addon:https://$addon.example.com/manifest.json",
    )

    private fun direct(addon: String, url: String) = StreamItem(
        name = url,
        url = url,
        addonName = addon,
        addonId = "addon:$addon:https://$addon.example.com/manifest.json",
    )

    @Test
    fun sameTorrentFromAnotherAddonStaysACandidateAfterTheFirstFailed() {
        val fromA = torrent("a")
        val fromB = torrent("b")
        val walk = PlayerSourceFallbackWalk(fromA, maxSources = 3)
        var offeredTried: Set<String> = emptySet()
        val next = walk.failed { failed, tried ->
            offeredTried = tried
            listOf(fromA, fromB).firstOrNull {
                !PlayerSourceFallback.isExcluded(it, tried, failed.addonId, failed.p2pInfoHash)
            }
        }

        assertEquals(fromB, next)
        assertTrue(PlayerSourceFallback.isExcluded(fromA, offeredTried, fromA.addonId, hash))
        assertFalse(PlayerSourceFallback.isExcluded(fromB, offeredTried, fromA.addonId, hash))
    }

    @Test
    fun otherCopiesOfTheFailedTorrentFromTheSameAddonAreStillLeftOut() {
        val failed = torrent("a", fileIdx = 0)
        val sameAddonOtherFile = torrent("a", fileIdx = 1)
        val tried = setOfNotNull(failed.playerSourceFallbackKey())

        assertTrue(PlayerSourceFallback.isExcluded(sameAddonOtherFile, tried, failed.addonId, hash))
        assertFalse(PlayerSourceFallback.isExcluded(torrent("b", fileIdx = 1), tried, failed.addonId, hash))
    }

    @Test
    fun walkKeyAddsTheAddonForTorrentsOnly() {
        assertNotEquals(torrent("a").playerSourceFallbackKey(), torrent("b").playerSourceFallbackKey())
        // The identity key the phone marks the playing row with is unchanged.
        assertEquals(torrent("a").playerSourceIdentityKey(), torrent("b").playerSourceIdentityKey())
        val link = direct("a", "https://cdn.example.com/x.mkv")
        assertEquals(link.playerSourceIdentityKey(), link.playerSourceFallbackKey())
    }

    @Test
    fun walkCarriesWalkKeysIntoTheNextEpisode() {
        val fromA = torrent("a")
        val walk = PlayerSourceFallbackWalk(fromA, maxSources = 3)
        assertEquals(setOfNotNull(fromA.playerSourceFallbackKey()), walk.resolved().keys)
    }

    private fun variety(): List<StreamItem> = listOf(
        torrent("a"),
        torrent("a", fileIdx = 1),
        torrent("b"),
        StreamItem(name = "no-addon torrent", infoHash = hash, fileIdx = 3, addonName = "", addonId = ""),
        direct("a", "https://cdn.example.com/1.mkv"),
        direct("b", "https://cdn.example.com/1.mkv"),
        StreamItem(name = "no-addon link", url = "https://cdn.example.com/2.mkv", addonName = "", addonId = ""),
        StreamItem(name = "meta only", addonName = "c", addonId = "addon:c"),
    )

    @Test
    fun walkNeverReturnsACandidateItRecordedAsTried() {
        val all = variety()
        for (first in all) {
            val walk = PlayerSourceFallbackWalk(first, maxSources = all.size)
            val returned = mutableListOf(first)
            while (true) {
                val next = walk.failed { failed, tried ->
                    all.firstOrNull { !PlayerSourceFallback.isExcluded(it, tried, null, null) }
                } ?: break
                assertFalse(next in returned, "re-picked ${next.name} after starting from ${first.name}")
                returned += next
            }
            assertTrue(all.all { walk.tried.contains(it) || it !in returned }, "everything returned is recorded")
        }
    }

    @Test
    fun keysACallerBuiltWithTheIdentityKeyStillExcludeWhatItTried() {
        // Transitional: a caller still recording playerSourceIdentityKey() never re-picks.
        for (stream in variety()) {
            val legacy = setOfNotNull(stream.playerSourceIdentityKey())
            assertTrue(PlayerSourceFallback.isTried(stream, legacy), "legacy key of ${stream.name}")
        }
        val opaque = PlayerSourceFallbackTried.None.including(torrent("a"))
        assertTrue(opaque.contains(torrent("a")))
        assertFalse(opaque.contains(torrent("b")), "opaque keys tell the add-ons apart")
        assertEquals(setOfNotNull(PlayerSourceFallback.triedKey(torrent("a"))), opaque.keys)
    }

    @Test
    fun isExcludedAfterReadsTheFailedSourceItself() {
        val failed = torrent("a")
        val tried = PlayerSourceFallbackTried.None.including(failed)
        assertTrue(PlayerSourceFallback.isExcludedAfter(torrent("a", fileIdx = 1), tried, failed))
        assertFalse(PlayerSourceFallback.isExcludedAfter(torrent("b"), tried, failed))
    }
}
