package com.nuvio.app.features.player

import com.nuvio.app.features.streams.StreamBadgeFilter
import com.nuvio.app.features.streams.StreamBadgeImport
import com.nuvio.app.features.streams.StreamBadgeMatcher
import com.nuvio.app.features.streams.StreamBadgePresentation
import com.nuvio.app.features.streams.StreamBadgeRules
import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertTrue

/**
 * Port of upstream `344117e73` + `83e528f00` `PlaybackMatchTextTest`, with `PlayerMediaInfo`
 * replaced by the plain-value [PlaybackMatchText.build] (the fork has no PlayerMediaInfo), plus the
 * NuvioTV `13683564d` codec-detection and file-name cases.
 */
class PlaybackMatchTextTest {
    private val filters = StreamBadgeMatcher.compile(
        StreamBadgeRules(
            imports = listOf(
                StreamBadgeImport(
                    sourceUrl = "https://example.com/badges.json",
                    filters = listOf(
                        filter("4K", "(?i)\\b(2160p|4k)\\b"),
                        filter("WebDL", "(?i)\\bweb[-. ]?dl\\b"),
                        filter("Vision", "(?i)\\b(dv|dovi|dolby[ .]?vision)\\b"),
                        filter("HDR", "(?i)\\bhdr(10)?\\b"),
                        filter("10bit", "(?i)\\b10[ -]?bit\\b"),
                        filter("HEVC", "(?i)\\b(hevc|[xh][ .]?265)\\b"),
                        filter("Atmos", "(?i)\\batmos\\b"),
                        filter("English", "(?i)\\b(eng|english)\\b"),
                    ),
                ),
            ),
        ),
    )

    private fun filter(name: String, pattern: String) =
        StreamBadgeFilter(name = name, pattern = pattern, imageURL = "https://example.com/$name.png")

    private fun text(
        videoWidth: Int? = null,
        videoHeight: Int? = null,
        videoCodec: String? = null,
        videoCodecString: String? = null,
        hdr: List<String> = emptyList(),
        bitDepth: Int? = null,
        audioCodec: String? = null,
        audioProfile: String? = null,
        audioChannels: Int? = null,
        languages: List<String> = emptyList(),
        fileName: String? = null,
        streamName: String? = null,
    ): String = PlaybackMatchText.build(
        videoWidth, videoHeight, videoCodec, videoCodecString, hdr, bitDepth,
        audioCodec, audioProfile, audioChannels, languages, fileName, streamName,
    )

    private fun names(text: String): List<String> =
        StreamBadgeMatcher.matchedBadges(listOf(text), filters).map { it.name }

    @Test
    fun matchesWhatIsPlaying() {
        val text = text(
            videoCodec = "HEVC",
            videoWidth = 3840,
            videoHeight = 1600,
            audioCodec = "E-AC-3-JOC",
            audioChannels = 6,
            hdr = listOf("DV", "HDR10"),
            bitDepth = 10,
            languages = listOf("eng"),
        )
        assertEquals(listOf("4K", "Vision", "HDR", "10bit", "HEVC", "Atmos", "English"), names(text))
    }

    @Test
    fun skipsBadgesThePlaybackDoesNotHave() {
        val text = text(videoCodec = "AVC", videoWidth = 1920, videoHeight = 1080, audioCodec = "AAC", audioChannels = 2)
        assertEquals(emptyList(), names(text))
    }

    @Test
    fun readsAtmosFromMpvAudioProfile() {
        val text = text(audioCodec = "TrueHD", audioProfile = "Dolby TrueHD + Dolby Atmos")
        assertEquals(listOf("Atmos"), names(text))
    }

    @Test
    fun showsNothingBeforePlaybackInfoLoads() {
        val empty = text()
        assertEquals("", empty)
        assertEquals(emptyList(), names(empty))
    }

    @Test
    fun buildsTheDocumentedTokenStringInOrder() {
        val text = text(
            videoWidth = 3840,
            videoHeight = 2160,
            videoCodec = "HEVC",
            hdr = listOf("DV", "HDR10"),
            bitDepth = 10,
            audioCodec = "E-AC-3-JOC",
            audioChannels = 6,
            languages = listOf("eng", "English"),
        )
        assertEquals(
            "2160p 4K UHD HEVC H.265 H265 x265 DV DoVi Dolby Vision HDR HDR10 10bit DD+ DDP EAC3 Atmos 5.1 eng English",
            text,
        )
    }

    @Test
    fun assumesTenBitForHdrWhenDepthIsUnknown() {
        assertTrue("10bit" in text(hdr = listOf("HLG")).split(" "))
        assertTrue("10bit" !in text(videoCodec = "AVC").split(" "))
    }

    @Test
    fun readsTransferNamesAsHdrFlags() {
        assertTrue("HDR10" in text(hdr = listOf("SMPTE ST 2084")).split(" "))
        assertTrue("HDR10" in text(hdr = listOf("pq")).split(" "))
        assertTrue("HLG" in text(hdr = listOf("ARIB STD-B67")).split(" "))
        assertTrue("Dolby Vision" in text(hdr = listOf("Dolby Vision")))
    }

