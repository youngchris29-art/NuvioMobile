package com.nuvio.app.features.player

import com.nuvio.app.features.streams.AddonStreamGroup
import com.nuvio.app.features.streams.StreamBadgeFilter
import com.nuvio.app.features.streams.StreamBadgeImport
import com.nuvio.app.features.streams.StreamBadgeMatcher
import com.nuvio.app.features.streams.StreamBadgePresentation
import com.nuvio.app.features.streams.StreamBadgeRules
import com.nuvio.app.features.streams.StreamItem
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
    fun readsCommaSeparatedCodecsStringsWhateverTheOrder() {
        // HLS-style CODECS lists put audio first as often as video.
        val audioFirstDv = text(videoCodecString = "ec-3,dvh1.05.06").split(" ")
        assertTrue("DV" in audioFirstDv && "DoVi" in audioFirstDv, "DV found after an audio entry")
        assertTrue("10bit" in audioFirstDv, "DV profile implies 10-bit")
        assertTrue("Vision" in names(text(videoCodecString = "ec-3, dvh1.05.06")))

        val audioLastMain10 = text(videoCodec = "HEVC", videoCodecString = "hvc1.2.4.L150.B0,ec-3").split(" ")
        assertTrue("10bit" in audioLastMain10)
        val audioFirstMain10 = text(videoCodec = "HEVC", videoCodecString = "ec-3,hvc1.2.4.L150.B0").split(" ")
        assertTrue("10bit" in audioFirstMain10)
        assertTrue("10bit" !in text(videoCodec = "HEVC", videoCodecString = "ec-3,hvc1.1.6.L93.B0").split(" "))
        assertTrue("DV" !in text(videoCodec = "HEVC", videoCodecString = "hvc1.2.4.L150.B0,ec-3").split(" "))

        // The video token comes from the first video entry, never from an audio one.
        val audioFirst = text(videoCodecString = "ec-3,dvh1.05.06")
        assertTrue("HEVC" in audioFirst.split(" "), "audio-first list still yields the HEVC token")
        assertTrue(audioFirst.split(" ").none { it.contains("EC-3", ignoreCase = true) || it.contains(",") }, "no junk token: $audioFirst")
        val audioOnly = text(videoCodecString = "ec-3,mp4a.40.2")
        assertEquals("", audioOnly, "audio-only codecs string adds no video token")
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
            filters = listOf(filter("Stream4K", "(?i)\\b2160p\\b")),
        )
        val playerPack = StreamBadgeImport(
            sourceUrl = "https://example.com/player.json",
            filters = listOf(filter("Player4K", "(?i)\\b2160p\\b")),
        )
        val rules = StreamBadgeRules(imports = listOf(streamPack, playerPack)).normalized()
        val otherRules = StreamBadgeRules(
            imports = listOf(
                StreamBadgeImport(
                    sourceUrl = "https://example.com/other.json",
                    filters = listOf(filter("Other4K", "(?i)\\b2160p\\b")),
                ),
            ),
        ).normalized()
        val playerSource = "https://example.com/player.json"
        val text = text(videoWidth = 3840, videoHeight = 2160)
        val groups = listOf(
            AddonStreamGroup(
                addonName = "Addon",
                addonId = "addon",
                streams = listOf(StreamItem(name = "Movie 2160p", addonName = "Addon", addonId = "addon")),
            ),
        )
        fun listBadges(r: StreamBadgeRules) =
            StreamBadgePresentation.apply(groups, r).single().streams.single().badges.map { it.name }
        fun playerBadges(r: StreamBadgeRules, source: String, matchText: String = text) =
            StreamBadgePresentation.playerBadges(r, source, matchText).map { it.name }

        // The stream list uses the active (first) pack, the player its own: alternate them with
        // different rules and sources so a shared cache slot would be evicted on every call.
        assertEquals(listOf("Stream4K"), listBadges(rules))
        assertEquals(listOf("Stream4K"), playerBadges(rules, ""), "blank source = the stream list's pack")
        assertEquals(listOf("Player4K"), playerBadges(rules, playerSource))
        assertEquals(listOf("Stream4K"), listBadges(rules))
        assertEquals(listOf("Other4K"), listBadges(otherRules))
        assertEquals(listOf("Player4K"), playerBadges(rules, playerSource))
        assertEquals(listOf("Other4K"), listBadges(otherRules))
        assertEquals(listOf("Stream4K"), listBadges(rules))
        assertEquals(listOf("Player4K"), playerBadges(rules, playerSource))
        assertEquals(emptyList(), playerBadges(rules, playerSource, ""))
        assertEquals(emptyList(), playerBadges(StreamBadgeRules(), "", text))
        assertEquals(listOf("Stream4K"), listBadges(rules))
    }

    @Test
    fun playerBadgesDropsFiltersWithoutAnImage() {
        val pack = StreamBadgeImport(
            sourceUrl = "https://example.com/player.json",
            filters = listOf(
                StreamBadgeFilter(name = "NoImage", pattern = "(?i)\\b2160p\\b", imageURL = ""),
                StreamBadgeFilter(name = "Blank", pattern = "(?i)\\b4k\\b", imageURL = "   "),
                filter("WithImage", "(?i)\\b2160p\\b"),
            ),
        )
        val rules = StreamBadgeRules(imports = listOf(pack)).normalized()
        val text = text(videoWidth = 3840, videoHeight = 2160)

        // The matcher itself still returns the image-less badges; only the player drops them.
        val matched = StreamBadgeMatcher.matchedBadges(listOf(text), StreamBadgeMatcher.compile(rules)).map { it.name }
        assertTrue("NoImage" in matched && "Blank" in matched)
        assertEquals(
            listOf("WithImage"),
            StreamBadgePresentation.playerBadges(rules, "https://example.com/player.json", text).map { it.name },
        )
    }

    @Test
    fun matchedBadgesOverloadIgnoresEmptyInput() {
        assertEquals(emptyList(), StreamBadgeMatcher.matchedBadges(emptyList(), filters))
        assertEquals(emptyList(), StreamBadgeMatcher.matchedBadges(listOf("2160p"), emptyList()))
    }
}
