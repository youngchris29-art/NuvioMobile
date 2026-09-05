package com.nuvio.app.features.home

import com.nuvio.app.core.sync.LaunchSyncSignal.LaunchSyncState

/**
 * BUG-86 (Wave H, the hero commit protocol): the pure decision half of the hero commit gate.
 *
 * The doubled hero is a TEMPORAL double: Home publishes a hero built from whichever catalogs
 * happened to have landed, and then the launch sync burst (addons pull, collections pull, home
 * catalog settings pull) reorders the rows, re-normalizes the hero sources and re-fetches the
 * catalogs a second later, so a SECOND, different hero commits on top of the first. The gate is the
 * fix: [HomeRepository] holds the hero (and the rows that move under it) until every input that can
 * still change the head has settled, then commits once and freezes the payload.
 *
 * This file is deliberately free of repository state so the whole decision table is unit testable
 * (`HeroCommitGateTest`); [HomeRepository] only gathers the inputs and applies the outcome.
 */
enum class HeroGateState {
    /** No catalog-bearing refresh has happened yet, so there is nothing to gate. */
    Idle,

    /** A load is in flight and the hero has not committed: publishes keep the previous payload. */
    Armed,

    /** The hero committed. Its payload is frozen and the head is pinned for the session. */
    Released,
}

/** Terminal state of one hero-source catalog's fetch. Both count as "this source has settled". */
enum class CatalogOutcome { Loaded, Failed }

/**
 * Everything the gate is allowed to look at.
 *
 * @param heroEnabled the profile's "Show Hero" setting.
 * @param heroSourceKeys the PERSISTED hero-source preference keys (see
 *   `HomeCatalogSettingsRepository.heroSourceKeys`), which may name catalogs whose addon manifest
 *   is still loading and therefore has no definition yet.
 * @param knownDefinitionKeys the keys of the catalog definitions that currently exist.
 * @param outcomes per definition key, the terminal outcome of its fetch this load.
 * @param manifestsPending true while a key in `heroSourceKeys - knownDefinitionKeys` can still turn
 *   into a real definition, i.e. while an ENABLED addon that has no manifest yet is still fetching
 *   one. An addon that already has a manifest and is merely re-fetching it does NOT count: its
 *   catalogs are already in `knownDefinitionKeys`, so waiting on it can only burn the gate's
 *   budget (see `HomeRepository.hasUnresolvedEnabledManifests`).
 * @param syncState the launch sync burst's state (see `LaunchSyncSignal`).
 * @param launchSyncExpected false when this account cannot get a launch sync at all (signed out or
 *   anonymous), which is what makes [LaunchSyncState.Idle] readable as "settled" rather than
 *   "has not started yet".
 * @param enrichmentPending how many candidate hero items still have a TMDB fetch outstanding.
 * @param candidateEmpty true when the hero candidate list is empty, which can never be a commit.
 *   The candidate is what the publish would actually carry, so it already includes the collection
 *   fallback: a Home whose hero-source catalogs came back empty but whose collection hero resolved
 *   has a NON-empty candidate and commits it (see `heroPublishSource`).
 * @param heroSourcesAllOff true when the profile's stored preferences name catalogs and every one
 *   of them has `heroSourceEnabled = false`: the user deliberately turned every hero source off.
 *   Distinct from an EMPTY [heroSourceKeys] on a profile that simply has no stored selection yet
 *   (`HomeCatalogSettingsRepository.heroSourceKeys` then falls back to the first definitions), and
 *   the difference matters: with every source off no catalog can ever fill the candidate, so
 *   waiting on [candidateEmpty] could only end at the timeout with the same empty hero, four
 *   seconds of held rows later.
 * @param resetRequested an EXPLICIT Hero Sources change from Settings: the user is looking at the
 *   result, so the gate must not make them wait for the burst.
 * @param elapsedMs milliseconds since the gate armed (0 while [HeroGateState.Idle]).
 * @param timeoutMs the hard cap, normally [HERO_COMMIT_GATE_TIMEOUT_MS].
 */
