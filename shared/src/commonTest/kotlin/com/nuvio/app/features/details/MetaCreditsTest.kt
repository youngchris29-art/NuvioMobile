package com.nuvio.app.features.details

import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertNull
import kotlin.test.assertTrue

class MetaCreditsTest {

    private fun member(
        name: String,
        job: String,
        id: Int? = null,
    ): MetaCrewMember = MetaCrewMember(
        name = name,
        job = job,
        category = MetaCrewCategory.fromJob(job)!!,
        tmdbId = id,
    )

    @Test
    fun creditKeyUsesIdAndJobOrNameAndJob() {
        assertEquals("tmdb:42|director", member("Jane Doe", "Director", id = 42).creditKey)
        assertEquals("name:jane doe|screenplay", member(" Jane Doe ", "Screenplay").creditKey)
        assertEquals("tmdb:42|writer", metaCreditKey(42, "Anything", "Writer"))
    }

    @Test
    fun fromJobMapsOnlyShownJobs() {
        assertEquals(MetaCrewCategory.DIRECTOR, MetaCrewCategory.fromJob("Director"))
        assertEquals(MetaCrewCategory.WRITER, MetaCrewCategory.fromJob("Screenplay"))
        assertEquals(MetaCrewCategory.WRITER, MetaCrewCategory.fromJob("story"))
        assertEquals(MetaCrewCategory.PRODUCER, MetaCrewCategory.fromJob("Executive Producer"))
        assertEquals(MetaCrewCategory.CREATOR, MetaCrewCategory.fromJob("Creator"))
        assertNull(MetaCrewCategory.fromJob("Director of Photography"))
        assertNull(MetaCrewCategory.fromJob(null))
    }

    @Test
    fun buildOrdersCreatorsDirectorsWritersProducers() {
        val crew = buildMetaCrew(
            creators = listOf(member("Creator One", "Creator", id = 1)),
            crew = listOf(
                member("Prod", "Producer", id = 5),
                member("Writer", "Writer", id = 4),
                member("Dir", "Director", id = 3),
            ),
        )
        assertEquals(listOf("Creator One", "Dir", "Writer", "Prod"), crew.map(MetaCrewMember::name))
        assertEquals(
            listOf(
                MetaCrewCategory.CREATOR,
                MetaCrewCategory.DIRECTOR,
                MetaCrewCategory.WRITER,
                MetaCrewCategory.PRODUCER,
            ),
            crew.map(MetaCrewMember::category),
        )
    }

    @Test
    fun buildDedupesSamePersonSameJobAndCollapsesWriterJobs() {
        val crew = buildMetaCrew(
            creators = emptyList(),
            crew = listOf(
                member("Dir", "Director", id = 3),
                member("Dir", "Director", id = 3),
                member("Pen", "Screenplay", id = 7),
                member("Pen", "Story", id = 7),
                member("Dir", "Writer", id = 3),
                member("No Id", "Writer"),
                member("no id", "Writer"),
            ),
        )
        assertEquals(
            listOf("tmdb:3|director", "tmdb:7|screenplay", "tmdb:3|writer", "name:no id|writer"),
            crew.map(MetaCrewMember::creditKey),
        )
        assertEquals(crew.size, crew.map(MetaCrewMember::creditKey).toSet().size)
    }

    @Test
    fun buildCapsEachCategoryAndTheWholeList() {
        val many = (1..10).flatMap { i ->
            listOf(
                member("D$i", "Director", id = 100 + i),
                member("W$i", "Writer", id = 200 + i),
                member("P$i", "Producer", id = 300 + i),
            )
        }
        val creators = (1..10).map { i -> member("C$i", "Creator", id = 400 + i) }
        val crew = buildMetaCrew(creators = creators, crew = many)
        assertEquals(META_CREW_LIMIT, crew.size)
        assertEquals(4, crew.count { it.category == MetaCrewCategory.CREATOR })
        assertEquals(4, crew.count { it.category == MetaCrewCategory.DIRECTOR })
        assertEquals(4, crew.count { it.category == MetaCrewCategory.WRITER })
        assertEquals(0, crew.count { it.category == MetaCrewCategory.PRODUCER })
        assertEquals(listOf("D1", "D2", "D3", "D4"), crew.filter { it.category == MetaCrewCategory.DIRECTOR }.map { it.name })
    }

    @Test
    fun buildForcesCreatorCategoryAndSkipsBlankNames() {
        val crew = buildMetaCrew(
            creators = listOf(member("Show Runner", "Writer", id = 9), member("  ", "Creator")),
            crew = emptyList(),
        )
        assertEquals(1, crew.size)
        assertEquals(MetaCrewCategory.CREATOR, crew.single().category)
    }

    @Test
    fun parserMapsAddonDirectorAndWriterIntoCrewWithoutIds() {
        val meta = MetaDetailsParser.parse(
            """
            {
              "meta": {
                "id": "tt1",
                "type": "movie",
                "name": "Film",
                "director": ["Jane Doe"],
                "writer": ["Jane Doe", "Bob Roe"]
              }
            }
            """.trimIndent(),
        )
        assertEquals(
            listOf("Jane Doe" to "Director", "Jane Doe" to "Writer", "Bob Roe" to "Writer"),
            meta.crew.map { it.name to it.job },
        )
        assertTrue(meta.crew.all { it.tmdbId == null })
        assertTrue(meta.creators.isEmpty())
        assertEquals("name:jane doe|director", meta.crew.first().creditKey)
    }

    @Test
    fun parserLeavesCrewEmptyWithoutAddonCredits() {
        val meta = MetaDetailsParser.parse(
            """{"meta":{"id":"tt2","type":"series","name":"Show"}}""",
        )
        assertTrue(meta.crew.isEmpty())
        assertTrue(meta.creators.isEmpty())
    }
}
