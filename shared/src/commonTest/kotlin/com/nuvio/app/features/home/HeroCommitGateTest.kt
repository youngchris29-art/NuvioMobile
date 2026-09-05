package com.nuvio.app.features.home

import com.nuvio.app.core.sync.LaunchSyncSignal.LaunchSyncState
import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertFalse
import kotlin.test.assertNotNull
import kotlin.test.assertNull
import kotlin.test.assertTrue

/**
 * BUG-86 (Wave H): the hero commit gate's decision table. Every case here is a launch shape that
 * produced a second, different hero commit on a tester's TV.
 */
class HeroCommitGateTest {

    /** A healthy launch: both hero sources loaded, sync settled, nothing outstanding. */
    private fun readyInputs(
        heroEnabled: Boolean = true,
        heroSourceKeys: Set<String> = setOf("a", "b"),
        knownDefinitionKeys: Set<String> = setOf("a", "b", "c"),
        outcomes: Map<String, CatalogOutcome> = mapOf(
            "a" to CatalogOutcome.Loaded,
            "b" to CatalogOutcome.Loaded,
        ),
        manifestsPending: Boolean = false,
        syncState: LaunchSyncState = LaunchSyncState.Settled,
        launchSyncExpected: Boolean = true,
        enrichmentPending: Int = 0,
        candidateEmpty: Boolean = false,
        heroSourcesAllOff: Boolean = false,
        resetRequested: Boolean = false,
        elapsedMs: Long = 500,
    ) = HeroGateInputs(
        heroEnabled = heroEnabled,
        heroSourceKeys = heroSourceKeys,
        knownDefinitionKeys = knownDefinitionKeys,
        outcomes = outcomes,
        manifestsPending = manifestsPending,
        syncState = syncState,
        launchSyncExpected = launchSyncExpected,
        enrichmentPending = enrichmentPending,
        candidateEmpty = candidateEmpty,
        heroSourcesAllOff = heroSourcesAllOff,
        resetRequested = resetRequested,
        elapsedMs = elapsedMs,
    )

    @Test
    fun releasesAllWhenEverythingSettled() {
        val decision = decideHeroGate(readyInputs())
        assertTrue(decision.released)
        assertEquals(HeroGateReason.ALL, decision.reason)
        assertEquals(HeroGateState.Released, decision.state)
    }

    @Test
    fun holdsWhileAHeroSourceCatalogHasNoOutcome() {
        val decision = decideHeroGate(
            readyInputs(outcomes = mapOf("a" to CatalogOutcome.Loaded))
        )
        assertFalse(decision.released)
        assertEquals(HeroGateState.Armed, decision.state)
        assertNull(decision.reason)
    }

    @Test
    fun aFailedFetchStillSettlesItsSource() {
        val decision = decideHeroGate(
            readyInputs(
                outcomes = mapOf("a" to CatalogOutcome.Failed, "b" to CatalogOutcome.Loaded),
            )
        )
        assertEquals(HeroGateReason.ALL, decision.reason)
    }

    @Test
    fun holdsWhileAPersistedHeroSourceKeyIsUnknownAndManifestsPending() {
        // "b" is persisted but its add-on manifest has not arrived, so no definition exists yet.
        val decision = decideHeroGate(
            readyInputs(
                knownDefinitionKeys = setOf("a"),
                outcomes = mapOf("a" to CatalogOutcome.Loaded),
                manifestsPending = true,
            )
        )
        assertFalse(decision.released)
    }

    @Test
    fun releasesWhenAnUnknownKeyCanNoLongerArrive() {
        // Same shape, manifests settled: "b" names a catalog this profile no longer has.
        val decision = decideHeroGate(
            readyInputs(
                knownDefinitionKeys = setOf("a"),
                outcomes = mapOf("a" to CatalogOutcome.Loaded),
                manifestsPending = false,
            )
        )
        assertEquals(HeroGateReason.ALL, decision.reason)
    }

    @Test
    fun holdsWhileTheLaunchSyncBurstIsRunning() {
        assertFalse(decideHeroGate(readyInputs(syncState = LaunchSyncState.Running)).released)
    }

    @Test
    fun releasesWhenTheProfileGetsNoLaunchSync() {
        assertEquals(
            HeroGateReason.ALL,
            decideHeroGate(readyInputs(syncState = LaunchSyncState.NotApplicable)).reason,
        )
    }

    @Test
    fun holdsOnIdleSyncWhileASyncIsStillExpected() {
        assertFalse(
            decideHeroGate(
                readyInputs(syncState = LaunchSyncState.Idle, launchSyncExpected = true)
            ).released
        )
    }

