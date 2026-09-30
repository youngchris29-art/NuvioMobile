package com.nuvio.app.features.mdblist

import com.nuvio.app.features.tracking.TrackingCapability
import com.nuvio.app.features.tracking.TrackingProviderId
import kotlin.test.AfterTest
import kotlin.test.BeforeTest
import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertFalse
import kotlin.test.assertNotNull
import kotlin.test.assertNull
import kotlin.test.assertTrue

/**
 * JVM-only on purpose: [MdbListTracker] reads its platform persistence while initialising, which on
 * Apple targets is the Keychain — unavailable to the native test executable (upstream needed a
 * keychain entitlements file for its iOS test target). The JVM actual is an in-memory map.
 */
class MdbListTrackerJvmTest {
    private val profileId get() = MdbListTracker.store.scope().profileId

    @BeforeTest
    fun alignWithActiveProfile() {
        // Other suites in this JVM may have moved ProfileRepository's active profile.
        MdbListTracker.ensureLoaded()
    }

    @AfterTest
    fun reset() {
        PlatformMdbListAuthPersistence.clear()
        MdbListTracker.clearLocalState()
    }

    @Test
    fun phaseOneRegistersAccountConnectionOnly() {
        assertEquals(TrackingProviderId.MDBLIST, MdbListTracker.descriptor.id)
        assertEquals("MDBList", MdbListTracker.descriptor.displayName)
        assertEquals(setOf(TrackingCapability.AUTHENTICATION), MdbListTracker.descriptor.capabilities)
    }

    @Test
    fun clearLocalStateIsMemoryOnly() {
        val scope = MdbListTracker.store.scope()
        assertTrue(MdbListTracker.store.authorize(MdbListTokens("access", "refresh", Long.MAX_VALUE), scope))
        MdbListTracker.ensureLoaded()
        assertTrue(MdbListTracker.isAuthenticated.value)
        val generation = MdbListTracker.accountGeneration

        MdbListTracker.clearLocalState()

        assertFalse(MdbListTracker.isAuthenticated.value)
        assertFalse(MdbListTracker.store.state.value.isAuthenticated)
        assertTrue(MdbListTracker.accountGeneration > generation)
        // Disk is the account wipe's job (AccountDataStores), never the tracker's.
        assertNotNull(PlatformMdbListAuthPersistence.read(profileId))
    }

    @Test
    fun removeStoredProfileErasesThatProfilesCredentials() {
        assertTrue(MdbListTracker.store.authorize(MdbListTokens("access", "refresh", Long.MAX_VALUE), MdbListTracker.store.scope()))
        assertNotNull(PlatformMdbListAuthPersistence.read(profileId))

        MdbListTracker.removeStoredProfile(profileId)

        assertNull(PlatformMdbListAuthPersistence.read(profileId))
        assertFalse(MdbListTracker.store.state.value.isAuthenticated)
    }

    @Test
    fun accountUiStateFlattensPendingDeviceAuthorization() {
        val session = MdbListDeviceSession(
            userCode = "ABCD-EFGH",
            verificationUri = "https://mdblist.com/oauth/device/",
            verificationUriComplete = "https://mdblist.com/oauth/device/?user_code=ABCD-EFGH",
            expiresAtEpochMs = 1_000L,
            intervalSeconds = 5,
            nextPollAtEpochMs = 500L,
        )
        assertTrue(MdbListTracker.store.saveSession(session, "device-secret", MdbListTracker.store.scope()))

        val state = MdbListTracker.accountUiState.value.takeIf { it.userCode != null }
            ?: waitForUiState { it.userCode != null }
        assertEquals("ABCD-EFGH", state.userCode)
        assertEquals("https://mdblist.com/oauth/device/?user_code=ABCD-EFGH", state.verificationUrlComplete)
        assertTrue(state.isAwaitingApproval)
        assertFalse(state.isConnected)
        assertEquals(MdbListConfig.CLIENT_ID.isNotBlank(), state.hasClientId)
    }

    private fun waitForUiState(predicate: (MdbListAccountUiState) -> Boolean): MdbListAccountUiState {
        repeat(200) {
            MdbListTracker.accountUiState.value.takeIf(predicate)?.let { return it }
            Thread.sleep(10)
        }
        return MdbListTracker.accountUiState.value
    }
}
