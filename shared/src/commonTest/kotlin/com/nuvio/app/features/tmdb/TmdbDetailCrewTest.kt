package com.nuvio.app.features.tmdb

import com.nuvio.app.features.details.MetaCrewCategory
import com.nuvio.app.features.details.MetaCrewMember
import com.nuvio.app.features.details.MetaDetails
import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertNotNull
import kotlin.test.assertNull
import kotlin.test.assertTrue

class TmdbDetailCrewTest {

    @Test
    fun movieCreditsCrewIsFilteredOrderedAndDeduped() {
        val (creators, crew) = tmdbDetailCrewFromJson(
            mediaType = "movie",
            detailsJson = """{"title":"Film","created_by":[{"id":99,"name":"Ignored"}]}""",
            creditsJson = """
                {
                  "cast": [{"id": 50, "name": "Actor", "character": "Hero"}],
                  "crew": [
                    {"id": 1, "name": "Pat Producer", "job": "Producer", "department": "Production"},
                    {"id": 2, "name": "Sam Screen", "job": "Screenplay", "department": "Writing", "profile_path": "/s.jpg"},
                    {"id": 3, "name": "Dana Director", "job": "Director", "department": "Directing"},
                    {"id": 2, "name": "Sam Screen", "job": "Story", "department": "Writing"},
                    {"id": 3, "name": "Dana Director", "job": "Director", "department": "Directing"},
                    {"id": 4, "name": "Eve Exec", "job": "Executive Producer", "department": "Production"},
                    {"id": 5, "name": "Cam Op", "job": "Director of Photography", "department": "Camera"},
                    {"id": 6, "name": "   ", "job": "Writer"}
                  ]
                }
            """.trimIndent(),
        )

        assertTrue(creators.isEmpty(), "films have no creators")
        assertEquals(
            listOf(
                "Dana Director" to "Director",
                "Sam Screen" to "Screenplay",
                "Pat Producer" to "Producer",
                "Eve Exec" to "Executive Producer",
            ),
            crew.map { it.name to it.job },
        )
        assertEquals(listOf("Directing", "Writing", "Production", "Production"), crew.map { it.department })
        assertEquals("tmdb:3|director", crew.first().creditKey)
        assertNotNull(crew[1].photo)
        assertNull(crew[0].photo)
    }

    @Test
    fun seriesCreatedByBecomesCreatorsAndLeadsAggregateCrew() {
        val (creators, crew) = tmdbDetailCrewFromJson(
            mediaType = "tv",
            detailsJson = """
                {
                  "name": "Show",
                  "created_by": [
                    {"id": 10, "name": "Casey Creator", "profile_path": "/c.jpg"},
                    {"name": "Unknown Id Creator"}
                  ]
                }
            """.trimIndent(),
            creditsJson = """
                {
                  "cast": [],
                  "crew": [
                    {"id": 10, "name": "Casey Creator", "department": "Writing",
                     "jobs": [{"job": "Creator", "episode_count": 10}, {"job": "Writer", "episode_count": 5}]},
                    {"id": 20, "name": "Rare Director", "department": "Directing",
                     "jobs": [{"job": "Director", "episode_count": 1}]},
                    {"id": 30, "name": "Regular Director", "department": "Directing",
                     "jobs": [{"job": "Director", "episode_count": 8}]},
                    {"id": 40, "name": "Big Exec", "department": "Production",
                     "jobs": [{"job": "Executive Producer", "episode_count": 20}]},
                    {"name": "Idless Writer", "department": "Writing",
                     "jobs": [{"job": "Teleplay", "episode_count": 3}]},
                    {"id": 50, "name": "Editor", "department": "Editing",
                     "jobs": [{"job": "Editor", "episode_count": 30}]}
                  ]
                }
            """.trimIndent(),
        )

        assertEquals(listOf("Casey Creator", "Unknown Id Creator"), creators.map(MetaCrewMember::name))
        assertTrue(creators.all { it.job == "Creator" && it.category == MetaCrewCategory.CREATOR })
        assertEquals(listOf(10, null), creators.map(MetaCrewMember::tmdbId))
        assertEquals("name:unknown id creator|creator", creators[1].creditKey)

        assertEquals(
            listOf(
                "Casey Creator" to "Creator",
                "Unknown Id Creator" to "Creator",
                "Regular Director" to "Director",
                "Rare Director" to "Director",
                "Casey Creator" to "Writer",
                "Idless Writer" to "Teleplay",
                "Big Exec" to "Executive Producer",
            ),
            crew.map { it.name to it.job },
        )
        // The aggregate "Creator" job for id 10 dedupes into the created_by entry.
        assertEquals(1, crew.count { it.creditKey == "tmdb:10|creator" })
        assertEquals("name:idless writer|teleplay", crew.single { it.name == "Idless Writer" }.creditKey)
        assertEquals(crew.size, crew.map(MetaCrewMember::creditKey).toSet().size)
    }

    @Test
    fun applyEnrichmentPrefersTmdbCrewAndKeepsAddonCrewWhenTmdbHasNone() {
        val addonCrew = listOf(
            MetaCrewMember(name = "Addon Dir", job = "Director", category = MetaCrewCategory.DIRECTOR),
        )
        val meta = MetaDetails(id = "tt1", type = "movie", name = "Film", crew = addonCrew)
        val tmdbCrew = listOf(
            MetaCrewMember(name = "Tmdb Dir", job = "Director", category = MetaCrewCategory.DIRECTOR, tmdbId = 7),
        )

        val withTmdb = TmdbMetadataService.applyEnrichment(
            meta = meta,
            enrichment = enrichment(crew = tmdbCrew),
            episodeMap = emptyMap(),
            settings = TmdbSettings(enabled = true),
        )
        assertEquals(tmdbCrew, withTmdb.crew)

        val withoutTmdb = TmdbMetadataService.applyEnrichment(
            meta = meta,
            enrichment = enrichment(crew = emptyList()),
            episodeMap = emptyMap(),
            settings = TmdbSettings(enabled = true),
        )
        assertEquals(addonCrew, withoutTmdb.crew)

        val creditsOff = TmdbMetadataService.applyEnrichment(
            meta = meta,
            enrichment = enrichment(crew = tmdbCrew),
            episodeMap = emptyMap(),
            settings = TmdbSettings(enabled = true, useCredits = false),
        )
        assertEquals(addonCrew, creditsOff.crew)
    }

    private fun enrichment(crew: List<MetaCrewMember>): TmdbEnrichment = TmdbEnrichment(
        localizedTitle = "Film",
        description = null,
        genres = emptyList(),
        backdrop = null,
        logo = null,
        poster = null,
        people = emptyList(),
        director = emptyList(),
        writer = emptyList(),
        releaseInfo = null,
        rating = null,
        runtimeMinutes = null,
        ageRating = null,
        status = null,
        countries = emptyList(),
        language = null,
        productionCompanies = emptyList(),
        networks = emptyList(),
        crew = crew,
    )
}
