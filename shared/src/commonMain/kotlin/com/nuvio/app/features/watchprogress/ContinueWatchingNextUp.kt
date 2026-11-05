package com.nuvio.app.features.watchprogress

import co.touchlab.kermit.Logger
import com.nuvio.app.features.details.MetaDetails
import com.nuvio.app.features.details.MetaDetailsRepository
import com.nuvio.app.features.details.MetaVideo
import com.nuvio.app.features.details.seriesPrimaryAction
import com.nuvio.app.features.profiles.ProfileRepository
import com.nuvio.app.features.tracking.WatchProgressSource
import com.nuvio.app.features.trakt.TraktSettingsRepository
import com.nuvio.app.features.watched.WatchedItem
import com.nuvio.app.features.watched.WatchedRepository
import com.nuvio.app.features.watched.normalizeWatchedMarkedAtEpochMs
import com.nuvio.app.features.watching.domain.WatchingContentRef
import kotlinx.atomicfu.locks.SynchronizedObject
import kotlinx.atomicfu.locks.synchronized
import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.delay
import kotlinx.coroutines.launch
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.async
import kotlinx.coroutines.awaitAll
import kotlinx.coroutines.coroutineScope
import kotlinx.coroutines.sync.Mutex
import kotlinx.coroutines.sync.Semaphore
import kotlinx.coroutines.sync.withLock
import kotlinx.coroutines.sync.withPermit
import kotlinx.coroutines.withContext

/**
 * tvOS "Up Next" for the Home Continue Watching row (FEAT-85, based on erdist's patch, GitHub #11).
 *
 * The shared row ([buildContinueWatchingRowEntries]) only lists titles that are started and not
 * finished, so a series drops out of the row as soon as an episode ends. Mobile fills the gap inside
 * composeApp's `HomeScreen.kt` (next-up items built per series); tvOS can't use that code, so this
 * is the same idea in :shared:
 *
 * 1. Seeds: per series, the latest completed episode, from watch progress (provider-aware via
 *    [WatchProgressRepository.shouldUseAsNextUpSeed]) plus watched history (not under Trakt, where
 *    mobile leaves local history out because Trakt's own projection carries it).
 * 2. A series is skipped when it already has an in-progress episode at least as recent as that
 *    completion (the in-progress card is the right one to show), when the active provider hides it,
 *    when it is outside the provider's recency window, or when its next-up was dismissed (the same
 *    profile-synced `dismissedNextUpKeys` mobile uses, so a dismissal on either device holds on both).
 * 3. The next episode comes from the same shared `seriesPrimaryAction` Detail's Play button uses,
 *    honouring the synced "Up next from furthest episode" and "Show unaired next up" preferences.
 *
 * Each result is a synthetic [WatchProgressEntry] at position 0 (source [WatchProgressSourceNextUp]),
 * so the existing Continue Watching cards and resume path play it from the start unchanged. Nothing
 * here is persisted: the entries are rebuilt from progress, history and preferences.
 */
const val WatchProgressSourceNextUp = "nuvio_next_up"

/** How many series are resolved per refresh (each new seed is one metadata fetch). */
const val ContinueWatchingNextUpResolveLimit = 20

/**
 * How long an episode marked watched from a Continue Watching card counts as a seed under Trakt
 * before Trakt's own progress has it (review P2-4). Trakt history usually lands in seconds; the
 * window only has to outlast a slow sync, and an expired mark that Trakt never confirmed is
 * exactly the state Trakt reports.
 */
const val ContinueWatchingNextUpTraktMarkWindowMs = 30L * 60L * 1_000L

/**
 * When the forced Trakt episode-progress refetch runs after a mark. Only this delayed call is
 * made (review round 2 P3-1): an immediate one ran before `markWatched` had pushed the history,
 * and while it was still in flight Trakt's in-flight guard turned the useful later call into a
 * no-op.
 */
internal const val ContinueWatchingNextUpTraktRefetchDelayMs = 5_000L

/** Parallel metadata fetches per refresh; mobile's `NEXT_UP_RESOLUTION_CONCURRENCY`. */
internal const val ContinueWatchingNextUpFetchConcurrency = 4

/**
 * What tvOS Home does with an Up Next episode that has not aired yet (FEAT-85 review P2-2).
 *
 * - [Drop] (current): no card. The synced "Show unaired next up" preference defaults on, and with
 *   it a caught-up show got a card whose stream picker is empty, for an episode the Upcoming row
 *   already lists with its air date.
 * - [LabelAirDate] (not built yet): keep the card, badge it "Airs <date>" and open Detail on press.
 *   Flipping [ContinueWatchingUnairedNextUpPolicy] keeps the card; the badge and the press route
 *   are Swift work in `ContinueWatchingRow` / `HomeRowActions` that has to land with the flip.
 */
enum class UnairedNextUpPolicy { Drop, LabelAirDate }

/** The one switch for the rule above. */
val ContinueWatchingUnairedNextUpPolicy: UnairedNextUpPolicy = UnairedNextUpPolicy.Drop

/** Pure (unit-tested): whether an Up Next episode gets a card under [policy]. */
fun keepNextUpEpisode(isReleased: Boolean, policy: UnairedNextUpPolicy): Boolean =
    isReleased || policy == UnairedNextUpPolicy.LabelAirDate

/**
 * The air check's verdict: whether the episode gets a card, and when the verdict goes stale.
 * [recheckAtEpochMs] is the release instant of an episode that has not aired; a cached result
 * past it is resolved again (review round 2 P2-1).
 */
data class NextUpAirCheck(val keep: Boolean, val recheckAtEpochMs: Long?)

