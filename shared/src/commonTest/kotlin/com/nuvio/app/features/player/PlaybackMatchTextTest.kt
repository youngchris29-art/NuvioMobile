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
import kotlin.test.assertFalse
import kotlin.test.assertTrue

/**
 * Port of upstream `344117e73` + `83e528f00` + `a744911a` `PlaybackMatchTextTest`, with
 * `PlayerMediaInfo` replaced by the plain-value [PlaybackMatchText.build] (the fork has no
 * PlayerMediaInfo), plus the NuvioTV `13683564d` codec-detection cases and the fork's own cases.
 */
class PlaybackMatchTextTest {
    private val rules = StreamBadgeRules(
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
        ).normalized()
    private val filters = StreamBadgeMatcher.compile(rules)

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
        audioProfiles: List<String> = emptyList(),
        audioChannels: Int? = null,
        languages: List<String> = emptyList(),
    ): String = PlaybackMatchText.build(
        videoWidth, videoHeight, videoCodec, videoCodecString, hdr, bitDepth,
        audioCodec, audioProfiles, audioChannels, languages,
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
        val text = text(audioCodec = "TrueHD", audioProfiles = listOf("Dolby TrueHD + Dolby Atmos"))
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
    fun skipsDtsXMpegHAndPcmEntriesBeforeTheVideoEntry() {
        val dtsxFirst = text(videoCodecString = "dtsx,hvc1.2.4.L150.B0").split(" ")
        assertTrue("HEVC" in dtsxFirst && "x265" in dtsxFirst, "video token from the hvc1 entry: $dtsxFirst")
        assertTrue("10bit" in dtsxFirst)
        assertTrue("DTSX" !in dtsxFirst, "no junk DTSX token: $dtsxFirst")

        val mpegHFirst = text(videoCodecString = "mhm1.0x0D,dvh1.08.06").split(" ")
        assertTrue("HEVC" in mpegHFirst && "DV" in mpegHFirst, "video token from the dvh1 entry: $mpegHFirst")
        assertTrue(mpegHFirst.none { it.startsWith("MHM1") }, "no junk MHM1 token: $mpegHFirst")

        for (audio in listOf("dtsx", "mha1.0x0D", "mhm1.0x0D", "ipcm", "lpcm")) {
            assertEquals("", text(videoCodecString = audio), "$audio alone adds no video token")
            val first = text(videoCodecString = "$audio,avc1.640028").split(" ")
            assertTrue("AVC" in first && "x264" in first, "$audio before avc1: $first")
        }
    }

    @Test
    fun readsDolbyVisionOverAvc() {
        for (codecs in listOf("dvav.04.06", "dva1.04.06")) {
            val tokens = text(videoCodecString = codecs).split(" ")
            assertTrue("AVC" in tokens && "H.264" in tokens && "x264" in tokens, "$codecs maps to AVC: $tokens")
            assertTrue("DV" in tokens && "DoVi" in tokens, "$codecs is Dolby Vision: $tokens")
            assertTrue(tokens.none { it.startsWith("DVA") }, "no junk DVAV/DVA1 token: $tokens")
            assertTrue("HEVC" !in tokens)
            assertTrue(tokens.none { it == "10bit" }, "$codecs is 8-bit, no 10bit token: $tokens")
        }
        assertTrue("10bit" in text(videoCodecString = "hvc1.2.4.L150.B0").split(" "), "hvc1.2 Main 10 stays 10bit")
        val labelled = text(videoCodec = "dva1").split(" ")
        assertTrue("AVC" in labelled && "DV" in labelled && "DVA1" !in labelled, "engine label dva1: $labelled")
        assertTrue("Vision" in names(text(videoCodecString = "ec-3,dvav.04.06")))
    }

    @Test
    fun readsDtsAndAc4Variants() {
        val ma = text(audioCodec = "DTS", audioProfiles = listOf("DTS-HD MA"))
        assertEquals("DTS DTS-HD DTS-HD MA", ma)
        assertTrue("DTS:X" in text(audioCodec = "DTS", audioProfiles = listOf("DTS:X")).split(" "))
        val ac4 = text(audioCodec = "AC-4").split(" ")
        assertTrue("AC-4" in ac4 && "AC4" in ac4)
        assertTrue("DTS-HD" !in text(audioCodec = "DTS", audioProfiles = listOf("")).split(" "))
    }

    @Test
    fun fileNameFillsInWhatTheEngineCannotDetect() {
        // The pack has no groups, so every filter may still match from the file name (phase two).
        val bare = text(videoCodec = "AVC", videoWidth = 1920, videoHeight = 1080)
        assertEquals(emptyList(), names(bare))
        fun playerNames(playback: String, meta: List<String>) =
            StreamBadgePresentation.playerBadges(rules, "", playback, emptyList(), meta).map { it.name }
        assertEquals(
            listOf("4K", "WebDL", "Vision", "HDR", "Atmos"),
            playerNames(bare, listOf("Movie.2023.2160p.WEB-DL.DV.HDR10.Atmos.mkv", "  ")),
        )
        assertTrue("Movie" !in bare, "the file name is never part of the decoder text: $bare")
        // A stream title alone still matches before the engine reports; all blank shows nothing.
        assertEquals(listOf("4K"), playerNames("", listOf("Some Stream\n4K")))
        assertEquals(emptyList(), playerNames(" ", listOf("", "  \n")))
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
            StreamBadgePresentation.playerBadges(r, source, matchText, emptyList(), emptyList()).map { it.name }

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
            StreamBadgePresentation.playerBadges(rules, "https://example.com/player.json", text, emptyList(), emptyList()).map { it.name },
        )
    }

    @Test
    fun matchedBadgesOverloadIgnoresEmptyInput() {
        assertEquals(emptyList(), StreamBadgeMatcher.matchedBadges(emptyList(), filters))
        assertEquals(emptyList(), StreamBadgeMatcher.matchedBadges(listOf("2160p"), emptyList()))
    }

    // Upstream a744911a cases.

    @Test
    fun dtsHdMaNotTriggeredByGermanLabel() {
        // mpv's codec profile plus a track titled German: "GERMAN" contains MA but is not Master Audio.
        val text = text(
            audioCodec = "dts",
            audioProfiles = listOf("DTS-HD HRA", "German"),
            audioChannels = 8,
            languages = listOf("ger", "German"),
        )
        assertFalse(text.contains("DTS-HD MA"), "DTS-HD MA should not appear for German DTS-HD HRA: $text")
        assertTrue(text.contains("DTS-HD"), "DTS-HD should still appear: $text")
    }

    @Test
    fun dtsHdMaAndDtsXBothAppear() {
        val text = text(audioCodec = "DTS", audioProfiles = listOf("DTS-HD MA", "DTS:X"), audioChannels = 8)
        assertTrue(text.contains("DTS-HD MA"), "DTS-HD MA should appear: $text")
        assertTrue(text.contains("DTS:X"), "DTS:X should appear: $text")
    }

    @Test
    fun pcmVariantsMapToPcm() {
        assertEquals("PCM", text(audioCodec = "pcm_s24le"))
        assertEquals("PCM", text(audioCodec = "pcm_bluray"))
    }

    @Test
    fun groupExclusionSkipsFilenameLangWhenDecoderMatches() {
        val langGroup = "Language"
        val sourceGroup = "Source"
        val playerFilters = StreamBadgeMatcher.compile(
            StreamBadgeRules(
                imports = listOf(
                    StreamBadgeImport(
                        sourceUrl = "https://example.com/badges.json",
                        filters = listOf(
                            StreamBadgeFilter(name = "English", pattern = "(?i)\\benglish\\b", imageURL = "eng.png", groupId = langGroup),
                            StreamBadgeFilter(name = "Polish", pattern = "(?i)\\bpol\\b", imageURL = "pol.png", groupId = langGroup),
                            StreamBadgeFilter(name = "WebDL", pattern = "(?i)\\bweb[-.]?dl\\b", imageURL = "webdl.png", groupId = sourceGroup),
                        ),
                    ),
                ),
            ),
        )
        val playback = "DD+ 5.1 English"
        val filename = listOf("Movie.POL.ENG.WebDL.mkv")
        val badges = StreamBadgeMatcher.matchedPlayerBadges(playback, filename, playerFilters).map { it.name }
        assertTrue("English" in badges, "English should appear (decoder match)")
        assertFalse("Polish" in badges, "Polish should NOT appear (group covered by decoder)")
        assertTrue("WebDL" in badges, "WebDL should appear (different group)")
    }

    @Test
    fun refineAddsAtmosFromFilenameWhenDecoderHasEac3() {
        val refined = PlaybackMatchText.refinePlaybackText("DD+ DDP EAC3 5.1", emptyList(), listOf("Movie.2160p.DDP5.1.Atmos.mkv"))
        assertTrue(refined.contains("Atmos"), "Atmos should be added: $refined")
    }

    @Test
    fun refineAddsDtsXFromFilenameWhenDecoderHasDtsHd() {
        val refined = PlaybackMatchText.refinePlaybackText("DTS DTS-HD 7.1", emptyList(), listOf("Movie.2160p.DTS-X.mkv"))
        assertTrue(refined.contains("DTS:X"), "DTS:X should be added: $refined")
    }

    @Test
    fun refineDoesNotAddAtmosWithoutMatchingBaseCodec() {
        val refined = PlaybackMatchText.refinePlaybackText("AAC 2.0", emptyList(), listOf("Movie.Atmos.mkv"))
        assertFalse(refined.contains("Atmos"), "Atmos should NOT be added without EAC3/TrueHD: $refined")
    }

    @Test
    fun orderRestoredToPackFilterOrderWithSharedImageUrl() {
        val filters = StreamBadgeMatcher.compile(
            StreamBadgeRules(
                imports = listOf(
                    StreamBadgeImport(
                        sourceUrl = "https://example.com/badges.json",
                        filters = listOf(
                            StreamBadgeFilter(name = "Remux", pattern = "(?i)\\bremux\\b", imageURL = "remux.png"),
                            StreamBadgeFilter(name = "HEVC", pattern = "(?i)\\bhevc\\b", imageURL = "hevc.png"),
                            StreamBadgeFilter(name = "HEVC-alt", pattern = "(?i)\\bh\\.?265\\b", imageURL = "hevc.png"),
                        ),
                    ),
                ),
            ),
        )
        val badges = StreamBadgeMatcher.matchedPlayerBadges("HEVC 2160p", listOf("Movie.Remux.mkv"), filters)
        assertEquals("Remux", badges[0].name)
        assertEquals("HEVC", badges[1].name)
    }

    // Fork cases.

    @Test
    fun nativeTitleOnlyDtsReadsTheTrackTitleAndRemuxProfile() {
        // The native engine has no codec profile without the remux's: the track title is all it has.
        assertEquals(
            "DTS DTS-HD DTS-HD MA 7.1",
            text(audioCodec = "dts", audioProfiles = listOf("DTS-HD MA 7.1"), audioChannels = 8),
        )
        assertEquals("DTS 7.1", text(audioCodec = "dts", audioProfiles = listOf("Surround 7.1"), audioChannels = 8))
        // FFmpeg's profile name for a DTS:X track, plus a bare title.
        assertEquals(
            "DTS DTS-HD DTS-HD MA DTS:X 7.1",
            text(audioCodec = "dts", audioProfiles = listOf("DTS-HD MA + DTS:X", "English"), audioChannels = 8),
        )
        assertEquals(
            "TrueHD Atmos 7.1",
            text(audioCodec = "truehd", audioProfiles = listOf("Dolby TrueHD + Dolby Atmos"), audioChannels = 8),
        )
    }

    @Test
    fun fileNameHdr10PlusRefinesADecoderPqThroughGroupExclusion() {
        val hdrGroup = "HDR"
        val pack = StreamBadgeImport(
            sourceUrl = "https://example.com/player.json",
            filters = listOf(
                StreamBadgeFilter(name = "HDR10", pattern = "(?i)\\bhdr(10)?\\b", imageURL = "hdr10.png", groupId = hdrGroup),
                StreamBadgeFilter(name = "HDR10+", pattern = "(?i)\\bhdr10\\+", imageURL = "hdr10p.png", groupId = hdrGroup),
            ),
        )
        val rules = StreamBadgeRules(imports = listOf(pack)).normalized()
        val pq = text(videoWidth = 3840, videoHeight = 2160, videoCodec = "HEVC", hdr = listOf("PQ"))
        val meta = listOf("Movie.2160p.HDR10+.HEVC.mkv")
        // Without the refine the decoder's HDR10 covers the group and the file name's HDR10+ is dropped.
        assertEquals(
            listOf("HDR10"),
            StreamBadgeMatcher.matchedPlayerBadges(pq, meta, StreamBadgeMatcher.compile(rules)).map { it.name },
        )
        assertEquals(
            listOf("HDR10", "HDR10+"),
            StreamBadgePresentation.playerBadges(rules, "", pq, emptyList(), meta).map { it.name },
        )
        assertEquals(listOf("HDR10"), StreamBadgePresentation.playerBadges(rules, "", pq, emptyList(), listOf("Movie.HDR.mkv")).map { it.name })
    }

    @Test
    fun atmosphereIsNotAtmos() {
        // Codex r1 P2: a substring match turned `Atmosphere` into an Atmos chip.
        val eac3 = "DD+ DDP EAC3 5.1"
        assertEquals(eac3, PlaybackMatchText.refinePlaybackText(eac3, emptyList(), listOf("Atmosphere.2022.EAC3.mkv", "Atmospheric Horror")))
        assertTrue(PlaybackMatchText.refinePlaybackText(eac3, emptyList(), listOf("Movie.2160p.DDP5.1.Atmos-GRP.mkv")).endsWith(" Atmos"))
        val titled = text(audioCodec = "eac3", audioProfiles = listOf("Atmosphere (Director's Commentary)"), audioChannels = 6)
        assertEquals("DD+ DDP EAC3 5.1", titled)
        assertTrue("Atmos" in text(audioCodec = "eac3", audioProfiles = listOf("Dolby Digital Plus + Dolby Atmos")).split(" "))
    }

    @Test
    fun remasteredDtsTitleIsNotMasterAudio() {
        // Codex r1 P2: `contains("MASTER")` read a remastered core DTS track as DTS-HD Master Audio.
        assertEquals(
            "DTS 5.1",
            text(audioCodec = "dts", audioProfiles = listOf("English DTS 5.1 (Remastered)"), audioChannels = 6),
        )
        for (title in listOf("DTS-HD MA 7.1", "DTSHD MA", "DTS-HD Master Audio 7.1", "English Master Audio")) {
            assertEquals(
                "DTS DTS-HD DTS-HD MA 7.1",
                text(audioCodec = "dts", audioProfiles = listOf(title), audioChannels = 8),
                title,
            )
        }
        val dtsHd = "DTS DTS-HD 7.1"
        assertEquals(dtsHd, PlaybackMatchText.refinePlaybackText(dtsHd, emptyList(), listOf("Movie.1080p.Remastered.DTS-HD.mkv")))
        assertEquals(dtsHd, PlaybackMatchText.refinePlaybackText(dtsHd, emptyList(), listOf("Movie.Remaster.Audio.DTS-HD.mkv")))
        assertTrue(
            PlaybackMatchText.refinePlaybackText(dtsHd, emptyList(), listOf("Movie.DTS-HD.Master.Audio.7.1.mkv")).endsWith(" DTS-HD MA"),
        )
    }

    @Test
    fun refineNeverContradictsTheDtsVariantTheDecoderNamed() {
        // Review r2 P2: a German DTS-HD HRA dub in a release named for its English DTS-HD MA track.
        val meta = listOf("Film.German.DL.2160p.DTS-HD.MA.7.1.DTS-X.mkv")
        val hraProfiles = listOf("DTS-HD HRA", "German")
        val hra = text(audioCodec = "dts", audioProfiles = hraProfiles, audioChannels = 8)
        assertEquals("DTS DTS-HD 7.1", hra)
        assertEquals(hra, PlaybackMatchText.refinePlaybackText(hra, hraProfiles, meta), "no MA, no DTS:X on an HRA track")
        // A title naming the variant counts too; FFmpeg's other DTS profiles block DTS:X.
        assertEquals(hra, PlaybackMatchText.refinePlaybackText(hra, listOf("German DTS-HD HRA 7.1"), meta))
        for (core in listOf("DTS", "DTS-ES", "DTS 96/24", "DTS Express")) {
            val coreText = text(audioCodec = "dts", audioProfiles = listOf(core), audioChannels = 6)
            assertEquals(coreText, PlaybackMatchText.refinePlaybackText(coreText, listOf(core), meta), core)
        }
        val maProfiles = listOf("DTS-HD MA")
        val ma = text(audioCodec = "dts", audioProfiles = maProfiles, audioChannels = 8)
        assertEquals(ma, PlaybackMatchText.refinePlaybackText(ma, maProfiles, meta), "an MA track without X gets no DTS:X")
        // Profiles that name no variant (a bare title, nothing at all) leave the refine to the file name.
        assertEquals(
            "$hra DTS-HD MA DTS:X",
            PlaybackMatchText.refinePlaybackText(hra, listOf("German"), meta),
        )
        assertEquals("$hra DTS-HD MA DTS:X", PlaybackMatchText.refinePlaybackText(hra, emptyList(), meta))
    }

    @Test
    fun atmosInATitleOnlyCountsForCodecsThatCarryIt() {
        // Review r2 P3: mpv passes the track title as a profile.
        assertEquals("AAC 2.0", text(audioCodec = "aac", audioProfiles = listOf("AAC 2.0 Atmos downmix"), audioChannels = 2))
        assertEquals(
            "DD AC3 5.1",
            text(audioCodec = "ac3", audioProfiles = listOf("AC3 5.1 (from TrueHD Atmos)"), audioChannels = 6),
        )
        assertTrue("Atmos" !in text(audioCodec = "dts", audioProfiles = listOf("DTS 5.1 (Atmos core)")).split(" "))
        assertTrue("Atmos" in text(audioCodec = "eac3", audioProfiles = listOf("English Atmos")).split(" "))
        assertTrue("Atmos" in text(audioCodec = "truehd", audioProfiles = listOf("Dolby TrueHD + Dolby Atmos")).split(" "))
        assertTrue("Atmos" in text(audioCodec = "ac4", audioProfiles = listOf("AC-4 Atmos")).split(" "))
    }

    @Test
    fun pcmS24leGetsThePcmLabelNotTheRawName() {
        val text = text(audioCodec = "pcm_s24le", audioChannels = 6)
        assertEquals("PCM 5.1", text)
        val pack = StreamBadgeImport(
            sourceUrl = "https://example.com/player.json",
            filters = listOf(filter("PCM", "(?i)\\b(l?pcm)\\b")),
        )
        val rules = StreamBadgeRules(imports = listOf(pack)).normalized()
        assertEquals(listOf("PCM"), StreamBadgePresentation.playerBadges(rules, "", text, emptyList(), emptyList()).map { it.name })
    }
}
