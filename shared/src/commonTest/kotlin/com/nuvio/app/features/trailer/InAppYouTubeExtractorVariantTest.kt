package com.nuvio.app.features.trailer

import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertNull

/**
 * RISK (beta.16+): the HLS SABR-fallback path lands on a bare, non-EDR `AVPlayerLayer`
 * by design (BUG-18/59 retirement — see `TrailerHeroPlayerView.swift`), so a PQ/HLG
 * VIDEO-RANGE variant renders milky/washed-out there. The 08-28 client swap
 * (android_vr -> visionos) changed which variants YouTube offers, making this newly
 * reachable. These pin [selectBestHlsVariant]'s SDR-preferring guard.
 * Ref: docs/steven-batch-plan-2026-08-29.md Wave 4 item 3.
 */
class InAppYouTubeExtractorVariantTest {

    private fun variant(
        id: String,
        height: Int,
        bandwidth: Long = height.toLong() * 1_000,
        width: Int = height * 16 / 9,
        videoRange: String? = null,
    ) = HlsVariantCandidate(
        url = id,
        width = width,
        height = height,
        bandwidth = bandwidth,
        videoRange = videoRange,
    )

    @Test
    fun prefersSdrOverHigherPqVariant() {
        val candidates = listOf(
            variant("pq-1080", height = 1080, videoRange = "PQ"),
            variant("sdr-720", height = 720, videoRange = "SDR"),
        )
        assertEquals("sdr-720", selectBestHlsVariant(candidates)?.url)
    }

    @Test
    fun fallsBackToUnfilteredBestWhenOnlyHdrVariantsExist() {
        val candidates = listOf(
            variant("hlg-720", height = 720, videoRange = "HLG"),
            variant("pq-1080", height = 1080, videoRange = "PQ"),
        )
        // No SDR survivor: the picker still returns the best HDR variant rather than
        // nothing — a washed-out trailer beats no trailer.
        assertEquals("pq-1080", selectBestHlsVariant(candidates)?.url)
    }

    @Test
    fun treatsMissingVideoRangeAsSdr() {
        val candidates = listOf(
            variant("pq-1080", height = 1080, videoRange = "PQ"),
            variant("untagged-720", height = 720, videoRange = null),
        )
        assertEquals("untagged-720", selectBestHlsVariant(candidates)?.url)
    }

    @Test
    fun keepsHeightBandwidthWidthOrderingAmongSurvivors() {
        val candidates = listOf(
            variant("sdr-720-low-bw", height = 720, bandwidth = 1_000, videoRange = "SDR"),
            variant("sdr-720-high-bw", height = 720, bandwidth = 5_000, videoRange = null),
            variant("sdr-480", height = 480, bandwidth = 9_000, videoRange = "SDR"),
        )
        assertEquals("sdr-720-high-bw", selectBestHlsVariant(candidates)?.url)
    }

    @Test
    fun returnsNullForEmptyCandidateList() {
        assertNull(selectBestHlsVariant(emptyList()))
    }
}