/**
 * Pure (unit-tested), review round 2 P2-1: the air check by release INSTANT, the same instant
 * `isEpisodeReleaseAired` compares. The verdict for an unaired episode carries that instant, so
 * the cache cannot hold "unaired" for the rest of the local day. Example: a weekly show out at
 * 2026-10-24T01:00Z (21:00 EDT on the 23rd), checked at 20:00 local; or a date-only "released
 * today" read as midnight before the local day has reached it.
 *
 * An unknown or unparseable date counts as aired, as `isReleasedBy` treats it. `available =
 * false` is deliberately not read: mobile surfaces an aired episode whatever that flag says
 * (`shouldSurfaceNextEpisode`), and `seriesPrimaryAction` has already applied it when choosing
 * the episode.
 */
fun nextUpAirCheck(
    released: String?,
    nowEpochMs: Long,
    policy: UnairedNextUpPolicy = ContinueWatchingUnairedNextUpPolicy,
): NextUpAirCheck {
    val releaseAt = parseReleaseDateToEpochMs(released) ?: return NextUpAirCheck(keep = true, recheckAtEpochMs = null)
    if (releaseAt <= nowEpochMs) return NextUpAirCheck(keep = true, recheckAtEpochMs = null)
    return NextUpAirCheck(keep = keepNextUpEpisode(isReleased = false, policy = policy), recheckAtEpochMs = releaseAt)
}

/**
 * Pure (unit-tested), review pass 3 P2-1: the earliest release still ahead among the main-season
 * episodes after the seed. With "Show unaired next up" OFF, `seriesPrimaryAction` returns no
 * action at all for a caught-up show whose next episode has not aired, so [nextUpAirCheck] is
 * never reached; this instant is the recheck for that "no card" instead, so it is not cached
 * until local midnight. Null when nothing later has a future date (the show is finished or
 * undated), which is a settled "no card" for the day.
 */
fun nextFutureReleaseAfterSeed(
    videos: List<MetaVideo>,
    seedSeasonNumber: Int,
    seedEpisodeNumber: Int,
    nowEpochMs: Long,
): Long? = videos
    .filter { video ->
        val season = video.season ?: return@filter false
        val episode = video.episode ?: return@filter false
        season > 0 && (season > seedSeasonNumber || (season == seedSeasonNumber && episode > seedEpisodeNumber))
    }
    .mapNotNull { video -> parseReleaseDateToEpochMs(video.released) }
    .filter { releaseAt -> releaseAt > nowEpochMs }
    .minOrNull()

/**
 * Pure (unit-tested): the episode a `seriesPrimaryAction` result points at, as mobile's
 * `videoForSeriesAction` finds it: by season and episode first, then by playback id.
 */
fun nextUpVideoFor(
    videos: List<MetaVideo>,
    contentId: String,
    seasonNumber: Int?,
    episodeNumber: Int?,
    videoId: String,
): MetaVideo? {
    if (seasonNumber != null && episodeNumber != null) {
        videos.firstOrNull { video -> video.season == seasonNumber && video.episode == episodeNumber }
            ?.let { return it }
    }
    return videos.firstOrNull { video ->
        video.id == videoId || buildPlaybackVideoId(
            parentMetaId = contentId,
            seasonNumber = video.season,
            episodeNumber = video.episode,
            fallbackVideoId = video.id,
        ) == videoId
    }
}

data class ContinueWatchingNextUpSeed(
    val contentType: String,
    val contentId: String,
    val seasonNumber: Int,
    val episodeNumber: Int,
    val markedAtEpochMs: Long,
    /**
     * The seasons and episodes next-up must leave out for this show, as the seed's entry carried
     * them ([WatchProgressEntry.excludedNextUpSeasons], [WatchProgressEntry.excludedNextUpEpisodeKeys]),
     * in one stable string: part of the resolve key, so a cached answer is not reused once the
     * user drops or restores a season (Codex r13).
     */
    val exclusionsFingerprint: String = "",
)

internal fun nextUpExclusionsFingerprint(seasons: Set<Int>, episodeKeys: Set<String>): String =
    if (seasons.isEmpty() && episodeKeys.isEmpty()) ""
    else seasons.sorted().joinToString(",") + "/" + episodeKeys.sorted().joinToString(",")

val WatchProgressEntry.isContinueWatchingNextUp: Boolean
    get() = source == WatchProgressSourceNextUp

/**
 * Pure seed selection (unit-tested). Returns at most [limit] series, most recently completed first.
 * The two stages below, split so a refresh can reuse stage 1 (review P3-2).
 */
fun buildContinueWatchingNextUpSeeds(
    progressEntries: List<WatchProgressEntry>,
    watchedItems: List<WatchedItem>,
    isProgressSeed: (WatchProgressEntry) -> Boolean,
    isDroppedShow: (contentId: String) -> Boolean,
    recencyCutoffEpochMs: Long?,
    preferFurthestEpisode: Boolean,
    dismissedNextUpKeys: Set<String>,
    limit: Int = ContinueWatchingNextUpResolveLimit,
): List<ContinueWatchingNextUpSeed> = filterNextUpSeedCandidates(
    candidates = buildNextUpSeedCandidates(progressEntries, watchedItems, isProgressSeed, preferFurthestEpisode),
    isDroppedShow = isDroppedShow,
    recencyCutoffEpochMs = recencyCutoffEpochMs,
    dismissedNextUpKeys = dismissedNextUpKeys,
    limit = limit,
)

/**
 * Stage 1, the O(entries) part: the latest finished episode per series, minus the series whose
 * in-progress episode is at least as recent. Depends only on progress, history, the provider's
 * seed rule and "furthest episode".
 */
