package com.nuvio.app.features.streams

import kotlinx.serialization.json.Json
import kotlin.test.AfterTest
import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertNull

/**
 * The fork keeps the link cache's expiring-credential guards that upstream 3d70db683 removed:
 * a tokenized/expiring link is neither saved nor returned, a plain link is.
 */
class StreamLinkCacheTokenTest {
    private val key = StreamLinkCacheRepository.contentKey(type = "movie", videoId = "tt-token-test")
    private val json = Json { ignoreUnknownKeys = true }

    @AfterTest
    fun cleanUp() = StreamLinkCacheRepository.remove(key)

    @Test
    fun linkWithExpiringTokenIsNotSaved() {
        StreamLinkCacheRepository.save(contentKey = key, url = TOKEN_URL, streamName = "1080p", addonName = "Test", addonId = "addon:test")
        assertNull(StreamLinkCacheRepository.getValid(key, ONE_HOUR_MS))
    }

    @Test
    fun savingAnExpiringLinkDropsTheEarlierPlainEntry() {
        StreamLinkCacheRepository.save(contentKey = key, url = PLAIN_URL, streamName = "1080p", addonName = "Test", addonId = "addon:test")
        StreamLinkCacheRepository.save(contentKey = key, url = TOKEN_URL, streamName = "1080p", addonName = "Test", addonId = "addon:test")
        assertNull(StreamLinkCacheRepository.getValid(key, ONE_HOUR_MS))
    }

    @Test
    fun storedExpiringLinkIsNotReturnedAndIsEvicted() {
        // An entry written by a build without the save guard is refused on read and removed.
        val entry = CachedStreamLink(
            url = TOKEN_URL,
            streamName = "1080p",
            addonName = "Test",
            addonId = "addon:test",
            cachedAtMs = epochMs(),
        )
        StreamLinkCacheStorage.saveEntry(storageKey(key), json.encodeToString(CachedStreamLink.serializer(), entry))

        assertNull(StreamLinkCacheRepository.getValid(key, ONE_HOUR_MS))
        assertNull(StreamLinkCacheStorage.loadEntry(storageKey(key)))
    }

    @Test
    fun plainLinkIsSavedAndReturned() {
        StreamLinkCacheRepository.save(contentKey = key, url = PLAIN_URL, streamName = "1080p", addonName = "Test", addonId = "addon:test")
        assertEquals(PLAIN_URL, StreamLinkCacheRepository.getValid(key, ONE_HOUR_MS)?.url)
    }

    // Mirrors StreamLinkCacheRepository.hashedKey (private).
    private fun storageKey(contentKey: String): String {
        val hash = contentKey.fold(0L) { acc, c -> acc * 31 + c.code }.toULong()
        return "stream_link_$hash"
    }

    private companion object {
        const val ONE_HOUR_MS = 60L * 60L * 1000L
        const val TOKEN_URL = "https://cdn.example.com/dld/file-id?token=abc&expires=1234"
        const val PLAIN_URL = "https://cdn.example.com/files/movie-1080p.mkv"
    }
}
