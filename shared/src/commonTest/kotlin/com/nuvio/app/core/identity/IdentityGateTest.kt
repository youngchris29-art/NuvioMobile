package com.nuvio.app.core.identity

import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.async
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.first
import kotlinx.coroutines.test.runTest
import kotlinx.coroutines.withContext
import kotlin.test.BeforeTest
import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertFailsWith
import kotlin.test.assertIs
import kotlin.test.assertNotNull
import kotlin.test.assertNull
import kotlin.test.assertTrue

/** Spec 4.1, 4.2, 5.11: the locks, the runtime's publication and the public gate. */
class IdentityGateTest {

    @BeforeTest
    fun reset() {
        resetIdentityForTest(slot = 2, serial = 9)
        // An Open state for account A on slot 2.
        IdentityRuntime.setForTest(
            BarrierState.initial(2).copy(scope = IdentityScope(accountA, 2), latestAccount = accountA, epoch = IdentityEpoch(3)),
        )
    }

    /** Risk table (16): commit inside commitPersisted relies on reentrancy, on JVM and Native alike. */
    @Test
    fun commitLockIsReentrant() {
        val token = assertNotNull(IdentityGate.currentToken())
        val result = IdentityGate.commitPersisted("account:user-a", 2) { minted ->
            IdentityGate.commit(minted, CommitKind.LocalWrite) { IdentityLocks.withCommit { IdentityLocks.commitDepth } }
        }
        val recorded = assertIs<PersistedResult.Recorded<CommitResult<Int>>>(result)
        assertEquals(CommitResult.Committed(3), recorded.value)
        assertEquals(token, IdentityGate.currentToken())
        assertEquals(0, IdentityLocks.commitDepth)
    }

    @Test
    fun applyInsideCommitIsALockOrderError() {
        assertFailsWith<IllegalStateException> {
            IdentityLocks.withCommit { IdentityLocks.withApply { } }
        }
        assertEquals(0, IdentityLocks.commitDepth)
        assertEquals(0, IdentityLocks.applyDepth)
        // commit inside apply is the allowed order
        assertEquals(1, IdentityLocks.withApply { IdentityLocks.withCommit { IdentityLocks.applyDepth } })
    }

    @Test
    fun applyDepthIsPerThread() = runTest {
        withContext(Dispatchers.Default) {
            val holding = MutableStateFlow(false)
            val release = MutableStateFlow(false)
            val holder = async(Dispatchers.Default) {
                IdentityLocks.withApply {
                    IdentityLocks.withApply { holding.value = true }
                    holding.value = true
                    while (!release.value) { /* hold this worker inside the apply lock */ }
                    IdentityLocks.applyDepth
                }
            }
            holding.first { it }
            // The holder blocks its worker, so this read runs on another thread.
            val elsewhere = async(Dispatchers.Default) { IdentityLocks.applyDepth }.await()
            release.value = true
            assertEquals(1, holder.await())
            assertEquals(0, elsewhere)
        }
    }

    @Test
    fun tokensOnlyWhileOpen() {
        assertEquals(IdentityToken(IdentityScope(accountA, 2), IdentityEpoch(3), 9), IdentityGate.currentToken())
        IdentityRuntime.reduce(BarrierEvent.Begin(TransitionKind.ProfileSelect))
        assertNull(IdentityGate.currentToken())
        // A profile drain does not close account-level work.
        assertEquals(AccountToken(accountA, 9), IdentityGate.currentAccountToken())
    }

    @Test
    fun accountTokenNullWhileAnAccountHoldIsClosed() {
        IdentityRuntime.reduce(BarrierEvent.Begin(TransitionKind.SignOut))
        assertNotNull(IdentityGate.currentAccountToken()) // Draining on a valid session
        IdentityRuntime.reduce(BarrierEvent.DrainEnded(DrainEnd.Settled))
        assertNull(IdentityGate.currentAccountToken())
        IdentityRuntime.reduce(BarrierEvent.ApplyFinished(2))
        IdentityRuntime.reduce(BarrierEvent.WindowOpened(TransitionKind.AccountPublished))
        assertNull(IdentityGate.currentAccountToken())
    }