data class HeroGateInputs(
    val heroEnabled: Boolean,
    val heroSourceKeys: Set<String>,
    val knownDefinitionKeys: Set<String>,
    val outcomes: Map<String, CatalogOutcome>,
    val manifestsPending: Boolean,
    val syncState: LaunchSyncState,
    val launchSyncExpected: Boolean = true,
    val enrichmentPending: Int,
    val candidateEmpty: Boolean,
    val heroSourcesAllOff: Boolean = false,
    val resetRequested: Boolean,
    val elapsedMs: Long,
    val timeoutMs: Long = HERO_COMMIT_GATE_TIMEOUT_MS,
)

/**
 * [state] is [HeroGateState.Released] when the hero may commit now, [HeroGateState.Armed] when it
 * must keep holding. [reason] is non-null exactly when released and is surfaced verbatim in the
 * device probe line (`gate=released:<reason>`) so a held launch is diagnosable from a photo.
 * [waiting] names the FIRST unmet input at this evaluation (see [HeroGateWait]); it rides the probe
 * as `gateWait=` so a `released:timeout` line says which input was late.
 */
data class HeroGateDecision(
    val state: HeroGateState,
    val reason: String?,
    val waiting: String = HeroGateWait.NONE,
) {
    val released: Boolean get() = state == HeroGateState.Released
}

/**
 * The gate's unmet-input vocabulary, in the order the readiness conjunction checks them. Values are
 * part of the probe contract (`gateWait=` in `HomeRepository.heroRankingDebug`): a timeout release
 * carries the input that was still outstanding when the budget ran out, which is the difference
 * between "the tester's network is slow" and "an event never re-evaluated the gate".
 */
object HeroGateWait {
    /** A tracked hero-source catalog has no terminal fetch outcome yet, or an unresolved persisted
     *  hero-source key can still become a definition because a manifest is still in flight. */
    const val SOURCES = "sources"

    /** The launch sync burst is running, or has not started yet and is still expected. */
    const val SYNC = "sync"

    /** At least one candidate hero item still has a TMDB enrichment fetch outstanding. */
    const val ENRICH = "enrich"

    /** Everything settled but the candidate list is empty, so there is nothing to commit. */
    const val EMPTY = "empty"

    /** Nothing outstanding. */
    const val NONE = "-"
}

/** The five release reasons. Values are part of the probe contract read by test31. */
object HeroGateReason {
    /** Every input settled and there is a non-empty candidate: the normal, healthy commit. */
    const val ALL = "all"

    /** Hero is off for this profile, so there is nothing to gate. */
    const val HERO_OFF = "heroOff"

    /** The user changed Hero Sources explicitly and must see the result now. */
    const val RESET = "reset"

    /** [HERO_COMMIT_GATE_TIMEOUT_MS] elapsed. Visible in the probe, never silent. */
    const val TIMEOUT = "timeout"

    /** No catalog can ever supply a hero here (collection-only or add-on-less profile). */
    const val NO_SOURCES = "noSources"
}

/**
 * Hard cap on how long the hero holds before it commits whatever it has.
 *
 * Sized from the cold-launch trace behind BUG-86: the launch sync burst landed about 2 s after the
 * load started, and the burst itself is 5 sequential RPCs plus 4 parallel ones, roughly 1 to 2.5 s
 * on home Wi-Fi. 4 s therefore covers a healthy launch with margin while still bounding the worst
 * case to something a user reads as "loading" rather than "broken". A timeout is never a guarantee,
 * which is why it is reported: the release reason rides the probe line as
 * `gate=released:timeout`, so a slow network shows up in the tester's photo instead of silently
 * degrading into the very double-commit this gate exists to prevent.
 */
const val HERO_COMMIT_GATE_TIMEOUT_MS = 4_000L

