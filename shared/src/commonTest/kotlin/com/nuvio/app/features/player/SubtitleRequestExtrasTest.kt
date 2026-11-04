package com.nuvio.app.features.player

import com.nuvio.app.features.streams.StreamBehaviorHints
import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertFalse
import kotlin.test.assertNotEquals
import kotlin.test.assertNull
import kotlin.test.assertTrue

// Ported from upstream SubtitleRequestExtrasTest (9cb86845 / 1aacf178 / 843e9e77), plus the
// fork's `of(...)`, file: clearing, dedupe-richness and hashable-source rules.
class SubtitleRequestExtrasTest {

    @Test
    fun buildsExtrasSegmentInStremioFieldOrderWithEncodedValues() {
        val extras = SubtitleRequestExtras(
            filename = "John.Wick.Chapter.4.2023.720p.WEBRip.x264.AAC-[YTS.MX].mp4",
            videoSize = 1_632_335_363L,
            videoHash = "9d8c1e6c3d434f50",
        )

        assertEquals(
            "videoHash=9d8c1e6c3d434f50&videoSize=1632335363&filename=John.Wick.Chapter.4.2023.720p.WEBRip.x264.AAC-%5BYTS.MX%5D.mp4",
            extras.toPathSegment(),
        )
    }

    @Test
    fun includesOnlyProvidedExtras() {
        assertEquals("filename=Movie.2024.1080p.mkv", SubtitleRequestExtras(filename = "Movie.2024.1080p.mkv").toPathSegment())
        assertEquals("videoSize=1632335363", SubtitleRequestExtras(videoSize = 1_632_335_363L).toPathSegment())
        assertEquals("videoHash=9d8c1e6c3d434f50", SubtitleRequestExtras(videoHash = "9d8c1e6c3d434f50").toPathSegment())
    }

    @Test
    fun ignoresBlankAndNonPositiveValues() {
        assertNull(SubtitleRequestExtras().toPathSegment())
        assertNull(SubtitleRequestExtras(filename = "   ", videoHash = "").toPathSegment())
        assertNull(SubtitleRequestExtras(videoSize = 0L).toPathSegment())
        assertEquals("videoSize=1", SubtitleRequestExtras(filename = " ", videoSize = 1L).toPathSegment())
    }

    @Test
    fun buildsExtrasFromStreamBehaviorHints() {
        assertEquals(
            "videoHash=abc123&videoSize=42&filename=Movie.2024.mkv",
            SubtitleRequestExtras.from(
                StreamBehaviorHints(filename = "Movie.2024.mkv", videoSize = 42L, videoHash = "abc123"),
            )?.toPathSegment(),
        )
        assertNull(SubtitleRequestExtras.from(StreamBehaviorHints()))
    }

    @Test
    fun subtitleRequestUrlAppendsExtrasBeforeJsonSuffix() {
        val url = buildSubtitleRequestUrl(
            manifestUrl = "https://addon.example.com/manifest.json",
            type = "tv",
            videoId = "tt37532893:1:5",
            extras = SubtitleRequestExtras(filename = "Episode Five.mkv", videoSize = 123L, videoHash = "deadbeef"),
        )
        assertEquals(
            "https://addon.example.com/subtitles/series/tt37532893%3A1%3A5/videoHash=deadbeef&videoSize=123&filename=Episode%20Five.mkv.json",
            url,
        )
    }

    @Test
    fun subtitleRequestUrlKeepsExistingShapeWhenNoUsableExtrasExist() {
        assertEquals(
            "https://addon.example.com/subtitles/series/tt37532893%3A1%3A5.json",
            buildSubtitleRequestUrl(
                manifestUrl = "https://addon.example.com/manifest.json",
                type = "series",
                videoId = "tt37532893:1:5",
                extras = SubtitleRequestExtras(filename = "  "),
            ),
        )
    }

    @Test
    fun subtitleRequestUrlPassesNullExtrasCleanly() {
        assertEquals(
            "https://addon.example.com/subtitles/movie/tt1234567.json",
            buildSubtitleRequestUrl("https://addon.example.com/manifest.json", "movie", "tt1234567", null),
        )
    }

    @Test
    fun subtitleRequestUrlPreservesAddonQueryParameters() {
        assertEquals(
            "https://addon.example.com/subtitles/movie/tt1234567/videoHash=abc.json?key=val",
            buildSubtitleRequestUrl(
                manifestUrl = "https://addon.example.com/manifest.json?key=val",
                type = "movie",
                videoId = "tt1234567",
                extras = SubtitleRequestExtras(videoHash = "abc"),
            ),
        )
    }

    @Test
    fun enrichingExtrasWithComputedHashPreservesExistingFields() {
        val enriched = SubtitleRequestExtras(filename = "Movie.2024.mkv", videoSize = 1_500_000L)
            .copy(videoHash = "cafebabe01234567")
        assertEquals(
            "videoHash=cafebabe01234567&videoSize=1500000&filename=Movie.2024.mkv",
            enriched.toPathSegment(),
        )
    }

