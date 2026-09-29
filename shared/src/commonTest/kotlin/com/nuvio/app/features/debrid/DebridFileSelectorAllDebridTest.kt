package com.nuvio.app.features.debrid

import com.nuvio.app.features.streams.StreamClientResolve
import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertNull

/**
 * Fork-only: AllDebrid is not an upstream provider, but since the port of upstream `6aa42153`
 * its selector shares the requested-episode rules the other providers use. It has no stable
 * per-file index, so `fileIdx` is ignored and a request with no episode still falls back to the
 * largest playable video.
 */
class DebridFileSelectorAllDebridTest {
    private val seasonPack = listOf(
        AllDebridFileNodeDto(
            n = "Show S01 1080p",
            e = listOf(
                AllDebridFileNodeDto(n = "Show.S01E01.1080p.mkv", s = 3_000, l = "https://ad/e01"),
                AllDebridFileNodeDto(n = "Show.S01E02.1080p.mkv", s = 1_000, l = "https://ad/e02"),
                AllDebridFileNodeDto(n = "Show.S01E03.1080p.mkv", s = 2_000, l = "https://ad/e03"),
                AllDebridFileNodeDto(n = "Sample", e = listOf(
                    AllDebridFileNodeDto(n = "sample.mkv", s = 9_000, l = "https://ad/sample"),
                )),
                AllDebridFileNodeDto(n = "Readme.txt", s = 50_000, l = "https://ad/readme"),
            ),
        ),
    ).flattenAllDebridFiles()

    @Test
    fun `flattening keeps the folder path and display name is the leaf`() {
        val file = seasonPack.single { it.link == "https://ad/sample" }

        assertEquals("Show S01 1080p/Sample/sample.mkv", file.name)
        assertEquals("sample.mkv", file.displayName())
    }

    @Test
    fun `season pack selects the requested episode instead of the largest file`() {
        val selected = AllDebridFileSelector().selectFile(seasonPack, resolve(), season = 1, episode = 2)

        assertEquals("https://ad/e02", selected?.link)
    }

    @Test
    fun `season pack uses the resolve season and episode when none are passed`() {
        val selected = AllDebridFileSelector().selectFile(seasonPack, resolve(season = 1, episode = 3), null, null)

        assertEquals("https://ad/e03", selected?.link)
    }

    @Test
    fun `season pack prefers the explicit filename over the episode pattern`() {
        val selected = AllDebridFileSelector().selectFile(
            seasonPack,
            resolve(filename = "Show.S01E03.1080p.mkv"),
            season = 1,
            episode = 2,
        )

        assertEquals("https://ad/e03", selected?.link)
    }

    @Test
    fun `missing requested episode returns null instead of another file`() {
        assertNull(AllDebridFileSelector().selectFile(seasonPack, resolve(), season = 1, episode = 4))
        assertNull(AllDebridFileSelector().selectFile(seasonPack, resolve(filename = "missing.mkv"), season = 1, episode = 4))
    }

    @Test
    fun `ambiguous requested episode returns null`() {
        val files = listOf(
            AllDebridFlatFile(name = "Show.S01E02.720p.mkv", size = 200, link = "https://ad/720"),
            AllDebridFlatFile(name = "Show.S01E02.1080p.mkv", size = 400, link = "https://ad/1080"),
        )

        assertNull(AllDebridFileSelector().selectFile(files, resolve(), season = 1, episode = 2))
    }

    @Test
    fun `exact path distinguishes repeated basenames across season folders`() {
        val files = listOf(
            AllDebridFileNodeDto(n = "Show", e = listOf(
                AllDebridFileNodeDto(n = "Season 1", e = listOf(
                    AllDebridFileNodeDto(n = "Episode 02.mkv", s = 200, l = "https://ad/s1e02"),
                )),
                AllDebridFileNodeDto(n = "Season 2", e = listOf(
                    AllDebridFileNodeDto(n = "Episode 02.mkv", s = 100, l = "https://ad/s2e02"),
                )),
            )),
        ).flattenAllDebridFiles()

        assertEquals(
            "https://ad/s2e02",
            AllDebridFileSelector().selectFile(files, resolve(filename = "Season 2\\Episode 02.mkv"), null, null)?.link,
        )
    }

    @Test
    fun `single file movie is selected`() {
        val files = listOf(
            AllDebridFileNodeDto(n = "Movie.2024.1080p.mkv", s = 8_000, l = "https://ad/movie"),
            AllDebridFileNodeDto(n = "Movie.2024.nfo", s = 1, l = "https://ad/nfo"),
        ).flattenAllDebridFiles()

        assertEquals("https://ad/movie", AllDebridFileSelector().selectFile(files, resolve(), null, null)?.link)
        assertEquals(
            "https://ad/movie",
            AllDebridFileSelector().selectFile(files, resolve(filename = "Movie.2024.1080p.mkv"), null, null)?.link,
        )
    }

    @Test
    fun `movie with a filename hint that misses still falls back to the largest video`() {
        val files = listOf(
            AllDebridFlatFile(name = "Movie/sample.mkv", size = 100, link = "https://ad/sample"),
            AllDebridFlatFile(name = "Movie/Movie.2024.2160p.mkv", size = 9_000, link = "https://ad/movie"),
        )

        val selected = AllDebridFileSelector().selectFile(
            files,
            resolve(filename = "Movie (2024) [2160p].mkv"),
            season = null,
            episode = null,
        )

        assertEquals("https://ad/movie", selected?.link)
    }

    @Test
    fun `fileIdx is ignored because the flattened tree has no stable index`() {
        val files = listOf(
            AllDebridFlatFile(name = "small.mkv", size = 100, link = "https://ad/small"),
            AllDebridFlatFile(name = "large.mkv", size = 900, link = "https://ad/large"),
        )

        assertEquals("https://ad/large", AllDebridFileSelector().selectFile(files, resolve(fileIdx = 0), null, null)?.link)
        assertEquals("https://ad/large", AllDebridFileSelector().selectFile(files, resolve(fileIdx = 7), null, null)?.link)
    }

    @Test
    fun `no playable video returns null`() {
        val files = listOf(AllDebridFlatFile(name = "Readme.txt", size = 100, link = "https://ad/readme"))

        assertNull(AllDebridFileSelector().selectFile(files, resolve(), null, null))
    }

    private fun resolve(
        fileIdx: Int? = null,
        season: Int? = null,
        episode: Int? = null,
        filename: String? = null,
    ): StreamClientResolve =
        StreamClientResolve(
            type = "debrid",
            service = DebridProviders.ALLDEBRID_ID,
            isCached = true,
            infoHash = "hash",
            fileIdx = fileIdx,
            filename = filename,
            season = season,
            episode = episode,
        )
}