    @Test
    fun normalizesRawEngineCodecNames() {
        val avc = text(videoCodec = "h264", audioCodec = "ac3").split(" ")
        assertTrue("x264" in avc && "AVC" in avc)
        assertTrue("DD" in avc && "AC3" in avc)
        val hevc = text(videoCodec = "hvc1", audioCodec = "eac3_joc").split(" ")
        assertTrue("x265" in hevc && "DDP" in hevc && "Atmos" in hevc)
        assertTrue("AV1" in text(videoCodec = "av01").split(" "))
        assertEquals("AAC", text(audioCodec = "aac"))
    }

    @Test
    fun readsDolbyVisionAndDepthFromTheCodecsString() {
        // Dual-layer DV arrives as an HEVC stream whose codecs string says dvhe (NuvioTV 13683564d).
        val dv = text(videoCodecString = "dvhe.08.06").split(" ")
        assertTrue("HEVC" in dv, "codec comes from the codecs string")
        assertTrue("DV" in dv && "DoVi" in dv)
        assertTrue("10bit" in dv)
        assertTrue("10bit" in text(videoCodec = "HEVC", videoCodecString = "hvc1.2.4.L150.B0").split(" "))
        assertTrue("10bit" !in text(videoCodec = "HEVC", videoCodecString = "hvc1.1.6.L93.B0").split(" "))
        assertTrue("10bit" in text(videoCodecString = "av01.0.13M.10").split(" "))
        assertTrue("Vision" in names(text(videoCodecString = "dvh1.05.06")))
    }

    @Test
    fun readsDtsAndAc4Variants() {
        val ma = text(audioCodec = "DTS", audioProfile = "DTS-HD MA")
        assertEquals("DTS DTS-HD DTS-HD MA", ma)
        assertTrue("DTS:X" in text(audioCodec = "DTS", audioProfile = "DTS:X").split(" "))
        val ac4 = text(audioCodec = "AC-4").split(" ")
        assertTrue("AC-4" in ac4 && "AC4" in ac4)
        assertTrue("DTS-HD" !in text(audioCodec = "DTS", audioProfile = "").split(" "))
    }

    @Test
    fun fileNameFillsInWhatTheEngineCannotDetect() {
        val bare = text(videoCodec = "AVC", videoWidth = 1920, videoHeight = 1080)
        assertEquals(emptyList(), names(bare))
        val withName = text(
            videoCodec = "AVC",
            videoWidth = 1920,
            videoHeight = 1080,
            fileName = "Movie.2023.2160p.WEB-DL.DV.HDR10.Atmos.mkv",
            streamName = "  ",
        )
        assertEquals(listOf("4K", "WebDL", "Vision", "HDR", "Atmos"), names(withName))
        assertTrue(withName.endsWith("Movie.2023.2160p.WEB-DL.DV.HDR10.Atmos.mkv"))
        assertTrue(text(streamName = "Some Stream 4K").contains("Some Stream 4K"))
    }

    @Test
    fun usesThePackChosenForThePlayer() {
        val streamPack = StreamBadgeImport(
            sourceUrl = "https://example.com/stream.json",
            filters = listOf(filter("Stream4K", "⁣​⁣")),
        )
        val playerPack = StreamBadgeImport(
            sourceUrl = "https://example.com/player.json",
            filters = listOf(filter("Player4K", "(?i)\\b2160p\\b")),
        )
        val rules = StreamBadgeRules(imports = listOf(streamPack, playerPack)).normalized()
        val text = text(videoWidth = 3840, videoHeight = 2160)
        fun namesFor(source: String) =
            StreamBadgeMatcher.matchedBadges(listOf(text), StreamBadgeMatcher.compile(rules.forPlayer(source))).map { it.name }

        assertEquals(emptyList(), namesFor(""))
        assertEquals(listOf("Player4K"), namesFor("https://example.com/player.json"))
        assertEquals(emptyList(), namesFor("https://example.com/removed.json"))
    }

    @Test
    fun playerBadgesUsesThePlayerPackWithItsOwnFilterCache() {
        val streamPack = StreamBadgeImport(
            sourceUrl = "https://example.com/stream.json",
            filters = listOf(filter("Stream4K", "⁣​⁣")),
        )
        val playerPack = StreamBadgeImport(
            sourceUrl = "https://example.com/player.json",
            filters = listOf(filter("Player4K", "(?i)\\b2160p\\b")),
        )
        val rules = StreamBadgeRules(imports = listOf(streamPack, playerPack)).normalized()
        val text = text(videoWidth = 3840, videoHeight = 2160)

        assertEquals(emptyList(), StreamBadgePresentation.playerBadges(rules, "", text).map { it.name })
        assertEquals(
            listOf("Player4K"),
            StreamBadgePresentation.playerBadges(rules, "https://example.com/player.json", text).map { it.name },
        )
        assertEquals(emptyList(), StreamBadgePresentation.playerBadges(rules, "https://example.com/player.json", ""))
        assertEquals(emptyList(), StreamBadgePresentation.playerBadges(StreamBadgeRules(), "", text))
    }

    @Test
    fun matchedBadgesOverloadIgnoresEmptyInput() {
        assertEquals(emptyList(), StreamBadgeMatcher.matchedBadges(emptyList(), filters))
        assertEquals(emptyList(), StreamBadgeMatcher.matchedBadges(listOf("2160p"), emptyList()))
    }
}
