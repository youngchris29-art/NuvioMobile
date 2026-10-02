package com.nuvio.app.features.trailer

import kotlin.test.AfterTest
import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertTrue

/** BUG-128: the max-fps preference reorders same-height formats without capping height. */
class InAppYouTubeExtractorFpsPreferenceTest {

    private val extractor = InAppYouTubeExtractor()
    private val bitrate = 4_000_000.0

    @AfterTest
    fun reset() {
        TrailerExtractionPreferences.maxVideoFps = 0
    }

    @Test
    fun noPreferenceKeepsHigherFpsFirst() {
        assertTrue(extractor.videoScore(1080, 60, bitrate, 0) > extractor.videoScore(1080, 30, bitrate, 0))
    }

    @Test
    fun preferenceDemotesOverLimitFps() {
        assertTrue(extractor.videoScore(1080, 30, bitrate, 30) > extractor.videoScore(1080, 60, bitrate, 30))
    }

    @Test
    fun heightStillDominatesUnderPreference() {
        assertTrue(extractor.videoScore(1080, 60, bitrate, 30) > extractor.videoScore(720, 30, bitrate, 30))
    }

    @Test
    fun defaultParameterReadsGlobalPreference() {
        TrailerExtractionPreferences.maxVideoFps = 30
        assertTrue(extractor.videoScore(1080, 30, bitrate) > extractor.videoScore(1080, 60, bitrate))
    }

    private fun candidate(itagName: String, height: Int, fps: Int, maxFps: Int) = StreamCandidate(
        client = "c",
        priority = 0,
        url = itagName,
        score = extractor.videoScore(height, fps, bitrate, maxFps),
        hasN = false,
        height = height,
        fps = fps,
        ext = "mp4",
    )

    private fun order(maxFps: Int) = extractor.sortCandidates(
        listOf(
            candidate("136", 720, 30, maxFps),
            candidate("137", 1080, 30, maxFps),
            candidate("299", 1080, 60, maxFps),
        ),
    ).map { it.url }

    @Test
    fun orderingWithoutAndWithPreference() {
        assertEquals(listOf("299", "137", "136"), order(0))
        assertEquals(listOf("137", "299", "136"), order(30))
    }
}
