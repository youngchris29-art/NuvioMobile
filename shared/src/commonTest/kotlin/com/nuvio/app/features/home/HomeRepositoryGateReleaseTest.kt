package com.nuvio.app.features.home

import com.nuvio.app.core.auth.AuthState
import com.nuvio.app.features.addons.AddonCatalog
import com.nuvio.app.features.addons.AddonManifest
import com.nuvio.app.features.addons.AddonResource
import com.nuvio.app.features.addons.ManagedAddon
import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertFalse
import kotlin.test.assertTrue

/**
 * BUG-86 (Wave H, K1b): the repository-side rules around the hero commit gate. Two of them decide
 * whether the gate is RE-EVALUATED when one of its inputs becomes ready. Both were reasons a
 * launch could only end at `gate=released:timeout` even though every input had settled well inside
 * the 4 s budget. The last one (`retainHeroItemOrigins`) decides what keeps a committed hero item
 * committed, and therefore when a hero may be frozen and pinned a second time.
 *
 * Scope note: [HomeRepository] itself is not driven here. It is a singleton whose load path fetches
 * real catalog pages over the network (`fetchCatalogPage`), runs its fan-out on
 * `Dispatchers.Default` with wall-clock timers, and reads three other singletons (AddonRepository,
 * TmdbSettingsRepository, AuthRepository) that have no injection seam, so a test that drove it would
 * be a network-dependent, timing-dependent flake rather than coverage. The decision table it
 * applies is covered by `HeroCommitGateTest`; the rules below are the repository-side inputs to
 * that table, extracted as pure functions precisely so they can be asserted here. The end-to-end
 * behaviour stays gated by test31 leg A on the simulator.
 */
class HomeRepositoryGateReleaseTest {

    // -----------------------------------------------------------------------------------------
    // shouldPublishAfterBatch: the catalog fan-out's publish cadence
    // -----------------------------------------------------------------------------------------

    @Test
    fun aSettledHomeKeepsTheBatchPublishInterval() {
        // Batches 0 and 1 publish, 2 does not, 3 does: the churn bound the interval exists for.
        assertTrue(shouldPublishAfterBatch(batchIndex = 0, gateArmed = false))
        assertTrue(shouldPublishAfterBatch(batchIndex = 1, gateArmed = false))
        assertFalse(shouldPublishAfterBatch(batchIndex = 2, gateArmed = false))
        assertTrue(shouldPublishAfterBatch(batchIndex = 3, gateArmed = false))
        assertFalse(shouldPublishAfterBatch(batchIndex = 4, gateArmed = false))
    }

    @Test
    fun anArmedGatePublishesAfterEveryBatch() {
        // Each batch carries fetch OUTCOMES, which are a gate input. Skipping the evaluation costs
        // a whole network round trip out of the gate's budget and saves nothing: a held publish
        // emits an equal HomeUiState, which the StateFlow suppresses.
        (0..9).forEach { batchIndex ->
            assertTrue(
                shouldPublishAfterBatch(batchIndex = batchIndex, gateArmed = true),
                "batch $batchIndex must re-evaluate the armed gate",
            )
        }
    }

    // -----------------------------------------------------------------------------------------
    // publishedIsLoading: what a publish reports while the gate holds, and what it reports after
    // -----------------------------------------------------------------------------------------

    @Test
    fun aHeldPublishReportsLoadingWhateverTheFanOutIsDoing() {
        // The rows a held publish republishes are the previous, empty ones on a cold launch.
        assertTrue(publishedIsLoading(catalogLoadInProgress = true, rowsHeld = true))
        assertTrue(
            publishedIsLoading(catalogLoadInProgress = false, rowsHeld = true),
            "the fan-out finishing under an armed gate must not paint the empty or error state",
        )
    }

    @Test
    fun aReleaseReportsTheRealLoadState() {
        assertFalse(publishedIsLoading(catalogLoadInProgress = false, rowsHeld = false))
        assertTrue(publishedIsLoading(catalogLoadInProgress = true, rowsHeld = false))
    }

