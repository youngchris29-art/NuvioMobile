package com.nuvio.app.core.identity

import com.nuvio.app.core.auth.AuthState
import com.nuvio.app.features.profiles.NuvioProfile
import com.nuvio.app.features.profiles.PinVerifyResult
import com.nuvio.app.features.profiles.ProfilePinCacheStorage
import com.nuvio.app.features.profiles.ProfileRepository
import com.nuvio.app.features.profiles.ProfileState
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.test.runTest
import kotlinx.coroutines.withContext
import kotlin.test.AfterTest
import kotlin.test.BeforeTest
import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertFalse
import kotlin.test.assertNotNull
import kotlin.test.assertTrue

/* W2 audit of 48217e880: PIN verify hands back the row the select uses; read-only verify in FailedApply; one list stamp. */

private fun real(block: suspend CoroutineScope.() -> Unit) = runTest { withContext(Dispatchers.Default) { block() } }

class PinVerifyRowTest {
    private val token = AccountToken(accountA, 1)
    private val kid = NuvioProfile(id = "kid", profileIndex = 2, name = "Kid", pinEnabled = true, updatedAt = "t1")
    private var rpcCalls = 0

    @BeforeTest fun setUp() {
        resetIdentityForTest(serial = 1)
        IdentityRuntime.setForTest(BarrierState.initial(1).copy(scope = IdentityScope(accountA, 1), latestAccount = accountA))
        ProfileIdentityRouterProvider.router = BarrierProfileIdentityRouter(FakeRouterPorts(EventLog()))
        ProfileRepository.setStateForTest(ProfileState(profiles = listOf(NuvioProfile(id = "one", profileIndex = 1), kid), isLoaded = true, listToken = token), "user-a")
        // The server row after the verify: a new revision and lock-out field, same row and PIN state.
        ProfileRepository.verifyRpcForTest = { _, _ ->
            rpcCalls++
            val s = ProfileRepository.state.value
            ProfileRepository.setStateForTest(s.copy(profiles = s.profiles.map {
                if (it.profileIndex == 2) it.copy(updatedAt = "t2", pinLockedUntil = "2026-11-26T10:00:00Z") else it
            }))
            PinVerifyResult(unlocked = true)
        }
    }

    @AfterTest fun tearDown() {
        ProfileRepository.verifyRpcForTest = null
        ProfilePinCacheStorage.removePayload(2)
        resetProfilesForTest()
        resetIdentityForTest()
    }

    /** Audit #1: a correct PIN enters although the verify's refresh changed the server row. */
    @Test
    fun aCorrectPinEntersAfterTheRefresh() = real {
        val shown = ProfileRepository.state.value.displayedRow(2)!!
        val check = ProfileRepository.verifyPin(shown, "1234")
        assertTrue(check.unlocked)
        val row = assertNotNull(check.row)
        assertEquals("t2", row.profile.updatedAt, "the refreshed row of the same list token")
        assertEquals(token, row.listToken)
        val listed = ProfileRepository.state.value.profiles
        assertEquals(Admission.Admit(2), SelectAdmission.decide(row.selectRequest(SelectOrigin.PickerTap)!!, true, token, listed, null, 1))
        // The prompt's own (pre-refresh) row is admitted too: the consent key, not the revision.
        assertEquals(Admission.Admit(2), SelectAdmission.decide(shown.selectRequest(SelectOrigin.PickerTap)!!, true, token, listed, null, 1))
    }

    /** Audit #2: in Recovery(FailedApply) the picker is the front; a PIN check still runs (read-only). */
    @Test
    fun failedApplyStillVerifies() = real {
        IdentityRuntime.setForTest(IdentityRuntime.snapshot().copy(recovery = RecoveryReason.FailedApply))
        val check = ProfileRepository.verifyPin(ProfileRepository.state.value.displayedRow(2)!!, "1234")
        assertFalse(check.refused)
        assertTrue(check.unlocked)
        assertEquals(1, rpcCalls)
    }

