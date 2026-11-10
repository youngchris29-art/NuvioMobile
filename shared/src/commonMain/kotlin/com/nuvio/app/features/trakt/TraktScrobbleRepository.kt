package com.nuvio.app.features.trakt

import co.touchlab.kermit.Logger
import com.nuvio.app.core.build.AppVersionConfig
import com.nuvio.app.core.profile.ActiveProfileProvider
import com.nuvio.app.features.addons.httpRequestRaw
import com.nuvio.app.features.tracking.TrackingMediaKind
import com.nuvio.app.features.tracking.TrackingMediaReference
import com.nuvio.app.features.tracking.TrackingProviderId
import com.nuvio.app.features.tracking.TrackingProviderRegistry
import com.nuvio.app.features.tracking.TrackingScrobbleAction
import com.nuvio.app.features.tracking.TrackingScrobbleEvent
import com.nuvio.app.features.tracking.TrackingScrobbler
import com.nuvio.app.features.tracking.TrackingSeekScrobblePolicy
import com.nuvio.app.core.coroutines.uncaughtCoroutineLogger
import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.SupervisorJob
import com.nuvio.app.features.profiles.MAX_PROFILES
import kotlin.time.Instant
import kotlin.random.Random

sealed interface TraktScrobbleItem {
    val itemKey: String

    data class Movie(
        val title: String?,
        val year: Int?,
        val ids: TraktExternalIds,
    ) : TraktScrobbleItem {
        override val itemKey: String =
            "movie:${ids.imdb ?: ids.tmdb ?: ids.trakt ?: title.orEmpty()}:${year ?: 0}"
    }

    data class Episode(
        val showTitle: String?,
        val showYear: Int?,
        val showIds: TraktExternalIds,
        val season: Int,
        val number: Int,
        val episodeTitle: String?,
    ) : TraktScrobbleItem {
        override val itemKey: String =
            "episode:${showIds.imdb ?: showIds.tmdb ?: showIds.trakt ?: showTitle.orEmpty()}:$season:$number"
    }
}

// Fork: public (upstream: internal) — shared tests consume these cross-module.
data class TraktEpisodeMappingInput(
    val contentId: String,
    val contentType: String,
    val videoId: String?,
    val season: Int,
    val episode: Int,
    val episodeTitle: String?,
)

fun TrackingMediaReference.toTraktEpisodeMappingInput(): TraktEpisodeMappingInput? {
    val episodeReference = episode ?: return null
    val season = episodeReference.season ?: return null
    val contentId = catalog?.contentId?.takeIf(String::isNotBlank)
        ?: ids.imdb?.takeIf(String::isNotBlank)
        ?: ids.tmdb?.let { value -> "tmdb:$value" }
        ?: ids.trakt?.let { value -> "trakt:$value" }
        ?: return null
    return TraktEpisodeMappingInput(
        contentId = contentId,
        contentType = catalog?.contentType?.takeIf(String::isNotBlank) ?: "series",
        videoId = catalog?.videoId?.takeIf(String::isNotBlank),
        season = season,
        episode = episodeReference.number,
        episodeTitle = episodeReference.title,
    )
}

object TraktScrobbleRepository : TrackingScrobbler {
    override val providerId: TrackingProviderId = TrackingProviderId.TRAKT
    override val seekScrobblePolicy: TrackingSeekScrobblePolicy =
        TrackingSeekScrobblePolicy.STOP_AND_RESTART

    private val log = Logger.withTag("TraktScrobble")

    private val scope = CoroutineScope(
        SupervisorJob() + Dispatchers.Default + uncaughtCoroutineLogger("TraktScrobbleRepository"),
    )

