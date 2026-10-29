package com.nuvio.app.core.util

// Allocation-free calendar helpers for the fixed-position timestamp parsers in the Simkl and
// MDBList providers (NuvioTV 07e041bee). Kept free of java.time so they run on every target.

internal fun isLeapYear(year: Int): Boolean =
    (year % 4 == 0 && year % 100 != 0) || year % 400 == 0

internal fun daysInMonth(year: Int, month: Int): Int = when (month) {
    1, 3, 5, 7, 8, 10, 12 -> 31
    4, 6, 9, 11 -> 30
    2 -> if (isLeapYear(year)) 29 else 28
    else -> 0
}

/** Days from 1970-01-01 to the given proleptic Gregorian date (negative before the epoch). */
internal fun daysSinceEpoch(year: Int, month: Int, day: Int): Long {
    val shiftedYear = if (month <= 2) year - 1 else year
    val era = (if (shiftedYear >= 0) shiftedYear else shiftedYear - 399) / 400
    val yearOfEra = shiftedYear - era * 400
    val dayOfYear = (153 * (month + if (month > 2) -3 else 9) + 2) / 5 + day - 1
    val dayOfEra = yearOfEra * 365 + yearOfEra / 4 - yearOfEra / 100 + dayOfYear
    return era.toLong() * 146_097L + dayOfEra - 719_468L
}

/** The [length] ASCII digits at [start] as an Int, or -1 when out of range or not all digits. */
internal fun decimalAt(text: CharSequence, start: Int, length: Int): Int {
    if (start < 0 || length <= 0 || start + length > text.length) return -1
    var value = 0
    for (index in start until start + length) {
        val digit = text[index] - '0'
        if (digit < 0 || digit > 9) return -1
        value = value * 10 + digit
    }
    return value
}

/** Milliseconds from the fraction digits in [start, end), truncated past three digits; -1 if any is not a digit. */
internal fun fractionMillisAt(text: CharSequence, start: Int, end: Int): Int {
    if (start >= end) return -1
    var millis = 0
    var scale = 100
    for (index in start until end) {
        val digit = text[index] - '0'
        if (digit < 0 || digit > 9) return -1
        if (scale > 0) {
            millis += digit * scale
            scale /= 10
        }
    }
    return millis
}
