package com.nuvio.app.features.mdblist

import java.time.Instant
import java.time.LocalDateTime
import java.time.OffsetDateTime
import java.time.ZoneOffset
import java.time.format.DateTimeFormatterBuilder
import java.time.temporal.ChronoField
import kotlin.random.Random
import kotlin.test.Test
import kotlin.test.assertEquals

/** Cross-checks the fast path against `java.time`, an oracle independent of kotlin.time.Instant. */
class MdbListTimestampJavaTimeTest {
    private val localFormat = DateTimeFormatterBuilder()
        .appendPattern("yyyy-MM-dd HH:mm:ss")
        .optionalStart()
        .appendFraction(ChronoField.NANO_OF_SECOND, 1, 9, true)
        .optionalEnd()
        .toFormatter()

    @Test
    fun `zulu and offset timestamps match java time`() {
        listOf(
            "1970-01-01T00:00:00Z", "2025-02-02T17:28:22Z", "2025-02-02T17:28:22.5Z",
            "2025-02-02T17:28:22.123456789Z", "2100-03-01T00:00:00Z",
        ).forEach { assertEquals(Instant.parse(it).toEpochMilli(), mdbListTimestamp(it), it) }
        listOf(
            "2025-02-02T17:28:22+02:00", "2025-02-02T17:28:22-05:30",
            "2025-02-02T17:28:22.250+00:00", "2025-02-02T00:00:00+18:00",
        ).forEach { assertEquals(OffsetDateTime.parse(it).toInstant().toEpochMilli(), mdbListTimestamp(it), it) }
    }

    @Test
    fun `space separated timestamps match java time local parsing`() {
        listOf("2025-02-02 17:28:22", "2025-02-02 17:28:22.000000", "2025-02-02 17:28:22.987654321")
            .forEach {
                assertEquals(LocalDateTime.parse(it, localFormat).toInstant(ZoneOffset.UTC).toEpochMilli(), mdbListTimestamp(it), it)
            }
    }

    @Test
    fun `random zulu timestamps match java time`() {
        val random = Random(99)
        repeat(5_000) {
            val year = 1 + random.nextInt(9999)
            val seconds = random.nextLong(0, 60)
            val value = "%04d-%02d-%02dT%02d:%02d:%02d.%03dZ".format(
                year, 1 + random.nextInt(12), 1 + random.nextInt(28),
                random.nextInt(24), random.nextInt(60), seconds, random.nextInt(1000),
            )
            assertEquals(Instant.parse(value).toEpochMilli(), mdbListTimestamp(value), value)
        }
    }
}