    /** The request path, write-ahead queue and replay (BUG-220), wired to the real singletons. */
    private val engine = TraktScrobbleEngine(
        activeProfileId = { ActiveProfileProvider.activeProfileId },
        authorizedHeaders = { TraktAuthRepository.authorizedHeaders() },
        isAuthenticated = { TraktAuthRepository.isAuthenticated.value },
        authenticatedChanges = { TraktAuthRepository.isAuthenticated },
        accountSlug = { TraktAuthRepository.currentUserSlug() },
        refreshAccount = {
            runCatching { TraktAuthRepository.refreshUserSettings() }
                .onFailure { error -> if (error is CancellationException) throw error }
        },
        http = { method, url, body, headers ->
            runCatching { httpRequestRaw(method = method, url = url, headers = headers, body = body) }
                .onFailure { error ->
                    if (error is CancellationException) throw error
                    log.w(error) { "Trakt $method ${url.substringBefore('?')} transport failure" }
                }
                .getOrNull()
                ?.let { response ->
                    TraktHttpReply(
                        status = response.status,
                        statusText = response.statusText,
                        body = response.body,
                        url = response.url,
                        headers = response.headers,
                    )
                }
        },
        refreshProgress = {
            runCatching { TraktProgressRepository.invalidateAndRefresh() }
                .onFailure { error ->
                    if (error is CancellationException) throw error
                    log.w { "Failed to refresh Trakt progress after stop: ${error.message}" }
                }
        },
        queue = TraktPendingScrobbleStopQueue(
            load = TraktPendingScrobbleStopStorage::load,
            save = TraktPendingScrobbleStopStorage::save,
            clear = TraktPendingScrobbleStopStorage::clear,
            now = TraktPlatformClock::nowEpochMs,
        ),
        now = TraktPlatformClock::nowEpochMs,
        newId = { "${TraktPlatformClock.nowEpochMs()}-${Random.nextInt(0, Int.MAX_VALUE)}" },
        scope = scope,
        appVersion = AppVersionConfig.VERSION_NAME,
        parseIsoMs = TraktPlatformClock::parseIsoDateTimeToEpochMs,
        formatIsoMs = { ms -> Instant.fromEpochMilliseconds(ms).toString() },
        trace = ::trace,
        debug = { message -> log.d { message() } },
        warn = { message -> log.w { message } },
    )

    /**
     * BUG-220 queue/replay lines. Kermit goes to os_log on Apple, which the device console pipe
     * (`devicectl --console`, scripts/device/console.sh) cannot see, so these are mirrored to
     * stdout (the SubtitleRepository precedent). They carry item keys and progress, never headers.
     */
    private fun trace(message: String) {
        log.i { message }
        println("[TraktScrobble] $message")
    }

    init {
        TrackingProviderRegistry.registerScrobbler(this)
    }

    /** Forces this object's initializer (and therefore its registry registration) to run. */
    fun ensureRegistered() = Unit

    /**
     * Provider-neutral scrobble entry point used by [TrackingScrobbleCoordinator].
     *
     * Phase 1 note: the player still calls [scrobbleStart]/[scrobbleStop] directly, so this path
     * is the registered seam rather than the live one. Both funnel into the same [sendScrobble]
     * dedupe/retry machinery, so wiring the coordinator up later changes no Trakt behaviour.
     */
    override suspend fun scrobble(
        profileId: Int,
        action: TrackingScrobbleAction,
        event: TrackingScrobbleEvent,
    ) {
        val item = buildItem(event.media) ?: return
        sendScrobble(
            profileId = profileId,
            action = action.wireValue,
            item = item,
            progressPercent = event.progressPercent.toFloat(),
        )
    }

    private suspend fun buildItem(media: TrackingMediaReference): TraktScrobbleItem? {
        val ids = TraktExternalIds(
            trakt = media.ids.trakt?.toTraktIntOrNull(),
            imdb = media.ids.imdb?.takeIf(String::isNotBlank),
            tmdb = media.ids.tmdb?.toTraktIntOrNull(),
        )
        if (!ids.hasAnyId()) return null
        if (media.kind == TrackingMediaKind.MOVIE) {
            return TraktScrobbleItem.Movie(
                title = media.title,
                year = media.year,
                ids = ids,
            )
        }

        val mappingInput = media.toTraktEpisodeMappingInput() ?: return null
        val mappedEpisode = TraktEpisodeMappingService.resolveEpisodeMapping(
            contentId = mappingInput.contentId,
            contentType = mappingInput.contentType,
            videoId = mappingInput.videoId,
            season = mappingInput.season,
            episode = mappingInput.episode,
            episodeTitle = mappingInput.episodeTitle,
        )
        return TraktScrobbleItem.Episode(
            showTitle = media.title,
            showYear = media.year,
            showIds = ids,
            season = mappedEpisode?.season ?: mappingInput.season,
            number = mappedEpisode?.episode ?: mappingInput.episode,
            episodeTitle = mappingInput.episodeTitle,
        )
    }

    suspend fun scrobbleStart(profileId: Int, item: TraktScrobbleItem, progressPercent: Float) {
        sendScrobble(profileId = profileId, action = "start", item = item, progressPercent = progressPercent)
    }

