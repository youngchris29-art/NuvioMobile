package com.nuvio.app.features.simkl

import kotlin.random.Random
import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertTrue

/**
 * Pins the fixed-position [parseSimklUtcEpochMs] to the anchored-regex implementation it replaced
 * (NuvioTV 07e041bee): same value, or null, for every input in each corpus.
 */
class SimklTimestampDifferentialTest {
    private val legacyPattern = Regex(
        "^(\\d{4})-(\\d{2})-(\\d{2})T(\\d{2}):(\\d{2}):(\\d{2})(?:\\.(\\d{1,9}))?Z$",
        RegexOption.IGNORE_CASE,
    )

    private fun legacy(value: String?): Long? {
        val match = value?.trim()?.let(legacyPattern::matchEntire) ?: return null
        val year = match.groupValues[1].toIntOrNull() ?: return null
        val month = match.groupValues[2].toIntOrNull() ?: return null
        val day = match.groupValues[3].toIntOrNull() ?: return null
        val hour = match.groupValues[4].toIntOrNull() ?: return null
        val minute = match.groupValues[5].toIntOrNull() ?: return null
        val second = match.groupValues[6].toIntOrNull() ?: return null
        val millis = match.groupValues[7].padEnd(3, '0').take(3).toIntOrNull() ?: 0
        if (year < 1970 || month !in 1..12 || hour !in 0..23 || minute !in 0..59 || second !in 0..59) return null
        val leap = (year % 4 == 0 && year % 100 != 0) || year % 400 == 0
        val monthDays = intArrayOf(31, if (leap) 29 else 28, 31, 30, 31, 30, 31, 31, 30, 31, 30, 31)
        if (day !in 1..monthDays[month - 1]) return null
        var days = 0L
        for (currentYear in 1970 until year) {
            days += if ((currentYear % 4 == 0 && currentYear % 100 != 0) || currentYear % 400 == 0) 366L else 365L
        }
        for (monthIndex in 0 until month - 1) days += monthDays[monthIndex]
        days += day - 1L
        return (((days * 24L + hour) * 60L + minute) * 60L + second) * 1_000L + millis
    }

    private fun pad(value: Int, width: Int) = value.toString().padStart(width, '0')

    private fun check(corpus: Collection<String?>, label: String): Int {
        var accepted = 0
        for (value in corpus) {
            val expected = legacy(value)
            assertEquals(expected, parseSimklUtcEpochMs(value), "$label: <$value>")
            if (expected != null) accepted++
        }
        return accepted
    }

    @Test
    fun `structured corpus matches the legacy regex parser`() {
        val corpus = linkedSetOf<String?>(null, "", " ")
        val dates = listOf(
            "1969-12-31", "1970-01-01", "1999-12-31", "2000-02-29", "2000-02-30", "2023-02-29", "2024-02-29",
            "2025-02-02", "2025-04-31", "2025-12-31", "2100-02-29", "2100-03-01", "2400-02-29", "9999-12-31",
            "2025-00-10", "2025-13-10", "2025-10-00", "2025-10-32",
        )
        val times = listOf("00:00:00", "12:34:56", "23:59:59", "23:59:60", "24:00:00", "00:60:00", "00:00:61", "7:08:09")
        val fractions = listOf("", ".", ".0", ".5", ".12", ".123", ".1234", ".123456789", ".1234567890", ".x")
        val zones = listOf("Z", "z", "", "+00:00", "ZZ", " Z", "UTC")
        val wraps = listOf("" to "", "  " to "", "" to "\n", "\t" to " ")
        val separators = listOf("T", "t", " ", "_")
        for (date in dates) for (time in times) for (fraction in fractions) for (zone in zones) {
            for (separator in separators) {
                val core = "$date$separator$time$fraction$zone"
                for ((prefix, suffix) in wraps) corpus += "$prefix$core$suffix"
            }
        }
        val accepted = check(corpus, "structured")
        assertTrue(accepted > 500, "structured corpus should keep a large accepted share, got $accepted")
    }

    @Test
    fun `random well formed corpus matches the legacy regex parser`() {
        val random = Random(20261020)
        val corpus = ArrayList<String>(20_000)
        repeat(20_000) {
            val fraction = when (random.nextInt(3)) {
                0 -> ""
                1 -> "." + (1..(1 + random.nextInt(9))).joinToString("") { random.nextInt(10).toString() }
                else -> ".${pad(random.nextInt(1000), 3)}"
            }
            corpus += "${pad(1960 + random.nextInt(200), 4)}-${pad(1 + random.nextInt(12), 2)}-${pad(1 + random.nextInt(31), 2)}" +
                "T${pad(random.nextInt(25), 2)}:${pad(random.nextInt(61), 2)}:${pad(random.nextInt(61), 2)}${fraction}Z"
        }
        check(corpus, "random")
    }

    @Test
    fun `single character mutations match the legacy regex parser`() {
        val random = Random(11)
        val seeds = listOf("2025-02-02T17:28:22Z", "2025-02-02T17:28:22.123Z", "2024-02-29T23:59:59.999999999Z")
        val alphabet = "0123456789-:.TtZz +x٠ "
        val corpus = linkedSetOf<String>()
        for (seed in seeds) {
            for (index in seed.indices) {
                corpus += seed.removeRange(index, index + 1)
                repeat(6) {
                    val c = alphabet[random.nextInt(alphabet.length)]
                    corpus += seed.replaceRange(index, index + 1, c.toString())
                    corpus += seed.substring(0, index) + c + seed.substring(index)
                }
            }
            corpus += seed + "Z"
            corpus += seed + "0"
            corpus += "0$seed"
        }
        check(corpus, "mutated")
    }
}