fun buildNextUpSeedCandidates(
    progressEntries: List<WatchProgressEntry>,
    watchedItems: List<WatchedItem>,
    isProgressSeed: (WatchProgressEntry) -> Boolean,
    preferFurthestEpisode: Boolean,
): List<ContinueWatchingNextUpSeed> {
    val markers = buildList {
        progressEntries.forEach { entry ->
            val season = entry.seasonNumber ?: return@forEach
            val episode = entry.episodeNumber ?: return@forEach
            if (season == 0) return@forEach
            if (!entry.parentMetaType.isSeriesTypeForContinueWatching()) return@forEach
            if (isMalformedNextUpSeedContentId(entry.parentMetaId)) return@forEach
            if (!isProgressSeed(entry)) return@forEach
            add(ContinueWatchingNextUpSeed(
                entry.parentMetaType, entry.parentMetaId, season, episode, entry.lastUpdatedEpochMs,
                exclusionsFingerprint = nextUpExclusionsFingerprint(entry.excludedNextUpSeasons, entry.excludedNextUpEpisodeKeys),
            ))
        }
        watchedItems.forEach { item ->
            val season = item.season ?: return@forEach
            val episode = item.episode ?: return@forEach
            if (season == 0) return@forEach
            if (!item.type.isSeriesTypeForContinueWatching()) return@forEach
            if (isMalformedNextUpSeedContentId(item.id)) return@forEach
            add(ContinueWatchingNextUpSeed(item.type, item.id, season, episode, normalizeWatchedMarkedAtEpochMs(item.markedAtEpochMs)))
        }
    }
    // The same two orderings as the shared `latestCompletedSeriesEpisode` mobile seeds from.
    val ordering = if (preferFurthestEpisode) {
        compareBy<ContinueWatchingNextUpSeed>({ it.seasonNumber }, { it.episodeNumber }, { it.markedAtEpochMs })
    } else {
        compareBy<ContinueWatchingNextUpSeed>({ it.markedAtEpochMs }, { it.seasonNumber }, { it.episodeNumber })
    }
    val latestInProgressBySeries = progressEntries
        .filter { entry -> entry.shouldTreatAsInProgressForContinueWatching() }
        .groupBy { entry -> entry.parentMetaId }
        .mapValues { (_, entries) -> entries.maxOf { entry -> entry.lastUpdatedEpochMs } }

    return markers
        .groupBy { seed -> seed.contentId }
        .mapNotNull { (_, seeds) -> seeds.maxWithOrNull(ordering) }
        // Mobile's `shouldTreatAsActiveInProgressForNextUpSuppression`: `>=`, so a tie keeps the
        // in-progress card.
        .filterNot { seed ->
            val inProgressAt = latestInProgressBySeries[seed.contentId] ?: return@filterNot false
            inProgressAt >= seed.markedAtEpochMs
        }
}

/**
 * Stage 2, per series only: the provider's hidden shows and recency window, the synced
 * dismissals, newest first, capped. Runs on every refresh, so a hidden-show or dismissal change
 * always applies even when stage 1 was reused.
 */
fun filterNextUpSeedCandidates(
    candidates: List<ContinueWatchingNextUpSeed>,
    isDroppedShow: (contentId: String) -> Boolean,
    recencyCutoffEpochMs: Long?,
    dismissedNextUpKeys: Set<String>,
    limit: Int = ContinueWatchingNextUpResolveLimit,
): List<ContinueWatchingNextUpSeed> = candidates
    .filterNot { seed -> isDroppedShow(seed.contentId) }
    .filter { seed -> recencyCutoffEpochMs == null || seed.markedAtEpochMs >= recencyCutoffEpochMs }
    .filterNot { seed ->
        nextUpDismissKey(seed.contentId, seed.seasonNumber, seed.episodeNumber) in dismissedNextUpKeys
    }
    .sortedByDescending { seed -> seed.markedAtEpochMs }
    .take(limit)

/**
 * Review P3-2: what stage 1 reads from one progress row. Playback position and an in-progress
 * row's timestamp are left out, so the saves Home sees every few seconds while it sits under the
 * player do not rebuild the seeds. Leaving the timestamp out is safe: an in-progress row only
 * ever moves forward in time, and when it overtakes a finished episode the merge
 * ([mergeContinueWatchingWithNextUp], newer card wins) already shows the in-progress card.
 * A row appearing, disappearing or finishing changes the signature.
 */
data class NextUpProgressSignature(
    val parentMetaId: String,
    val parentMetaType: String,
    val videoId: String,
    val seasonNumber: Int?,
    val episodeNumber: Int?,
    val source: String,
    val isCompleted: Boolean,
    /** The completion time for a finished row; 0 for any other. */
    val completedAtEpochMs: Long,
)

/** Pure (unit-tested): the stage-1 signature of a progress list. */
fun nextUpProgressSignature(entries: List<WatchProgressEntry>): List<NextUpProgressSignature> =
    entries.map { entry ->
        val completed = entry.isEffectivelyCompleted
        NextUpProgressSignature(
            parentMetaId = entry.parentMetaId,
            parentMetaType = entry.parentMetaType,
            videoId = entry.videoId,
            seasonNumber = entry.seasonNumber,
            episodeNumber = entry.episodeNumber,
            source = entry.source,
            isCompleted = completed,
            completedAtEpochMs = if (completed) entry.lastUpdatedEpochMs else 0L,
        )
    }

/**
 * Pure merge (unit-tested), mobile's `buildHomeContinueWatchingItems` rule: one card per series,
 * the more recent of its in-progress entry and its next-up wins, and an in-progress entry wins a
 * tie. So an episode abandoned half way keeps its card until a LATER episode is finished, and the
 * card for an Up Next the user starts playing turns into that episode's progress card at once
 * (its progress is newer than the completion the Up Next was dated from).
 *
 * Returns [inProgress] itself when there is nothing to merge, so Home's structural compare sees an
 * unchanged row and does not republish.
 */
