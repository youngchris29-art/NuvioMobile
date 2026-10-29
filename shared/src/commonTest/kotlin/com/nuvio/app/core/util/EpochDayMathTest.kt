package com.nuvio.app.core.util

import kotlin.test.Test
import kotlin.test.assertEquals

class EpochDayMathTest {
    @Test
    fun `days since epoch pins known dates`() {
        assertEquals(0L, daysSinceEpoch(1970, 1, 1))
        assertEquals(-1L, daysSinceEpoch(1969, 12, 31))
        assertEquals(11_016L, daysSinceEpoch(2000, 2, 29))
        assertEquals(20_121L, daysSinceEpoch(2025, 2, 2))
        assertEquals(-719_162L, daysSinceEpoch(1, 1, 1))
    }

    @Test
    fun `days since epoch advances by exactly one day across month year and leap boundaries`() {
        var previous = daysSinceEpoch(1969, 12, 31)
        for (year in 1970..2105) {
            for (month in 1..12) {
                for (day in 1..daysInMonth(year, month)) {
                    val current = daysSinceEpoch(year, month, day)
                    assertEquals(previous + 1, current, "$year-$month-$day")
                    previous = current
                }
            }
        }
    }

    @Test
    fun `leap years follow the gregorian rule`() {
        assertEquals(29, daysInMonth(2000, 2))
        assertEquals(28, daysInMonth(1900, 2))
        assertEquals(29, daysInMonth(2024, 2))
        assertEquals(28, daysInMonth(2023, 2))
        assertEquals(0, daysInMonth(2024, 13))
    }

    @Test
    fun `decimalAt reads only complete digit runs`() {
        assertEquals(2025, decimalAt("2025-02", 0, 4))
        assertEquals(2, decimalAt("2025-02", 5, 2))
        assertEquals(-1, decimalAt("20a5", 0, 4))
        assertEquals(-1, decimalAt("2025", 2, 4))
        assertEquals(-1, decimalAt("2025", 0, 0))
        assertEquals(-1, decimalAt("+123", 0, 4))
    }

    @Test
    fun `fraction millis truncate past three digits and reject non digits`() {
        assertEquals(500, fractionMillisAt(".5Z", 1, 2))
        assertEquals(123, fractionMillisAt(".123999Z", 1, 7))
        assertEquals(7, fractionMillisAt(".007Z", 1, 4))
        assertEquals(-1, fractionMillisAt(".1x3Z", 1, 4))
        assertEquals(-1, fractionMillisAt(".Z", 1, 1))
    }
}
