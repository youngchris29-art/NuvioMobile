package com.nuvio.app.features.addons

import com.nuvio.app.core.auth.AuthState
import kotlin.test.Test
import kotlin.test.assertFalse
import kotlin.test.assertTrue

// Pure-function coverage for the beta.15 addon-wipe guards (see
// docs/addon-wipe-investigation-2026-08-28.md). Deliberately does not touch AddonRepository or
// AuthRepository — both are singletons with network/platform dependencies — so these tests only
// exercise the two top-level decision functions the repository delegates to.
class AddonSyncGuardsTest {
    private val authenticatedNonAnon = AuthState.Authenticated(userId = "u1", email = "u1@example.com", isAnonymous = false)
    private val authenticatedAnon = AuthState.Authenticated(userId = "u2", email = null, isAnonymous = true)

    @Test
    fun `blocks push for a signed-in account whose addons were never pulled`() {
        assertTrue(shouldBlockUnhydratedAddonPush(authenticatedNonAnon, pulledFromServer = false))
    }

    @Test
    fun `allows push for a signed-in account once addons have been pulled`() {
        assertFalse(shouldBlockUnhydratedAddonPush(authenticatedNonAnon, pulledFromServer = true))
    }

    @Test
    fun `allows push for an anonymous account regardless of pull state`() {
        assertFalse(shouldBlockUnhydratedAddonPush(authenticatedAnon, pulledFromServer = false))
    }

    @Test
    fun `allows push when signed out`() {
        assertFalse(shouldBlockUnhydratedAddonPush(AuthState.Unauthenticated, pulledFromServer = false))
    }

    @Test
    fun `allows push while auth state is still loading`() {
        assertFalse(shouldBlockUnhydratedAddonPush(AuthState.Loading, pulledFromServer = false))
    }

    @Test
    fun `allows seeding immediately when signed out`() {
        assertTrue(defaultAddonSeedingAllowed(AuthState.Unauthenticated, serverPullSettled = false))
    }

    @Test
    fun `allows seeding immediately while auth state is still loading`() {
        assertTrue(defaultAddonSeedingAllowed(AuthState.Loading, serverPullSettled = false))
    }

    @Test
    fun `allows seeding immediately for an anonymous account`() {
        assertTrue(defaultAddonSeedingAllowed(authenticatedAnon, serverPullSettled = false))
    }

    @Test
    fun `blocks seeding for a signed-in account before the server pull settles`() {
        assertFalse(defaultAddonSeedingAllowed(authenticatedNonAnon, serverPullSettled = false))
    }

    @Test
    fun `allows seeding for a signed-in account once the server pull has settled`() {
        assertTrue(defaultAddonSeedingAllowed(authenticatedNonAnon, serverPullSettled = true))
    }
}
