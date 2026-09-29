package com.nuvio.app.features.debrid

import com.nuvio.app.features.streams.StreamClientResolve
import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertNull
import kotlin.test.assertTrue

/** Fork-only: fileIdx fallback for absolute-numbered packs and sample-clip disambiguation. */
class DebridFileSelectorForkFallbackTest {
    private val animeNames = listOf(
        "[Group] Show - 04 (1080p).mkv",
        "[Group] Show - 05 (1080p).mkv",
        "[Group] Show - 06 (1080p).mkv",
        "Readme.txt",
    )

    private fun torbox(names: List<String>) =
        names.mapIndexed { i, n -> TorboxTorrentFileDto(id = 100 + i, name = n, size = 100L + i) }

    private fun realDebrid(names: List<String>) =
        names.mapIndexed { i, n -> RealDebridTorrentFileDto(id = 100 + i, path = "/$n", bytes = 100L + i) }

    private fun resolve(fileIdx: Int? = null) = StreamClientResolve(fileIdx = fileIdx)

    @Test
    fun `absolute numbered pack uses fileIdx when no episode name matches`() {
        assertEquals(101, TorboxFileSelector().selectFile(torbox(animeNames), resolve(1), 1, 5)?.id)
        assertEquals(101, RealDebridFileSelector().selectFile(realDebrid(animeNames), resolve(1), 1, 5)?.id)
    }

    @Test
    fun `absolute numbered pack with fileIdx on a non video file returns null`() {
        assertNull(TorboxFileSelector().selectFile(torbox(animeNames), resolve(3), 1, 5))
        assertNull(RealDebridFileSelector().selectFile(realDebrid(animeNames), resolve(3), 1, 5))
    }

    @Test
    fun `absolute numbered pack without fileIdx does not guess`() {
        assertNull(TorboxFileSelector().selectFile(torbox(animeNames), resolve(), 1, 5))
        assertNull(RealDebridFileSelector().selectFile(realDebrid(animeNames), resolve(), 1, 5))
    }

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
    fun `fileIdx pointing at another episode returns null`() {
        assertNull(TorboxFileSelector().selectFile(torbox(animeNames), resolve(0), 1, 5))
        assertNull(RealDebridFileSelector().selectFile(realDebrid(animeNames), resolve(2), 1, 5))
    }

    @Test
    fun `fileIdx with crc block and resolution selects the requested episode`() {
        val names = listOf("[Group] Show - 04 (1080p) [A1B2C3D4].mkv", "[Group] Show - 05 (1080p) [A1B2C3D4].mkv")
        assertEquals(101, TorboxFileSelector().selectFile(torbox(names), resolve(1), 1, 5)?.id)
    }

    @Test
    fun `numbers that are not episodes never satisfy the fileIdx fallback`() {
        val names = listOf("Show - 07 (1080p) 10bit.mkv", "Show 2019 x265 1080p 5.1.mkv")
        assertNull(TorboxFileSelector().selectFile(torbox(names), resolve(0), 1, 10))
        assertNull(TorboxFileSelector().selectFile(torbox(names), resolve(1), 1, 1))
        assertNull(TorboxFileSelector().selectFile(torbox(names), resolve(1), 1, 265))
        assertNull(TorboxFileSelector().selectFile(torbox(names), resolve(1), 1, 2019))
    }

    @Test
    fun `reordered absolute numbered pack never returns a different episode`() {
        for (names in listOf(animeNames, animeNames.reversed())) {
            for (idx in 0..3) {
                val selected = TorboxFileSelector().selectFile(torbox(names), resolve(idx), 1, 5)
                assertTrue(selected == null || selected.name?.contains(" - 05 ") == true, "idx=$idx -> ${selected?.name}")
                val rd = RealDebridFileSelector().selectFile(realDebrid(names), resolve(idx), 1, 5)
                assertTrue(rd == null || rd.path?.contains(" - 05 ") == true, "idx=$idx -> ${rd?.path}")
            }
        }
    }
}