    @Test
    fun idleSyncIsReadyForASignedOutAccount() {
        assertEquals(
            HeroGateReason.ALL,
            decideHeroGate(
                readyInputs(syncState = LaunchSyncState.Idle, launchSyncExpected = false)
            ).reason,
        )
    }

    @Test
    fun holdsWhileEnrichmentIsOutstanding() {
        assertFalse(decideHeroGate(readyInputs(enrichmentPending = 3)).released)
    }

    @Test
    fun candidateEmptyNeverReleasesAll() {
        val decision = decideHeroGate(readyInputs(candidateEmpty = true))
        assertFalse(decision.released)
        assertNull(decision.reason)
    }

    @Test
    fun timeoutReleasesRegardlessOfEveryOtherInput() {
        val decision = decideHeroGate(
            readyInputs(
                outcomes = emptyMap(),
                manifestsPending = true,
                syncState = LaunchSyncState.Running,
                enrichmentPending = 8,
                elapsedMs = HERO_COMMIT_GATE_TIMEOUT_MS,
            )
        )
        assertEquals(HeroGateReason.TIMEOUT, decision.reason)
    }

    @Test
    fun timeoutDoesNotReleaseAnEmptyCandidateEarly() {
        // One millisecond before the cap the gate is still holding, even with nothing to show.
        assertFalse(
            decideHeroGate(
                readyInputs(candidateEmpty = true, elapsedMs = HERO_COMMIT_GATE_TIMEOUT_MS - 1)
            ).released
        )
    }

    @Test
    fun heroOffOutranksEveryOtherReason() {
        val decision = decideHeroGate(
            readyInputs(
                heroEnabled = false,
                resetRequested = true,
                syncState = LaunchSyncState.Running,
                elapsedMs = HERO_COMMIT_GATE_TIMEOUT_MS + 1,
            )
        )
        assertEquals(HeroGateReason.HERO_OFF, decision.reason)
    }

    @Test
    fun anExplicitResetReleasesWithoutWaitingForTheBurst() {
        val decision = decideHeroGate(
            readyInputs(
                resetRequested = true,
                outcomes = emptyMap(),
                syncState = LaunchSyncState.Running,
                enrichmentPending = 4,
            )
        )
        assertEquals(HeroGateReason.RESET, decision.reason)
    }

    @Test
    fun noSourcesReleasesACollectionOnlyProfile() {
        val decision = decideHeroGate(
            readyInputs(
                heroSourceKeys = emptySet(),
                knownDefinitionKeys = emptySet(),
                outcomes = emptyMap(),
                manifestsPending = false,
                candidateEmpty = true,
            )
        )
        assertEquals(HeroGateReason.NO_SOURCES, decision.reason)
    }

    @Test
    fun noSourcesWaitsWhileAManifestCanStillProduceACatalog() {
        val decision = decideHeroGate(
            readyInputs(
                heroSourceKeys = emptySet(),
                knownDefinitionKeys = emptySet(),
                outcomes = emptyMap(),
                manifestsPending = true,
                candidateEmpty = true,
            )
        )
        assertFalse(decision.released)
    }

    // -----------------------------------------------------------------------------------------
    // K1b: `gateWait` — the first unmet input, so a `released:timeout` line in a tester's photo
    // says WHICH input was late instead of only that the budget ran out.
    // -----------------------------------------------------------------------------------------

    @Test
    fun aHealthyReleaseIsWaitingOnNothing() {
        assertEquals(HeroGateWait.NONE, decideHeroGate(readyInputs()).waiting)
    }

    @Test
    fun anUnsettledCatalogReportsSources() {
        val decision = decideHeroGate(readyInputs(outcomes = mapOf("a" to CatalogOutcome.Loaded)))
        assertEquals(HeroGateWait.SOURCES, decision.waiting)
    }

    @Test
    fun anUnresolvedPersistedKeyReportsSourcesEvenWithEveryTrackedKeySettled() {
        // The exact shape the settled-count probe cannot show: every key that HAS a definition has
        // an outcome (`sources=1/1`), and the gate is still held by a persisted key whose add-on
        // manifest has not landed.
        val decision = decideHeroGate(
            readyInputs(
                knownDefinitionKeys = setOf("a"),
                outcomes = mapOf("a" to CatalogOutcome.Loaded),
                manifestsPending = true,
            )
        )
        assertFalse(decision.released)
        assertEquals(HeroGateWait.SOURCES, decision.waiting)
    }