fun mergeContinueWatchingWithNextUp(
    inProgress: List<WatchProgressEntry>,
    nextUp: List<WatchProgressEntry>,
): List<WatchProgressEntry> {
    if (nextUp.isEmpty()) return inProgress
    val seen = mutableSetOf<String>()
    return (inProgress.map { it to true } + nextUp.map { it to false })
        .sortedWith(
            compareByDescending<Pair<WatchProgressEntry, Boolean>> { (entry, _) -> entry.lastUpdatedEpochMs }
                .thenByDescending { (_, isProgress) -> isProgress },
        )
        .filter { (entry, _) -> seen.add(entry.parentMetaId.ifBlank { entry.videoId }) }
        .map { (entry, _) -> entry }
}

/**
 * Pure (unit-tested): drops the next-up entries whose dismiss key is now in [dismissedNextUpKeys].
 * Home applies it the moment the preferences change, so a removed Up Next card leaves the row at
 * once instead of after the next resolution.
 */
fun withoutDismissedNextUp(
    entries: List<WatchProgressEntry>,
    dismissKeyByVideoId: Map<String, String>,
    dismissedNextUpKeys: Set<String>,
): List<WatchProgressEntry> = entries.filterNot { entry ->
    entry.isContinueWatchingNextUp && dismissKeyByVideoId[entry.videoId] in dismissedNextUpKeys
}

/**
 * Pure (unit-tested), FEAT-85 review P2-1: the Up Next a series would show once its in-progress
 * card [removedVideoId] is removed, i.e. the seed to dismiss so Remove takes the whole series out
 * of the row (the in-progress card was what suppressed that seed). Recency window, hidden shows
 * and existing dismissals are left out on purpose: dismissing a seed that would not show anyway
 * is harmless.
 */
fun nextUpSeedAfterRemoval(
    progressEntries: List<WatchProgressEntry>,
    watchedItems: List<WatchedItem>,
    contentId: String,
    removedVideoId: String,
    isProgressSeed: (WatchProgressEntry) -> Boolean,
    preferFurthestEpisode: Boolean,
): ContinueWatchingNextUpSeed? = buildContinueWatchingNextUpSeeds(
    progressEntries = progressEntries.filter { entry ->
        entry.parentMetaId == contentId && entry.videoId != removedVideoId
    },
    watchedItems = watchedItems.filter { item -> item.id == contentId },
    isProgressSeed = isProgressSeed,
    isDroppedShow = { false },
    recencyCutoffEpochMs = null,
    preferFurthestEpisode = preferFurthestEpisode,
    dismissedNextUpKeys = emptySet(),
    limit = 1,
).firstOrNull()

/**
 * Pure (unit-tested), review P2-4: the marks still inside [windowMs] for [profileId]. Under Trakt
 * these stand in for watched history, which Home leaves out there (as mobile does).
 */
fun activeRecentNextUpMarks(
    marks: List<RecentNextUpMark>,
    profileId: Int,
    nowEpochMs: Long,
    windowMs: Long = ContinueWatchingNextUpTraktMarkWindowMs,
): List<WatchedItem> = marks
    .filter { mark -> mark.profileId == profileId && nowEpochMs - mark.item.markedAtEpochMs in 0..windowMs }
    .map { mark -> mark.item }

data class RecentNextUpMark(val profileId: Int, val item: WatchedItem)

/**
 * Pure (unit-tested), review round 2 P3-2: [marks] without the ones an unmark covers. An item with
 * a season and episode unmarks that episode; one without (a whole show or a movie) unmarks every
 * mark for its id.
 */
fun withoutUnmarkedNextUpMarks(
    marks: List<RecentNextUpMark>,
    unmarked: Collection<WatchedItem>,
): List<RecentNextUpMark> = marks.filterNot { mark ->
    unmarked.any { item ->
        item.id == mark.item.id &&
            (item.season == null || item.episode == null ||
                (item.season == mark.item.season && item.episode == mark.item.episode))
    }
}

/**
 * The inputs a seed's resolution depends on besides the episode metadata. Two refreshes with the
 * same key give the same next episode, so the result is reused instead of refetched; the date is
 * in it so an episode that airs overnight is picked up the next day. The profile is in it so a
 * result can never cross a profile switch, even one that lands between two refreshes.
 */
internal fun nextUpResolveKey(
    seed: ContinueWatchingNextUpSeed,
    profileId: Int,
    source: String,
    preferFurthestEpisode: Boolean,
    showUnairedNextUp: Boolean,
    todayIsoDate: String,
): String = listOf(
    source,
    seed.contentType,
    seed.contentId,
    seed.seasonNumber.toString(),
    seed.episodeNumber.toString(),
    if (preferFurthestEpisode) "furthest" else "latest",
    if (showUnairedNextUp) "unaired" else "aired",
    todayIsoDate,
    seed.exclusionsFingerprint,
).joinToString("|", prefix = "p$profileId|")

/**
 * One read of everything a refresh depends on (review round 2 P3-3: built by
 * [ContinueWatchingNextUp] from the repositories, by tests directly).
 *
 * [historyItems] is watched history; [NextUpEngine] uses it for every source but Trakt, where it
 * substitutes the recent Continue Watching marks (mobile leaves history out under Trakt).
 */
internal class NextUpInputs(
    val profileId: Int,
    val source: WatchProgressSource,
    val preferFurthestEpisode: Boolean,
    val showUnairedNextUp: Boolean,
    val dismissedNextUpKeys: Set<String>,
    val nowEpochMs: Long,
    val todayIsoDate: String,
    val entries: List<WatchProgressEntry>,
    val historyItems: List<WatchedItem>,
    /** The active provider's seed rule ([WatchProgressRepository.shouldUseAsNextUpSeed]). */
    val isProgressSeed: (entry: WatchProgressEntry, nowEpochMs: Long) -> Boolean,
)

