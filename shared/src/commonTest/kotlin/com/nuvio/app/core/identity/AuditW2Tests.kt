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

    /** Review r7 #1: the slot's profile was replaced between the verify and its refresh: the check authorises nothing. */
    @Test
    fun aReplacedRowIsNotAuthorisedByTheCheck() = real {
        ProfileRepository.verifyRpcForTest = { _, _ ->
            rpcCalls++
            val s = ProfileRepository.state.value
            ProfileRepository.setStateForTest(s.copy(profiles = s.profiles.map {
                if (it.profileIndex == 2) NuvioProfile(id = "other", profileIndex = 2, name = "Other", pinEnabled = true) else it
            }))
            PinVerifyResult(unlocked = true)
        }
        val check = ProfileRepository.verifyPin(ProfileRepository.state.value.displayedRow(2)!!, "1234")
        assertTrue(check.refused, "refused, not unlocked")
        assertEquals(null, check.row)
    }

    private fun replaceSlot(slot: Int, with: NuvioProfile) {
        val s = ProfileRepository.state.value
        ProfileRepository.setStateForTest(s.copy(profiles = (s.profiles.filter { it.profileIndex != slot } + with).sortedBy { it.profileIndex }))
    }

    /** An offline verification (no server): the cached digest decides. */
    private suspend fun offlineVerify(slot: Int, pin: String): Boolean {
        val saved = ProfileRepository.verifyRpcForTest
        ProfileRepository.verifyRpcForTest = null
        try {
            return ProfileRepository.verifyPin(ProfileRepository.state.value.displayedRow(slot)!!, pin).unlocked
        } finally {
            ProfileRepository.verifyRpcForTest = saved
        }
    }

    /** Review r8 #1: a replacement during the refresh caches nothing; offline, the old PIN never opens it. */
    @Test
    fun aReplacementDuringTheRefreshCachesNothing() = real {
        ProfilePinCacheStorage.removePayload(2)
        ProfileRepository.verifyRpcForTest = { _, _ ->
            replaceSlot(2, NuvioProfile(id = "other", profileIndex = 2, name = "Other", pinEnabled = true, updatedAt = "tB"))
            PinVerifyResult(unlocked = true)
        }
        assertTrue(ProfileRepository.verifyPin(ProfileRepository.state.value.displayedRow(2)!!, "1234").refused)
        assertFalse(offlineVerify(2, "1234"), "the old PIN must not unlock the replacement offline")
    }

    /** Positive control: an adopted verify caches the PIN for the verified row (offline unlock works). */
    @Test
    fun anAdoptedVerifyCachesThePin() = real {
        ProfilePinCacheStorage.removePayload(2)
        assertTrue(ProfileRepository.verifyPin(ProfileRepository.state.value.displayedRow(2)!!, "1234").unlocked)
        assertTrue(offlineVerify(2, "1234"))
        assertFalse(offlineVerify(2, "9999"))
    }

    /** Review r8 #3: the returned row is built from the snapshot admission checked, in the same section. */
    @Test
    fun theReturnedRowComesFromTheAdmittedSnapshot() = real {
        ProfileRepository.afterPinAdmissionForTest = {
            replaceSlot(2, NuvioProfile(id = "other", profileIndex = 2, name = "Other", pinEnabled = true))
        }
        try {
            val check = ProfileRepository.verifyPin(ProfileRepository.state.value.displayedRow(2)!!, "1234")
            assertEquals("kid", check.row?.profile?.id)
        } finally {
            ProfileRepository.afterPinAdmissionForTest = {}
        }
    }

    /** Review r8: a PIN set adopts the row after it (lock on) and caches; a replacement adopts nothing. */
    @Test
    fun aPinSetAdoptsTheRowAfterItOrNothing() = real {
        ProfilePinCacheStorage.removePayload(3)
        replaceSlot(3, NuvioProfile(id = "three", profileIndex = 3, name = "Three", pinEnabled = false, updatedAt = "t1"))
        ProfileRepository.pinWriteRpcForTest = {
            replaceSlot(3, NuvioProfile(id = "three", profileIndex = 3, name = "Three", pinEnabled = true, updatedAt = "t2"))
        }
        try {
            val check = ProfileRepository.setPin(ProfileRepository.state.value.displayedRow(3)!!, "1111")
            assertTrue(check.unlocked)
            assertEquals(true, check.row?.profile?.pinEnabled)
            assertEquals("three", check.row?.profile?.id)
            assertTrue(offlineVerify(3, "1111"))
            // Set again while another profile replaces slot 3 during the refresh.
            ProfilePinCacheStorage.removePayload(3)
            ProfileRepository.pinWriteRpcForTest = {
                replaceSlot(3, NuvioProfile(id = "new", profileIndex = 3, name = "New", pinEnabled = true, updatedAt = "t3"))
            }
            val replaced = ProfileRepository.setPin(ProfileRepository.state.value.displayedRow(3)!!, "2222")
            assertEquals(null, replaced.row)
            assertFalse(offlineVerify(3, "2222"))
        } finally {
            ProfileRepository.pinWriteRpcForTest = null
            ProfilePinCacheStorage.removePayload(3)
        }
    }

    /** P3: a PIN removal clears the slot's cache entry only while its account holds, inside the section. */
    @Test
    fun aPinRemovalClearsTheCacheOnlyForItsAccount() = real {
        try {
            ProfilePinCacheStorage.savePayload(2, "entry")
            ProfileRepository.pinWriteRpcForTest = {
                // Another account opens between the RPC and the section (its own slot-2 entry).
                IdentityRuntime.setForTest(BarrierState.initial(1).copy(scope = IdentityScope(accountB, 1), latestAccount = accountB))
            }
            ProfileRepository.clearPin(ProfileRepository.state.value.displayedRow(2)!!, "1234")
            assertEquals("entry", ProfilePinCacheStorage.loadPayload(2), "the other account's entry is kept")
            IdentityRuntime.setForTest(BarrierState.initial(1).copy(scope = IdentityScope(accountA, 1), latestAccount = accountA))
            ProfileRepository.pinWriteRpcForTest = {}
            ProfileRepository.clearPin(ProfileRepository.state.value.displayedRow(2)!!, "1234")
            assertEquals(null, ProfilePinCacheStorage.loadPayload(2), "removed for its own account")
        } finally {
            ProfileRepository.pinWriteRpcForTest = null
        }
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

    /** Review r7 #5: a restamp refused by an operation that then fails is redone at the next Open. */
    @Test
    fun aRefusedRestampIsRedoneAtTheNextOpen() {
        var first = true
        IdentityImmediate.onAccountTokenSettled = { t ->
            if (first) {
                first = false
                IdentityImmediate.serialChanging() // an account operation begins before the stamp's section
            }
            ProfileRepository.stampListIfCurrent(t)
        }
        serial = 2; IdentityImmediate.serialChanging(); IdentityImmediate.chainEnded()
        assertEquals(AccountToken(accountA, 1), ProfileRepository.state.value.listToken, "the stamp was refused by the window")
        IdentityImmediate.chainEnded() // the operation fails: no account or serial change
        assertInvariant("next Open")
        assertEquals(AccountToken(accountA, 2), ProfileRepository.state.value.listToken)
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

/** Review r7 #2: delete and edit admit the displayed row (id and lock state) inside the section that acts. */
class RowActionAdmissionTest {
    private val token = AccountToken(accountA, 1)
    private val deletes = mutableListOf<Int>()
    private val pushes = mutableListOf<List<com.nuvio.app.features.profiles.ProfilePushPayload>>()
    private val a2 = NuvioProfile(id = "a2", profileIndex = 2, name = "A2")

    @BeforeTest fun setUp() {
        resetIdentityForTest(serial = 1)
        IdentityRuntime.setForTest(BarrierState.initial(1).copy(scope = IdentityScope(accountA, 1), latestAccount = accountA))
        ProfileIdentityRouterProvider.router = BarrierProfileIdentityRouter(FakeRouterPorts(EventLog()))
        ProfileRepository.isGuestForTest = false
        ProfileRepository.deleteRpcForTest = { deletes += it }
        ProfileRepository.pushRpcForTest = { pushes += it }
        ProfileRepository.setStateForTest(ProfileState(profiles = listOf(NuvioProfile(id = "a1", profileIndex = 1), a2), isLoaded = true, listToken = token), "user-a")
    }

    @AfterTest fun tearDown() {
        ProfileRepository.deleteRpcForTest = null
        ProfileRepository.pushRpcForTest = null
        ProfileRepository.isGuestForTest = null
        resetProfilesForTest()
        resetIdentityForTest()
    }

    private fun replaceSlot2(with: NuvioProfile) {
        val s = ProfileRepository.state.value
        ProfileRepository.setStateForTest(s.copy(profiles = s.profiles.map { if (it.profileIndex == 2) with else it }))
    }

    @Test
    fun aStaleActionForAReplacedRowChangesNothing() = real {
        val shown = ProfileRepository.state.value.displayedRow(2)!!
        replaceSlot2(NuvioProfile(id = "b2", profileIndex = 2, name = "B2"))
        ProfileRepository.deleteProfile(shown)
        ProfileRepository.updateProfile(shown, name = "Renamed", avatarColorHex = "#000000")
        assertEquals(emptyList(), deletes)
        assertEquals(emptyList(), pushes)
        assertEquals("b2", ProfileRepository.state.value.profiles.first { it.profileIndex == 2 }.id)
    }

    @Test
    fun aNewlyLockedRowIsNotActedOn() = real {
        val shown = ProfileRepository.state.value.displayedRow(2)!!
        replaceSlot2(a2.copy(pinEnabled = true))
        ProfileRepository.deleteProfile(shown)
        ProfileRepository.updateProfile(shown, name = "Renamed", avatarColorHex = "#000000")
        assertEquals(emptyList(), deletes)
        assertEquals(emptyList(), pushes)
    }

    @Test
    fun theSameRowIsActedOn() = real {
        val shown = ProfileRepository.state.value.displayedRow(2)!!
        replaceSlot2(a2.copy(name = "A2 renamed elsewhere", updatedAt = "t9")) // same profile, same lock
        ProfileRepository.updateProfile(shown, name = "Renamed", avatarColorHex = "#000000")
        assertEquals(listOf("Renamed"), pushes.single().filter { it.profileIndex == 2 }.map { it.name })
        ProfileRepository.deleteProfile(shown)
        assertEquals(listOf(2), deletes)
    }

    /** The rule itself: every reason. */
    @Test
    fun ruleTable() {
        val listed = listOf(a2)
        assertEquals(null, RowAdmission.decide(a2, token, token, listed))
        assertEquals(RowRejection.AccountChanged, RowAdmission.decide(a2, token, AccountToken(accountA, 2), listed))
        assertEquals(RowRejection.AccountChanged, RowAdmission.decide(a2, null, token, listed))
        assertEquals(RowRejection.SlotGone, RowAdmission.decide(a2, token, token, emptyList()))
        assertEquals(RowRejection.RowReplaced, RowAdmission.decide(a2, token, token, listOf(a2.copy(id = "b2"))))
        assertEquals(RowRejection.LockChanged, RowAdmission.decide(a2, token, token, listOf(a2.copy(pinEnabled = true))))
        assertEquals(null, RowAdmission.decide(a2, token, token, listOf(a2.copy(name = "x", updatedAt = "t2", pinLockedUntil = "z"))))
    }
}