    @Test
    fun aRunningBurstReportsSync() {
        assertEquals(
            HeroGateWait.SYNC,
            decideHeroGate(readyInputs(syncState = LaunchSyncState.Running)).waiting,
        )
    }

    @Test
    fun outstandingEnrichmentReportsEnrich() {
        assertEquals(HeroGateWait.ENRICH, decideHeroGate(readyInputs(enrichmentPending = 2)).waiting)
    }

    @Test
    fun anEmptyCandidateWithEverythingElseSettledReportsEmpty() {
        assertEquals(HeroGateWait.EMPTY, decideHeroGate(readyInputs(candidateEmpty = true)).waiting)
    }

    @Test
    fun sourcesOutrankAnEmptyCandidate() {
        // An empty candidate list is a symptom of unloaded catalogs, so the CAUSE is reported.
        val decision = decideHeroGate(readyInputs(outcomes = emptyMap(), candidateEmpty = true))
        assertEquals(HeroGateWait.SOURCES, decision.waiting)
    }

    @Test
    fun aTimeoutCarriesTheInputItWasWaitingOn() {
        val decision = decideHeroGate(
            readyInputs(
                syncState = LaunchSyncState.Running,
                elapsedMs = HERO_COMMIT_GATE_TIMEOUT_MS,
            )
        )
        assertEquals(HeroGateReason.TIMEOUT, decision.reason)
        assertEquals(HeroGateWait.SYNC, decision.waiting)
    }

    @Test
    fun aTimeoutWithEveryInputReadyIsAMissingReEvaluation() {
        // The K1b signature: the budget ran out with nothing outstanding, which can only mean no
        // event re-evaluated the gate when its last input became ready.
        val decision = decideHeroGate(readyInputs(elapsedMs = HERO_COMMIT_GATE_TIMEOUT_MS))
        assertEquals(HeroGateReason.TIMEOUT, decision.reason)
        assertEquals(HeroGateWait.NONE, decision.waiting)
    }

    @Test
    fun heroOffAndResetReportNothingOutstanding() {
        assertEquals(
            HeroGateWait.NONE,
            decideHeroGate(readyInputs(heroEnabled = false, syncState = LaunchSyncState.Running)).waiting,
        )
        assertEquals(
            HeroGateWait.NONE,
            decideHeroGate(readyInputs(resetRequested = true, outcomes = emptyMap())).waiting,
        )
    }

    // -----------------------------------------------------------------------------------------
    // The `noSources` re-arm: the slow-addon profile, start to finish.
    // -----------------------------------------------------------------------------------------

    /**
     * The whole sequence a profile whose add-on manifests land after the Idle budget goes through.
     * Before the re-arm existed it stopped at step 1: the gate stayed Released on a
     * claim that had been falsified, and the catalog hero that arrived afterwards was never
     * committed, never frozen and never pinned.
     */
    @Test
    fun noSourcesThenACatalogRefreshCommitsAndPinsTheCatalogHero() {
        // 1. The grace lifts with no definitions and no manifest still in flight: nothing can
        //    supply a hero, so the gate must not hold Home behind a timer it never armed.
        val noSources = decideHeroGate(
            readyInputs(
                heroSourceKeys = emptySet(),
                knownDefinitionKeys = emptySet(),
                outcomes = emptyMap(),
                manifestsPending = false,
                candidateEmpty = true,
            )
        )
        assertEquals(HeroGateReason.NO_SOURCES, noSources.reason)

        // 2. A catalog-bearing refresh arrives, which falsifies that claim. This is the ONLY
        //    release the repository is allowed to take back.
        assertTrue(heroGateShouldRearm(HeroGateState.Released, noSources.reason))

        // 3. Re-armed with a fresh budget: the catalogs are fetching, so the gate holds again.
        val rearmed = decideHeroGate(
            readyInputs(
                heroSourceKeys = setOf("a", "b"),
                knownDefinitionKeys = setOf("a", "b"),
                outcomes = emptyMap(),
                candidateEmpty = true,
                elapsedMs = 0,
            )
        )
        assertEquals(HeroGateState.Armed, rearmed.state)
        assertEquals(HeroGateWait.SOURCES, rearmed.waiting)

        // 4. Both catalogs settle and the second release is an ordinary commit, not another
        //    `noSources`.
        val committed = decideHeroGate(
            readyInputs(
                heroSourceKeys = setOf("a", "b"),
                knownDefinitionKeys = setOf("a", "b"),
                elapsedMs = 1_200,
            )
        )
        assertEquals(HeroGateReason.ALL, committed.reason)
        assertFalse(heroGateShouldRearm(HeroGateState.Released, committed.reason))

        // 5. And the head that commit chose is pinned to index 0 from then on, even after a later
        //    publish re-ranks the pool under it (the burst's reorder).
        val head = "movie:head"
        val reranked = listOf("movie:other", head, "movie:third")
        assertEquals(
            listOf(head, "movie:other", "movie:third"),
            pinCommittedHead(
                ranking = reranked,
                committedKey = head,
                keepFrom = reranked,
                key = { it },
            ),
        )
    }

