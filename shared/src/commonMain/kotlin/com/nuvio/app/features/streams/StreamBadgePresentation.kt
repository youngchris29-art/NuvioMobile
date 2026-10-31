package com.nuvio.app.features.streams

import com.nuvio.app.features.player.PlaybackMatchText
import kotlinx.atomicfu.locks.SynchronizedObject
import kotlinx.atomicfu.locks.synchronized

object StreamBadgePresentation {
    private val streamFilters = CompiledFilterCache()
    private val playerFilters = CompiledFilterCache()

    fun apply(groups: List<AddonStreamGroup>, rules: StreamBadgeRules): List<AddonStreamGroup> {
        // Each addon group is presented on its own with the same rules, so their regexes are
        // compiled once and reused until the rules change.
        val filters = streamFilters.filtersFor(rules)
        if (filters.isEmpty()) return groups
        return groups.map { group ->
            group.copy(
                streams = group.streams.map { stream ->
                    val matchedBadges = StreamBadgeMatcher.matchedBadges(stream, filters)
                    if (matchedBadges.isEmpty()) {
                        stream
                    } else {
                        stream.copy(badges = mergeBadges(stream.badges, matchedBadges))
                    }
                },
            )
        }
    }

    /**
     * Badges for what is playing, matched against the pack chosen for the player
     * ([playerBadgeSource], blank = the stream list's pack). [playbackText] is what the decoder
     * reports (see `PlaybackMatchText.build`) and [audioProfiles] the profiles passed to it, so the
     * refine never contradicts a DTS variant the decoder named; [metaCandidates] are the stream's
     * file name and title lines, each kept apart so one candidate's lookaheads never see another's
     * text. The playback
     * text is refined from them first (`PlaybackMatchText.refinePlaybackText`), then matched in two
     * phases (`StreamBadgeMatcher.matchedPlayerBadges`, upstream a744911a): a filter in a group the
     * decoder already covered never matches from the file name. The player pack has its own
     * compiled-filter slot, so the stream list and the player never evict each other.
     */
    fun playerBadges(
        rules: StreamBadgeRules,
        playerBadgeSource: String,
        playbackText: String,
        audioProfiles: List<String>,
        metaCandidates: List<String>,
    ): List<StreamBadge> {
        val meta = metaCandidates.map { it.replace(whitespace, " ").trim() }.filter { it.isNotEmpty() }
        if (playbackText.isBlank() && meta.isEmpty()) return emptyList()
        val filters = playerFilters.filtersFor(rules, playerBadgeSource)
        if (filters.isEmpty()) return emptyList()
        val playback = PlaybackMatchText.refinePlaybackText(playbackText, audioProfiles, meta).takeIf { it.isNotBlank() }
        // A pack filter with a name but no image would render as an empty chip in the player
        // (upstream 344117e73 / 83e528f00 / NuvioTV 13683564d drop them).
        return StreamBadgeMatcher.matchedPlayerBadges(playback, meta, filters)
            .filter { it.imageURL.isNotBlank() }
    }

    private val whitespace = Regex("\\s+")

    private class CompiledFilterCache {
        private val lock = SynchronizedObject()
        private var cachedRules: StreamBadgeRules? = null
        private var cachedSource: String = ""
        private var cachedFilters: List<CompiledStreamBadgeFilter> = emptyList()

        // `==` on the data class short-circuits on the same instance, so the repeated
        // calls with the repository's published rules never walk the rule set.
        fun filtersFor(rules: StreamBadgeRules, playerSource: String? = null): List<CompiledStreamBadgeFilter> =
            synchronized(lock) {
                val source = playerSource.orEmpty()
                if (cachedRules != rules || cachedSource != source) {
                    cachedFilters = StreamBadgeMatcher.compile(
                        if (playerSource == null) rules else rules.forPlayer(source),
                    )
                    cachedRules = rules
                    cachedSource = source
                }
                cachedFilters
            }
    }

    private fun mergeBadges(existing: List<StreamBadge>, matched: List<StreamBadge>): List<StreamBadge> {
        if (existing.isEmpty()) return matched
        val seenKeys = existing.mapTo(mutableSetOf()) { it.dedupeKey() }
        return existing + matched.filter { badge -> seenKeys.add(badge.dedupeKey()) }
    }

    private fun StreamBadge.dedupeKey(): String =
        (imageURL.takeIf { it.isNotBlank() } ?: name).lowercase()
}
