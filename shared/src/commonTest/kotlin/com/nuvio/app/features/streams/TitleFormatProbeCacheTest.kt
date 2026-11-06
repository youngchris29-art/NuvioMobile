package com.nuvio.app.features.streams

import com.nuvio.app.features.streams.TitleFormatBadge.DOLBY_ATMOS
import com.nuvio.app.features.streams.TitleFormatBadge.DOLBY_VISION
import com.nuvio.app.features.streams.TitleFormatBadge.HDR
import com.nuvio.app.features.streams.TitleFormatBadge.UHD_4K
import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertNotNull
import kotlin.test.assertNull

class TitleFormatProbeCacheTest {

    private var now = 1_000_000L
    private fun cache(capacity: Int = TitleFormatProbeCache.DEFAULT_CAPACITY) =
        TitleFormatProbeCache(clock = { now }, capacity = capacity)

    private val sixHours = 6L * 60 * 60 * 1_000
    private val thirtyMinutes = 30L * 60 * 1_000

    @Test
    fun constantsAreSixHoursAndThirtyMinutes() {
        assertEquals(sixHours, TitleFormatProbeCache.POSITIVE_TTL_MS)
        assertEquals(thirtyMinutes, TitleFormatProbeCache.EMPTY_TTL_MS)
        assertEquals(200, TitleFormatProbeCache.DEFAULT_CAPACITY)
    }

    @Test
    fun positiveEntryLivesSixHours() {
        val cache = cache()
        cache.record("k", listOf(UHD_4K), TitleFormatSource.PROBE)

        now += sixHours - 1
        assertEquals(listOf(UHD_4K), cache.get("k")?.badges)

        now += 1
        assertNull(cache.get("k"))
    }

    @Test
    fun emptyEntryLivesThirtyMinutes() {
        val cache = cache()
        cache.record("k", emptyList(), TitleFormatSource.PROBE)

        now += thirtyMinutes - 1
        assertNotNull(cache.get("k"))

        now += 1
        assertNull(cache.get("k"))
    }

    @Test
    fun recordingIntoALiveEntryMergesAndRestartsTheTtl() {
        val cache = cache()
        cache.record("k", listOf(HDR), TitleFormatSource.PROBE)
        now += sixHours - 10
        val merged = cache.record("k", listOf(DOLBY_VISION, DOLBY_ATMOS), TitleFormatSource.PROBE)

        assertEquals(listOf(DOLBY_VISION, DOLBY_ATMOS), merged.badges)
        now += sixHours - 10
        assertNotNull(cache.get("k"))
    }

    @Test
    fun anEmptyEntryGrowsIntoAPositiveTtl() {
        val cache = cache()
        cache.record("k", emptyList(), TitleFormatSource.PROBE)
        cache.record("k", listOf(UHD_4K), TitleFormatSource.PROBE)

        now += thirtyMinutes + 1
        assertNotNull(cache.get("k"))
    }

    @Test
    fun anExpiredEntryIsNotMergedInto() {
        val cache = cache()
        cache.record("k", listOf(DOLBY_VISION), TitleFormatSource.PROBE)
        now += sixHours
        val fresh = cache.record("k", listOf(UHD_4K), TitleFormatSource.PROBE)
        assertEquals(listOf(UHD_4K), fresh.badges)
    }

    @Test
    fun evictsTheLeastRecentlyUsedEntryAtCapacity() {
        val cache = cache(capacity = 2)
        cache.record("a", listOf(UHD_4K), TitleFormatSource.PROBE)
        cache.record("b", listOf(UHD_4K), TitleFormatSource.PROBE)
        // A hit makes "a" the most recent, so "b" is the one evicted.
        assertNotNull(cache.get("a"))
        cache.record("c", listOf(UHD_4K), TitleFormatSource.PROBE)

        assertNotNull(cache.get("a"))
        assertNull(cache.get("b"))
        assertNotNull(cache.get("c"))
    }

    @Test
    fun pickerSourceSticks() {
        val cache = cache()
        cache.record("k", listOf(UHD_4K), TitleFormatSource.PICKER)
        val after = cache.record("k", listOf(DOLBY_ATMOS), TitleFormatSource.PROBE)
        assertEquals(TitleFormatSource.PICKER, after.source)
        assertEquals(TitleFormatSource.PICKER, cache.get("k")?.source)
    }

    @Test
    fun probeThenPickerBecomesPicker() {
        val cache = cache()
        cache.record("k", listOf(UHD_4K), TitleFormatSource.PROBE)
        assertEquals(TitleFormatSource.PROBE, cache.get("k")?.source)
        assertEquals(TitleFormatSource.PICKER, cache.record("k", listOf(UHD_4K), TitleFormatSource.PICKER).source)
    }
}
