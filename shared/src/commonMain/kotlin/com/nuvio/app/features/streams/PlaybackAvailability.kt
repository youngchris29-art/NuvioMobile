package com.nuvio.app.features.streams

import com.nuvio.app.core.build.FeaturePolicyProvider
import com.nuvio.app.features.addons.AddonManifest
import com.nuvio.app.features.addons.AddonRepository
import com.nuvio.app.features.addons.ManagedAddon
import com.nuvio.app.features.details.MetaDetailsRepository
import com.nuvio.app.features.downloads.DownloadsRepository
import com.nuvio.app.features.plugins.PluginScraper
import com.nuvio.app.features.plugins.PluginScraperHostProvider
import com.nuvio.app.features.plugins.PluginsUiState

/**
 * Ported from upstream `972109f9` ("fix(playback): disable play when no source is available",
 * composeApp `features/streams/PlaybackAvailability.kt`) into `:shared` so the tvOS frontend can
 * grey out its Play button exactly as upstream's Compose screens do.
 *
 * Left out on purpose:
 * - The `@Composable rememberPlaybackAvailability()` wrapper (`collectAsStateWithLifecycle` has no
 *   tvOS/SwiftUI equivalent through this seam). The Swift call site re-derives a fresh
 *   [PlaybackAvailability] via [current] whenever it needs a fresh read instead.
 * - Upstream reads plugin state via a composeApp-only `PluginRepository` singleton, which has no
 *   commonMain home. `:shared` already factors that exact seam out as [PluginScraperHostProvider]
 *   (see `StreamsRepository.kt`'s `load()`), so [current] goes through the host instead.
 * - The `StreamsRepository.kt`/`StreamsScreen.kt`/`MetaDetailsScreen.kt`/`DetailActionButtons.kt`
 *   halves of the upstream commit are Compose-UI wiring with no `:shared` footprint here; the
 *   fork's `StreamsRepository.kt:192-211` BUG-74 id-remap block is untouched by this file and must
 *   stay exactly as it is (see the fork-only [StreamVideoIdRemap] used below, which upstream does
 *   not have — it did not exist yet when `972109f9` was written).
 *
 * **Deliberate fork deviation — the gate FAILS OPEN on a remappable id.** Upstream's predicate is
 * a plain "does an enabled addon accept this exact id", which on this fork would disable Play for
 * a case that demonstrably works: with only `tt`-prefix stream addons installed, a `tmdb:550`
 * title matches nothing here, yet `StreamsRepository.load()` resolves the IMDb id and asks those
 * very addons (BUG-74). The gate is synchronous and the remap needs a TMDB round-trip, so it
 * cannot know whether the title HAS an IMDb id — it answers on reachability instead, via the same
 * [StreamVideoIdRemap.wouldReachMoreAddons] predicate the repository triggers the remap on. A
 * title whose remap then fails lands on the Streams screen's own empty state, which is upstream's
 * pre-`972109f9` behaviour; disabling Play on a title that plays fine would be the worse bug.
 * Ids the remap does not apply to are unaffected: a `kitsu:` id, or a `tmdb:` id with no `tt`
 * addon to reach, still reads as unavailable.
 */

/**
 * Whether this manifest declares a `stream` resource that can serve [type]/[videoId]. Delegates
 * the id-prefix check to [StreamVideoIdRemap.accepts] (the fork's BUG-74 predicate — an empty
 * prefix list means "accepts anything", same manifest convention upstream's inline check used).
 */
fun AddonManifest.supportsStream(type: String, videoId: String): Boolean =
    resources.any { resource ->
        resource.name == "stream" &&
            resource.types.contains(type) &&
            StreamVideoIdRemap.accepts(resource.idPrefixes, videoId)
    }

/**
 * Fork: whether an enabled addon that cannot take [videoId] as-is WOULD be asked for it after
 * `StreamsRepository.load()`'s BUG-74 remap — the fail-open half of the gate (see the file header).
 *
 * Built exactly like the repository's own trigger: the `stream` resources for [type], their
 * declared id prefixes, addons declaring none dropped (they accept anything, so
 * [supportsStream] already answered for them), then [StreamVideoIdRemap.wouldReachMoreAddons].
 * That predicate is `tmdb:`-only, so every other id shape answers false here.
 */
private fun anyAddonReachableAfterRemap(
    addons: List<ManagedAddon>,
    type: String,
    videoId: String,
): Boolean {
    val streamIdPrefixes = addons.mapNotNull { addon ->
        if (!addon.enabled) return@mapNotNull null
        addon.manifest?.resources
            ?.filter { it.name == "stream" && it.types.contains(type) }
            ?.flatMap { it.idPrefixes }
            ?.takeIf { it.isNotEmpty() }
    }
    return StreamVideoIdRemap.wouldReachMoreAddons(videoId, streamIdPrefixes)
}

