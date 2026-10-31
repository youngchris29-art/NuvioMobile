package com.nuvio.app.features.player

/**
 * Builds the text the player's badge filters are matched against, from what the player reports
 * about the media that is playing (upstream `344117e73` "show badges for what is playing"; codec
 * detection from NuvioTV `13683564d`; every audio profile checked and the decoder text refined from
 * the file name, upstream `a744911a`).
 *
 * Pure and platform-free: it takes plain values, so an AVPlayer, an mpv or an ExoPlayer front end
 * can all call it. The result is one string of space-separated tokens, for example
 * `"2160p 4K UHD HEVC H.265 H265 x265 DV DoVi Dolby Vision HDR HDR10 10bit DD+ DDP EAC3 Atmos 5.1 eng"`,
 * to be passed as the playback candidate to `StreamBadgePresentation.playerBadges`, which refines it
 * ([refinePlaybackText]) and matches it in two phases against the file name and stream title
 * (`StreamBadgeMatcher.matchedPlayerBadges`). The file name is never part of this text, so the
 * refine step only ever reads it on the meta side.
 *
 * Swift: `PlaybackMatchText.shared.build(...)`. Kotlin default arguments do not bridge, so a Swift
 * caller passes every argument (`nil` for the unknown ones).
 */
object PlaybackMatchText {

    /**
     * @param videoWidth decoded video width in pixels, or null while unknown.
     * @param videoHeight decoded video height in pixels, or null while unknown.
     * @param videoCodec codec name as the engine reports it: `HEVC`, `AVC`, `h264`, `hvc1`, `AV1`...
     *   Falls back to [videoCodecString] when null or blank.
     * @param videoCodecString RFC 6381 codecs string (`dvh1.08.06`, `hvc1.2.4.L150.B0`, `av01.0.13M.10`),
     *   used for Dolby Vision, 10-bit and codec detection when the engine's own flags miss them.
     * @param hdr HDR flags. Accepts `DV`, `HDR10`, `HLG` and the usual spellings of the same things
     *   (`Dolby Vision`, `PQ`, `SMPTE ST 2084`, `HDR10+`, `ARIB STD-B67`), case-insensitive. Pass the
     *   transfer function name here when that is all the engine exposes.
     * @param bitDepth luma bit depth when known; 10 is assumed for HDR/DV media when null.
     * @param audioCodec audio codec as reported: `E-AC-3`, `eac3`, `AC-3`, `DTS`, `TrueHD`, `AAC`...
     *   `E-AC-3-JOC` is read as Dolby Atmos.
     * @param audioProfiles audio profiles and labels of the playing track, every one checked: the
     *   engine's codec profile (`Dolby TrueHD + Dolby Atmos`, `DTS-HD MA + DTS:X`) and the track title.
     * @param audioChannels channel count of the playing audio track.
     * @param languages language tokens for the playing audio track (code and/or name).
     */
    fun build(
        videoWidth: Int?,
        videoHeight: Int?,
        videoCodec: String?,
        videoCodecString: String?,
        hdr: List<String>,
        bitDepth: Int?,
        audioCodec: String?,
        audioProfiles: List<String>,
        audioChannels: Int?,
        languages: List<String>,
    ): String {
        val codecString = videoCodecString?.trim()?.lowercase().orEmpty()
        val hdrFlags = hdrFlags(hdr, codecString, videoCodec)
        val tokens = buildList {
            addAll(resolutionTokens(videoWidth, videoHeight))
            addAll(videoCodecTokens(videoCodec, codecString))
            if (hdrFlags.dolbyVision) addAll(listOf("DV", "DoVi", "Dolby Vision"))
            if (hdrFlags.hdr10) addAll(listOf("HDR", "HDR10"))
            if (hdrFlags.hlg) addAll(listOf("HDR", "HLG"))
            val hasHdr = hdrFlags.dolbyVision || hdrFlags.hdr10 || hdrFlags.hlg
            (bitDepth?.takeIf { it > 0 } ?: bitDepthFromCodecString(codecString) ?: 10.takeIf { hasHdr && !hdrFlags.dolbyVisionOverAvcOnly })
                ?.let { add("${it}bit") }
            addAll(audioTokens(normalizedAudioCodec(audioCodec), audioProfiles))
            channelsToken(audioChannels)?.let(::add)
            languages.mapNotNull { it.trim().takeIf(String::isNotEmpty) }.let(::addAll)
        }.distinct()
        return tokens.joinToString(" ")
    }

