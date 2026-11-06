package com.nuvio.app.features.streams

import kotlin.test.Test
import kotlin.test.assertFalse
import kotlin.test.assertTrue

/** Parity with the tvOS `StreamsViewModel.isListable` that [StreamListability] was ported from. */
class StreamListabilityTest {

    private fun stream(
        url: String? = null,
        infoHash: String? = null,
        ytId: String? = null,
        addonId: String = "addon:com.stremio.torrentio.addon:https://torrentio.strem.fun/manifest.json",
    ) = StreamItem(
        name = "Fixture",
        url = url,
        infoHash = infoHash,
        ytId = ytId,
        addonName = "Fixture",
        addonId = addonId,
    )

    @Test
    fun directHttpUrlIsListableWithOrWithoutDebrid() {
        val direct = stream(url = "https://cdn.example.com/movie.mkv")
        assertTrue(StreamListability.isListable(direct, debridCanResolve = false))
        assertTrue(StreamListability.isListable(direct, debridCanResolve = true))
    }

    @Test
    fun magnetOnlyIsNotListable() {
        val magnet = stream(url = "magnet:?xt=urn:btih:0123456789abcdef0123456789abcdef01234567", addonId = "plugin:scraper")
        assertFalse(StreamListability.isListable(magnet, debridCanResolve = false))
        assertFalse(StreamListability.isListable(magnet, debridCanResolve = true))
    }

    @Test
    fun addonTorrentIsListableOnlyWhenDebridCanResolve() {
        val torrent = stream(infoHash = "0123456789abcdef0123456789abcdef01234567")
        assertTrue(StreamListability.isListable(torrent, debridCanResolve = true))
        assertFalse(StreamListability.isListable(torrent, debridCanResolve = false))
    }

    @Test
    fun addonMagnetUrlIsListableOnlyWhenDebridCanResolve() {
        val torrent = stream(url = "magnet:?xt=urn:btih:0123456789abcdef0123456789abcdef01234567")
        assertTrue(StreamListability.isListable(torrent, debridCanResolve = true))
        assertFalse(StreamListability.isListable(torrent, debridCanResolve = false))
    }

    @Test
    fun nonAddonTorrentIsNeverADebridCandidate() {
        val torrent = stream(infoHash = "0123456789abcdef0123456789abcdef01234567", addonId = "plugin:scraper")
        assertFalse(StreamListability.isListable(torrent, debridCanResolve = true))
    }

    @Test
    fun youTubeIdOnlyIsListable() {
        val youTube = stream(ytId = "dQw4w9WgXcQ")
        assertTrue(StreamListability.isListable(youTube, debridCanResolve = false))
        assertTrue(StreamListability.isListable(youTube, debridCanResolve = true))
    }

    @Test
    fun youTubeIdWithAUrlFallsBackToTheUrlRule() {
        val withMagnet = stream(url = "magnet:?xt=urn:btih:0123456789abcdef0123456789abcdef01234567", ytId = "dQw4w9WgXcQ", addonId = "plugin:x")
        assertFalse(StreamListability.isListable(withMagnet, debridCanResolve = false))
    }

    @Test
    fun emptyStreamIsNotListable() {
        assertFalse(StreamListability.isListable(stream(), debridCanResolve = true))
    }
}