    @Test
    fun onlyANoSourcesReleaseMayReArm() {
        // Every other reason IS a hero commit: re-arming on one would let the head move again,
        // which is the bug the gate exists to prevent.
        listOf(
            HeroGateReason.ALL,
            HeroGateReason.TIMEOUT,
            HeroGateReason.HERO_OFF,
            HeroGateReason.RESET,
            null,
        ).forEach { reason ->
            assertFalse(
                heroGateShouldRearm(HeroGateState.Released, reason),
                "a $reason release must stay committed",
            )
        }
    }

    @Test
    fun anUnreleasedGateNeverReArms() {
        // Re-arming an Idle or Armed gate would restart the budget mid-launch and could hold Home
        // past its own timeout.
        assertFalse(heroGateShouldRearm(HeroGateState.Idle, HeroGateReason.NO_SOURCES))
        assertFalse(heroGateShouldRearm(HeroGateState.Armed, HeroGateReason.NO_SOURCES))
    }

    // -----------------------------------------------------------------------------------------
    // Codex round 2: an ALL-OFF hero-source selection is not a reason to spend the whole budget
    // -----------------------------------------------------------------------------------------

    @Test
    fun anAllOffSelectionWithSettledManifestsDoesNotWaitOutTheBudgetOnAnEmptyCandidate() {
        // Every hero source turned off: the pool excludes every catalog by construction, so no
        // amount of waiting can fill the candidate. Holding would only reach the same empty hero
        // 4 s later, with Home's rows held behind it the whole time.
        val decision = decideHeroGate(
            readyInputs(
                heroSourceKeys = emptySet(),
                outcomes = emptyMap(),
                candidateEmpty = true,
                heroSourcesAllOff = true,
            )
        )
        assertEquals(HeroGateReason.ALL, decision.reason)
        assertEquals(HeroGateWait.NONE, decision.waiting)
    }

    @Test
    fun anAllOffSelectionStillWaitsWhileAManifestCanStillProduceACatalog() {
        // A catalog whose add-on has not loaded yet has no stored preference, so normalize's
        // second pass would seat it in the slots the all-off selection freed. The definition set
        // has to be final before "no source can ever fill this" is true.
        val decision = decideHeroGate(
            readyInputs(
                heroSourceKeys = emptySet(),
                knownDefinitionKeys = setOf("a"),
                outcomes = mapOf("a" to CatalogOutcome.Loaded),
                manifestsPending = true,
                candidateEmpty = true,
                heroSourcesAllOff = true,
            )
        )
        assertFalse(decision.released)
        assertEquals(HeroGateWait.EMPTY, decision.waiting)
    }

    @Test
    fun anAllOffSelectionWithACollectionFallbackCommitsTheFallback() {
        // The candidate already includes the collection fallback (see `heroPublishSource`), so
        // this releases on `all` with something to show rather than on the timeout with nothing.
        val decision = decideHeroGate(
            readyInputs(
                heroSourceKeys = emptySet(),
                outcomes = emptyMap(),
                candidateEmpty = false,
                heroSourcesAllOff = true,
            )
        )
        assertEquals(HeroGateReason.ALL, decision.reason)
    }

    @Test
    fun anEmptySelectionThatIsMerelyUnknownStillWaits() {
        // The same empty key set WITHOUT the all-off flag is "no selection is known yet" (a fresh
        // profile whose definitions have not arrived), which must keep waiting.
        val decision = decideHeroGate(
            readyInputs(
                heroSourceKeys = emptySet(),
                outcomes = emptyMap(),
                candidateEmpty = true,
                heroSourcesAllOff = false,
            )
        )
        assertFalse(decision.released)
        assertEquals(HeroGateWait.EMPTY, decision.waiting)
    }

    // -----------------------------------------------------------------------------------------
    // Codex round 2: heroPublishSource — a release must be able to take the collection fallback
    // in the SAME publish that releases.
    // -----------------------------------------------------------------------------------------