/**
 * The stateful half of Up Next (review round 2 P3-3), with its outside world injected so the
 * cache, generation guard, Trakt marks and removal order are unit-tested. [ContinueWatchingNextUp]
 * owns the one production instance.
 */
internal class NextUpEngine(
    private val fetchMeta: suspend (type: String, id: String) -> MetaDetails?,
    private val prepareEntries: suspend (entries: List<WatchProgressEntry>, contentId: String) -> List<WatchProgressEntry>,
    private val isDroppedShow: (contentId: String) -> Boolean,
    private val recencyCutoffEpochMs: (nowEpochMs: Long) -> Long?,
    private val refetchEpisodeProgress: (contentId: String) -> Unit,
    private val refetchScope: CoroutineScope,
    private val unairedPolicy: () -> UnairedNextUpPolicy = { ContinueWatchingUnairedNextUpPolicy },
) {
    private val log = Logger.withTag("CWNextUp")
    private val lock = SynchronizedObject()

    /** videoId of each resolved next-up entry → its dismiss key (seed episode, as mobile keys it). */
    private var dismissKeysByVideoId: Map<String, String> = emptyMap()

    /**
     * Conclusive results of the last refresh by [nextUpResolveKey]; a null entry is a settled "no
     * next episode" (series finished, next one unaired). Only the current seeds' keys are kept, so
     * the map never outgrows [ContinueWatchingNextUpResolveLimit]. A failed fetch is not stored and
     * is retried on the next refresh. A result with [CachedOutcome.recheckAtEpochMs] is used only
     * until that instant (an unaired episode's release).
     */
    private var resolvedByKey: Map<String, CachedOutcome> = emptyMap()

    private class CachedOutcome(val entry: WatchProgressEntry?, val recheckAtEpochMs: Long?) {
        fun isUsableAt(nowEpochMs: Long): Boolean = recheckAtEpochMs == null || nowEpochMs < recheckAtEpochMs
    }

    /**
     * Review P2-4: episodes marked watched from a Continue Watching card while Trakt is the source.
     * Trakt's progress only shows the mark after its history push and a refetch, and Home leaves
     * watched history out under Trakt, so without these the card would not move on until the next
     * Trakt sync.
     */
    private var recentTraktMarks: List<RecentNextUpMark> = emptyList()

    /**
     * Review P3-2: the inputs stage 1 last ran on. `watchedItems` compares as a list, which is
     * cheap when it is the same `WatchedRepository` snapshot (the usual case: progress saves do
     * not touch history) because Kotlin list equality checks identity first.
     */
    private data class SeedStageOneKey(
        val profileId: Int,
        val source: WatchProgressSource,
        val preferFurthestEpisode: Boolean,
        val minuteBucket: Long,
        val progress: List<NextUpProgressSignature>,
        val watchedItems: List<WatchedItem>,
    )

    private var lastStageOne: Pair<SeedStageOneKey, List<ContinueWatchingNextUpSeed>>? = null

    /** Stage-1 rebuilds since construction (tests read it to tell a cache hit from a miss). */
    internal var stageOneBuilds: Int = 0
        private set

    /** Bumped by [reset]; a refresh that started before it does not write back. */
    private var generation = 0L

    /** Last logged summary, so the probe line prints once per change, not once per refresh. */
    private var lastSummary: String? = null

    /**
     * One refresh at a time. Home cancels its Swift task on every new trigger, but a Swift cancel
     * does not reach a running Kotlin call; serialising means an overlapping refresh waits and then
     * finds the first one's results in [resolvedByKey] instead of fetching the same series again.
     */
    private val resolveMutex = Mutex()

    /** The watched items seed selection reads for [inputs] (see [NextUpInputs.historyItems]). */
    private fun seedWatchedItems(inputs: NextUpInputs): List<WatchedItem> =
        if (inputs.source == WatchProgressSource.TRAKT) {
            activeRecentNextUpMarks(
                marks = synchronized(lock) { recentTraktMarks },
                profileId = inputs.profileId,
                nowEpochMs = inputs.nowEpochMs,
            )
        } else {
            inputs.historyItems
        }

    /**
     * [inputs] is read inside the refresh lock, after the generation (review pass 3 P3-1). A
     * refresh queued behind a slow one used to carry inputs read before it waited, so after a
     * profile switch in between it could write the outgoing profile's cards and dismiss keys
     * under the new generation.
     */
    suspend fun resolve(inputs: () -> NextUpInputs, limit: Int): List<WatchProgressEntry> =
        resolveMutex.withLock {
            val startGeneration = synchronized(lock) { generation }
            resolveLocked(inputs(), startGeneration, limit)
        }

    private suspend fun resolveLocked(
        inputs: NextUpInputs,
        startGeneration: Long,
        limit: Int,
    ): List<WatchProgressEntry> {
        val now = inputs.nowEpochMs
        val source = inputs.source
        val entries = inputs.entries
        val watchedItems = seedWatchedItems(inputs)
        val isProgressSeed: (WatchProgressEntry) -> Boolean = { entry -> inputs.isProgressSeed(entry, now) }
        // Review P3-2: stage 1 is rebuilt only when what it reads changed. The provider's Trakt
        // playback seed rule is time-bound (minutes), so under Trakt the key also carries the
        // minute.
        val stageOneKey = SeedStageOneKey(
            profileId = inputs.profileId,
            source = source,
            preferFurthestEpisode = inputs.preferFurthestEpisode,
            minuteBucket = if (source == WatchProgressSource.TRAKT) now / 60_000L else 0L,
            progress = nextUpProgressSignature(entries),
            watchedItems = watchedItems,
        )
        val cachedStageOne = synchronized(lock) { lastStageOne }
        val candidates = if (cachedStageOne != null && cachedStageOne.first == stageOneKey) {
            cachedStageOne.second
        } else {
            buildNextUpSeedCandidates(
                progressEntries = entries,
                watchedItems = watchedItems,
                isProgressSeed = isProgressSeed,
                preferFurthestEpisode = inputs.preferFurthestEpisode,
            ).also { built ->
                synchronized(lock) {
                    stageOneBuilds += 1
                    if (generation == startGeneration) lastStageOne = stageOneKey to built
                }
            }
        }
        val seeds = filterNextUpSeedCandidates(
            candidates = candidates,
            isDroppedShow = isDroppedShow,
            recencyCutoffEpochMs = recencyCutoffEpochMs(now),
            dismissedNextUpKeys = inputs.dismissedNextUpKeys,
            limit = limit,
        )
        val known = synchronized(lock) { resolvedByKey }
        val semaphore = Semaphore(ContinueWatchingNextUpFetchConcurrency)
        val outcomes = coroutineScope {
            seeds.map { seed ->
                val key = nextUpResolveKey(
                    seed = seed,
                    profileId = inputs.profileId,
                    source = source.name,
                    preferFurthestEpisode = inputs.preferFurthestEpisode,
                    showUnairedNextUp = inputs.showUnairedNextUp,
                    todayIsoDate = inputs.todayIsoDate,
                )
                async {
                    val cached = known[key]?.takeIf { it.isUsableAt(now) }
                    if (cached != null) {
                        // Same seed episode, possibly re-finished: keep the card dated from it.
                        SeedOutcome(
                            seed = seed,
                            key = key,
                            entry = cached.entry?.copy(lastUpdatedEpochMs = seed.markedAtEpochMs),
                            conclusive = true,
                            fetched = false,
                            recheckAtEpochMs = cached.recheckAtEpochMs,
                        )
                    } else {
                        semaphore.withPermit {
                            resolveSeed(seed = seed, key = key, inputs = inputs, watchedItems = watchedItems)
                        }
                    }
                }
            }.awaitAll()
        }
        val resolved = outcomes.mapNotNull { outcome -> outcome.entry?.let { entry -> entry to outcome.seed } }
        synchronized(lock) {
            if (generation != startGeneration) return emptyList()
            resolvedByKey = outcomes.filter { it.conclusive }
                .associate { it.key to CachedOutcome(it.entry, it.recheckAtEpochMs) }
            dismissKeysByVideoId = resolved.associate { (entry, seed) ->
                entry.videoId to nextUpDismissKey(seed.contentId, seed.seasonNumber, seed.episodeNumber)
            }
            // Probe line for the console stream / rig: one per change in what Up Next shows.
            val summary = "seeds=${seeds.size} cards=${resolved.size} " +
                "fetched=${outcomes.count { it.fetched }} failed=${outcomes.count { !it.conclusive }} " +
                "source=${source.name} ids=${resolved.joinToString(",") { (entry, _) -> entry.videoId }}"
            if (summary != lastSummary) {
                lastSummary = summary
                log.i { "upnext $summary" }
            }
        }
        return resolved.map { (entry, _) -> entry }
    }

    fun dismissKeysSnapshot(): Map<String, String> = synchronized(lock) { dismissKeysByVideoId }

    /**
     * Continue Watching › Remove for any card. A next-up card is dismissed (profile-synced; the
     * series comes back once a later episode is finished, because playing any of its episodes
     * clears its keys in `WatchProgressRepository.upsert`). A progress card clears its progress
     * and, for a series, also dismisses the Up Next its removal would uncover (review P2-1: E3
     * finished, E4 half watched, Remove E4 used to bring "Up Next · S01E04" back 1.5 s later).
     *
     * The phone's Remove calls `removeProgress(contentId)`, which drops every progress row of the
     * series; its watched history survives, so by its code the phone can still build the same Up
     * Next from history. This keeps tvOS's episode-level clear and adds the synced dismissal, so
     * the series leaves the row here AND the phone hides that Up Next too.
     */
    fun removeFromContinueWatching(
        entry: WatchProgressEntry,
        inputs: () -> NextUpInputs,
        addDismissedKey: (String) -> Unit,
        clearProgress: (WatchProgressEntry) -> Unit,
    ) {
        if (entry.isContinueWatchingNextUp) {
            val key = synchronized(lock) { dismissKeysByVideoId[entry.videoId] } ?: return
            addDismissedKey(key)
            return
        }
        if (entry.parentMetaType.isSeriesTypeForContinueWatching()) {
            val snapshot = inputs()
            nextUpSeedAfterRemoval(
                progressEntries = snapshot.entries,
                watchedItems = seedWatchedItems(snapshot),
                contentId = entry.parentMetaId,
                removedVideoId = entry.videoId,
                isProgressSeed = { candidate -> snapshot.isProgressSeed(candidate, snapshot.nowEpochMs) },
                preferFurthestEpisode = snapshot.preferFurthestEpisode,
            )?.let { seed ->
                // Before the clear: the clear publishes, and the refresh it schedules must already
                // see the dismissal.
                addDismissedKey(nextUpDismissKey(seed.contentId, seed.seasonNumber, seed.episodeNumber))
            }
        }
        clearProgress(entry)
    }

    /**
     * Continue Watching › Mark Episode Watched, called before `WatchedRepository.markWatched`.
     * Only Trakt needs it (review P2-4): the mark counts as a seed right away (see
     * [recentTraktMarks]), and Trakt's progress for the show is refetched once, after
     * [ContinueWatchingNextUpTraktRefetchDelayMs], when the async history push has had time to land.
     * Any other source sees the mark through watched history already. Returns whether it recorded
     * a mark. [isStillCurrent] is asked before the refetch (same source and profile).
     */
    fun noteMarkedWatched(
        entry: WatchProgressEntry,
        source: WatchProgressSource,
        profileId: Int,
        nowEpochMs: Long,
        isStillCurrent: () -> Boolean,
    ): Boolean {
        if (source != WatchProgressSource.TRAKT) return false
        val season = entry.seasonNumber ?: return false
        val episode = entry.episodeNumber ?: return false
        val mark = RecentNextUpMark(
            profileId = profileId,
            item = WatchedItem(
                id = entry.parentMetaId,
                type = entry.parentMetaType,
                name = entry.title,
                season = season,
                episode = episode,
                markedAtEpochMs = nowEpochMs,
            ),
        )
        synchronized(lock) {
            recentTraktMarks = activeRecentNextUpMarks(recentTraktMarks, profileId, nowEpochMs)
                .map { item -> RecentNextUpMark(profileId, item) } + mark
        }
        refetchScope.launch {
            delay(ContinueWatchingNextUpTraktRefetchDelayMs)
            if (isStillCurrent()) refetchEpisodeProgress(entry.parentMetaId)
        }
        return true
    }

    /**
     * `WatchedRepository.unmarkWatched` (review round 2 P3-2): an episode unmarked within the mark
     * window must stop seeding Up Next straight away, not 30 minutes later.
     */
    fun onUnmarkedWatched(items: Collection<WatchedItem>) {
        if (items.isEmpty()) return
        synchronized(lock) {
            recentTraktMarks = withoutUnmarkedNextUpMarks(recentTraktMarks, items)
        }
    }

    /** Profile switch and account wipe: drop everything; an in-flight refresh cannot write back. */
    fun reset() {
        synchronized(lock) {
            generation += 1
            resolvedByKey = emptyMap()
            dismissKeysByVideoId = emptyMap()
            recentTraktMarks = emptyList()
            lastStageOne = null
            lastSummary = null
        }
    }

    private class SeedOutcome(
        val seed: ContinueWatchingNextUpSeed,
        val key: String,
        val entry: WatchProgressEntry?,
        /** False for a failed fetch: not cached, retried on the next refresh. */
        val conclusive: Boolean,
        val fetched: Boolean,
        /** See [NextUpAirCheck.recheckAtEpochMs]. */
        val recheckAtEpochMs: Long? = null,
    )

    private suspend fun resolveSeed(
        seed: ContinueWatchingNextUpSeed,
        key: String,
        inputs: NextUpInputs,
        watchedItems: List<WatchedItem>,
    ): SeedOutcome {
        fun settled(entry: WatchProgressEntry?, recheckAtEpochMs: Long? = null) =
            SeedOutcome(seed, key, entry, conclusive = true, fetched = true, recheckAtEpochMs = recheckAtEpochMs)
        return try {
            val meta = fetchMeta(seed.contentType, seed.contentId)
                ?: return SeedOutcome(seed, key, null, conclusive = false, fetched = true)
            val preparedEntries = prepareEntries(inputs.entries, seed.contentId)
            // The seed's own content ref, as mobile passes `completedEntry.content`: an add-on can
            // answer with an aliased meta id (a tmdb: id for a tt one), and the user's progress,
            // the dismiss key and the in-progress dedup are all keyed by the id they watched under.
            val content = WatchingContentRef(type = seed.contentType, id = seed.contentId)
            val action = meta.seriesPrimaryAction(
                content = content,
                entries = preparedEntries,
                watchedItems = watchedItems,
                todayIsoDate = inputs.todayIsoDate,
                preferFurthestEpisode = inputs.preferFurthestEpisode,
                showUnairedNextUp = inputs.showUnairedNextUp,
                allowRewatch = false,
            ) ?: return settled(
                entry = null,
                // Pass 3 P2-1: "Show unaired next up" off and the next episode not out yet.
                recheckAtEpochMs = nextFutureReleaseAfterSeed(
                    videos = meta.videos,
                    seedSeasonNumber = seed.seasonNumber,
                    seedEpisodeNumber = seed.episodeNumber,
                    nowEpochMs = inputs.nowEpochMs,
                ),
            )
            // A resume action means an episode is already in progress: its own card covers it.
            if (action.resumePositionMs != null) return settled(null)
            val season = action.seasonNumber ?: return settled(null)
            val episode = action.episodeNumber ?: return settled(null)
            // The seed episode itself is never "next".
            if (season == seed.seasonNumber && episode == seed.episodeNumber) return settled(null)
            // P2-2: an episode that has not aired gets no card (see [UnairedNextUpPolicy]); the
            // verdict is reused only until its release instant (round 2 P2-1). No matching video
            // at all is no card either, as on mobile.
            val video = nextUpVideoFor(meta.videos, seed.contentId, season, episode, action.videoId)
                ?: return settled(null)
            val airCheck = nextUpAirCheck(video.released, inputs.nowEpochMs, unairedPolicy())
            if (!airCheck.keep) return settled(null, airCheck.recheckAtEpochMs)
            settled(
                WatchProgressEntry(
                    contentType = seed.contentType,
                    parentMetaId = seed.contentId,
                    parentMetaType = seed.contentType,
                    videoId = action.videoId,
                    title = meta.name,
                    logo = meta.logo,
                    poster = meta.poster,
                    background = meta.background,
                    seasonNumber = season,
                    episodeNumber = episode,
                    episodeTitle = action.episodeTitle,
                    episodeThumbnail = action.episodeThumbnail,
                    lastPositionMs = 0L,
                    durationMs = 0L,
                    lastUpdatedEpochMs = seed.markedAtEpochMs,
                    isCompleted = false,
                    source = WatchProgressSourceNextUp,
                ),
                airCheck.recheckAtEpochMs,
            )
        } catch (error: Throwable) {
            if (error is CancellationException) throw error
            log.w { "upnext resolve failed for ${seed.contentId}: ${error.message}" }
            SeedOutcome(seed, key, null, conclusive = false, fetched = true)
        }
    }
}

