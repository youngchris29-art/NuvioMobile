package com.nuvio.app.core.identity

import kotlin.test.Test
import kotlin.test.assertEquals

/** Spec 4.3a point 5: kind {8} × class {2}. */
class CancelPolicyTest {

    private val profileKinds = setOf(TransitionKind.ProfileSelect, TransitionKind.ActiveProfileDelete, TransitionKind.SlotRemoved)

    @Test
    fun everyCombination() {
        val classes = listOf(WorkClass.Profile(IdentityScope(accountA, 1)), WorkClass.Account(accountA))
        var count = 0
        for (kind in TransitionKind.entries) for (cls in classes) {
            val expected = if (kind in profileKinds) cls is WorkClass.Profile else true
            assertEquals(expected, CancelPolicy.cancels(kind, cls), "$kind $cls")
            count++
        }
        assertEquals(16, count)
    }

    @Test
    fun profileJobsOfAnyScopeAreCancelledByAProfileSwitch() {
        listOf(IdentityScope(accountA, 1), IdentityScope(accountB, 4), IdentityScope(AccountKey.None, 2)).forEach {
            assertEquals(true, CancelPolicy.cancels(TransitionKind.ProfileSelect, WorkClass.Profile(it)))
        }
    }
}
