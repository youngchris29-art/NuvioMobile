package com.nuvio.app.features.tmdb

import kotlinx.coroutines.test.runTest
import kotlinx.serialization.json.buildJsonObject
import kotlin.test.AfterTest
import kotlin.test.BeforeTest
import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertNull

class TmdbPersonSearchServiceTest {
    private val fixture = """
        {"page":1,"results":[
          {"id":287,"name":"Brad Pitt","profile_path":"/pitt.jpg","known_for_department":"Acting",
           "known_for":[{"title":"Fight Club","media_type":"movie"},{"name":"Some Show","media_type":"tv"},{"media_type":"movie"}]},
          {"id":1,"name":null,"profile_path":null},
          {"id":2,"name":"No Photo","known_for_department":"Directing"}
        ],"total_results":3}
    """.trimIndent()

    @BeforeTest
    fun setUp() {
        TmdbPersonSearchService.clearCacheForTest()
        TmdbSettingsStorage.replaceFromSyncPayload(buildJsonObject {})
        TmdbSettingsRepository.onProfileChanged()
    }

    @AfterTest
    fun tearDown() {
        TmdbPersonSearchService.httpGetForTest = null
        TmdbPersonSearchService.clearCacheForTest()
        TmdbSettingsStorage.replaceFromSyncPayload(buildJsonObject {})
        TmdbSettingsRepository.onProfileChanged()
    }

    @Test
    fun decodeDropsNullNamesAndMapsKnownFor() {
        val people = parsePersonSearch(fixture)
        assertEquals(listOf(287, 2), people.map { it.tmdbId })
        val pitt = people.first()
        assertEquals("Brad Pitt", pitt.name)
        assertEquals("https://image.tmdb.org/t/p/w185/pitt.jpg", pitt.profileUrl)
        assertEquals("Acting", pitt.knownForDepartment)
        assertEquals(listOf("Fight Club", "Some Show"), pitt.knownFor)
        assertNull(people[1].profileUrl)
        assertEquals(emptyList(), people[1].knownFor)
    }

    @Test
    fun disabledTmdbReturnsEmptyWithoutARequest() = runTest {
        var requests = 0
        TmdbPersonSearchService.httpGetForTest = { requests += 1; fixture }
        assertEquals(emptyList(), TmdbPersonSearchService.searchPeopleChecked("brad", 10))
        assertEquals(0, requests)
    }

    @Test
    fun blankQueryReturnsEmptyWithoutARequest() = runTest {
        TmdbSettingsRepository.setEnabled(true)
        var requests = 0
        TmdbPersonSearchService.httpGetForTest = { requests += 1; fixture }
        assertEquals(emptyList(), TmdbPersonSearchService.searchPeople("   "))
        assertEquals(0, requests)
    }

    @Test
    fun enabledSearchHitsTheEndpointOnceAndCaches() = runTest {
        TmdbSettingsRepository.setEnabled(true)
        val urls = mutableListOf<String>()
        TmdbPersonSearchService.httpGetForTest = { urls += it; fixture }
        val first = TmdbPersonSearchService.searchPeople("Brad", limit = 1)
        val again = TmdbPersonSearchService.searchPeople("brad", limit = 10)
        assertEquals(1, urls.size)
        assertEquals(true, urls.single().contains("search/person"))
        assertEquals(true, urls.single().contains("include_adult=false"))
        assertEquals(1, first.size)
        assertEquals(2, again.size)
    }

    @Test
    fun failureIsEmptyForSearchPeopleAndThrowsForChecked() = runTest {
        TmdbSettingsRepository.setEnabled(true)
        TmdbPersonSearchService.httpGetForTest = { error("boom") }
        assertEquals(emptyList(), TmdbPersonSearchService.searchPeople("x"))
        var threw = false
        try {
            TmdbPersonSearchService.searchPeopleChecked("x", 10)
        } catch (_: IllegalStateException) {
            threw = true
        }
        assertEquals(true, threw)
    }
}
