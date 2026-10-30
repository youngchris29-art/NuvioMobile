package com.nuvio.app.features.plugins

import com.nuvio.app.features.profiles.ProfileRepository
import kotlinx.serialization.encodeToString
import kotlinx.serialization.json.Json
import kotlin.test.AfterTest
import kotlin.test.BeforeTest
import kotlin.test.Test
import kotlin.test.assertEquals

/** Settings > Sources > Plugins "All Providers": one repository on or off in one update and one save. */
class PluginRepositoryScrapersEnabledTest {
    private val repoA = "https://example.test/a/manifest.json"
    private val repoB = "https://example.test/b/manifest.json"

    private fun scraper(
        id: String,
        repositoryUrl: String,
        enabled: Boolean,
        manifestEnabled: Boolean = true,
    ) = StoredPluginScraper(
        id = id,
        repositoryUrl = repositoryUrl,
        name = id,
        description = "",
        version = "1.0.0",
        filename = "$id.js",
        supportedTypes = listOf("movie"),
        enabled = enabled,
        manifestEnabled = manifestEnabled,
        code = "",
    )

    private fun seed(scrapers: List<StoredPluginScraper>) {
        val now = currentEpochMillis()
        val state = StoredPluginsState(
            repositories = listOf(repoA, repoB).map { url ->
                StoredPluginRepository(
                    manifestUrl = url,
                    name = url,
                    scraperCount = scrapers.count { it.repositoryUrl == url },
                    lastUpdated = now,
                )
            },
            scrapers = scrapers,
        )
        PluginStorage.saveState(ProfileRepository.activeProfileId, Json.encodeToString(state))
        PluginRepository.clearLocalState()
        PluginRepository.initialize()
    }

    private fun enabledById(): Map<String, Boolean> =
        PluginRepository.uiState.value.scrapers.associate { it.id to it.enabled }

    @BeforeTest
    fun clearBefore() = PluginRepository.clearLocalState()

    @AfterTest
    fun clearAfter() {
        PluginStorage.saveState(ProfileRepository.activeProfileId, Json.encodeToString(StoredPluginsState()))
        PluginRepository.clearLocalState()
    }

    @Test
    fun enablingTurnsOnEveryProviderThatTheManifestAllowsAndLeavesOtherRepositories() {
        seed(
            listOf(
                scraper("a1", repoA, enabled = false),
                scraper("a2", repoA, enabled = false),
                scraper("a3", repoA, enabled = false, manifestEnabled = false),
                scraper("b1", repoB, enabled = false),
            ),
        )

        PluginRepository.setRepositoryScrapersEnabled(repoA, enabled = true)

        assertEquals(
            mapOf("a1" to true, "a2" to true, "a3" to false, "b1" to false),
            enabledById(),
        )
    }

    @Test
    fun disablingTurnsOffEveryProviderOfTheRepository() {
        seed(
            listOf(
                scraper("a1", repoA, enabled = true),
                scraper("a2", repoA, enabled = true),
                scraper("b1", repoB, enabled = true),
            ),
        )

        PluginRepository.setRepositoryScrapersEnabled(repoA, enabled = false)

        assertEquals(mapOf("a1" to false, "a2" to false, "b1" to true), enabledById())
    }

    @Test
    fun theWholeRepositoryIsSavedOnceAndTheSavedStateMatches() {
        seed(
            listOf(
                scraper("a1", repoA, enabled = false),
                scraper("a2", repoA, enabled = false),
                scraper("a3", repoA, enabled = false),
            ),
        )
        val savesBefore = PluginRepository.persistCount

        PluginRepository.setRepositoryScrapersEnabled(repoA, enabled = true)

        assertEquals(1, PluginRepository.persistCount - savesBefore)
        val stored = Json.decodeFromString<StoredPluginsState>(
            PluginStorage.loadState(ProfileRepository.activeProfileId).orEmpty(),
        )
        assertEquals(listOf(true, true, true), stored.scrapers.map { it.enabled })
    }
}
