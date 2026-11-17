package com.nuvio.app.features.player

import com.nuvio.app.features.streams.StreamAutoPlayMode
import com.nuvio.app.features.streams.StreamAutoPlayRanking
import com.nuvio.app.features.streams.StreamAutoPlaySource
import com.nuvio.app.features.streams.StreamBehaviorHints
import com.nuvio.app.features.streams.StreamItem
import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertFalse
import kotlin.test.assertNull
import kotlin.test.assertTrue

/**
 * W4 group B: the shared source-fallback rule (upstream 8fba6c71e): which entry points fall back,
 * how many further sources, the start-up limit, and the next best-ranked untried candidate.
 */
class PlayerSourceFallbackPolicyTest {
    private val installed = setOf("Alpha", "Beta", "Gamma")

    private fun stream(name: String, addon: String = "Alpha", bingeGroup: String? = null, size: Long = 1L) = StreamItem(
        name = name,
        url = "https://example.com/${addon.lowercase()}/${name.replace(' ', '-')}.mp4",
        addonName = addon,
        addonId = "addon:$addon",
        behaviorHints = StreamBehaviorHints(bingeGroup = bingeGroup, videoSize = size),
    )

    private fun torrent(hash: String, fileIdx: Int, addon: String, name: String = "Movie 1080p") = StreamItem(
        name = name,
        infoHash = hash,
        fileIdx = fileIdx,
        addonName = addon,
        addonId = "addon:$addon",
    )

    private fun scope(
        mode: StreamAutoPlayMode = StreamAutoPlayMode.FIRST_STREAM,
        regex: String = "",
        ranking: StreamAutoPlayRanking = StreamAutoPlayRanking.BEST_QUALITY,
        preferredBingeGroup: String? = null,
        preferBingeGroup: Boolean = false,
        bingeGroupOnly: Boolean = false,
    ) = StreamAutoPickScope(
        mode = mode,
        regexPattern = regex,
        source = StreamAutoPlaySource.ALL_SOURCES,
        selectedAddons = emptySet(),
        selectedPlugins = emptySet(),
        preferredBingeGroup = preferredBingeGroup,
        preferBingeGroupInSelection = preferBingeGroup,
        bingeGroupOnly = bingeGroupOnly,
        ranking = ranking,
    )

    private fun ranked(
        streams: List<StreamItem>,
        scope: StreamAutoPickScope = scope(),
        tried: Set<String> = emptySet(),
        failedAddonId: String? = null,
        failedInfoHash: String? = null,
    ) = PlayerSourceFallback.rankedCandidates(
        streams = streams,
        scope = scope,
        triedKeys = tried,
        failedAddonId = failedAddonId,
        failedInfoHash = failedInfoHash,
        installedAddonNames = installed,
        debridEnabled = true,
        activeResolverProviderId = "realdebrid",
    )

    private fun next(
        streams: List<StreamItem>,
        scope: StreamAutoPickScope = scope(),
        tried: Set<String> = emptySet(),
        failedAddonId: String? = null,
        failedInfoHash: String? = null,
    ) = PlayerSourceFallback.nextCandidate(
        streams, scope, tried, failedAddonId, failedInfoHash, installed, true, "realdebrid",
    )

    private fun keys(vararg streams: StreamItem) = streams.mapNotNull { it.playerSourceFallbackKey() }.toSet()

    // ----- isActive / furtherSources / startupLimitSeconds -----

    @Test
    fun isActiveTruthTable() {
        for (on in listOf(true, false)) {
            for (mode in StreamAutoPlayMode.entries) {
                val settings = PlayerSettingsUiState(streamAutoPlayFallbackOnFailure = on, streamAutoPlayMode = mode)
                assertEquals(
                    on && mode != StreamAutoPlayMode.MANUAL,
                    PlayerSourceFallback.isActive(settings, PlayerSourceFallbackEntry.FIRST_PLAY),
                    "first play on=$on mode=$mode",
                )
                assertEquals(
                    on,
                    PlayerSourceFallback.isActive(settings, PlayerSourceFallbackEntry.NEXT_EPISODE),
                    "next episode on=$on mode=$mode",
                )
            }
        }
    }

