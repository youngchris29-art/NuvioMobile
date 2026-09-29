package com.nuvio.app.features.simkl

import kotlinx.serialization.json.buildJsonObject
import kotlinx.serialization.json.put
import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertSame
import kotlin.test.assertTrue

class SimklPlaybackMergeTest {
    @Test
    fun `held playback newer than the fetched one for the same episode wins`() {
        val fetched = episode(progress = 88.0, pausedAt = "2024-04-30T22:00:00Z")
        val held = episode(progress = 83.0, pausedAt = "2024-04-30T22:30:00Z")

        val merged = mergeFetchedPlayback(listOf(fetched), listOf(held))

        assertEquals(listOf(held), merged)
    }

    @Test
    fun `fetched playback newer than the held one wins`() {
        val fetched = episode(progress = 88.0, pausedAt = "2024-04-30T22:30:00Z")
        val held = episode(progress = 83.0, pausedAt = "2024-04-30T22:00:00Z")

        val merged = mergeFetchedPlayback(listOf(fetched), listOf(held))

        assertEquals(listOf(fetched), merged)
    }

    @Test
    fun `entries only in the fetch are kept beside a held winner`() {
        val other = episode(number = 6, progress = 10.0, pausedAt = "2024-04-30T21:00:00Z")
        val fetched = episode(progress = 88.0, pausedAt = "2024-04-30T22:00:00Z")
        val held = episode(progress = 83.0, pausedAt = "2024-04-30T22:30:00Z")

        val merged = mergeFetchedPlayback(listOf(fetched, other), listOf(held))

        assertEquals(2, merged.size)
        assertTrue(other in merged)
        assertTrue(held in merged)
    }

    @Test
    fun `a held entry absent from the fetch is dropped`() {
        val fetched = episode(number = 6, progress = 10.0, pausedAt = "2024-04-30T21:00:00Z")
        val held = episode(number = 5, progress = 83.0, pausedAt = "2024-04-30T22:30:00Z")

        val merged = mergeFetchedPlayback(listOf(fetched), listOf(held))

        assertEquals(listOf(fetched), merged)
    }

    @Test
    fun `an empty held list returns the fetch untouched`() {
        val fetched = listOf(episode(progress = 88.0, pausedAt = "2024-04-30T22:00:00Z"))

        assertSame(fetched, mergeFetchedPlayback(fetched, emptyList()))
    }

    @Test
    fun `a movie and an episode of the same title do not collide`() {
        val fetchedMovie = SimklPlaybackSession(
            id = 1,
            progress = 50.0,
            pausedAt = "2024-04-30T22:00:00Z",
            type = "movie",
            movie = media(),
        )
        val heldEpisode = episode(progress = 83.0, pausedAt = "2024-04-30T22:30:00Z")

        val merged = mergeFetchedPlayback(listOf(fetchedMovie), listOf(heldEpisode))

        assertEquals(listOf(fetchedMovie), merged)
    }

    private fun episode(
        number: Int = 5,
        progress: Double,
        pausedAt: String,
    ) = SimklPlaybackSession(
        id = 12345,
        progress = progress,
        pausedAt = pausedAt,
        type = "episode",
        episode = SimklPlaybackEpisode(season = 1, number = number),
        show = media(),
    )

    private fun media() = SimklMedia(
        title = "Title",
        ids = buildJsonObject {
            put("simkl", 39687)
            put("imdb", "tt4574334")
        },
    )
}