/**
 * The Idle half of the decision table: what a publish that lands BEFORE the first catalog-bearing
 * refresh is allowed to do.
 *
 * Before that refresh there is genuinely nothing to decide. A profile whose add-ons are still
 * fetching their manifests looks exactly like one that will never have a catalog at all, and
 * releasing [HeroGateReason.NO_SOURCES] here would commit an empty hero on every launch, ahead of
 * the manifests. So the answer is to hold. The point of this function is that the hold is BOUNDED,
 * by the same budget every other launch shape gets.
 *
 * It was not, and that was a real regression. The gate's own [HERO_COMMIT_GATE_TIMEOUT_MS] timer is
 * armed by the first catalog-bearing refresh, so a profile whose enabled add-ons declare no
 * catalogs (a subtitle or stream-only add-on plus collections) never arms it: the only exit was the
 * separate first-refresh grace. Since Wave H holds the ROWS as well as the hero, that grace became
 * a full-screen "Setting up your catalogs..." on every launch of such a profile, for LONGER than a
 * catalog-bearing profile is ever held, even though the catalog-less one has strictly less to wait
 * for. Past the budget the honest answer is the one the post-grace path already gives: no catalog
 * can supply a hero here, so release `noSources` and let the rows and the collection fallback
 * through.
 *
 * @param awaitingFirstRefresh whether the first catalog-bearing refresh is still outstanding.
 * @param idleElapsedMs milliseconds since the FIRST publish evaluated in this Idle era, which is
 *   the closest the Idle path has to the armed path's "since the gate armed".
 * @param timeoutMs the hard cap, normally [HERO_COMMIT_GATE_TIMEOUT_MS].
 * @return the hold decision, or null when the caller must fall through to [decideHeroGate] with an
 *   empty definition set, which releases [HeroGateReason.NO_SOURCES].
 */
fun decideIdleHeroGate(
    awaitingFirstRefresh: Boolean,
    idleElapsedMs: Long,
    timeoutMs: Long = HERO_COMMIT_GATE_TIMEOUT_MS,
): HeroGateDecision? = if (awaitingFirstRefresh && idleElapsedMs < timeoutMs) {
    HeroGateDecision(state = HeroGateState.Armed, reason = null, waiting = HeroGateWait.SOURCES)
} else {
    null
}

/**
 * The gate's whole decision table. Order matters and is part of the contract:
 * hero off, then explicit reset, then timeout, then the readiness conjunction.
 */
fun decideHeroGate(inputs: HeroGateInputs): HeroGateDecision {
    // Computed before the early returns so a TIMEOUT release can still report what it was waiting
    // on. That is the whole diagnostic value of the probe's `gateWait=` field: a timeout with
    // `gateWait=sync` is a slow network, a timeout with `gateWait=-` means every input was ready
    // and something failed to re-evaluate the gate.
    val waiting = firstUnmetInput(inputs)

    if (!inputs.heroEnabled) return released(HeroGateReason.HERO_OFF)
    if (inputs.resetRequested) return released(HeroGateReason.RESET)
    if (inputs.elapsedMs >= inputs.timeoutMs) return released(HeroGateReason.TIMEOUT, waiting)

    val trackedKeys = inputs.heroSourceKeys.intersect(inputs.knownDefinitionKeys)

    // Nothing to wait for and nothing that can still arrive: a collection-only profile, or one
    // whose add-ons are all gone. Holding would pin Home on the timeout for no reason.
    if (trackedKeys.isEmpty() && inputs.knownDefinitionKeys.isEmpty() && !inputs.manifestsPending) {
        return released(HeroGateReason.NO_SOURCES)
    }

    return if (waiting == HeroGateWait.NONE) {
        released(HeroGateReason.ALL)
    } else {
        HeroGateDecision(state = HeroGateState.Armed, reason = null, waiting = waiting)
    }
}

/**
 * The readiness conjunction, reported as the FIRST unmet term instead of a bare boolean.
 *
 * Order is diagnostic, not arbitrary: an empty candidate list is a SYMPTOM of unloaded sources, so
 * `sources` is reported ahead of `empty`, and a launch that reports `empty` really does have every
 * catalog settled and nothing to show.
 */
