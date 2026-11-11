package com.nuvio.app.features.streams

import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertFalse
import kotlin.test.assertTrue

/** Pack sources compare with scheme and host case-insensitive and the rest of the URL exact. */
class StreamBadgeSourceMatchTest {
    private val a = "https://example.com/packs/Anime.json"
    private val b = "https://example.com/packs/anime.json"

    private fun pack(url: String, isActive: Boolean = true) = StreamBadgeImport(
        sourceUrl = url,
        filters = listOf(StreamBadgeFilter(id = "f", name = "F", pattern = "x")),
        isActive = isActive,
    )

    @Test
    fun packsDifferingOnlyInPathCaseAreTwoPacks() {
        val rules = StreamBadgeRules().upsert(pack(a)).upsert(pack(b))
        assertEquals(listOf(a, b), rules.imports.map { it.sourceUrl })
        assertEquals(b, rules.activeImport?.sourceUrl)
        assertEquals(listOf(false, true), rules.imports.map { it.isActive })
    }

    @Test
    fun hostCaseDifferenceIsTheSamePack() {
        val rules = StreamBadgeRules()
            .upsert(pack("https://EXAMPLE.com/p.json"))
            .upsert(pack("https://example.com/p.json"))
        assertEquals(listOf("https://example.com/p.json"), rules.imports.map { it.sourceUrl })
    }

    @Test
    fun removeSourceRemovesOnlyTheExactPathPack() {
        val rules = StreamBadgeRules().upsert(pack(a)).upsert(pack(b)).removeSource(a)
        assertEquals(listOf(b), rules.imports.map { it.sourceUrl })
        val viaHostCase = StreamBadgeRules().upsert(pack(a)).upsert(pack(b)).removeSource("https://EXAMPLE.com/packs/anime.json")
        assertEquals(listOf(a), viaHostCase.imports.map { it.sourceUrl })
    }

    @Test
    fun setActiveSourceActivatesTheExactPathPack() {
        val rules = StreamBadgeRules().upsert(pack(a)).upsert(pack(b)).setActiveSource(a)
        assertEquals(a, rules.activeImport?.sourceUrl)
        assertEquals(listOf(true, false), rules.imports.map { it.isActive })
    }

    @Test
    fun containsSourceMatchesHostCaseOnly() {
        val rules = StreamBadgeRules().upsert(pack(b))
        assertTrue(rules.containsSource("https://EXAMPLE.com/packs/anime.json"))
        assertTrue(rules.containsSource("  $b "))
        assertFalse(rules.containsSource(a))
        assertFalse(rules.containsSource(""))
    }

    @Test
    fun forPlayerWithAPathCaseVariantFallsBackToTheActiveImport() {
        val rules = StreamBadgeRules().upsert(pack("https://example.com/Only.json"))
        assertEquals("https://example.com/Only.json", rules.forPlayer("https://example.com/only.json").activeImport?.sourceUrl)
        val two = StreamBadgeRules().upsert(pack(a), activate = true).upsert(pack("https://other.example/x.json"))
        // The variant is no pack: the active import (the other pack) stays active.
        assertEquals("https://other.example/x.json", two.forPlayer("https://example.com/packs/ANIME.json").activeImport?.sourceUrl)
        // The exact source activates its pack.
        assertEquals(a, two.forPlayer(a).activeImport?.sourceUrl)
    }

    @Test
    fun theImportLimitStillAppliesToDistinctPathCaseVariants() {
        var rules = StreamBadgeRules()
        listOf("https://e.com/A.json", "https://e.com/a.json", "https://e.com/b.json", "https://e.com/B.json").forEach {
            rules = rules.upsert(pack(it))
        }
        assertEquals(STREAM_BADGE_IMPORT_LIMIT, rules.imports.size)
    }
}