/** The production wiring of [NextUpEngine] over the app's repositories; what Swift calls. */
object ContinueWatchingNextUp {
    internal val engine = NextUpEngine(
        // `cacheResult = false`: a bulk caller, like the Upcoming sweep. Results are reused
        // through the engine's own cache instead, so a seed is fetched once until it changes.
        fetchMeta = { type, id -> MetaDetailsRepository.fetch(type = type, id = id, cacheResult = false) },
        prepareEntries = { entries, contentId -> WatchProgressRepository.prepareNextUpProgressEntries(entries, contentId) },
        isDroppedShow = { contentId -> WatchProgressRepository.isDroppedShow(contentId) },
        recencyCutoffEpochMs = { now ->
            WatchProgressRepository.activeProviderContinueWatchingCutoffEpochMs(
                daysCap = TraktSettingsRepository.uiState.value.continueWatchingDaysCap,
                nowEpochMs = now,
            )
        },
        refetchEpisodeProgress = { contentId ->
            WatchProgressRepository.refreshEpisodeProgress(contentId, forceRefresh = true)
        },
        refetchScope = CoroutineScope(SupervisorJob() + Dispatchers.Default),
    )

    /**
     * Resolves the next-up entries for the active profile and progress source. The work runs on
     * `Dispatchers.Default` (Home calls this from the main actor). A failed metadata fetch just
     * leaves that series out of this refresh. `@Throws` so nothing unexpected can abort the process
     * when called from Swift (`try await`).
     */
    @Throws(Throwable::class)
    suspend fun resolveEntries(limit: Int): List<WatchProgressEntry> {
        ensureInputsLoaded()
        return withContext(Dispatchers.Default) { engine.resolve(::currentInputs, limit) }
    }