    suspend fun scrobbleStop(profileId: Int, item: TraktScrobbleItem, progressPercent: Float) {
        sendScrobble(profileId = profileId, action = "stop", item = item, progressPercent = progressPercent)
    }

    /**
     * BUG-231: the playing session's position, called by the players on their progress tick. With
     * Trakt as the watch progress source the resume position exists only on Trakt, and Trakt
     * learns it from the session's stop; a crash or force-quit never sends one. This keeps the
     * position as a provisional pending stop (throttled in the outbox) that the next launch
     * replays. Nothing is sent to Trakt here.
     */
    suspend fun noteSessionProgress(profileId: Int, item: TraktScrobbleItem, progressPercent: Float): Boolean =
        engine.noteSessionProgress(profileId, item, progressPercent)

    suspend fun buildItem(
        contentType: String,
        parentMetaId: String,
        videoId: String?,
        title: String?,
        seasonNumber: Int?,
        episodeNumber: Int?,
        episodeTitle: String?,
        releaseInfo: String? = null,
    ): TraktScrobbleItem? {
        val normalizedType = contentType.trim().lowercase()
        var ids = parseTraktContentIds(parentMetaId)

        // Fallback: if parentMetaId doesn't resolve to valid Trakt IDs, try videoId.
        // Some addons use non-standard contentId (e.g. "tun_tt7821582") but set a
        // valid IMDB/TMDB videoId (e.g. "tt7821582:3:7").
        if (!ids.hasAnyId() && !videoId.isNullOrBlank() && videoId != parentMetaId) {
            ids = parseTraktContentIds(videoId)
        }

        // Don't send scrobble if we still have no valid Trakt IDs — would cause
        // title-based fuzzy match on Trakt API resulting in wrong show matched.
        if (!ids.hasAnyId()) return null

        val parsedYear = extractTraktYear(releaseInfo)

        return if (
            normalizedType in listOf("series", "tv", "show", "tvshow") &&
            seasonNumber != null &&
            episodeNumber != null
        ) {
            val mappedEpisode = TraktEpisodeMappingService.resolveEpisodeMapping(
                contentId = parentMetaId,
                contentType = contentType,
                videoId = videoId,
                season = seasonNumber,
                episode = episodeNumber,
                episodeTitle = episodeTitle,
            )
            TraktScrobbleItem.Episode(
                showTitle = title,
                showYear = parsedYear,
                showIds = ids,
                season = mappedEpisode?.season ?: seasonNumber,
                number = mappedEpisode?.episode ?: episodeNumber,
                episodeTitle = episodeTitle,
            )
        } else {
            TraktScrobbleItem.Movie(
                title = title,
                year = parsedYear,
                ids = ids,
            )
        }
    }

    private suspend fun sendScrobble(
        profileId: Int,
        action: String,
        item: TraktScrobbleItem,
        progressPercent: Float,
    ) = engine.send(profileId, action, item, progressPercent)

    // ── BUG-220 pending-stop replay ─────────────────────────────────────────────────────────

    /**
     * Profile-selection hook (tvOS fan-out after `traktAuth`, composeApp's adapter): every launch
     * enters through it, so this is the launch drain. The first call arms the auth watcher, which
     * drains again whenever Trakt auth turns on (device-flow connect, credential sync pull).
     */
    fun onProfileChanged(profileId: Int) = engine.onProfileChanged(profileId)

    fun requestPendingStopReplay(profileId: Int = ActiveProfileProvider.activeProfileId) =
        engine.requestReplay(profileId)

    suspend fun replayPendingStops(profileId: Int = ActiveProfileProvider.activeProfileId): TraktPendingStopDrainResult =
        engine.replay(profileId)

    /** Trakt disconnect: never replay this profile's stops into the next account connected. */
    suspend fun clearPendingStops(profileId: Int) = engine.clearPendingStops(profileId)

    /** Profile removal (non-suspending caller). */
    fun clearPendingStopsAsync(profileId: Int) = engine.clearPendingStopsAsync(profileId)

    /** Sign-out: every profile slot's queue (the keys themselves are erased via AccountDataStores). */
    fun clearLocalState() = engine.onAccountDataWiped(1..MAX_PROFILES)
}

private fun Long.toTraktIntOrNull(): Int? = takeIf { value -> value in 1L..Int.MAX_VALUE.toLong() }?.toInt()
