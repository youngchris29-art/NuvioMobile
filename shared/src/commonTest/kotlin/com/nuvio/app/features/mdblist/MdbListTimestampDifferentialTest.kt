package com.nuvio.app.features.mdblist

import kotlin.random.Random
import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertFailsWith
import kotlin.test.assertTrue
import kotlin.time.Instant

/**
 * Pins the fixed-position fast path in [mdbListTimestamp] to the chain it replaced (NuvioTV
 * 07e041bee): for every input in a structured, a random and a mutated corpus the new parser must
 * return the legacy value, or throw where the legacy chain threw.
 */
class MdbListTimestampDifferentialTest {
    private val legacyLocal = Regex("""^(\d{4}-\d{2}-\d{2}) (\d{2}:\d{2}:\d{2})(?:\.(\d{1,9}))?$""")

    private fun legacy(value: String): Long? = runCatching { Instant.parse(value).toEpochMilliseconds() }
        .recoverCatching {
            val match = legacyLocal.matchEntire(value.trim()) ?: error("no match")
            val fraction = match.groupValues[3]
            val fractionPart = if (fraction.isEmpty()) "" else ".${fraction.padEnd(9, '0')}"
            Instant.parse("${match.groupValues[1]}T${match.groupValues[2]}${fractionPart}Z").toEpochMilliseconds()
        }
        .getOrNull()

    private fun pad(value: Int, width: Int) = value.toString().padStart(width, '0')

    private fun check(corpus: Collection<String>, label: String): Int {
        var accepted = 0
        for (value in corpus) {
            val expected = legacy(value)
            if (expected == null) {
                assertFailsWith<MdbListDecodingException>("$label: <$value>") { mdbListTimestamp(value) }
            } else {
                assertEquals(expected, mdbListTimestamp(value), "$label: <$value>")
                accepted++
            }
        }
        return accepted
    }

    @Test
    fun `structured corpus matches the legacy chain`() {
        val corpus = linkedSetOf<String>()
        val dates = listOf(
            "0001-01-01", "1969-12-31", "1970-01-01", "1999-12-31", "2000-02-29", "2000-02-30", "2023-02-29",
            "2024-02-29", "2025-02-02", "2025-04-31", "2025-12-31", "2100-02-29", "2100-03-01", "9999-12-31",
            "2025-00-10", "2025-13-10", "2025-10-00", "2025-10-32",
        )
        val times = listOf(
            "00:00:00", "12:34:56", "23:59:59", "23:59:60", "24:00:00", "00:60:00", "00:00:61", "7:08:09",
        )
        val fractions = listOf("", ".", ".0", ".5", ".12", ".123", ".1234", ".123456789", ".1234567890", ".x")
        val zones = listOf("", "Z", "z", "+00:00", "-00:00", "+02:00", "-05:30", "+18:00", "+18:01", "-18:00", "+19:00", "+0200", "+02", "UTC")
        for (date in dates) for (time in times) for (fraction in fractions) for (zone in zones) {
            corpus += "${date}T$time$fraction$zone"
            corpus += "${date} $time$fraction$zone"
            corpus += "${date}t$time$fraction$zone"
        }
        corpus += listOf("", " ", "yesterday", "2025-02-02", "2025-02-02T", "2025-02-02T17:28", " 2025-02-02T17:28:22Z", "2025-02-02T17:28:22Z\n")
        val accepted = check(corpus, "structured")
        assertTrue(accepted > 1_000, "structured corpus should keep a large accepted share, got $accepted")
    }

    @Test
    fun `random well formed corpus matches the legacy chain`() {
        val random = Random(20261020)
        val corpus = ArrayList<String>(20_000)
        repeat(20_000) {
            val year = 1 + random.nextInt(9999)
            val month = 1 + random.nextInt(12)
            val day = 1 + random.nextInt(28)
            val fraction = when (random.nextInt(4)) {
                0 -> ""
                1 -> "." + (1..(1 + random.nextInt(9))).joinToString("") { random.nextInt(10).toString() }
                2 -> ".${random.nextInt(1000).toString().padStart(3, '0')}"
                else -> ""
            }
            val zone = when (random.nextInt(4)) {
                0 -> "Z"
                1 -> "+${pad(random.nextInt(19), 2)}:${pad(random.nextInt(60), 2)}"
                2 -> "-${pad(random.nextInt(19), 2)}:${pad(random.nextInt(60), 2)}"
                else -> "Z"
            }
            val core = "${pad(year, 4)}-${pad(month, 2)}-${pad(day, 2)}T" +
                "${pad(random.nextInt(24), 2)}:${pad(random.nextInt(60), 2)}:${pad(random.nextInt(60), 2)}"
            corpus += "$core$fraction$zone"
            corpus += core.replace('T', ' ') + fraction
        }
        check(corpus, "random")
    }

    @Test
    fun `single character mutations match the legacy chain`() {
        val random = Random(7)
        val seeds = listOf(
            "2025-02-02T17:28:22Z", "2025-02-02T17:28:22.123Z", "2025-02-02T17:28:22+02:00",
            "2025-02-02 17:28:22", "2025-02-02 17:28:22.123456", "2024-02-29T23:59:59.999999999-05:30",
        )
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