    @Test
    fun nullSettingsReadAsTheDefaults() {
        // On by default; first play still needs an auto-play mode and settings that are not loaded are MANUAL.
        assertFalse(PlayerSourceFallback.isActive(null, PlayerSourceFallbackEntry.FIRST_PLAY))
        assertTrue(PlayerSourceFallback.isActive(null, PlayerSourceFallbackEntry.NEXT_EPISODE))
        assertEquals(3, PlayerSourceFallback.furtherSources(null, PlayerSourceFallbackEntry.NEXT_EPISODE))
        assertEquals(3, PlayerSourceFallback.nextEpisodeMaxFurtherSources(null))
        assertEquals(15, PlayerSourceFallback.startupLimitSeconds(null, PlayerSourceFallbackEntry.NEXT_EPISODE))
        assertEquals(0, PlayerSourceFallback.furtherSources(null, PlayerSourceFallbackEntry.FIRST_PLAY))
        assertNull(PlayerSourceFallback.startupLimitSeconds(null, PlayerSourceFallbackEntry.FIRST_PLAY))
    }

    @Test
    fun furtherSourcesIsZeroWhenInactiveAndClampsOutOfRangeValues() {
        val off = PlayerSettingsUiState(streamAutoPlayFallbackOnFailure = false, streamAutoPlayFallbackMaxSources = 5)
        assertEquals(0, PlayerSourceFallback.furtherSources(off, PlayerSourceFallbackEntry.NEXT_EPISODE))
        assertEquals(0, PlayerSourceFallback.nextEpisodeMaxFurtherSources(off))

        for ((stored, expected) in mapOf(0 to 1, 11 to 10, -1 to 1, 1 to 1, 10 to 10, 4 to 4)) {
            val settings = PlayerSettingsUiState(
                streamAutoPlayMode = StreamAutoPlayMode.FIRST_STREAM,
                streamAutoPlayFallbackMaxSources = stored,
            )
            assertEquals(expected, PlayerSourceFallback.furtherSources(settings, PlayerSourceFallbackEntry.FIRST_PLAY), "stored $stored")
            assertEquals(expected, PlayerSourceFallback.furtherSources(settings, PlayerSourceFallbackEntry.NEXT_EPISODE), "stored $stored")
        }
    }

    @Test
    fun startupLimitIsNullWhenInactiveAndClampsOutOfRangeValues() {
        val off = PlayerSettingsUiState(streamAutoPlayFallbackOnFailure = false)
        assertNull(PlayerSourceFallback.startupLimitSeconds(off, PlayerSourceFallbackEntry.NEXT_EPISODE))
        val manual = PlayerSettingsUiState(streamAutoPlayMode = StreamAutoPlayMode.MANUAL)
        assertNull(PlayerSourceFallback.startupLimitSeconds(manual, PlayerSourceFallbackEntry.FIRST_PLAY))
        assertEquals(15, PlayerSourceFallback.startupLimitSeconds(manual, PlayerSourceFallbackEntry.NEXT_EPISODE))

        for ((stored, expected) in mapOf(4 to 5, 46 to 45, 5 to 5, 45 to 45, 30 to 30)) {
            val settings = PlayerSettingsUiState(
                streamAutoPlayMode = StreamAutoPlayMode.FIRST_STREAM,
                streamAutoPlayFallbackStartupTimeoutSeconds = stored,
            )
            assertEquals(expected, PlayerSourceFallback.startupLimitSeconds(settings, PlayerSourceFallbackEntry.FIRST_PLAY), "stored $stored")
        }
    }

    @Test
    fun swiftOptionListsMatchTheRanges() {
        assertEquals((1..10).toList(), PlayerSourceFallback.sourcesToTryOptions)
        assertEquals(listOf(5, 10, 15, 20, 25, 30, 35, 40, 45), PlayerSourceFallback.startupLimitOptions)
    }

