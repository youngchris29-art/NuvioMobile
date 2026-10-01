package com.nuvio.app.features.debrid

import com.nuvio.app.features.streams.StreamClientResolve
import com.nuvio.app.features.streams.StreamItem
import kotlinx.coroutines.test.runTest
import kotlinx.serialization.json.buildJsonObject
import kotlin.test.AfterTest
import kotlin.test.BeforeTest
import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertFalse
import kotlin.test.assertNotEquals
import kotlin.test.assertNotNull
import kotlin.test.assertNull

/**
 * `DirectDebridPlaybackResolver.invalidate(stream, season, episode)` drops the resolve-cache entry
 * the next `resolve` would read.
 *
 * The cache itself cannot be driven from a unit test: it is private, and it is only filled by a
 * successful provider call (`DebridProviderApis` and `httpRequestRaw` have no injection point, the
 * base URLs are constants), so "resolve caches, invalidate, the next resolve hits the network
 * again" is not reproducible here without a network layer. What decides which entry `invalidate`
 * drops is the key builder `debridResolveCacheKey`, which `resolve`, `cachedPlayableStream` and
 * `invalidate` all share, so these tests pin that key (a drift between what `resolve` stores and
 * what `invalidate` removes would be a drift in this one function), plus the no-network paths of
 * `invalidate` itself.
 */
class DirectDebridResolverInvalidateTest {
    @BeforeTest
    fun initialize() {
        resetDebridSettings()
    }

    @AfterTest
    fun clearState() {
        resetDebridSettings()
    }

    private fun resetDebridSettings() {
        DebridSettingsStorage.replaceFromSyncPayload(buildJsonObject {})
        DebridSettingsRepository.onProfileChanged()
    }

    private fun connectTorbox(apiKey: String = "torbox-key-one") {
        DebridSettingsRepository.setProviderApiKey(DebridProviders.TORBOX_ID, apiKey)
    }

    private fun directStream(
        infoHash: String? = "ABCDEF0123456789",
        service: String = DebridProviders.TORBOX_ID,
        filename: String? = "Show.S01E02.1080p.mkv",
        fileIdx: Int? = null,
        season: Int? = null,
        episode: Int? = null,
    ) = StreamItem(
        name = "Torbox",
        addonName = "Debrid addon",
        addonId = "addon:debrid",
        clientResolve = StreamClientResolve(
            type = "debrid",
            service = service,
            isCached = true,
            infoHash = infoHash,
            filename = filename,
            fileIdx = fileIdx,
            season = season,
            episode = episode,
        ),
    )

    private fun torrentStream(infoHash: String = "ABC123", fileIdx: Int? = null) = StreamItem(
        name = "Torrent",
        addonName = "Torrent addon",
        addonId = "addon:torrent",
        infoHash = infoHash,
        fileIdx = fileIdx,
    )

    @Test
    fun `there is no cache key without a connected resolver`() {
        assertNull(directStream().debridResolveCacheKey(1, 2))
        assertNull(torrentStream().debridResolveCacheKey(1, 2))
    }

    @Test
    fun `the cache key is stable for the same stream and episode`() {
        connectTorbox()
        val first = directStream().debridResolveCacheKey(1, 2)
        assertNotNull(first)
        assertEquals(first, directStream().debridResolveCacheKey(1, 2))
    }

    @Test
    fun `the cache key differs per season and episode`() {
        connectTorbox()
        val stream = directStream()
        val keys = listOf(
            stream.debridResolveCacheKey(1, 2),
            stream.debridResolveCacheKey(1, 3),
            stream.debridResolveCacheKey(2, 2),
            stream.debridResolveCacheKey(null, null),
        )
        keys.forEach { assertNotNull(it) }
        assertEquals(keys.size, keys.toSet().size, "each season/episode needs its own entry: $keys")
    }