/** Fork: [supportsStream] across the enabled addons, plus the remap fail-open above. */
private fun anyAddonCanStream(
    addons: List<ManagedAddon>,
    type: String,
    videoId: String,
): Boolean = addons.any { it.enabled && it.manifest?.supportsStream(type, videoId) == true } ||
    anyAddonReachableAfterRemap(addons, type, videoId)

/**
 * Upstream-shaped predicate, matching `972109f9`'s free function of the same name apart from the
 * documented remap fail-open, kept so upstream's 5-case `PlaybackAvailabilityTest.kt` ports
 * unchanged (none of its cases uses a `tmdb:` id, so none of them changes answer).
 * [PlaybackAvailability] itself does not call this overload — see the [PluginScraper]-list overload
 * below, fed by the fork's [PluginScraperHostProvider] seam.
 */
fun hasCompatiblePlaybackSource(
    addons: List<ManagedAddon>,
    plugins: PluginsUiState,
    type: String,
    videoId: String,
): Boolean = anyAddonCanStream(addons, type, videoId) ||
    (plugins.pluginsEnabled && plugins.scrapers.any { it.enabled && it.supportsType(type) })

/**
 * Same predicate, shaped for callers that already have a type-filtered scraper list (the
 * `PluginScraperHost.getEnabledScrapersForType(type)` seam already returns only enabled scrapers
 * that support [type] — see `StreamsRepository.kt:169-173` for the precedent). The `enabled`/
 * `supportsType` check is kept anyway as defense in depth rather than trusting the caller's filter.
 */
fun hasCompatiblePlaybackSource(
    addons: List<ManagedAddon>,
    enabledScrapersForType: List<PluginScraper>,
    type: String,
    videoId: String,
): Boolean = anyAddonCanStream(addons, type, videoId) ||
    enabledScrapersForType.any { it.enabled && it.supportsType(type) }

/**
 * Whether a title can be played at all right now, from any source: an installed addon, an enabled
 * plugin scraper, an embedded (meta-provided) stream, or a local download. Build one via [current]
 * for a given `type`/`videoId` pair; construct directly only from tests.
 */
class PlaybackAvailability(
    private val addons: List<ManagedAddon>,
    private val enabledScrapersForType: List<PluginScraper>,
) {
    /** True when an addon, a plugin scraper, or an embedded meta stream can serve [type]/[videoId]. */
    fun canStream(type: String, videoId: String): Boolean =
        hasCompatiblePlaybackSource(addons, enabledScrapersForType, type, videoId) ||
            MetaDetailsRepository.findEmbeddedStreams(videoId).isNotEmpty()

    /**
     * [canStream] plus a locally downloaded file for this title (or this season/episode, when
     * [seasonNumber]/[episodeNumber] are given). Mirrors `DetailViewModel`'s series-action shape:
     * pass the specific episode's `videoId`/season/episode for a series, or nulls for a movie.
     */
    fun canPlay(
        type: String,
        videoId: String,
        parentMetaId: String,
        seasonNumber: Int? = null,
        episodeNumber: Int? = null,
    ): Boolean = canStream(type, videoId) || DownloadsRepository.findPlayableDownload(
        parentMetaId = parentMetaId,
        seasonNumber = seasonNumber,
        episodeNumber = episodeNumber,
        videoId = videoId,
    ) != null

    companion object {
        /**
         * Builds a [PlaybackAvailability] for [type] from live repository state: every installed
         * addon ([AddonRepository]) and, when plugins are enabled for this build
         * ([FeaturePolicyProvider]), every enabled scraper that supports [type]
         * ([PluginScraperHostProvider]). tvOS has no `PluginRepository` — [FeaturePolicyProvider]'s
         * default policy leaves `pluginsEnabled = false`, so this is `emptyList()` there today; the
         * seam is honoured anyway so a future tvOS plugin host needs no change here.
         *
         * Call [current] again for a different `type` — the returned instance's scraper list is
         * already filtered to the `type` it was built with, so [canStream]/[canPlay] should be
         * called with that same `type`.
         */
        fun current(type: String): PlaybackAvailability = PlaybackAvailability(
            addons = AddonRepository.uiState.value.addons,
            enabledScrapersForType = if (FeaturePolicyProvider.policy.pluginsEnabled) {
                PluginScraperHostProvider.host.getEnabledScrapersForType(type)
            } else {
                emptyList()
            },
        )
    }
}