    /**
     * Codex branch review round 7, the bug in one sequence. A profile whose hero-source catalogs
     * fail (or come back empty) reaches the gate's release with the fan-out already over: the held
     * publish before it forced `isLoading = true`, and every publish that is not the fan-out's own
     * used to take its load state from the PUBLISHED value. Feeding that back in made `true`
     * absorbing: the release carried it, and so did every publish after, so the error state and its
     * Retry button were unreachable for the rest of the session and Home sat on the loading
     * placeholder. The real load state is an input now, not an echo.
     */
    @Test
    fun aReleaseAfterAFailedFanOutLeavesTheLoadingPlaceholder() {
        val catalogLoadInProgress = false // the fan-out ended, with an error and no sections

        val held = publishedIsLoading(catalogLoadInProgress = catalogLoadInProgress, rowsHeld = true)
        assertTrue(held, "the last held publish still reports loading")

        // The old shape: the next publish re-derived its load state from the published one.
        assertTrue(
            publishedIsLoading(catalogLoadInProgress = held, rowsHeld = false),
            "re-deriving from the published value is what pinned the placeholder on",
        )

        // The fixed shape: the release asks the load path, which says the fan-out is over.
        assertFalse(
            publishedIsLoading(catalogLoadInProgress = catalogLoadInProgress, rowsHeld = false),
            "the releasing publish must hand the error state through",
        )
    }

    // -----------------------------------------------------------------------------------------
    // hasUnresolvedEnabledManifests: can a persisted hero-source key still become a definition?
    // -----------------------------------------------------------------------------------------

    private fun manifest(id: String) = AddonManifest(
        id = id,
        name = id,
        description = "",
        version = "1.0.0",
        resources = listOf(AddonResource(name = "catalog", types = listOf("movie"))),
        types = listOf("movie"),
        catalogs = listOf(AddonCatalog(type = "movie", id = "top", name = "Top")),
        transportUrl = "https://example.com/$id/manifest.json",
    )

    private fun addon(
        id: String,
        enabled: Boolean = true,
        loaded: Boolean = true,
        refreshing: Boolean = false,
    ) = ManagedAddon(
        manifestUrl = "https://example.com/$id/manifest.json",
        manifest = if (loaded) manifest(id) else null,
        enabled = enabled,
        isRefreshing = refreshing,
    )

    @Test
    fun anAddonStillFetchingItsFirstManifestIsPending() {
        assertTrue(listOf(addon("a", loaded = false, refreshing = true)).hasUnresolvedEnabledManifests())
    }

    @Test
    fun aReFetchOfAnAlreadyLoadedManifestIsNotPending() {
        // The K1b fix. `refreshAddon` marks an addon with a manifest as refreshing, and the old
        // `enabled && isRefreshing` predicate then reported "a manifest is pending" for an add-on
        // whose catalogs were already definitions, pinning the gate on an answer that could not
        // change, for as long as the slowest re-fetch took.
        assertFalse(listOf(addon("a", loaded = true, refreshing = true)).hasUnresolvedEnabledManifests())
    }

    @Test
    fun aDisabledAddonIsNeverPending() {
        assertFalse(
            listOf(addon("a", enabled = false, loaded = false, refreshing = true))
                .hasUnresolvedEnabledManifests()
        )
    }

    @Test
    fun anAddonThatFailedItsManifestIsNotPending() {
        // No manifest and not fetching: it can never produce a definition, so waiting on it would
        // only burn the budget.
        assertFalse(listOf(addon("a", loaded = false, refreshing = false)).hasUnresolvedEnabledManifests())
    }

    @Test
    fun oneUnresolvedAddonAmongLoadedOnesIsPending() {
        assertTrue(
            listOf(
                addon("a", loaded = true, refreshing = true),
                addon("b", loaded = true),
                addon("c", loaded = false, refreshing = true),
            ).hasUnresolvedEnabledManifests()
        )
    }

    @Test
    fun anEmptyAddonListIsNotPending() {
        assertFalse(emptyList<ManagedAddon>().hasUnresolvedEnabledManifests())
    }

    // -----------------------------------------------------------------------------------------
    // launchSyncExpected: the second factor of the gate's sync term, and the third outside input
    // -----------------------------------------------------------------------------------------

    private fun authenticated(anonymous: Boolean) = AuthState.Authenticated(
        userId = "user-1",
        email = if (anonymous) null else "user@example.com",
        isAnonymous = anonymous,
    )

    @Test
    fun aSignedInAccountExpectsALaunchSync() {
        assertTrue(authenticated(anonymous = false).launchSyncExpected())
    }

    @Test
    fun aSignedOutAccountExpectsNoLaunchSync() {
        // This is the case the gate used to hold its whole budget on: no burst is coming, so
        // LaunchSyncState.Idle already MEANS settled, and nothing else would ever say so.
        assertFalse(AuthState.Unauthenticated.launchSyncExpected())
    }

    @Test
    fun anAnonymousAccountExpectsNoLaunchSync() {
        assertFalse(authenticated(anonymous = true).launchSyncExpected())
    }

    @Test
    fun aRestoringSessionStillExpectsALaunchSync() {
        // It can still resolve to a signed-in account; the gate's own timeout bounds a stalled
        // restore.
        assertTrue(AuthState.Loading.launchSyncExpected())
    }

