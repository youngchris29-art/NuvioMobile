package com.nuvio.app.features.streams

import kotlinx.coroutines.flow.toList
import kotlinx.coroutines.test.TestScope
import kotlinx.coroutines.test.runTest
import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertNotEquals

/** Upstream 8fba6c71e `StreamSearchSessionsTest`, on the fork's injectable store (W4). */
class StreamSearchSessionsTest {
    private val fetcher = ScriptedSearchFetcher()

    private fun TestScope.store() = StreamSearchSessionStore(fetcher, now = { testScheduler.currentTime }, scope = backgroundScope)

    @Test
    fun aSecondSearchForTheSameEpisodeReusesTheResults() = runTest {
        val store = store()
        val first = store.search(PROFILE, SearchFixtures.targets(), forceRefresh = false).toList()
        val second = store.search(PROFILE, SearchFixtures.targets(), forceRefresh = false).toList()

        assertEquals(listOf("a@tt1:1:1", "b@tt1:1:1"), fetcher.addonFetches)
        assertEquals(1, store.startedCount)
        assertEquals(first, second)
    }

    @Test
    fun forceRefreshStartsANewSearch() = runTest {
        val store = store()
        store.search(PROFILE, SearchFixtures.targets(), forceRefresh = false).toList()
        store.search(PROFILE, SearchFixtures.targets(), forceRefresh = true).toList()

        assertEquals(2, store.startedCount)
        assertEquals(2, fetcher.fetchCount("a"))
    }

    @Test
    fun anotherEpisodeIsASeparateSearch() = runTest {
        val store = store()
        store.search(PROFILE, SearchFixtures.targets(videoId = "tt1:1:1", episode = 1), forceRefresh = false).toList()
        store.search(PROFILE, SearchFixtures.targets(videoId = "tt1:1:2", episode = 2), forceRefresh = false).toList()

        assertEquals(2, store.startedCount)
        assertEquals(2, store.heldKeys().size)
    }

    @Test
    fun anotherProfileIsASeparateSearch() = runTest {
        val store = store()
        store.search(PROFILE, SearchFixtures.targets(), forceRefresh = false).toList()
        store.search(PROFILE + 1, SearchFixtures.targets(), forceRefresh = false).toList()

        assertEquals(2, store.startedCount)
        assertEquals(listOf(PROFILE + 1), store.heldKeys().map { it.profileId })
    }

    @Test
    fun aChangedSourceSetupIsASeparateSearch() = runTest {
        val store = store()
        store.search(PROFILE, SearchFixtures.targets(addons = listOf("a")), forceRefresh = false).toList()
        store.search(PROFILE, SearchFixtures.targets(addons = listOf("other")), forceRefresh = false).toList()
        // Fork: the debrid account is part of the setup (upstream 4c414a5f4).
        store.search(PROFILE, SearchFixtures.targets(addons = listOf("other"), debrid = "torbox:7"), forceRefresh = false).toList()

        assertEquals(3, store.startedCount)
        // The same episode's older setups are dropped, not kept beside the new one.
        assertEquals(1, store.heldKeys().size)
    }

    @Test
    fun theKeyCarriesEachAddonsRequestIdAndTheDebridAccount() {
        val plain = SearchFixtures.targets(requestId = "tt1").sourceConfiguration
        assertEquals(
            // Review r10 findings: each add-on with the URL it is fetched from.
            "addon:addon:a:https://a.example.com/manifest.json@tt1~https://a.example.com/manifest.json|" +
                "addon:addon:b:https://b.example.com/manifest.json@tt1~https://b.example.com/manifest.json|debrid:none",
            plain,
        )
        assertNotEquals(plain, SearchFixtures.targets(requestId = "tmdb:1").sourceConfiguration)
        assertNotEquals(plain, SearchFixtures.targets(requestId = "tt1", debrid = "torbox:1").sourceConfiguration)
        val grouped = SearchFixtures.targets(
            plugins = listOf(PluginProviderGroup("plugin-repo:x", "X", listOf(SearchFixtures.scraper("s1"), SearchFixtures.scraper("s2")))),
        ).sourceConfiguration
        assertEquals(true, grouped.contains("plugin:plugin-repo:x:s1,s2"))
    }

    private companion object {
        const val PROFILE = 1
    }
}