    @Test
    fun aCatalogHeroAlwaysOutranksTheFallbackAndTheHold() {
        assertEquals(
            HeroPublishSource.Catalog,
            heroPublishSource(
                heroEnabled = true,
                catalogHeroEmpty = false,
                holding = true,
                resetRequested = false,
            ),
        )
    }

    @Test
    fun heroOffPublishesNothingEvenWhileHolding() {
        assertEquals(
            HeroPublishSource.Off,
            heroPublishSource(
                heroEnabled = false,
                catalogHeroEmpty = true,
                holding = true,
                resetRequested = false,
            ),
        )
    }

    @Test
    fun anArmedGateHoldsTheFallbackBackMidLoad() {
        // BUG-42's rule, now expressed through the gate: the fallback is for a Home whose catalogs
        // yield no hero, not for the first few hundred ms before they land.
        assertEquals(
            HeroPublishSource.Held,
            heroPublishSource(
                heroEnabled = true,
                catalogHeroEmpty = true,
                holding = true,
                resetRequested = false,
            ),
        )
    }

    @Test
    fun anExplicitResetOutranksTheHold() {
        // The user just changed Hero Sources and is looking at the result: the stale hero goes now.
        assertEquals(
            HeroPublishSource.CollectionFallback,
            heroPublishSource(
                heroEnabled = true,
                catalogHeroEmpty = true,
                holding = true,
                resetRequested = true,
            ),
        )
    }

    /**
     * The Codex round 2 P1, end to end: hero-source catalogs that came back with nothing usable,
     * a collection fallback that resolved BEFORE the budget ran out, and a gate held by the launch
     * sync burst until the timeout.
     *
     * The old order — publish list chosen while Armed, gate released afterwards in the same
     * publish — committed the previous (empty) hero here and froze it, and nothing published
     * again: the fan-out was over and the release had just cancelled the gate's watchers, so the
     * collection hero stayed missing for the rest of the session.
     */
    @Test
    fun aTimeoutReleaseCommitsTheResolvedCollectionFallbackRatherThanTheEmptyHeldHero() {
        // 1. The candidate is what the publish would carry with nothing holding it, so it is the
        //    resolved fallback, and the gate is asked about THAT.
        val candidateSource = heroPublishSource(
            heroEnabled = true,
            catalogHeroEmpty = true,
            holding = false,
            resetRequested = false,
        )
        assertEquals(HeroPublishSource.CollectionFallback, candidateSource)

        // 2. Held by the burst, one millisecond inside the budget: the previous hero is
        //    republished unchanged.
        val held = decideHeroGate(
            readyInputs(
                candidateEmpty = false,
                syncState = LaunchSyncState.Running,
                elapsedMs = HERO_COMMIT_GATE_TIMEOUT_MS - 1,
            )
        )
        assertFalse(held.released)
        assertEquals(
            HeroPublishSource.Held,
            heroPublishSource(
                heroEnabled = true,
                catalogHeroEmpty = true,
                holding = !held.released,
                resetRequested = false,
            ),
        )

        // 3. The budget runs out. The release and the list are decided in this one publish, so the
        //    commit is the collection fallback, not the empty hero that was being held.
        val releasedOnTimeout = decideHeroGate(
            readyInputs(
                candidateEmpty = false,
                syncState = LaunchSyncState.Running,
                elapsedMs = HERO_COMMIT_GATE_TIMEOUT_MS,
            )
        )
        assertEquals(HeroGateReason.TIMEOUT, releasedOnTimeout.reason)
        assertEquals(
            HeroPublishSource.CollectionFallback,
            heroPublishSource(
                heroEnabled = true,
                catalogHeroEmpty = true,
                holding = !releasedOnTimeout.released,
                resetRequested = false,
            ),
        )
    }

    @Test
    fun aFallbackThatResolvesInsideTheBudgetReleasesOnAllRatherThanEmpty() {
        // The same launch with the burst settled: a non-empty candidate is a commit, so the
        // fallback lands without spending the budget at all.
        val decision = decideHeroGate(readyInputs(candidateEmpty = false))
        assertEquals(HeroGateReason.ALL, decision.reason)
        assertEquals(
            HeroPublishSource.CollectionFallback,
            heroPublishSource(
                heroEnabled = true,
                catalogHeroEmpty = true,
                holding = !decision.released,
                resetRequested = false,
            ),
        )
    }

