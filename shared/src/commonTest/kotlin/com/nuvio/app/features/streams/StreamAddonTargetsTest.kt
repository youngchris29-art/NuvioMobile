package com.nuvio.app.features.streams

import com.nuvio.app.features.addons.AddonManifest
import com.nuvio.app.features.addons.AddonResource
import com.nuvio.app.features.addons.ManagedAddon
import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertTrue

/** [streamAddonTargets]: which installed add-ons get asked, in what order, and with which id (BUG-74). */
class StreamAddonTargetsTest {

    private fun addon(
        id: String,
        name: String = id,
        types: List<String> = listOf("movie", "series"),
        idPrefixes: List<String> = emptyList(),
        enabled: Boolean = true,
        resourceName: String = "stream",
        withManifest: Boolean = true,
        userSetName: String? = null,
    ): ManagedAddon {
        val url = "https://$id.example.com/manifest.json"
        return ManagedAddon(
            manifestUrl = url,
            manifest = if (withManifest) {
                AddonManifest(
                    id = id,
                    name = name,
                    description = "",
                    version = "1.0.0",
                    resources = listOf(AddonResource(name = resourceName, types = types, idPrefixes = idPrefixes)),
                    types = types,
                    transportUrl = url,
                )
            } else {
                null
            },
            userSetName = userSetName,
            enabled = enabled,
        )
    }

    private fun targets(
        installed: List<ManagedAddon>,
        type: String = "movie",
        videoId: String = "tt0133093",
        imdbVideoId: String? = null,
    ) = streamAddonTargets(installed, type, videoId, imdbVideoId)

    @Test
    fun keepsTheUsersAddonOrder() {
        val result = targets(listOf(addon("c"), addon("a"), addon("b")))
        assertEquals(listOf("c", "a", "b"), result.map { it.addonName })
    }

    @Test
    fun targetCarriesInstanceIdManifestAndRequestId() {
        val installed = addon("com.example.streams", name = "Example")
        val target = targets(listOf(installed)).single()
        assertEquals("Example", target.addonName)
        assertEquals("addon:com.example.streams:https://com.example.streams.example.com/manifest.json", target.addonId)
        assertEquals("tt0133093", target.videoId)
        assertEquals(installed.manifest, target.manifest)
    }

    @Test
    fun userSetNameWinsOverManifestName() {
        val target = targets(listOf(addon("a", name = "Manifest Name", userSetName = "My Torrentio"))).single()
        assertEquals("My Torrentio", target.addonName)
    }

    @Test
    fun disabledAddonsAreExcluded() {
        val result = targets(listOf(addon("a"), addon("b", enabled = false), addon("c")))
        assertEquals(listOf("a", "c"), result.map { it.addonName })
    }

    @Test
    fun typeMismatchIsExcluded() {
        val result = targets(
            listOf(addon("movies-only", types = listOf("movie")), addon("series-only", types = listOf("series"))),
            type = "series",
            videoId = "tt0944947:1:1",
        )
        assertEquals(listOf("series-only"), result.map { it.addonName })
    }

    @Test
    fun nonStreamResourcesAreExcluded() {
        val result = targets(listOf(addon("catalog-only", resourceName = "catalog"), addon("streamer")))
        assertEquals(listOf("streamer"), result.map { it.addonName })
    }

    @Test
    fun addonWithoutManifestIsExcluded() {
        val result = targets(listOf(addon("broken", withManifest = false), addon("ok")))
        assertEquals(listOf("ok"), result.map { it.addonName })
    }

    @Test
    fun emptyInstalledListGivesNoTargets() {
        assertTrue(targets(emptyList()).isEmpty())
    }

    @Test
    fun ttPrefixAddonDoesNotMatchTmdbIdOnTheFirstPass() {
        val result = targets(
            listOf(addon("tt-only", idPrefixes = listOf("tt"))),
            videoId = "tmdb:603",
            imdbVideoId = null,
        )
        assertTrue(result.isEmpty())
    }

    @Test
    fun ttPrefixAddonMatchesTheImdbIdOnTheSecondPass() {
        val result = targets(
            listOf(addon("tt-only", idPrefixes = listOf("tt"))),
            videoId = "tmdb:603",
            imdbVideoId = "tt0133093",
        )
        assertEquals(listOf("tt0133093"), result.map { it.videoId })
    }

    @Test
    fun eachAddonGetsTheIdItAccepts() {
        val result = targets(
            listOf(
                addon("tt-only", idPrefixes = listOf("tt")),
                addon("tmdb-aware", idPrefixes = listOf("tmdb:")),
                addon("no-prefixes"),
            ),
            videoId = "tmdb:603",
            imdbVideoId = "tt0133093",
        )
        assertEquals(
            listOf("tt-only" to "tt0133093", "tmdb-aware" to "tmdb:603", "no-prefixes" to "tmdb:603"),
            result.map { it.addonName to it.videoId },
        )
    }

    @Test
    fun tmdbIdAddonGetsTheTmdbVideoIdWhenNoImdbIdIsKnown() {
        val result = targets(
            listOf(addon("tmdb-aware", idPrefixes = listOf("tmdb:")), addon("tt-only", idPrefixes = listOf("tt"))),
            videoId = "tmdb:603",
            imdbVideoId = null,
        )
        assertEquals(listOf("tmdb-aware" to "tmdb:603"), result.map { it.addonName to it.videoId })
    }

    @Test
    fun episodeSuffixIsKeptOnTheRemappedId() {
        val result = targets(
            listOf(addon("tt-only", idPrefixes = listOf("tt"))),
            type = "series",
            videoId = "tmdb:1399:1:5",
            imdbVideoId = "tt0944947:1:5",
        )
        assertEquals(listOf("tt0944947:1:5"), result.map { it.videoId })
    }
}
