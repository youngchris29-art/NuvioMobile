package com.nuvio.app.features.debrid

import com.nuvio.app.features.streams.StreamClientResolve
import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertNull

/**
 * Fork-only: sample-clip disambiguation, plus a pin that there is no fileIdx fallback for
 * packs whose names do not carry the requested episode.
 */
class DebridFileSelectorSampleTest {
    private fun torbox(names: List<String>) =
        names.mapIndexed { i, n -> TorboxTorrentFileDto(id = 100 + i, name = n, size = 100L + i) }

    private fun realDebrid(names: List<String>) =
        names.mapIndexed { i, n -> RealDebridTorrentFileDto(id = 100 + i, path = "/$n", bytes = 100L + i) }

    private fun resolve(fileIdx: Int? = null) = StreamClientResolve(fileIdx = fileIdx)

    @Test
    fun `episode with a sample clip selects the real episode for every provider`() {
        val names = listOf("Show.S01E05.sample.mkv", "Show.S01E05.mkv", "Show.S01E06.mkv")
        assertEquals("Show.S01E05.mkv", TorboxFileSelector().selectFile(torbox(names), resolve(), 1, 5)?.name)
        assertEquals("/Show.S01E05.mkv", RealDebridFileSelector().selectFile(realDebrid(names), resolve(), 1, 5)?.path)
        assertEquals(
            "Show.S01E05.mkv",
            PremiumizeDirectDownloadFileSelector().selectFile(
                names.map { PremiumizeDirectDownloadFileDto(path = it, size = 10, link = "https://pm/$it") },
                resolve(), 1, 5,
            )?.path,
        )
        assertEquals(
            "Show.S01E05.mkv",
            AllDebridFileSelector().selectFile(
                names.map { AllDebridFlatFile(name = it, size = 10, link = "https://ad/$it") },
                resolve(), 1, 5,
            )?.name,
        )
    }

    @Test
    fun `two real files for the same episode stay ambiguous`() {
        val names = listOf("Show.S01E05.720p.mkv", "Show.S01E05.1080p.mkv")
        assertNull(TorboxFileSelector().selectFile(torbox(names), resolve(), 1, 5))
        assertNull(
            AllDebridFileSelector().selectFile(
                names.map { AllDebridFlatFile(name = it, size = 10, link = "https://ad/$it") },
                resolve(), 1, 5,
            ),
        )
    }

    @Test
    fun `a title containing Sampler is not treated as a sample`() {
        val names = listOf("Sampler.S01E05.mkv", "Sampler.S01E05.sample.mkv")
        assertEquals("Sampler.S01E05.mkv", TorboxFileSelector().selectFile(torbox(names), resolve(), 1, 5)?.name)
    }

    @Test
    fun `absolute numbered pack does not resolve through fileIdx`() {
        // Deliberate: a file index cannot be trusted to line up with the provider's file list,
        // so names without the requested SxxEyy / NxM episode return null even with a valid fileIdx.
        val names = listOf(
            "[Group] Show - 04 (1080p).mkv",
            "[Group] Show - 05 (1080p).mkv",
            "[Group] Show - 06 (1080p).mkv",
        )
        assertNull(TorboxFileSelector().selectFile(torbox(names), resolve(1), 1, 5))
        assertNull(RealDebridFileSelector().selectFile(realDebrid(names), resolve(1), 1, 5))
    }
}