    // Every refine token is delimited: `Atmosphere` is not Atmos, `Remaster Audio` is not Master Audio.
    private val refineAtmos = Regex("""\batmos\b""", RegexOption.IGNORE_CASE)
    private val refineDtsHdMa = Regex("""dts-?hd[ ._-]?ma\b|\bmaster[ ._-]?audio\b""", RegexOption.IGNORE_CASE)
    private val refineDtsX = Regex("""\bdts[ ._:-]?x\b""", RegexOption.IGNORE_CASE)
    private val refineHdr10Plus = Regex("""\bhdr10\+""", RegexOption.IGNORE_CASE)

    /** FFmpeg's DTS profile names, whole (`avcodec_profile_name`, mpv's `codec-profile`). */
    private val ffmpegDtsProfile = Regex("""^DTS(-ES| 96/24|-HD HRA|-HD MA( \+ DTS:X( IMAX)?)?| EXPRESS)?$""")

    /** A DTS variant named inside a longer label, such as a track title (`German DTS-HD HRA 7.1`). */
    private val namedDtsVariant = Regex("""\bHRA\b|\bDTS-ES\b|\b96/24\b|\bEXPRESS\b""")

    /**
     * Whether [audioProfiles] name the exact DTS variant: an FFmpeg profile name, or a title naming a
     * variant that is neither MA nor DTS:X. Then the decoder text already says everything it has,
     * and a release name's MA or DTS:X belongs to another track of the file.
     */
    private fun knowsDtsVariant(audioProfiles: List<String>): Boolean = audioProfiles.any { profile ->
        val label = profile.trim().uppercase()
        ffmpegDtsProfile.matches(label) || namedDtsVariant.containsMatchIn(label)
    }

    /**
     * [decoderText] (from [build]) with the details a decoder cannot report but the file name or
     * stream title ([metadata]) confirms: Atmos, DTS-HD MA, DTS:X, HDR10+ (upstream `a744911a`). Each
     * one is added only when the decoder already confirms its base format, so a file named Atmos
     * playing AAC stays AAC: Atmos needs E-AC-3 or TrueHD, DTS-HD MA needs DTS-HD, DTS:X needs DTS,
     * HDR10+ needs HDR10. Runs before the two-phase match so these tokens count as playback hits.
     *
     * [audioProfiles] are the ones passed to [build]. When they name the exact DTS variant (FFmpeg's
     * `DTS-HD HRA`, `DTS-HD MA`, `DTS`, `DTS-ES`…), the DTS-HD MA and DTS:X refines are skipped: the
     * decoder has spoken, and a release name listing `DTS-HD.MA` describes another track (a German
     * HRA dub in a file whose English track is MA). Atmos has no such check: FFmpeg names a profile
     * for E-AC-3 and TrueHD only when it detects Atmos, so a profile never says "no Atmos".
     */
    fun refinePlaybackText(decoderText: String, audioProfiles: List<String>, metadata: List<String>): String {
        if (decoderText.isBlank() || metadata.isEmpty()) return decoderText
        val dtsVariantKnown = knowsDtsVariant(audioProfiles)
        val joined = metadata.joinToString(" ")
        val extra = mutableListOf<String>()
        val hasEac3OrTrueHd = decoderText.contains("DD+") || decoderText.contains("DDP") ||
            decoderText.contains("EAC3") || decoderText.contains("TrueHD")
        if (hasEac3OrTrueHd && !decoderText.contains("Atmos") && refineAtmos.containsMatchIn(joined)) {
            extra += "Atmos"
        }
        if (decoderText.contains("DTS-HD") && !decoderText.contains("DTS-HD MA") && !dtsVariantKnown &&
            refineDtsHdMa.containsMatchIn(joined)
        ) {
            extra += "DTS-HD MA"
        }
        if (decoderText.contains("DTS") && !decoderText.contains("DTS:X") && !dtsVariantKnown &&
            refineDtsX.containsMatchIn(joined)
        ) {
            extra += "DTS:X"
        }
        if (decoderText.contains("HDR10") && !decoderText.contains("HDR10+") &&
            refineHdr10Plus.containsMatchIn(joined)
        ) {
            extra += "HDR10+"
        }
        if (extra.isEmpty()) return decoderText
        return "$decoderText ${extra.joinToString(" ")}"
    }

    /**
     * [dolbyVisionOverAvcOnly] is true when the only HDR signal is a `dvav`/`dva1` entry (Dolby Vision
     * over AVC, profile 9, 8-bit): no hdr list entry, no HEVC/AV1 Dolby Vision entry, no HDR10/HLG.
     */
    private data class HdrFlags(
        val dolbyVision: Boolean,
        val hdr10: Boolean,
        val hlg: Boolean,
        val dolbyVisionOverAvcOnly: Boolean,
    )

