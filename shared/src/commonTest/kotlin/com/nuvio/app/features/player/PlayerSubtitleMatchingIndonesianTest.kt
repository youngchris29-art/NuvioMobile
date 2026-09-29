package com.nuvio.app.features.player

import kotlin.test.Test
import kotlin.test.assertEquals

/**
 * Bahasa Indonesia/Malaysia subtitle language matching tests (upstream d95b4f9b).
 */
class PlayerSubtitleMatchingIndonesianTest {

    @Test
    fun bahasaIndonesiaTrackWithMaySoundCodeResolvesToIndonesian() {
        val variant = SubtitleLanguageMatching.detectTrackLanguageVariant(
            language = "may",
            name = "Bahasa Indonesia",
            trackId = null,
        )
        assertEquals("id", variant)
    }

    @Test
    fun bahasaMalaysiaTrackResolvesToMalay() {
        val variant = SubtitleLanguageMatching.detectTrackLanguageVariant(
            language = "ms",
            name = "Bahasa Malaysia",
            trackId = null,
        )
        assertEquals("ms", variant)
    }

    @Test
    fun indCodeStillMapsToDIndonesian() {
        val normalized = SubtitleLanguageMatching.normalizeLanguageCode("ind")
        assertEquals("id", normalized)
    }
}