    @Test
    fun `the cache key reads the season and episode the stream carries when none is passed`() {
        connectTorbox()
        val stream = directStream(season = 1, episode = 2)
        assertEquals(stream.debridResolveCacheKey(1, 2), stream.debridResolveCacheKey(null, null))
        assertNotEquals(stream.debridResolveCacheKey(1, 2), stream.debridResolveCacheKey(3, 4))
    }

    @Test
    fun `the cache key ignores the case and padding of the torrent identity`() {
        connectTorbox()
        assertEquals(
            directStream(infoHash = "abcdef0123456789").debridResolveCacheKey(1, 2),
            directStream(infoHash = "  ABCDEF0123456789 ").debridResolveCacheKey(1, 2),
        )
        assertNotEquals(
            directStream(infoHash = "abcdef0123456789").debridResolveCacheKey(1, 2),
            directStream(infoHash = "fedcba9876543210").debridResolveCacheKey(1, 2),
        )
    }

    @Test
    fun `the cache key follows the file index and filename`() {
        connectTorbox()
        val base = directStream(fileIdx = 1).debridResolveCacheKey(1, 2)
        assertNotEquals(base, directStream(fileIdx = 2).debridResolveCacheKey(1, 2))
        assertNotEquals(base, directStream(fileIdx = 1, filename = "Show.S01E03.1080p.mkv").debridResolveCacheKey(1, 2))
    }

    @Test
    fun `there is no cache key for a stream of a provider that is not the active resolver`() {
        connectTorbox()
        assertNotNull(directStream(service = DebridProviders.TORBOX_ID).debridResolveCacheKey(1, 2))
        assertNull(directStream(service = DebridProviders.PREMIUMIZE_ID).debridResolveCacheKey(1, 2))
        assertNull(directStream(service = "not-a-provider").debridResolveCacheKey(1, 2))
    }

    @Test
    fun `the cache key changes with the API key and does not contain it`() {
        connectTorbox("torbox-key-one")
        val first = directStream().debridResolveCacheKey(1, 2)
        assertNotNull(first)
        assertFalse(first.contains("torbox-key-one"), "the key must carry a fingerprint, not the secret")

        connectTorbox("torbox-key-two")
        val second = directStream().debridResolveCacheKey(1, 2)
        assertNotNull(second)
        assertNotEquals(first, second)
    }

    @Test
    fun `a torrent that needs a local resolve is keyed by identity file and episode`() {
        connectTorbox()
        val stream = torrentStream(infoHash = "ABC123", fileIdx = 1)
        val key = stream.debridResolveCacheKey(1, 2)
        assertNotNull(key)
        assertEquals(key, torrentStream(infoHash = " abc123 ", fileIdx = 1).debridResolveCacheKey(1, 2))
        assertNotEquals(key, torrentStream(infoHash = "ABC123", fileIdx = 2).debridResolveCacheKey(1, 2))
        assertNotEquals(key, stream.debridResolveCacheKey(1, 3))
        assertNotEquals(key, torrentStream(infoHash = "ABC124", fileIdx = 1).debridResolveCacheKey(1, 2))
    }

    @Test
    fun `invalidate of a stream without a cache key does nothing`() {
        // No resolver connected: there is no key, so nothing is launched and nothing throws.
        DirectDebridPlaybackResolver.invalidate(directStream(), season = 1, episode = 2)
        DirectDebridPlaybackResolver.invalidate(torrentStream(), season = null, episode = null)
    }

    @Test
    fun `invalidate of a keyed stream with nothing cached returns and leaves nothing cached`() = runTest {
        connectTorbox()
        DebridSettingsRepository.setEnabled(true)
        val stream = directStream()
        assertNotNull(stream.debridResolveCacheKey(1, 2))
        assertNull(DirectDebridPlaybackResolver.cachedPlayableStream(stream, season = 1, episode = 2))

        DirectDebridPlaybackResolver.invalidate(stream, season = 1, episode = 2)

        assertNull(DirectDebridPlaybackResolver.cachedPlayableStream(stream, season = 1, episode = 2))
    }
}
