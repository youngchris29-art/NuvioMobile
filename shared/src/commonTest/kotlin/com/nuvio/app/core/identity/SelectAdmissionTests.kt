package com.nuvio.app.core.identity

import com.nuvio.app.features.profiles.NuvioProfile
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.launch
import kotlinx.coroutines.test.runTest
import kotlinx.coroutines.withContext
import kotlin.test.AfterTest
import kotlin.test.BeforeTest
import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertIs
import kotlin.test.assertTrue

/* Rule G (spec 31.1): selection admission, pure and in the barrier. */

private fun real(block: suspend CoroutineScope.() -> Unit) = runTest { withContext(Dispatchers.Default) { block() } }

class SelectAdmissionTest {
    private val shown = AccountToken(accountA, 5)

    /**
     * gated {yes, no} × current {null, same, other account, same account other serial} × slotListed
     * {yes, no} × rowSame {yes, no} × origin {PickerTap, AutoEnter, Restore, DeleteFallback} ×
     * deletingIsActive {yes, no} = 256 combinations. Classified impossible (asserted to get the
     * verdict of their reachable twin): a non-delete origin with deletingIsActive = yes (`deleting`
     * is null for them); a row that "changed" while the slot is not listed (no row to compare);
     * DeleteFallback with rowSame = no (it carries no row). Reachable: 3 non-delete origins × 2 × 4
     * × 3 (listed+same, listed+changed, unlisted) = 72, plus DeleteFallback 2 × 4 × 2 × 2 = 32: 104;
     * impossible 152.
     */
    @Test
    fun everyCombination() {
        val currents = listOf(null, shown, AccountToken(accountB, 5), AccountToken(accountA, 6))
        var total = 0
        var reachable = 0
        var impossible = 0
        for (gated in listOf(true, false)) for (current in currents) for (slotListed in listOf(true, false))
            for (rowSame in listOf(true, false)) for (origin in SelectOrigin.entries) for (deletingIsActive in listOf(true, false)) {
                total++
                val slot = 2
                val isDelete = origin == SelectOrigin.DeleteFallback
                val displayedRow = NuvioProfile(profileIndex = 2, name = "Two")
                val row = if (rowSame) displayedRow else displayedRow.copy(pinEnabled = true)
                val listed = listOf(NuvioProfile(profileIndex = 1), NuvioProfile(profileIndex = 3)) + (if (slotListed) listOf(row) else emptyList())
                val request = SelectRequest(slot, shown, origin, displayedRow)
                val deleting = if (isDelete) 1 else null
                val activeSlot = if (deletingIsActive) 1 else 3
                val verdict = SelectAdmission.decide(request, gated, current, listed, deleting, activeSlot)
                val twin = when {
                    !isDelete && deletingIsActive -> SelectAdmission.decide(request, gated, current, listed, null, 3)
                    !isDelete && !slotListed && !rowSame -> SelectAdmission.decide(request, gated, current, listed.filter { it.profileIndex != 2 }, deleting, activeSlot)
                    isDelete && !rowSame -> SelectAdmission.decide(request, gated, current, listed.map { if (it.profileIndex == 2) displayedRow else it }, deleting, activeSlot)
                    else -> null
                }
                if (twin != null) {
                    impossible++
                    assertEquals(twin, verdict, "impossible case gated=$gated current=$current listed=$slotListed same=$rowSame origin=$origin")
                    continue
                }
                reachable++
                val expected: Admission = when {
                    !gated -> Admission.Reject(SelectRejection.Phase)
                    current != shown -> Admission.Reject(SelectRejection.AccountChanged)
                    isDelete && !deletingIsActive -> Admission.Reject(SelectRejection.SlotGone)
                    isDelete -> Admission.Admit(listed.map { it.profileIndex }.filter { it != 1 }.min())
                    !slotListed -> Admission.Reject(SelectRejection.SlotGone)
                    !rowSame -> Admission.Reject(SelectRejection.RowChanged)
                    else -> Admission.Admit(slot)
                }
                assertEquals(expected, verdict, "gated=$gated current=$current listed=$slotListed same=$rowSame origin=$origin active=$deletingIsActive")
            }
        assertEquals(256, total)
        assertEquals(104, reachable)
        assertEquals(152, impossible)
    }

    @Test
    fun deleteFallbackWithNothingLeftRemovesTheActiveProfile() {
        assertEquals(
            Admission.Admit(SelectAdmission.NONE_REMAIN),
            SelectAdmission.decide(SelectRequest(0, shown, SelectOrigin.DeleteFallback), true, shown, listOf(NuvioProfile(profileIndex = 1)), deleting = 1, activeSlot = 1),
        )
    }
}

class SelectAdmissionDriverTest {
    private val log = EventLog()
    private lateinit var ops: FakeProfileOps

    @BeforeTest fun setUp() { ops = installDriverFakes(log) }
    @AfterTest fun tearDown() = resetIdentityForTest()

    /** P19 / r4 #1: displayed under A, the session changed before the apply: nothing applied. */
    @Test
    fun selectAcrossAccountChangeAppliesNothing() = real {
        val shown = assertNotNullToken()
        IdentityRuntime.authSerial = { 2 } // a new session (same account) before the apply
        val result = assertIs<TransitionResult.Preempted>(IdentityBarrier.selectProfile(SelectRequest(2, shown, SelectOrigin.PickerTap)))
        assertEquals(SelectRejection.AccountChanged, result.rejection)
        assertEquals(emptyList(), log.all())
        assertEquals(1, ops.active)
    }