    // -----------------------------------------------------------------------------------------
    // retainHeroItemOrigins: what keeps a committed hero item committed
    // -----------------------------------------------------------------------------------------

    /**
     * `pruneCommittedPayloadsLocked`'s rule, which is a single expression: a frozen payload
     * survives while its item still has an origin. Mirrored here so both steps can be asserted as
     * one sequence: the retention rule above it is the half that carries the logic.
     */
    private fun prune(committed: Map<String, String>, origins: Map<String, String>) =
        committed.filterKeys { itemKey -> itemKey in origins }

    @Test
    fun aCatalogItemKeepsItsOriginWhileItsDefinitionIsInstalled() {
        val origins = mapOf("item-1" to "addon.top")
        assertEquals(
            origins,
            retainHeroItemOrigins(
                origins = origins,
                knownDefinitionKeys = setOf("addon.top"),
                collectionHeroKeys = emptySet(),
            ),
        )
    }

    @Test
    fun aCatalogItemLosesItsOriginWhenItsDefinitionLeaves() {
        // The user removed or disabled the add-on: the one event allowed to evict a committed item.
        assertTrue(
            retainHeroItemOrigins(
                origins = mapOf("item-1" to "addon.top"),
                knownDefinitionKeys = setOf("other.addon"),
                collectionHeroKeys = emptySet(),
            ).isEmpty()
        )
    }

    @Test
    fun aCollectionHeroKeepsItsSentinelWhileItIsStillCached() {
        val origins = mapOf("item-1" to COLLECTION_HERO_ORIGIN)
        assertEquals(
            origins,
            retainHeroItemOrigins(
                origins = origins,
                // No catalog behind it, by definition: the sentinel is not a definition key.
                knownDefinitionKeys = emptySet(),
                collectionHeroKeys = setOf("item-1"),
            ),
        )
    }

    /**
     * Codex branch review round 5. The sentinel origin used to be preserved unconditionally, so a
     * collection-backed head stayed pinned and frozen after the collection behind it was gone. The
     * commit map never emptied, `serveCommittedHeroItemsLocked` skipped its re-freeze, and the
     * REPLACEMENT fallback was published unfrozen and unpinned, repaintable by the next
     * enrichment or sync publish.
     */
    @Test
    fun aSupersededCollectionHeroLosesItsSentinelAndItsCommit() {
        val committedPayloads = mapOf("old-1" to "payload-old-1", "old-2" to "payload-old-2")
        val committedOrigins = committedPayloads.keys.associateWith { COLLECTION_HERO_ORIGIN }

        // The collection request key changed: ensureCollectionHeroFallback empties
        // cachedCollectionHeroItems and publishes straight away, so this publish sees no cache.
        val afterInvalidation = retainHeroItemOrigins(
            origins = committedOrigins,
            knownDefinitionKeys = emptySet(),
            collectionHeroKeys = emptySet(),
        )
        assertTrue(afterInvalidation.isEmpty(), "the superseded fallback must stop being retainable")
        assertTrue(
            prune(committedPayloads, afterInvalidation).isEmpty(),
            "with no origin left, the frozen payloads and the pinned head go too",
        )

        // The replacement fallback resolves and publishes. Its items are the only ones with an
        // origin, and the commit map it re-freezes into is empty: a first commit, on the new head.
        val replacement = setOf("new-1", "new-2")
        val afterReplacement = retainHeroItemOrigins(
            origins = afterInvalidation + replacement.associateWith { COLLECTION_HERO_ORIGIN },
            knownDefinitionKeys = emptySet(),
            collectionHeroKeys = replacement,
        )
        assertEquals(replacement, afterReplacement.keys)
        assertTrue(
            prune(committedPayloads, afterReplacement).isEmpty(),
            "no payload from the previous collection may survive into the new commit",
        )
    }

    @Test
    fun theAuthTransitionThatSettlesTheGateChangesTheCollectedBoolean() {
        // Why the collector is mapped to this boolean rather than to AuthState: the collector must
        // fire on the transition that flips the gate's sync term (Loading -> Unauthenticated), and
        // must NOT fire on an Authenticated state being rewritten with the same answer (a token
        // refresh), which distinctUntilChanged then suppresses.
        assertTrue(AuthState.Loading.launchSyncExpected() != AuthState.Unauthenticated.launchSyncExpected())
        assertEquals(
            authenticated(anonymous = false).launchSyncExpected(),
            AuthState.Authenticated(userId = "user-1", email = "new@example.com", isAnonymous = false)
                .launchSyncExpected(),
        )
    }
}
