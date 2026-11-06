package com.nuvio.app.features.streams

import com.nuvio.app.features.streams.TitleFormatBadge.DOLBY_ATMOS
import com.nuvio.app.features.streams.TitleFormatBadge.DOLBY_VISION
import com.nuvio.app.features.streams.TitleFormatBadge.DTS_X
import com.nuvio.app.features.streams.TitleFormatBadge.HDR
import com.nuvio.app.features.streams.TitleFormatBadge.HDR10_PLUS
import com.nuvio.app.features.streams.TitleFormatBadge.UHD_4K
import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertFalse
import kotlin.test.assertTrue

/**
 * Detail format badges: [TitleFormatBadges.aggregateStreams] over streams shaped like what add-ons
 * send (name / title / description / filename), plus [TitleFormatBadges.merge] and
 * [TitleFormatBadges.isComplete].
 */
class TitleFormatBadgesTest {

    private fun stream(
        name: String? = null,
        title: String? = null,
        description: String? = null,
        filename: String? = null,
    ) = StreamItem(
        name = name,
        title = title,
        description = description,
        url = "https://example.com/stream.mkv",
        addonName = "Fixture",
        addonId = "addon:fixture",
        behaviorHints = StreamBehaviorHints(filename = filename),
    )

    private fun badges(vararg streams: StreamItem) = TitleFormatBadges.aggregateStreams(streams.toList())

    // --- resolution -------------------------------------------------------------------------

    @Test
    fun resolution2160pLightsFourK() {
        assertEquals(listOf(UHD_4K), badges(stream(name = "Movie.2024.2160p.WEB-DL.x265-GRP")))
    }

    @Test
    fun resolution1080pLightsNothing() {
        assertEquals(emptyList(), badges(stream(name = "Movie.2024.1080p.WEB-DL.x264-GRP")))
    }

    @Test
    fun aiUpscaled2160pDoesNotLightFourKButItsAtmosCounts() {
        val upscaled = stream(name = "Movie.2024.2160p.AI.Upscaled.WEB-DL.DDP5.1.Atmos.HDR.x265-GRP")
        assertEquals(listOf(DOLBY_ATMOS), badges(upscaled))
    }

    @Test
    fun camSourceIsIgnoredEvenAt2160pWithAtmos() {
        assertEquals(emptyList(), badges(stream(name = "Movie.2024.2160p.CAM.Atmos.HDR-GRP")))
    }

    // --- dynamic range ----------------------------------------------------------------------

    @Test
    fun dolbyVisionBeatsHdr10PlusBeatsHdr() {
        val dv = stream(name = "Movie.2024.1080p.WEB-DL.DV.HDR10Plus-GRP")
        val hdr10Plus = stream(name = "Movie.2024.1080p.WEB-DL.HDR10Plus-GRP")
        val hdr = stream(name = "Movie.2024.1080p.WEB-DL.HDR-GRP")

        assertEquals(listOf(DOLBY_VISION), badges(hdr, hdr10Plus, dv))
        assertEquals(listOf(HDR10_PLUS), badges(hdr, hdr10Plus))
        assertEquals(listOf(HDR), badges(hdr))
    }

    @Test
    fun hlgMapsToHdr() {
        assertEquals(listOf(HDR), badges(stream(name = "Movie.2024.1080p.WEB-DL.HLG-GRP")))
    }

    @Test
    fun dvHdr10CountsAsDolbyVisionOnly() {
        assertEquals(
            listOf(DOLBY_VISION),
            badges(stream(name = "Movie 2024 1080p WEB-DL DV HDR10")),
        )
    }

    @Test
    fun dvdripIsNotDolbyVision() {
        assertEquals(emptyList(), badges(stream(name = "Movie.2018.DVDRip.XviD-GRP")))
    }

    @Test
    fun hdripIsNotHdr() {
        assertEquals(emptyList(), badges(stream(name = "Movie.2018.1080p.HDRip.x264-GRP")))
    }

    // --- audio ------------------------------------------------------------------------------

    @Test
    fun atmosAndDtsXBothShow() {
        assertEquals(
            listOf(DOLBY_ATMOS, DTS_X),
            badges(
                stream(name = "Movie.2024.1080p.BluRay.TrueHD.Atmos.7.1-GRP"),
                stream(name = "Movie.2024.1080p.BluRay.DTS:X.7.1-GRP"),
            ),
        )
    }

    @Test
    fun dtsHdMasterAudioAloneLightsNothing() {
        assertEquals(emptyList(), badges(stream(name = "Movie 2024 1080p BluRay DTS-HD MA 5.1-GRP")))
    }

    @Test
    fun ddpWithAtmosLightsAtmos() {
        assertEquals(listOf(DOLBY_ATMOS), badges(stream(name = "Movie 2024 1080p WEB-DL DDP5.1 Atmos")))
    }

    // --- aggregate behaviour ----------------------------------------------------------------

    @Test
    fun emptyInputGivesEmptyOutput() {
        assertEquals(emptyList(), TitleFormatBadges.aggregateStreams(emptyList()))
    }

