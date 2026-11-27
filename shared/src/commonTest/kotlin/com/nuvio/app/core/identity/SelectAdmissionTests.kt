package com.nuvio.app.core.identity

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
     * {yes, no} × origin {PickerTap, AutoEnter, Restore, DeleteFallback} × deletingIsActive {yes, no}
     * = 128 combinations; for the three non-delete origins `deleting` is null (impossible to be
     * active), so their 48 "deletingIsActive = yes" combinations are classified impossible and must
     * get the same verdict as with it null; 80 reachable cases are asserted against the oracle.
     */
    @Test
    fun everyCombination() {
        val currents = listOf(null, shown, AccountToken(accountB, 5), AccountToken(accountA, 6))
        var total = 0
        var reachable = 0
        var impossible = 0
        for (gated in listOf(true, false)) for (current in currents) for (slotListed in listOf(true, false))
            for (origin in SelectOrigin.entries) for (deletingIsActive in listOf(true, false)) {
                total++
                val slot = 2
                val listed = if (slotListed) listOf(1, 2, 3) else listOf(1, 3)
                val request = SelectRequest(slot, shown, origin)
                val isDelete = origin == SelectOrigin.DeleteFallback
                val deleting = if (isDelete) 1 else null
                val activeSlot = if (deletingIsActive) 1 else 3
                val verdict = SelectAdmission.decide(request, gated, current, listed, deleting, activeSlot)
                if (!isDelete && deletingIsActive) {
                    impossible++
                    // The decision ignores `deleting`/the active slot for these origins.
                    assertEquals(SelectAdmission.decide(request, gated, current, listed, null, 3), verdict)
                    continue
                }
                reachable++
                val expected: Admission = when {
                    !gated -> Admission.Reject(SelectRejection.Phase)
                    current != shown -> Admission.Reject(SelectRejection.AccountChanged)
                    isDelete && !deletingIsActive -> Admission.Reject(SelectRejection.SlotGone)
                    isDelete -> Admission.Admit(listed.filter { it != 1 }.min())
                    !slotListed -> Admission.Reject(SelectRejection.SlotGone)
                    else -> Admission.Admit(slot)
                }
                assertEquals(expected, verdict, "gated=$gated current=$current listed=$slotListed origin=$origin active=$deletingIsActive")
            }
        assertEquals(128, total)
        assertEquals(80, reachable)
        assertEquals(48, impossible)
    }

    @Test
    fun deleteFallbackWithNothingLeftRemovesTheActiveProfile() {
        assertEquals(
            Admission.Admit(SelectAdmission.NONE_REMAIN),
            SelectAdmission.decide(SelectRequest(0, shown, SelectOrigin.DeleteFallback), true, shown, listOf(1), deleting = 1, activeSlot = 1),
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