    /** The repositories' current state (StateFlow values: safe to read off main). */
    private fun currentInputs(): NextUpInputs {
        val prefs = ContinueWatchingPreferencesRepository.uiState.value
        val source = WatchProgressRepository.activeSourceState.value
        return NextUpInputs(
            profileId = ProfileRepository.activeProfileId,
            source = source,
            preferFurthestEpisode = prefs.upNextFromFurthestEpisode,
            showUnairedNextUp = prefs.showUnairedNextUp,
            dismissedNextUpKeys = prefs.dismissedNextUpKeys,
            nowEpochMs = WatchProgressClock.nowEpochMs(),
            todayIsoDate = CurrentDateProvider.todayIsoDate(),
            // The published projection (the same list mobile's Home reads), not a private snapshot.
            entries = WatchProgressRepository.uiState.value.entries,
            // Read only off Trakt; see [NextUpInputs.historyItems].
            historyItems = if (source == WatchProgressSource.TRAKT) emptyList() else WatchedRepository.uiState.value.items,
            isProgressSeed = { entry, now -> WatchProgressRepository.shouldUseAsNextUpSeed(entry, now) },
        )
    }

    /** The dismiss keys of the entries the last refresh returned, for [withoutDismissedNextUp]. */
    fun dismissKeysSnapshot(): Map<String, String> = engine.dismissKeysSnapshot()