    @Test
    fun fromReturnsNullWhenHintsHaveOnlyBlankValues() {
        assertNull(SubtitleRequestExtras.from(StreamBehaviorHints(filename = "  ", videoSize = 0L, videoHash = "")))
    }

    @Test
    fun fromRetainsVideoHashFromHints() {
        val extras = SubtitleRequestExtras.from(StreamBehaviorHints(videoHash = "prehashed", videoSize = 100L))
        assertEquals("prehashed", extras?.videoHash)
        assertEquals(100L, extras?.videoSize)
    }

    // --- sourceFilenameFromUrl ---

    @Test
    fun sourceFilenameFromUrlExtractsLastPathSegment() {
        assertEquals("Movie.2024.1080p.mkv", sourceFilenameFromUrl("https://cdn.example.com/files/Movie.2024.1080p.mkv"))
    }

    @Test
    fun sourceFilenameFromUrlStripsQueryAndFragment() {
        assertEquals("video.mp4", sourceFilenameFromUrl("https://cdn.example.com/video.mp4?token=abc&expires=123"))
        assertEquals("video.mp4", sourceFilenameFromUrl("https://cdn.example.com/video.mp4#t=10"))
    }

    @Test
    fun sourceIdentityTellsHeadersApartAndIgnoresTheirOrder() {
        // Review r2: the same endpoint with other authorization headers can be another file.
        val plain = subtitleSourceIdentity("https://cdn.example.com/a.mkv", emptyMap())
        val authed = subtitleSourceIdentity("https://cdn.example.com/a.mkv", mapOf("Authorization" to "Bearer x"))
        val authedOther = subtitleSourceIdentity("https://cdn.example.com/a.mkv", mapOf("Authorization" to "Bearer y"))
        assertNotEquals(plain, authed)
        assertNotEquals(authed, authedOther)
        assertEquals(
            subtitleSourceIdentity("https://x/a", mapOf("Referer" to "r", "User-Agent" to "u")),
            subtitleSourceIdentity("https://x/a", mapOf("user-agent" to "u", "referer" to "r")),
        )
    }

    @Test
    fun sourceFilenameFromUrlDecodesPercentEscapesOnce() {
        // Review r1: the add-on gets "Movie Name.mkv", not "Movie%2520Name.mkv".
        assertEquals("Movie Name.mkv", sourceFilenameFromUrl("https://cdn.example.com/Movie%20Name.mkv"))
        assertEquals("100%.mkv", sourceFilenameFromUrl("https://cdn.example.com/100%25.mkv"))
        assertEquals("你好.mkv", sourceFilenameFromUrl("https://cdn.example.com/%E4%BD%A0%E5%A5%BD.mkv"))
        assertEquals("bad%ZZ.mkv", sourceFilenameFromUrl("https://cdn.example.com/bad%ZZ.mkv"), "malformed: kept as is")
        assertEquals("filename=Movie%20Name.mkv",
            SubtitleRequestExtras.of(filename = null, videoSize = null, videoHash = null,
                sourceUrl = "https://cdn.example.com/Movie%20Name.mkv")?.toPathSegment())
    }

    @Test
    fun sourceFilenameFromUrlReturnsNullWhenUnusable() {
        assertNull(sourceFilenameFromUrl("https://cdn.example.com/stream"))
        assertNull(sourceFilenameFromUrl("https://cdn.example.com/"))
        assertNull(sourceFilenameFromUrl(null))
    }

    // --- from(hints, sourceUrl) / of(...) ---

    @Test
    fun fromWithUrlFallsBackToUrlFilenameWhenHintsHaveNone() {
        val extras = SubtitleRequestExtras.from(StreamBehaviorHints(videoSize = 42L), "https://cdn.example.com/files/Movie.2024.mkv")
        assertEquals("Movie.2024.mkv", extras?.filename)
        assertEquals(42L, extras?.videoSize)
    }

    @Test
    fun fromWithUrlPrefersHintFilenameOverUrl() {
        val extras = SubtitleRequestExtras.from(
            StreamBehaviorHints(filename = "RealName.mkv", videoSize = 10L),
            "https://cdn.example.com/files/hash123.mp4",
        )
        assertEquals("RealName.mkv", extras?.filename)
    }

    @Test
    fun fromWithUrlReturnsNullWhenNothingUsable() {
        assertNull(SubtitleRequestExtras.from(StreamBehaviorHints(), "https://cdn.example.com/"))
    }