    @Test
    fun firstPlayScopeReadsTheUserSettings() {
        val settings = PlayerSettingsUiState(
            streamAutoPlayMode = StreamAutoPlayMode.REGEX_MATCH,
            streamAutoPlayRegex = "2160p",
            streamAutoPlaySource = StreamAutoPlaySource.INSTALLED_ADDONS_ONLY,
            streamAutoPlaySelectedAddons = setOf("Alpha"),
            streamAutoPlaySelectedPlugins = setOf("Scraper"),
        )
        val scope = StreamAutoPickScope.firstPlay(settings)
        assertEquals(StreamAutoPlayMode.REGEX_MATCH, scope.mode)
        assertEquals("2160p", scope.regexPattern)
        assertEquals(StreamAutoPlaySource.INSTALLED_ADDONS_ONLY, scope.source)
        assertEquals(setOf("Alpha"), scope.selectedAddons)
        assertEquals(setOf("Scraper"), scope.selectedPlugins)
        assertNull(scope.preferredBingeGroup)
        assertFalse(scope.bingeGroupOnly)
    }

    // ----- candidates (ported from upstream PlayerSourceFallbackTest) -----

    @Test
    fun nextCandidateIsTheFirstMatchNotTriedYet() {
        val a = stream("Movie 1080p", addon = "Alpha")
        val b = stream("Movie 720p", addon = "Beta")
        val c = stream("Movie 480p", addon = "Gamma")
        val list = listOf(a, b, c)
        // LIST_ORDER keeps list order, the tried first source is left out.
        val listOrder = scope(ranking = StreamAutoPlayRanking.LIST_ORDER)
        assertEquals(a, next(list, listOrder))
        assertEquals(b, next(list, listOrder, tried = keys(a)))
        assertEquals(c, next(list, listOrder, tried = keys(a, b)))
    }

    @Test
    fun otherCopiesOfTheFailedTorrentAreSkipped() {
        val failed = torrent("ABC", 1, "Alpha")
        val sameAddonCopy = torrent("ABC", 2, "Alpha")
        val otherAddonCopy = torrent("abc", 2, "Beta")
        val unrelated = torrent("DEF", 1, "Alpha")
        val list = listOf(failed, sameAddonCopy, otherAddonCopy, unrelated)
        val listOrder = scope(ranking = StreamAutoPlayRanking.LIST_ORDER)
        // Torrents with no cache state need a P2P-ready resolver: debridEnabled with an unknown state is not
        // auto-playable, so judge by exclusion directly as well.
        assertTrue(PlayerSourceFallback.isExcluded(sameAddonCopy, keys(failed), "addon:Alpha", "ABC"))
        assertFalse(PlayerSourceFallback.isExcluded(otherAddonCopy, keys(failed), "addon:Alpha", "ABC"))
        val remaining = ranked(list, listOrder, tried = keys(failed), failedAddonId = "addon:Alpha", failedInfoHash = "ABC")
        assertFalse(sameAddonCopy in remaining)
        assertFalse(failed in remaining)
    }

    @Test
    fun noCandidateWhenEverySourceWasTried() {
        val a = stream("Movie 1080p", addon = "Alpha")
        val b = stream("Movie 720p", addon = "Beta")
        assertNull(next(listOf(a, b), tried = keys(a, b)))
        assertTrue(ranked(listOf(a, b), tried = keys(a, b)).isEmpty())
        assertNull(next(emptyList()))
    }

    @Test
    fun regexModeOnlyFallsBackToMatchingSources() {
        val a = stream("Movie 2160p HDR", addon = "Alpha")
        val b = stream("Movie 1080p", addon = "Beta")
        val c = stream("Movie 2160p WEB", addon = "Gamma")
        val regex = scope(mode = StreamAutoPlayMode.REGEX_MATCH, regex = "2160p", ranking = StreamAutoPlayRanking.LIST_ORDER)
        assertEquals(listOf(a, c), ranked(listOf(a, b, c), regex))
        assertEquals(c, next(listOf(a, b, c), regex, tried = keys(a)))
        assertNull(next(listOf(a, b, c), regex, tried = keys(a, c)))
    }

    @Test
    fun manualModeWithoutBingeGroupHasNoCandidates() {
        val a = stream("Movie 1080p")
        assertNull(next(listOf(a), scope(mode = StreamAutoPlayMode.MANUAL)))
    }

    // ----- rankedCandidates -----