    /** HEVC (`dvhe`/`dvh1`), AV1 (`dav1`) and AVC (`dvav`/`dva1`) Dolby Vision sample entries. */
    private val dolbyVisionCodecPrefixes = listOf("dvhe", "dvh1", "dav1", "dvav", "dva1")

    /** The AVC Dolby Vision sample entries, whose base layer is 8-bit. */
    private val dolbyVisionAvcPrefixes = listOf("dvav", "dva1")

    private fun hdrFlags(hdr: List<String>, codecString: String, videoCodec: String?): HdrFlags {
        val flags = hdr.map { it.trim().lowercase() }
        val label = videoCodec?.trim()?.lowercase()
        // Dual-layer Dolby Vision carries an HEVC/AV1 mime type, so the codecs string is the tell
        // (NuvioTV 13683564d).
        val dvEntries = (codecEntries(codecString) + listOfNotNull(label))
            .filter { entry -> dolbyVisionCodecPrefixes.any(entry::startsWith) }
        val dvFromLabel = label == "dolby vision"
        val dvFromHdrList = flags.any { it == "dv" || it == "dovi" || it.contains("dolby vision") }
        val hdr10 = flags.any {
            it.startsWith("hdr10") || it == "hdr" || it == "pq" || it.contains("2084")
        }
        val hlg = flags.any { it == "hlg" || it.contains("b67") }
        return HdrFlags(
            dolbyVision = dvEntries.isNotEmpty() || dvFromLabel || dvFromHdrList,
            hdr10 = hdr10,
            hlg = hlg,
            dolbyVisionOverAvcOnly = dvEntries.isNotEmpty() &&
                dvEntries.all { entry -> dolbyVisionAvcPrefixes.any(entry::startsWith) } &&
                !dvFromLabel && !dvFromHdrList && !hdr10 && !hlg,
        )
    }

    private fun resolutionTokens(width: Int?, height: Int?): List<String> {
        if (width == null || height == null) return emptyList()
        return when {
            width >= 3800 || height >= 2100 -> listOf("2160p", "4K", "UHD")
            width >= 2500 || height >= 1400 -> listOf("1440p", "2K")
            width >= 1900 || height >= 1000 -> listOf("1080p", "FHD")
            width >= 1260 || height >= 700 -> listOf("720p")
            else -> listOf("${height}p", "SD")
        }
    }

    private val hevcTokens = listOf("HEVC", "H.265", "H265", "x265")
    private val avcTokens = listOf("AVC", "H.264", "H264", "x264")

    private fun videoCodecTokens(codec: String?, codecString: String): List<String> {
        val label = codec?.trim()?.takeIf { it.isNotEmpty() }
        val key = (label ?: firstVideoCodecEntry(codecString)?.substringBefore('.').orEmpty()).lowercase()
        return when {
            key.isEmpty() -> emptyList()
            key == "hevc" || key == "h265" || key == "h.265" || key == "dolby vision" ||
                key.startsWith("hvc1") || key.startsWith("hev1") ||
                key.startsWith("dvh1") || key.startsWith("dvhe") -> hevcTokens
            key == "avc" || key == "h264" || key == "h.264" ||
                key.startsWith("avc1") || key.startsWith("avc3") ||
                key.startsWith("dvav") || key.startsWith("dva1") -> avcTokens
            key == "av1" || key.startsWith("av01") || key.startsWith("dav1") -> listOf("AV1")
            key == "vp9" || key.startsWith("vp09") -> listOf("VP9")
            else -> listOf(label ?: key.uppercase())
        }
    }

    /**
     * HEVC Main 10 (profile 2), Dolby Vision profiles and AV1's explicit depth field are 10-bit
     * (NuvioTV 13683564d). Returns null when the string says nothing.
     */
    private fun bitDepthFromCodecString(codecString: String): Int? =
        codecEntries(codecString).firstNotNullOfOrNull { entry ->
            when {
                entry.startsWith("hev1.2.") || entry.startsWith("hvc1.2.") -> 10
                entry.startsWith("dvhe") || entry.startsWith("dvh1") -> 10
                entry.startsWith("av01.") ->
                    entry.split('.').getOrNull(3)?.toIntOrNull()?.takeIf { it > 0 }
                else -> null
            }
        }

