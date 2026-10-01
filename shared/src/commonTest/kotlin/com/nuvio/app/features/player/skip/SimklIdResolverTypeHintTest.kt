package com.nuvio.app.features.player.skip

import kotlinx.serialization.json.Json
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.jsonArray
import kotlinx.serialization.json.jsonObject
import kotlinx.serialization.json.jsonPrimitive
import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertNull
import kotlin.test.assertSame

/**
 * Upstream 317bf2dc (Simkl type hint): the pure half of [SimklIdResolver.resolveIds]'s candidate
 * narrowing. `httpGetText` has no test seam, so the network path is not exercised here.
 */
class SimklIdResolverTypeHintTest {

    private val results: List<JsonObject> = Json.parseToJsonElement(
        """
        [
          { "type": "movie", "ids": { "simkl": 11 } },
          { "type": "show",  "ids": { "simkl": 22 } },
          { "type": "anime", "ids": { "simkl": 33 } },
          { "ids": { "simkl": 44 } },
          { "type": "tv",    "ids": { "simkl": 55 } }
        ]
        """.trimIndent()
    ).jsonArray.map { it.jsonObject }

    private fun ids(candidates: List<JsonObject>) =
        candidates.map { it["ids"]!!.jsonObject["simkl"]!!.jsonPrimitive.content.toLong() }

    @Test
    fun seriesHintKeepsOnlyShowEntries() {
        // A "tv"-typed entry is accepted alongside "show", in response order.
        assertEquals(listOf(22L, 55L), ids(SimklIdResolver.selectCandidatesForTypeHint(results, "series")))
        assertEquals(listOf(22L, 55L), ids(SimklIdResolver.selectCandidatesForTypeHint(results, "TV")))
        assertEquals(listOf(11L), ids(SimklIdResolver.selectCandidatesForTypeHint(results, "movie")))
        assertEquals(listOf(33L), ids(SimklIdResolver.selectCandidatesForTypeHint(results, "anime")))
    }

    @Test
    fun hintWithNoMatchFallsBackToTheFullListSoTheFirstResultStillWins() {
        val moviesOnly = results.take(1)
        assertSame(moviesOnly, SimklIdResolver.selectCandidatesForTypeHint(moviesOnly, "series"))
    }

    @Test
    fun absentOrUnknownHintLeavesTheListUntouched() {
        assertSame(results, SimklIdResolver.selectCandidatesForTypeHint(results, null))
        assertSame(results, SimklIdResolver.selectCandidatesForTypeHint(results, "  "))
        assertSame(results, SimklIdResolver.selectCandidatesForTypeHint(results, "channel"))
        assertNull(SimklIdResolver.expectedSimklTypes("channel"))
        assertNull(SimklIdResolver.expectedSimklTypes(null))
    }

    @Test
    fun showHintAcceptsBothSimklSpellings() {
        assertEquals(setOf("show", "tv"), SimklIdResolver.expectedSimklTypes("tvshow"))
        assertEquals(setOf("show", "tv"), SimklIdResolver.expectedSimklTypes("Show"))
        assertEquals(setOf("movie"), SimklIdResolver.expectedSimklTypes("film"))
    }
}