    @Test
    fun commitRunsTheBlockOnlyOnCommit() {
        val token = IdentityGate.currentToken()
        var ran = 0
        assertEquals(CommitResult.Committed(1), IdentityGate.commit(token, CommitKind.LocalWrite) { ++ran })
        IdentityRuntime.reduce(BarrierEvent.Begin(TransitionKind.ProfileSelect))
        assertEquals(CommitResult.Committed(2), IdentityGate.commit(token, CommitKind.LocalWrite) { ++ran })
        assertEquals(CommitResult.Rejected(RejectReason.BarrierInProgress), IdentityGate.commit(token, CommitKind.Start) { ++ran })
        IdentityRuntime.reduce(BarrierEvent.DrainEnded(DrainEnd.Settled))
        assertEquals(CommitResult.Rejected(RejectReason.WritesClosed), IdentityGate.commit(token, CommitKind.LocalWrite) { ++ran })
        assertEquals(CommitResult.Rejected(RejectReason.WritesClosed), IdentityGate.commit(null, CommitKind.LocalWrite) { ++ran })
        assertEquals(2, ran)
    }

    @Test
    fun serialChangeRejectsAsAccountChanged() {
        val token = IdentityGate.currentToken()
        IdentityRuntime.authSerial = { 10 }
        assertEquals(Verdict.Reject(RejectReason.AccountChanged), IdentityGate.check(token, CommitKind.LocalWrite))
        assertEquals(Verdict.Reject(RejectReason.AccountChanged), IdentityGate.checkAccount(AccountToken(accountA, 9)))
    }

    @Test
    fun staleTokenAfterASettle() {
        val token = IdentityGate.currentToken()
        IdentityRuntime.reduce(BarrierEvent.Begin(TransitionKind.ProfileSelect))
        IdentityRuntime.reduce(BarrierEvent.DrainEnded(DrainEnd.Settled))
        IdentityRuntime.reduce(BarrierEvent.ApplyGate())
        IdentityRuntime.reduce(BarrierEvent.ApplyFinished(2))
        assertEquals(Verdict.Reject(RejectReason.StaleEpoch), IdentityGate.check(token, CommitKind.LocalWrite, "test"))
        assertEquals(IdentityEpoch(4), IdentityGate.currentEpoch())
    }

    @Test
    fun commitPersistedDecidesAndMintsInOneStep() {
        val recorded = IdentityGate.commitPersisted("account:user-a", 2) { it }
        assertEquals(PersistedResult.Recorded(IdentityToken(IdentityScope(accountA, 2), IdentityEpoch(3), 9)), recorded)
        assertEquals(PersistedResult.Dropped(DropReason.OtherProfile), IdentityGate.commitPersisted("account:user-a", 1) { it })
        assertEquals(PersistedResult.Dropped(DropReason.LegacySession), IdentityGate.commitPersisted(null, 2) { it })
        IdentityRuntime.reduce(BarrierEvent.WindowOpened(TransitionKind.AccountWipe))
        var ran = false
        assertEquals(PersistedResult.Parked, IdentityGate.commitPersisted("account:user-a", 2) { ran = true })
        assertTrue(!ran)
    }

    @Test
    fun runtimePublishesInReductionOrder() {
        val seen = mutableListOf<IdentityState>()
        seen += IdentityRuntime.state.value
        IdentityRuntime.reduce(BarrierEvent.Begin(TransitionKind.ProfileSelect)); seen += IdentityGate.state.value
        IdentityRuntime.reduce(BarrierEvent.DrainEnded(DrainEnd.Settled)); seen += IdentityGate.state.value
        IdentityRuntime.reduce(BarrierEvent.ApplyGate()); seen += IdentityGate.state.value
        IdentityRuntime.reduce(BarrierEvent.ApplyFinished(1)); seen += IdentityGate.state.value
        assertEquals(
            listOf<IdentityPhase>(
                IdentityPhase.Open, IdentityPhase.Draining(IdentityEpoch(3)), IdentityPhase.Applying(IdentityEpoch(3)),
                IdentityPhase.Applying(IdentityEpoch(3)), IdentityPhase.Open,
            ),
            seen.map { it.phase },
        )
        // withSlot: the runtime's slot wins over the event's (2 is the active slot here).
        assertEquals(IdentityScope(accountA, 2), seen.last().scope)
    }

    @Test
    fun seedSlotOnlyBeforeTheFirstReduce() {
        resetIdentityForTest(slot = 1)
        IdentityRuntime.seedSlot(3)
        assertEquals(3, IdentityGate.state.value.scope.slot)
        IdentityRuntime.reduce(BarrierEvent.WindowOpened(TransitionKind.AccountPublished))
        IdentityRuntime.seedSlot(4)
        assertEquals(3, IdentityGate.state.value.scope.slot)
    }
}
