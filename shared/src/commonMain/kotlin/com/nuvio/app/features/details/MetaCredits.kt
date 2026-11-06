package com.nuvio.app.features.details

/**
 * Which crew group a [MetaCrewMember] belongs to, in display order: creators (series) first, then
 * directors, writers and producers. Frontends map it to a localized label; [MetaCrewMember.job]
 * keeps the provider's own job string ("Screenplay", "Executive Producer").
 */
enum class MetaCrewCategory {
    CREATOR,
    DIRECTOR,
    WRITER,
    PRODUCER,
    ;

    companion object {
        /** The category of a TMDB crew job, or null for jobs the detail page does not show. */
        fun fromJob(job: String?): MetaCrewCategory? =
            when (job?.trim()?.lowercase()) {
                "creator" -> CREATOR
                "director" -> DIRECTOR
                "writer", "screenplay", "story", "teleplay" -> WRITER
                "producer", "executive producer" -> PRODUCER
                else -> null
            }
    }
}

/**
 * One crew credit on the detail page (C10/C12): a creator, director, writer or producer. Separate
 * from [MetaPerson] so the Swift-visible `MetaPerson` initializer keeps its shape.
 */
data class MetaCrewMember(
    val name: String,
    /** Provider job string: "Creator", "Director", "Screenplay", "Executive Producer", ... */
    val job: String,
    val category: MetaCrewCategory,
    /** TMDB department ("Directing", "Writing", "Production"); null for creators and add-on data. */
    val department: String? = null,
    val photo: String? = null,
    /** TMDB person id; null for add-on supplied names. */
    val tmdbId: Int? = null,
) {
    /**
     * Stable identity for focus memory and dedupe: person id + job, or the lowercased name + job
     * when there is no id. The same person under two jobs gets two keys.
     */
    val creditKey: String
        get() = metaCreditKey(tmdbId = tmdbId, name = name, job = job)
}

/** Stable key for a person under one job (see [MetaCrewMember.creditKey]). */
fun metaCreditKey(tmdbId: Int?, name: String, job: String?): String {
    val normalizedJob = job?.trim()?.lowercase().orEmpty()
    return if (tmdbId != null) {
        "tmdb:$tmdbId|$normalizedJob"
    } else {
        "name:${name.trim().lowercase()}|$normalizedJob"
    }
}

/** Upper bound on the detail page's crew list. */
const val META_CREW_LIMIT: Int = 12

/** Per-category cap so one long list (e.g. a series' episode directors) cannot fill the row. */
private const val META_CREW_PER_CATEGORY_LIMIT: Int = 4

/**
 * Orders and trims crew for the detail page: [creators] first, then [crew] grouped as directors,
 * writers, producers, each group in its input order (pass TMDB order, or episode count descending
 * for series). A person appears once per category (the first job wins, so "Screenplay" and "Story"
 * by one writer collapse into one card), and once per [MetaCrewMember.creditKey]. Each group is
 * capped at four and the whole list at [limit].
 */
fun buildMetaCrew(
    creators: List<MetaCrewMember>,
    crew: List<MetaCrewMember>,
    limit: Int = META_CREW_LIMIT,
): List<MetaCrewMember> {
    val all = creators.map { it.copy(category = MetaCrewCategory.CREATOR) } + crew
    val seenCredits = mutableSetOf<String>()
    val seenPersonInCategory = mutableSetOf<String>()
    val result = mutableListOf<MetaCrewMember>()
    for (category in MetaCrewCategory.entries) {
        var taken = 0
        for (member in all) {
            if (member.category != category) continue
            if (taken >= META_CREW_PER_CATEGORY_LIMIT || result.size >= limit) break
            val name = member.name.trim()
            if (name.isEmpty()) continue
            val personKey = metaCreditKey(member.tmdbId, name, null) + "|" + category.name
            if (!seenCredits.add(member.creditKey) || !seenPersonInCategory.add(personKey)) continue
            result += if (name == member.name) member else member.copy(name = name)
            taken++
        }
    }
    return result
}

/**
 * Add-on meta fallback: the `director` / `writer` name lists as crew entries without ids, used
 * when TMDB credits are absent.
 */
fun addonMetaCrew(directors: List<String>, writers: List<String>): List<MetaCrewMember> =
    buildMetaCrew(
        creators = emptyList(),
        crew = directors.map { name ->
            MetaCrewMember(name = name, job = "Director", category = MetaCrewCategory.DIRECTOR)
        } + writers.map { name ->
            MetaCrewMember(name = name, job = "Writer", category = MetaCrewCategory.WRITER)
        },
    )