    /** Audit #2: a refusal is its own outcome (never "Incorrect PIN"), and no RPC runs. */
    @Test
    fun failedPublishAndAnotherAccountRefuse() = real {
        val shown = ProfileRepository.state.value.displayedRow(2)!!
        for (reason in listOf(RecoveryReason.FailedPublish, RecoveryReason.FailedWipe)) {
            IdentityRuntime.setForTest(BarrierState.initial(1).copy(scope = IdentityScope(accountA, 1), latestAccount = accountA, recovery = reason))
            assertTrue(ProfileRepository.verifyPin(shown, "1234").refused, "$reason")
        }
        IdentityRuntime.setForTest(BarrierState.initial(1).copy(scope = IdentityScope(accountB, 1), latestAccount = accountB))
        assertTrue(ProfileRepository.verifyPin(shown, "1234").refused, "a row of another account")
        assertEquals(0, rpcCalls)
    }
}

/** Audit #3: after any settled transition, the displayed list's token is the current token, or the list is empty. */
class ListTokenWalkTest {
    private var serial = 1L

    @BeforeTest fun setUp() {
        resetIdentityForTest(serial = 1)
        IdentityRuntime.authSerial = { serial }
        IdentityRuntime.setForTest(BarrierState.initial(1).copy(scope = IdentityScope(accountA, 1), latestAccount = accountA))
        IdentityImmediate.onAccountTokenSettled = { ProfileRepository.stampListIfCurrent(it) }
        // The account hook's role: load the new account's list (here: empty until its pull) and stamp it.
        IdentityImmediate.onAccountPublished = { account ->
            val owner = when (account) { is AccountKey.Account -> account.userId; is AccountKey.Guest -> account.guestId; AccountKey.None -> null }
            ProfileRepository.setStateForTest(ProfileState(), owner)
        }
        ProfileRepository.setStateForTest(ProfileState(profiles = listOf(NuvioProfile(profileIndex = 1)), isLoaded = true, listToken = AccountToken(accountA, 1)), "user-a")
    }

    @AfterTest fun tearDown() {
        resetProfilesForTest()
        resetIdentityForTest()
    }

    private fun assertInvariant(step: String) {
        val model = IdentityRuntime.snapshot()
        assertTrue(model.window == null && model.recovery == null, "$step: settled")
        val s = ProfileRepository.state.value
        val current = AccountToken(model.latestAccount, serial)
        assertTrue(s.profiles.isEmpty() || s.listToken == current, "$step: list ${s.listToken} vs current $current")
    }

    /** A pull's publication for [owner]'s list under the current token. */
    private fun pulled(owner: String, vararg slots: Int) {
        val current = AccountToken(IdentityRuntime.snapshot().latestAccount, serial)
        IdentityGate.commitAccount(current, "test pull") {
            ProfileRepository.setStateForTest(ProfileState(profiles = slots.map { NuvioProfile(profileIndex = it) }, isLoaded = true, listToken = current), owner)
        }
    }

    @Test
    fun everySettleLeavesACurrentOrEmptyList() {
        assertInvariant("start")
        // Same-account session change (token refresh): the serial moves, the list stays and is re-stamped.
        serial = 2; IdentityImmediate.serialChanging(); IdentityImmediate.chainEnded()
        assertInvariant("A serial 2")
        assertEquals(1, ProfileRepository.state.value.profiles.size, "the same account keeps its list")
        serial = 3; IdentityImmediate.serialChanging(); IdentityImmediate.chainEnded()
        assertInvariant("A serial 3")
        // Account switch: B's list is empty until its pull lands under B's token.
        serial = 4
        IdentityImmediate.serialChanging()
        IdentityImmediate.publishAuth(AuthState.Authenticated("user-b", null, isAnonymous = false)) {}
        IdentityImmediate.chainEnded()
        assertInvariant("B published")
        pulled("user-b", 1, 2)
        assertInvariant("B pulled")
        serial = 5; IdentityImmediate.serialChanging(); IdentityImmediate.chainEnded()
        assertInvariant("B serial 5")
        assertEquals(2, ProfileRepository.state.value.profiles.size)
        // Sign out: None owns no list; whatever is in memory is cleared by the hook.
        serial = 6
        IdentityImmediate.serialChanging()
        IdentityImmediate.publishAuth(AuthState.Unauthenticated) {}
        IdentityImmediate.chainEnded()
        assertInvariant("signed out")
        // Guest.
        serial = 7
        IdentityImmediate.serialChanging()
        IdentityImmediate.publishAuth(AuthState.Authenticated("g", null, isAnonymous = true)) {}
        IdentityImmediate.chainEnded()
        pulled("g", 1)
        serial = 8; IdentityImmediate.serialChanging(); IdentityImmediate.chainEnded()
        assertInvariant("guest serial 8")
    }
}