    /** P19 / r4 #2: the slot left the published list while the select was queued: nothing applied. */
    @Test
    fun selectOfSlotRemovedWhileQueued() = real {
        val shown = assertNotNullToken()
        IdentityBarrier.beforeApplyLock = { ops.listed = setOf(1, 3) } // a pull removed slot 2 before admission
        val result = assertIs<TransitionResult.Preempted>(IdentityBarrier.selectProfile(SelectRequest(2, shown, SelectOrigin.PickerTap)))
        assertEquals(SelectRejection.SlotGone, result.rejection)
        assertEquals(emptyList(), log.all())
        assertEquals(1, ops.active)
    }

    /** Review r5 #2: a row of A's list, tapped after B opened (B's list not yet shown), is never admitted into B. */
    @Test
    fun staleRowOfAnotherAccountTappedAfterItOpened() = real {
        val listOfA = assertNotNullToken() // the token A's list was stamped with
        IdentityRuntime.authSerial = { 2 }
        IdentityImmediate.serialChanging()
        IdentityImmediate.publishAuth(com.nuvio.app.core.auth.AuthState.Authenticated("user-b", null, isAnonymous = false)) {}
        IdentityImmediate.chainEnded() // B is open; slot 2 exists in B (PIN-protected, say)
        ops.rowContent = mapOf(2 to NuvioProfile(profileIndex = 2, pinEnabled = true, updatedAt = "b2"))
        val result = assertIs<TransitionResult.Preempted>(IdentityBarrier.selectProfile(SelectRequest(2, listOfA, SelectOrigin.PickerTap)))
        assertEquals(SelectRejection.AccountChanged, result.rejection)
        assertEquals(emptyList(), log.all())
    }

    /** Review r5 #3: a PIN enabled (by a pull) between the tap and admission is enforced: back to the picker. */
    @Test
    fun pinEnabledBetweenTapAndAdmission() = real {
        val shown = assertNotNullToken()
        val displayed = NuvioProfile(profileIndex = 2, updatedAt = "r1")
        ops.rowContent = mapOf(2 to displayed)
        IdentityBarrier.beforeApplyLock = { ops.rowContent = mapOf(2 to displayed.copy(pinEnabled = true, updatedAt = "r2")) }
        val result = assertIs<TransitionResult.Preempted>(
            IdentityBarrier.selectProfile(SelectRequest(2, shown, SelectOrigin.PickerTap, displayed)),
        )
        assertEquals(SelectRejection.RowChanged, result.rejection)
        assertEquals(emptyList(), log.all())
    }

    /** Audit #1: a replaced row (another id in the same slot) is refused, whatever its revision. */
    @Test
    fun emptyRevisionStillDetectsAReplacedRow() = real {
        val shown = assertNotNullToken()
        val displayed = NuvioProfile(id = "row-a", profileIndex = 2, name = "Old", updatedAt = "")
        ops.rowContent = mapOf(2 to displayed.copy(id = "row-b")) // same slot, same (empty) revision, another row
        val result = assertIs<TransitionResult.Preempted>(IdentityBarrier.selectProfile(SelectRequest(2, shown, SelectOrigin.PickerTap, displayed)))
        assertEquals(SelectRejection.RowChanged, result.rejection)
    }

    /**
     * Audit #1: the PIN verify's own refresh changes the server row's revision and lock-out
     * fields; the consent key (slot, id, PIN on/off) is unchanged, so the select is admitted.
     */
    @Test
    fun verifyRefreshOfTheSameRowIsAdmitted() = real {
        val shown = assertNotNullToken()
        val displayed = NuvioProfile(id = "row-a", profileIndex = 2, name = "Kid", pinEnabled = true, updatedAt = "t1")
        ops.rowContent = mapOf(2 to displayed.copy(updatedAt = "t2", pinLockedUntil = "2026-11-26T10:00:00Z", name = "Kid (renamed)"))
        assertIs<TransitionResult.Done>(IdentityBarrier.selectProfile(SelectRequest(2, shown, SelectOrigin.PickerTap, displayed)))
    }

    /** Audit #1 (keeps r5 #3): PIN turned on between the tap and admission is refused. */
    @Test
    fun pinEnabledSinceTheTapIsRefused() = real {
        val shown = assertNotNullToken()
        val displayed = NuvioProfile(id = "row-a", profileIndex = 2, name = "Kid", pinEnabled = false, updatedAt = "t1")
        ops.rowContent = mapOf(2 to displayed.copy(pinEnabled = true))
        val result = assertIs<TransitionResult.Preempted>(IdentityBarrier.selectProfile(SelectRequest(2, shown, SelectOrigin.PickerTap, displayed)))
        assertEquals(SelectRejection.RowChanged, result.rejection)
    }

    /** B23 in one section: a relist cannot be published between the recheck and the write. */
    @Test
    fun slotRemovalRacesRelistInOneSection() = real {
        val token = assertNotNullToken()
        ops.listed = setOf(2, 3) // the active slot 1 is gone
        val relistAttempting = MutableStateFlow(false)
        var relistDone = false
        val relistHook = ops
        var started = false
        relistHook.onIsListed = { slot ->
            if (!started) {
                started = true
                CoroutineScope(Dispatchers.Default).launch {
                    relistAttempting.value = true
                    IdentityLocks.withCommit { // a pull's publication (commitAccount) takes this lock
                        ops.listed = setOf(1, 2, 3)
                        log.add("relist")
                        relistDone = true
                    }
                }
                spinUntil { relistAttempting.value }
            }
        }
        IdentityBarrier.requestSlotRemoved(1, token)
        eventually { relistDone }
        eventually { !IdentityGate.state.value.transitioning }
        // The relist waited for the section: the write ("removed") came first, never after a relist.
        assertEquals(listOf("removed", "relist"), log.all())
    }

    private fun assertNotNullToken(): AccountToken = kotlin.test.assertNotNull(IdentityGate.currentAccountToken())
}