    /**
     * Sample-entry prefixes of audio codecs, so an audio-first codecs list never yields a video token:
     * Dolby (`ec-3`, `ac-3`, `ac-4`), AAC (`mp4a`), DTS (`dtsc`/`dtse`/`dtsh`/`dtsl`, DTS:X / DTS-UHD
     * `dtsx`), MPEG-H (`mha1`, `mhm1`), PCM (`ipcm`, `lpcm`) and the open codecs.
     */
    private val audioCodecPrefixes = listOf(
        "ec-3", "ac-3", "ac-4", "mp4a", "dtsc", "dtse", "dtsh", "dtsl", "dtsx", "mha1", "mhm1", "ipcm", "lpcm",
        "opus", "flac", "alac", "mp3", "vorbis",
    )

    /** The first non-audio entry of the codecs list, or null when it only names audio. */
    private fun firstVideoCodecEntry(codecString: String): String? =
        codecEntries(codecString).firstOrNull { entry -> audioCodecPrefixes.none(entry::startsWith) }

    /** An HLS-style CODECS attribute is a comma list ("ec-3,dvh1.05.06"); audio may come first. */
    private fun codecEntries(codecString: String): List<String> =
        codecString.split(',').map { it.trim() }.filter { it.isNotEmpty() }

    private fun normalizedAudioCodec(codec: String?): String? {
        val trimmed = codec?.trim()?.takeIf { it.isNotEmpty() } ?: return null
        return when (trimmed.lowercase().replace('_', '-')) {
            "ac3", "ac-3" -> "AC-3"
            "eac3", "ec3", "ec-3", "e-ac-3" -> "E-AC-3"
            "eac3-joc", "ec3-joc", "ec-3-joc", "e-ac-3-joc" -> "E-AC-3-JOC"
            "ac4", "ac-4" -> "AC-4"
            "truehd" -> "TrueHD"
            "dca" -> "DTS"
            "aac" -> "AAC"
            "mp3" -> "MP3"
            "flac" -> "FLAC"
            "alac" -> "ALAC"
            "opus" -> "Opus"
            "vorbis" -> "Vorbis"
            else -> when {
                // FFmpeg names every PCM layout (`pcm_s24le`, `pcm_f32be`, `pcm_bluray`).
                trimmed.lowercase().startsWith("pcm") -> "PCM"
                else -> trimmed
            }
        }
    }

    // Profiles include the track title (mpv, native), so every token is matched as a word: a track
    // titled `German` is not `MA` (fork review r2/r3; upstream's `contains("MA")` has that bug), one
    // titled `DTS 5.1 (Remastered)` is not Master Audio, one titled `Atmosphere` is not Atmos.
    private val dtsMasterAudio = Regex("\\bMA\\b|\\bMASTER[ ._-]?AUDIO\\b")
    private val dtsX = Regex("\\bDTS:?X\\b")
    private val atmosProfile = Regex("\\bATMOS\\b|\\bJOC\\b")

    private fun audioTokens(codec: String?, profiles: List<String>): List<String> {
        val label = codec?.uppercase() ?: return emptyList()
        val profileLabels = profiles.map { it.uppercase() }
        fun anyProfile(test: (String) -> Boolean) = profileLabels.any(test)
        return buildList {
            when {
                label.startsWith("E-AC-3") -> addAll(listOf("DD+", "DDP", "EAC3"))
                label == "AC-3" -> addAll(listOf("DD", "AC3"))
                label == "AC-4" -> addAll(listOf("AC-4", "AC4"))
                label.startsWith("DTS") -> {
                    val master = anyProfile { dtsMasterAudio.containsMatchIn(it) }
                    add("DTS")
                    if (label.contains("HD") || master || anyProfile { it.contains("DTS-HD") || it.contains("DTSHD") }) {
                        add("DTS-HD")
                    }
                    if (master) add("DTS-HD MA")
                    if (anyProfile { dtsX.containsMatchIn(it) }) add("DTS:X")
                }
                else -> add(codec)
            }
            // Only the Dolby codecs that carry Atmos read it from a profile: an AAC or AC-3 track
            // titled `AAC 2.0 Atmos downmix` is not Atmos.
            val carriesAtmos = label.startsWith("E-AC-3") || label == "TRUEHD" || label == "AC-4"
            if (label.endsWith("JOC") || carriesAtmos && anyProfile { atmosProfile.containsMatchIn(it) }) add("Atmos")
        }
    }

    private fun channelsToken(channels: Int?): String? = when (channels) {
        1 -> "1.0"
        2 -> "2.0"
        6 -> "5.1"
        8 -> "7.1"
        else -> null
    }
}