    @Test
    fun firstStreamBestQualityOrdersByResolutionMinusTried() {
        val p720 = stream("Movie 720p", addon = "Alpha")
        val p2160 = stream("Movie 2160p", addon = "Beta")
        val p1080 = stream("Movie 1080p", addon = "Gamma")
        val list = listOf(p720, p2160, p1080)

        assertEquals(listOf(p2160, p1080, p720), ranked(list))
        assertEquals(listOf(p1080, p720), ranked(list, tried = keys(p2160)))
        assertEquals(listOf(p720), ranked(list, tried = keys(p2160, p1080)))
        // nextCandidate is always the head of the ranked list.
        assertEquals(p2160, next(list))
        assertEquals(p1080, next(list, tried = keys(p2160)))
    }

    @Test
    fun aBingeGroupPreferenceOnlyReordersTheRankedList() {
        val p2160 = stream("Movie 2160p", addon = "Alpha", bingeGroup = "other")
        val p1080 = stream("Movie 1080p", addon = "Beta", bingeGroup = "mine")
        val p720 = stream("Movie 720p", addon = "Gamma")
        val preferred = scope(preferredBingeGroup = "mine", preferBingeGroup = true)

        val result = ranked(listOf(p2160, p1080, p720), preferred)
        assertEquals(listOf(p1080, p2160, p720), result)
        // Nothing is dropped compared with the plain ranking.
        assertEquals(ranked(listOf(p2160, p1080, p720)).toSet(), result.toSet())
    }

    @Test
    fun bingeGroupOnlyScopeReturnsOnlyThatGroupInRankedOrder() {
        val g1 = stream("Show S01E02 1080p", addon = "Alpha", bingeGroup = "grp")
        val other = stream("Show S01E02 2160p", addon = "Beta", bingeGroup = "different")
        val g2 = stream("Show S01E02 720p", addon = "Gamma", bingeGroup = "grp")
        val none = stream("Show S01E02 480p", addon = "Alpha")
        val only = scope(
            mode = StreamAutoPlayMode.MANUAL,
            ranking = StreamAutoPlayRanking.LIST_ORDER,
            preferredBingeGroup = "grp",
            preferBingeGroup = true,
            bingeGroupOnly = true,
        )
        val list = listOf(g1, other, g2, none)

        // The selector alone returns one stream in this scope; the expansion picks again per untried set.
        assertEquals(listOf(g1, g2), ranked(list, only))
        assertEquals(listOf(g2), ranked(list, only, tried = keys(g1)))
        assertTrue(ranked(list, only, tried = keys(g1, g2)).isEmpty())
        assertEquals(g1, next(list, only))
        assertEquals(g2, next(list, only, tried = keys(g1)))
        assertNull(next(list, only, tried = keys(g1, g2)))
    }

    // ----- seeded walk -----

    @Test
    fun aSeededWalkContinuesTheCountAndSkipsWhatWasTried() {
        val a = stream("Source 1", addon = "Alpha")
        val b = stream("Source 2", addon = "Alpha")
        val c = stream("Source 3", addon = "Alpha")
        val d = stream("Source 4", addon = "Alpha")
        val all = listOf(a, b, c, d)
        val pick = { _: StreamItem, tried: Set<String> -> all.firstOrNull { it.playerSourceFallbackKey() !in tried } }

        // Up Next tried {a} and used 2 attempts; the player's first failure was b; budget 3.
        val walk = PlayerSourceFallbackWalk(b, 3, PlayerSourceFallbackTried(keys(a), attempts = 2))
        assertEquals(2, walk.attempts)
        assertEquals(c, walk.failed(pick))
        assertEquals(3, walk.attempts)
        // Budget spent: no further source even though d is untried.
        assertNull(walk.failed(pick))
        assertEquals(keys(a, b, c), walk.tried.keys)
    }

    @Test
    fun theTwoArgumentWalkStartsFresh() {
        val a = stream("Source 1", addon = "Alpha")
        val b = stream("Source 2", addon = "Alpha")
        val walk = PlayerSourceFallbackWalk(a, 1)
        assertEquals(0, walk.attempts)
        assertEquals(b, walk.failed { _, tried -> listOf(a, b).firstOrNull { it.playerSourceFallbackKey() !in tried } })
        assertNull(walk.failed { _, _ -> null })
    }
}