    // ---------------------------------------------------------------------------------------
    // The Idle half of the table: publishes that land before the first catalog-bearing refresh.
    // ---------------------------------------------------------------------------------------

    @Test
    fun theIdleHoldCoversThePublishesBeforeTheFirstCatalogBearingRefresh() {
        // Releasing here would commit an empty hero on every launch, before the add-on manifests
        // have arrived, so inside the budget the answer is always hold.
        val decision = assertNotNull(
            decideIdleHeroGate(awaitingFirstRefresh = true, idleElapsedMs = 0)
        )
        assertFalse(decision.released)
        assertEquals(HeroGateState.Armed, decision.state)
        assertNull(decision.reason)
        assertEquals(HeroGateWait.SOURCES, decision.waiting)
    }

    @Test
    fun theIdleHoldStillHoldsOneMillisecondInsideTheBudget() {
        assertNotNull(
            decideIdleHeroGate(
                awaitingFirstRefresh = true,
                idleElapsedMs = HERO_COMMIT_GATE_TIMEOUT_MS - 1,
            )
        )
    }

    @Test
    fun theIdleHoldEndsAtTheGateBudget() {
        // The escape. A profile whose enabled add-ons declare no catalogs (a subtitle or
        // stream-only add-on plus collections) never gets a catalog-bearing refresh, so the gate's
        // own timer is never armed and this is the only bound the hold has. Without it the whole
        // of Home, rows included since Wave H, sat on "Setting up your catalogs..." until the
        // separate first-refresh grace lifted, on every launch.
        assertNull(
            decideIdleHeroGate(
                awaitingFirstRefresh = true,
                idleElapsedMs = HERO_COMMIT_GATE_TIMEOUT_MS,
            )
        )
        assertNull(
            decideIdleHeroGate(
                awaitingFirstRefresh = true,
                idleElapsedMs = HERO_COMMIT_GATE_TIMEOUT_MS * 2,
            )
        )
    }

    @Test
    fun aLiftedFirstRefreshGraceEndsTheIdleHoldWhateverTheElapsedTime() {
        // The pre-existing exit, unchanged: once the grace has lifted awaitingFirstRefresh the
        // caller falls through to the full table on the very next publish.
        assertNull(decideIdleHeroGate(awaitingFirstRefresh = false, idleElapsedMs = 0))
    }

    @Test
    fun theIdleEscapeFallsThroughToNoSourcesAndPublishesTheCollectionFallback() {
        // The whole point of the escape, end to end. Falling through means asking the full table
        // with an EMPTY definition set (what `evaluateHeroGateLocked` reports once it is still Idle
        // past the hold), which is the profile's honest state: no catalog can supply a hero here.
        assertNull(
            decideIdleHeroGate(
                awaitingFirstRefresh = true,
                idleElapsedMs = HERO_COMMIT_GATE_TIMEOUT_MS,
            )
        )
        val decision = decideHeroGate(
            readyInputs(
                heroSourceKeys = emptySet(),
                knownDefinitionKeys = emptySet(),
                outcomes = emptyMap(),
                manifestsPending = false,
                candidateEmpty = true,
                elapsedMs = 0,
            )
        )
        assertTrue(decision.released)
        assertEquals(HeroGateReason.NO_SOURCES, decision.reason)
        // Released with an empty catalog hero, so the rows publish and the hero comes from the
        // collection fallback rather than being held for the rest of the grace.
        assertEquals(
            HeroPublishSource.CollectionFallback,
            heroPublishSource(
                heroEnabled = true,
                catalogHeroEmpty = true,
                holding = !decision.released,
                resetRequested = false,
            ),
        )
    }

    @Test
    fun theIdleBudgetIsTheSameOneEveryOtherLaunchShapeGets() {
        // The bug was an asymmetry, not a missing timer: a catalog-BEARING launch is bounded at
        // HERO_COMMIT_GATE_TIMEOUT_MS by the armed path's own timeout, while the catalog-less one,
        // which has strictly less to wait for, was bounded only by the longer first-refresh grace.
        val armedAtBudget = decideHeroGate(
            readyInputs(syncState = LaunchSyncState.Running, elapsedMs = HERO_COMMIT_GATE_TIMEOUT_MS)
        )
        assertTrue(armedAtBudget.released)
        assertEquals(HeroGateReason.TIMEOUT, armedAtBudget.reason)
        assertNull(
            decideIdleHeroGate(
                awaitingFirstRefresh = true,
                idleElapsedMs = HERO_COMMIT_GATE_TIMEOUT_MS,
            )
        )
    }
}
