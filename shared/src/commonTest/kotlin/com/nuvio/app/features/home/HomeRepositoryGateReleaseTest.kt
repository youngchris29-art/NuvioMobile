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
 * BUG-86 (Wave H, K1b): the two repository-side rules that decide whether the hero commit gate is
 * RE-EVALUATED when one of its inputs becomes ready. Both were reasons a launch could only end at
 * `gate=released:timeout` even though every input had settled well inside the 4 s budget.
 *
 * Scope note: [HomeRepository] itself is not driven here. It is a singleton whose load path fetches
 * real catalog pages over the network (`fetchCatalogPage`), runs its fan-out on
 * `Dispatchers.Default` with wall-clock timers, and reads three other singletons (AddonRepository,
 * TmdbSettingsRepository, AuthRepository) that have no injection seam, so a test that drove it would
 * be a network-dependent, timing-dependent flake rather than coverage. The decision table it
 * applies is covered by `HeroCommitGateTest`; the two rules below are the repository-side inputs to
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