    /** [withoutDismissedNextUp] against the current preferences and the last refresh's keys. */
    fun withoutDismissed(entries: List<WatchProgressEntry>): List<WatchProgressEntry> =
        withoutDismissedNextUp(
            entries = entries,
            dismissKeyByVideoId = dismissKeysSnapshot(),
            dismissedNextUpKeys = ContinueWatchingPreferencesRepository.uiState.value.dismissedNextUpKeys,
        )

    /** See [NextUpEngine.removeFromContinueWatching]. */
    fun removeFromContinueWatching(entry: WatchProgressEntry) {
        engine.removeFromContinueWatching(
            entry = entry,
            inputs = {
                ensureInputsLoaded()
                currentInputs()
            },
            addDismissedKey = ContinueWatchingPreferencesRepository::addDismissedNextUpKey,
            clearProgress = { card ->
                WatchProgressRepository.clearProgress(videoId = card.videoId, parentMetaId = card.parentMetaId)
            },
        )
    }

    /** See [NextUpEngine.noteMarkedWatched]. */
    fun noteMarkedWatched(entry: WatchProgressEntry) {
        val source = WatchProgressRepository.activeSourceState.value
        val profileId = ProfileRepository.activeProfileId
        engine.noteMarkedWatched(
            entry = entry,
            source = source,
            profileId = profileId,
            nowEpochMs = WatchProgressClock.nowEpochMs(),
            isStillCurrent = {
                WatchProgressRepository.activeSourceState.value == source &&
                    ProfileRepository.activeProfileId == profileId
            },
        )
    }

    /** See [NextUpEngine.onUnmarkedWatched]. */
    fun onUnmarkedWatched(items: Collection<WatchedItem>) = engine.onUnmarkedWatched(items)

    private fun ensureInputsLoaded() {
        WatchProgressRepository.ensureLoaded()
        WatchedRepository.ensureLoaded()
        ContinueWatchingPreferencesRepository.ensureLoaded()
        TraktSettingsRepository.ensureLoaded()
    }

    /**
     * Profile switch (`TvOsProviderInstaller`'s profile fan-out, next to the Upcoming row's step):
     * the same reset as the account wipe. The generation bump means a refresh still running for
     * the outgoing profile cannot write its results or dismiss keys back afterwards.
     */
    fun onProfileChanged() = engine.reset()

    /** Account wipe (`TvOsAccountDataCleaner`): the cached results name the outgoing account's shows. */
    fun clearLocalState() = engine.reset()
}