    @Test
    fun fromWithUrlCreatesExtrasFromUrlFilenameAlone() {
        val extras = SubtitleRequestExtras.from(StreamBehaviorHints(), "https://cdn.example.com/Episode.S01E05.720p.mkv")
        assertEquals("Episode.S01E05.720p.mkv", extras?.filename)
        assertNull(extras?.videoHash)
        assertNull(extras?.videoSize)
    }

    @Test
    fun localFileSourcesCarryNoExtras() {
        assertNull(SubtitleRequestExtras.of("Movie.mkv", 42L, "abc", "file:///var/mobile/Movie.mkv"))
    }

    @Test
    fun ofMatchesFromForTheSameFields() {
        assertEquals(
            SubtitleRequestExtras.from(StreamBehaviorHints(videoSize = 7L), "https://h/x/Show.mkv"),
            SubtitleRequestExtras.of(null, 7L, null, "https://h/x/Show.mkv"),
        )
    }

    // --- dedupe richness / merge ---

    @Test
    fun hashedRequestIsRicherThanUnhashedPrefetch() {
        val prefetch = SubtitleRequestExtras(filename = "Movie.mkv", videoSize = 10L)
        assertTrue(prefetch.copy(videoHash = "0011223344556677").isRicherThan(prefetch))
        assertTrue(SubtitleRequestExtras(videoHash = "0011223344556677").isRicherThan(null))
    }

    @Test
    fun requestWithoutNewInformationIsNotRicher() {
        val hashed = SubtitleRequestExtras(filename = "Movie.mkv", videoSize = 10L, videoHash = "0011223344556677")
        val prefetch = SubtitleRequestExtras(filename = "Movie.mkv", videoSize = 10L)
        assertFalse(prefetch.isRicherThan(hashed))
        assertFalse(null.isRicherThan(prefetch))
        assertFalse(null.isRicherThan(null))
        assertFalse(prefetch.isRicherThan(prefetch.copy()))
        // A different URL-derived filename alone never re-queries.
        assertFalse(prefetch.copy(filename = "Other.mkv").isRicherThan(prefetch))
        assertFalse(hashed.copy(filename = null).isRicherThan(hashed))
    }

    @Test
    fun filenameOrSizeAddedToABareRequestIsRicher() {
        assertTrue(SubtitleRequestExtras(filename = "Movie.mkv").isRicherThan(null))
        assertTrue(SubtitleRequestExtras(videoSize = 5L).isRicherThan(SubtitleRequestExtras(filename = "Movie.mkv")))
    }

    @Test
    fun mergeFillsGapsFromPreviousRequest() {
        val merged = SubtitleRequestExtras(videoHash = "abc", videoSize = 99L)
            .mergedOver(SubtitleRequestExtras(filename = "Movie.mkv", videoSize = 10L))
        assertEquals(SubtitleRequestExtras(filename = "Movie.mkv", videoSize = 99L, videoHash = "abc"), merged)
        assertNull((null as SubtitleRequestExtras?).mergedOver(null))
    }

    @Test
    fun upgradedSubtitlesLeadAndPreviousOnesAreKeptWithoutDuplicates() {
        fun sub(url: String) = AddonSubtitle(id = url, url = url, language = "en", display = url)
        assertEquals(
            listOf(sub("b"), sub("c"), sub("a")),
            mergeUpgradedSubtitles(upgraded = listOf(sub("b"), sub("c")), previous = listOf(sub("a"), sub("b"))),
        )
        assertEquals(listOf(sub("a")), mergeUpgradedSubtitles(upgraded = emptyList(), previous = listOf(sub("a"))))
    }

    // --- hashable source ---

    @Test
    fun hashableSourcesAreRemoteHttpFiles() {
        assertTrue(isHashableSubtitleSource("https://cdn.example.com/files/Movie.mkv?token=1"))
        assertTrue(isHashableSubtitleSource("http://debrid.example.net:8080/dl/abc"))
    }

    @Test
    fun nonFileSourcesAreNotHashed() {
        assertFalse(isHashableSubtitleSource(null))
        assertFalse(isHashableSubtitleSource(""))
        assertFalse(isHashableSubtitleSource("file:///tmp/Movie.mkv"))
        assertFalse(isHashableSubtitleSource("torrent://abcdef"))
        assertFalse(isHashableSubtitleSource("https://cdn.example.com/hls/master.m3u8?x=1"))
        assertFalse(isHashableSubtitleSource("https://cdn.example.com/dash/stream.mpd"))
        assertFalse(isHashableSubtitleSource("http://127.0.0.1:8123/remux/index.m3u8"))
        assertFalse(isHashableSubtitleSource("http://localhost:9000/video.mkv"))
        assertFalse(isHashableSubtitleSource("http://[::1]:9000/video.mkv"))
        assertFalse(isHashableSubtitleSource("https://rr3---sn.googlevideo.com/videoplayback?id=1"))
        assertFalse(isHashableSubtitleSource("https://www.youtube.com/watch?v=abc"))
    }
}