private fun firstUnmetInput(inputs: HeroGateInputs): String {
    val trackedKeys = inputs.heroSourceKeys.intersect(inputs.knownDefinitionKeys)
    val unknownKeys = inputs.heroSourceKeys - inputs.knownDefinitionKeys
    // A persisted hero-source key with no definition yet is only a reason to wait while a manifest
    // that could still supply it is loading. Once the manifests have settled, that key names a
    // catalog this profile simply does not have any more and can never produce an outcome.
    val sourcesReady = trackedKeys.all { key -> key in inputs.outcomes } &&
        (unknownKeys.isEmpty() || !inputs.manifestsPending)
    if (!sourcesReady) return HeroGateWait.SOURCES

    val syncReady = when (inputs.syncState) {
        LaunchSyncState.NotApplicable, LaunchSyncState.Settled -> true
        LaunchSyncState.Idle -> !inputs.launchSyncExpected
        LaunchSyncState.Running -> false
    }
    if (!syncReady) return HeroGateWait.SYNC

    if (inputs.enrichmentPending != 0) return HeroGateWait.ENRICH
    // An empty candidate is worth waiting on only while a hero SOURCE could still fill it. Once the
    // user has turned every hero source off AND the definition set is final (no manifest can still
    // arrive with catalogs that would default into the free slots), nothing will ever arrive:
    // holding here would spend the whole budget and then commit the same empty hero, with Home's
    // rows held behind it the entire time. Releasing instead lets the publish fall through to the
    // collection fallback (see [heroPublishSource]), which is the only hero such a profile can have.
    if (inputs.candidateEmpty && !(inputs.heroSourcesAllOff && !inputs.manifestsPending)) {
        return HeroGateWait.EMPTY
    }
    return HeroGateWait.NONE
}

private fun released(reason: String, waiting: String = HeroGateWait.NONE) =
    HeroGateDecision(state = HeroGateState.Released, reason = reason, waiting = waiting)

/** Which list a publish's hero items come from. See [heroPublishSource]. */
enum class HeroPublishSource {
    /** "Show Hero" is off for this profile: the hero region is empty by configuration. */
    Off,

    /** The hero-source catalogs produced a selection, which is what the hero normally is. */
    Catalog,

    /** Nothing may commit yet, so the PREVIOUS hero is republished unchanged. */
    Held,

    /** No catalog hero and nothing holding: the collection fallback is this Home's hero. */
    CollectionFallback,
}

/**
 * Where one publish's hero comes from, given the gate's decision for that SAME publish.
 *
 * The order of the branches is the contract, and so is the caller's order of operations: the gate
 * must be asked BEFORE this is evaluated. It used to be the other way round. The published list
 * was chosen while the gate was still Armed and the gate was then released later in the same
 * publish, so a Home whose hero-source catalogs came back empty could never show its collection
 * fallback: the [Held] branch republished the previous (empty) hero, the timeout released on that
 * empty list, and the commit froze it. Nothing published afterwards, because the fan-out was over
 * and the gate's watchers were cancelled at release, so the collection hero stayed missing for the
 * rest of the session. Deciding first makes a release fall through to [CollectionFallback] in the
 * very publish that releases.
 *
 * @param holding whether this publish must keep the previous payload: while the gate is Armed that
 *   is the gate's own answer; after the commit it is the legacy BUG-42 mid-load hold, which now
 *   covers newcomers only.
 * @param resetRequested an explicit Hero Sources change, which outranks the hold: the user is
 *   looking at the result, so a stale hero must leave now.
 */
fun heroPublishSource(
    heroEnabled: Boolean,
    catalogHeroEmpty: Boolean,
    holding: Boolean,
    resetRequested: Boolean,
): HeroPublishSource = when {
    !heroEnabled -> HeroPublishSource.Off
    !catalogHeroEmpty -> HeroPublishSource.Catalog
    holding && !resetRequested -> HeroPublishSource.Held
    else -> HeroPublishSource.CollectionFallback
}