    @Test
    fun outputOrderIsStableWhateverTheInputOrder() {
        val fourK = stream(name = "Movie.2024.2160p.WEB-DL-GRP")
        val dv = stream(name = "Movie.2024.1080p.WEB-DL.DV-GRP")
        val atmos = stream(name = "Movie.2024.1080p.WEB-DL.Atmos-GRP")
        val dtsX = stream(name = "Movie.2024.1080p.WEB-DL.DTS:X-GRP")
        val expected = listOf(UHD_4K, DOLBY_VISION, DOLBY_ATMOS, DTS_X)

        assertEquals(expected, badges(fourK, dv, atmos, dtsX))
        assertEquals(expected, badges(dtsX, atmos, dv, fourK))
        assertEquals(expected, badges(atmos, fourK, dtsX, dv))
    }

    @Test
    fun atMostFourBadgesEvenWhenEveryFormatIsPresent() {
        val everything = listOf(
            stream(name = "Movie.2024.2160p.UHD.BluRay.REMUX.DV.HDR10Plus.HDR.HLG.TrueHD.Atmos.DTS:X.7.1-GRP"),
            stream(name = "Movie.2024.2160p.WEB-DL.HDR10Plus-GRP"),
            stream(name = "Movie.2024.1080p.WEB-DL.HDR-GRP"),
        )
        val result = TitleFormatBadges.aggregateStreams(everything)
        assertEquals(listOf(UHD_4K, DOLBY_VISION, DOLBY_ATMOS, DTS_X), result)
        assertTrue(result.size <= 4)
    }

    @Test
    fun formatsAreReadFromTitleDescriptionAndFilenameToo() {
        assertEquals(listOf(UHD_4K), badges(stream(title = "Movie 2024 2160p")))
        assertEquals(listOf(DOLBY_ATMOS), badges(stream(description = "TrueHD Atmos 7.1")))
        assertEquals(listOf(DOLBY_VISION), badges(stream(filename = "Movie.2024.1080p.WEB-DL.DV.mkv")))
    }

    // --- real add-on shapes -----------------------------------------------------------------

    @Test
    fun torrentioShape() {
        val torrentio = stream(
            name = "Torrentio\n4k DV | HDR",
            title = "Dune.Part.Two.2024.2160p.WEB-DL.DDP5.1.Atmos.DV.HDR.H265-FLUX\n👤 187 💾 18.4 GB ⚙️ ThePirateBay",
            filename = "Dune.Part.Two.2024.2160p.WEB-DL.DDP5.1.Atmos.DV.HDR.H265-FLUX.mkv",
        )
        assertEquals(listOf(UHD_4K, DOLBY_VISION, DOLBY_ATMOS), badges(torrentio))
    }

    @Test
    fun torrentioShapeWithoutFormatsLightsNothing() {
        val torrentio = stream(
            name = "Torrentio\n1080p",
            title = "Lizzie.Borden.Took.an.Ax.2014.1080p.WEBRip.x264-RARBG\n👤 3 💾 1.66 GB ⚙️ RARBG",
        )
        assertEquals(emptyList(), badges(torrentio))
    }

    @Test
    fun aioStreamsShape() {
        val aio = stream(
            name = "[TB+] AIOStreams 4K",
            description = "🎬 Dune: Part Two\n📺 BluRay REMUX 🎞️ HEVC HDR10Plus 🎧 TrueHD Atmos 🔊 7.1\n📦 52.1 GB 🌐 English",
        )
        assertEquals(listOf(UHD_4K, HDR10_PLUS, DOLBY_ATMOS), badges(aio))
    }

    @Test
    fun mediaFusionShape() {
        val mediaFusion = stream(
            name = "MediaFusion 4k 🗲 Torbox",
            description = "📂 Dune.Part.Two.2024.2160p.UHD.BluRay.REMUX.DV.HDR10.TrueHD.Atmos.7.1-FraMeSToR\n" +
                "💿 UHD BluRay REMUX | 🎞 HEVC | 🔊 TrueHD Atmos 7.1 | 🌐 English",
        )
        assertEquals(listOf(UHD_4K, DOLBY_VISION, DOLBY_ATMOS), badges(mediaFusion))
    }

    // --- merge / isComplete -----------------------------------------------------------------

    @Test
    fun mergeIsAUnionInDisplayOrderKeepingTheHighestDynamicRange() {
        assertEquals(
            listOf(DOLBY_VISION, DOLBY_ATMOS),
            TitleFormatBadges.merge(listOf(HDR, DOLBY_ATMOS), listOf(DOLBY_VISION)),
        )
        assertEquals(
            listOf(UHD_4K, HDR10_PLUS, DTS_X),
            TitleFormatBadges.merge(listOf(DTS_X, HDR), listOf(HDR10_PLUS, UHD_4K)),
        )
        assertEquals(listOf(HDR), TitleFormatBadges.merge(emptyList(), listOf(HDR)))
        assertEquals(emptyList(), TitleFormatBadges.merge(emptyList(), emptyList()))
    }

    @Test
    fun isCompleteNeedsFourKDolbyVisionAtmosAndDtsX() {
        assertTrue(TitleFormatBadges.isComplete(listOf(UHD_4K, DOLBY_VISION, DOLBY_ATMOS, DTS_X)))
        assertFalse(TitleFormatBadges.isComplete(listOf(UHD_4K, HDR10_PLUS, DOLBY_ATMOS, DTS_X)))
        assertFalse(TitleFormatBadges.isComplete(listOf(UHD_4K, DOLBY_VISION, DOLBY_ATMOS)))
        assertFalse(TitleFormatBadges.isComplete(emptyList()))
    }
}
