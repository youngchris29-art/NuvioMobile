package com.nuvio.app.core.identity

import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.ExperimentalCoroutinesApi
import kotlinx.coroutines.NonCancellable
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.async
import kotlinx.coroutines.awaitCancellation
import kotlinx.coroutines.cancel
import kotlinx.coroutines.delay
import kotlinx.coroutines.launch
import kotlinx.coroutines.test.TestScope
import kotlinx.coroutines.test.currentTime
import kotlinx.coroutines.test.runCurrent
import kotlinx.coroutines.test.runTest
import kotlinx.coroutines.withContext
import kotlin.test.BeforeTest
import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertFalse
import kotlin.test.assertIs
import kotlin.test.assertNotNull
import kotlin.test.assertNull
import kotlin.test.assertTrue

/** Spec 4.3 and 4.3a (revision 8), on virtual time except the two race tests. */
@OptIn(ExperimentalCoroutinesApi::class)
class IdentityWorkTest {

    private val epoch = IdentityEpoch(3)

    @BeforeTest
    fun reset() {
        resetIdentityForTest(slot = 1, serial = 5)
        IdentityRuntime.setForTest(
            BarrierState.initial(1).copy(scope = IdentityScope(accountA, 1), latestAccount = accountA, epoch = epoch),
        )
    }

    private fun token() = assertNotNull(IdentityGate.currentToken())

    /** B1 through the registry (sets the awaited id); returns the Begin's transition id. */
    private fun begin(kind: TransitionKind = TransitionKind.ProfileSelect): Long {
        val reduced = IdentityWork.beginTransition(kind)
        IdentityEffects.run(reduced)
        return assertNotNull(reduced.state.drained).transitionId
    }

    /** What a drain end's effects say it was (B2, B3, B3a/B3b, B4/B5). */
    private fun outcome(reduced: Reduced): DrainEnd {
        IdentityEffects.run(reduced)
        val effects = reduced.effects
        return when {
            BarrierEffect.EndPreempted in effects -> DrainEnd.Preempted
            BarrierEffect.EndFailed in effects -> DrainEnd.TeardownUnconfirmed
            effects.any { it is BarrierEffect.Log && "teardown unconfirmed" in it.line } -> DrainEnd.TeardownUnconfirmed
            effects.any { it is BarrierEffect.CancelJobs && it.logNames } -> DrainEnd.JobsDeadline
            BarrierEffect.RunApply in effects -> DrainEnd.Settled
            else -> error("no drain end in $effects")
        }
    }

    private suspend fun drain(id: Long, teardownRequired: Boolean = false, deadlineMs: Long = 2_000): DrainEnd =
        outcome(IdentityWork.awaitDrained(epoch, id, deadlineMs, teardownRequired))

    private fun TestScope.launchWork(name: String, kind: CommitKind = CommitKind.Start, block: suspend CoroutineScope.() -> Unit) =
        IdentityWork.launch(token(), name, backgroundScope, kind, block)

    @Test
    fun jobFinishingInTimeSettles() = runTest {
        assertNotNull(launchWork("short") { delay(500) })
        assertEquals(DrainEnd.Settled, drain(begin()))
        assertEquals(500, currentTime)
    }

    @Test
    fun jobNeverEndingHitsDeadlineAt2000ms() = runTest {
        val job = assertNotNull(launchWork("stuck") { awaitCancellation() })
        assertEquals(DrainEnd.JobsDeadline, drain(begin()))
        assertEquals(2_000, currentTime)
        runCurrent()
        assertTrue(job.isCancelled) // B3's CancelJobs, snapshot taken in the reducing section
    }

    @Test
    fun teardownMissingIsTeardownUnconfirmed() = runTest {
        assertEquals(DrainEnd.TeardownUnconfirmed, drain(begin(), teardownRequired = true))
        assertEquals(2_000, currentTime)
    }

    @Test
    fun teardownArrivingSettles() = runTest {
        val id = begin()
        backgroundScope.launch { delay(300); IdentityBarrier.teardownDone(id) }
        assertEquals(DrainEnd.Settled, drain(id, teardownRequired = true))
        assertEquals(300, currentTime)
    }

    @Test
    fun staleAckFromFailedAttemptIgnored() = runTest {
        val first = begin()
        // Attempt 1 fails closed (B3a): same epoch, nothing changed.
        assertEquals(DrainEnd.TeardownUnconfirmed, outcome(IdentityWork.endDrainUnconfirmed(first)))
        assertEquals(epoch, IdentityGate.currentEpoch())
        val second = begin()
        assertTrue(second != first)
        backgroundScope.launch {
            delay(100); IdentityBarrier.teardownDone(first) // late, AFTER attempt 2's Begin
            delay(400); IdentityBarrier.teardownDone(second)
        }
        assertEquals(DrainEnd.Settled, drain(second, teardownRequired = true))
        assertEquals(500, currentTime) // the late ack did not settle it at 100 ms
    }

    @Test
    fun ackBeforeDrainIgnored() = runTest {
        IdentityBarrier.teardownDone(1) // nothing awaited yet
        val id = begin()
        assertEquals(1, id)
        assertEquals(DrainEnd.TeardownUnconfirmed, drain(id, teardownRequired = true))
    }

    @Test
    fun teardownWinsOverJobs() = runTest {
        assertNotNull(launchWork("stuck") { awaitCancellation() })
        assertEquals(DrainEnd.TeardownUnconfirmed, drain(begin(), teardownRequired = true))
    }

    @Test
    fun deadlineIsTotalNotPerJob() = runTest {
        assertNotNull(launchWork("first") { delay(1_500) })
        val id = begin()
        backgroundScope.launch {
            delay(1_000)
            // The send that finishes a committed write, launched mid-drain.
            assertNotNull(IdentityWork.launch(IdentityToken(IdentityScope(accountA, 1), epoch, 5), "second", backgroundScope, CommitKind.RemoteSend) { delay(1_500) })
        }
        assertEquals(DrainEnd.JobsDeadline, drain(id))
        assertEquals(2_000, currentTime)
    }

    @Test
    fun deadlineCallNeverNull() = runTest {
        assertNotNull(launchWork("stuck") { awaitCancellation() })
        val id = begin()
        assertNull(IdentityWork.tryEndDrain(id, deadline = false))
        assertEquals(DrainEnd.JobsDeadline, outcome(assertNotNull(IdentityWork.tryEndDrain(id, deadline = true))))
        // A deadline call for an id that is not awaited still reduces (B15 logs it), never null.
        assertNotNull(IdentityWork.tryEndDrain(99, deadline = true))
    }

    @Test
    fun startRefusedWhileDraining() = runTest {
        val t = token()
        begin()
        assertNull(IdentityWork.launch(t, "new", backgroundScope) { })
        assertNull(IdentityWork.launch(null, "untokened", backgroundScope, CommitKind.RemoteSend) { })
    }

    @Test
    fun remoteSendAllowedWhileDraining() = runTest {
        val t = token()
        val id = begin()
        val job = assertNotNull(IdentityWork.launch(t, "send", backgroundScope, CommitKind.RemoteSend) { delay(100) })
        assertEquals(listOf(job), IdentityWork.jobsOf(profile = true))
        assertEquals(DrainEnd.Settled, drain(id))
        assertEquals(100, currentTime)
        assertTrue(IdentityWork.jobsOf(profile = true).isEmpty())
    }

    @Test
    fun staleTokenRefused() = runTest {
        val t = token()
        val id = begin()
        outcome(assertNotNull(IdentityWork.tryEndDrain(id, deadline = false)))
        IdentityRuntime.reduce(BarrierEvent.ApplyGate())
        IdentityRuntime.reduce(BarrierEvent.ApplyFinished(1))
        assertNull(IdentityWork.launch(t, "old", backgroundScope, CommitKind.RemoteSend) { })
        assertNotNull(IdentityWork.launch(token(), "fresh", backgroundScope) { })
    }

    @Test
    fun preemptEndsDrain() = runTest {
        assertNotNull(launchWork("stuck") { awaitCancellation() })
        val id = begin()
        backgroundScope.launch { delay(300); IdentityRuntime.reduce(BarrierEvent.WindowOpened(TransitionKind.AccountWipe)) }
        assertEquals(DrainEnd.Preempted, drain(id, teardownRequired = true))
        assertEquals(300, currentTime)
    }

    @Test
    fun cancelDoesNotJoin() = runTest {
        val job = assertNotNull(launchWork("slow-cleanup") {
            try {
                awaitCancellation()
            } finally {
                withContext(NonCancellable) { delay(10_000) }
            }
        })
        runCurrent()
        val id = begin()
        val before = currentTime
        outcome(assertNotNull(IdentityWork.tryEndDrain(id, deadline = true))) // B3 cancels it
        assertEquals(before, currentTime)
        runCurrent()
        assertTrue(job.isCancelled)
        assertFalse(job.isCompleted) // still in its cleanup; nobody waited for it
    }

    @Test
    fun awaitingBarrierJobNotWaitedButCancelled() = runTest {
        val job = assertNotNull(launchWork("caller") {
            // A child context still names the registered job (review r2-3).
            withContext(Dispatchers.Unconfined) {
                assertNotNull(IdentityWork.markAwaitingBarrier(assertNotNull(coroutineContext[IdentityJobElement])))
            }
            awaitCancellation()
        })
        runCurrent()
        assertTrue(IdentityWork.isAwaiting(job))
        assertEquals(DrainEnd.Settled, drain(begin()))
        assertEquals(0, currentTime)
        runCurrent()
        assertTrue(job.isCancelled) // B2's CancelJobs includes awaiting-barrier jobs
    }

    @Test
    fun profileSwitchCancelsEveryProfileJob() = runTest {
        val older = assertNotNull(launchWork("older") { awaitCancellation() })
        // A first switch that fails closed leaves the epoch; a second admission later still counts.
        val first = begin()
        outcome(IdentityWork.endDrainUnconfirmed(first))
        IdentityRuntime.setForTest(IdentityRuntime.snapshot().copy(epoch = IdentityEpoch(4)))
        val newer = assertNotNull(IdentityWork.launch(assertNotNull(IdentityGate.currentToken()), "newer", backgroundScope) { awaitCancellation() })
        val account = assertNotNull(IdentityWork.launchAccount(IdentityGate.currentAccountToken(), "push", backgroundScope) { awaitCancellation() })
        val id = begin()
        assertEquals(DrainEnd.JobsDeadline, outcome(assertNotNull(IdentityWork.tryEndDrain(id, deadline = true))))
        runCurrent()
        assertTrue(older.isCancelled)
        assertTrue(newer.isCancelled)
        assertTrue(account.isActive) // account work belongs to the account
    }

    @Test
    fun failedSwitchCancelsNothing() = runTest {
        val job = assertNotNull(launchWork("save") { awaitCancellation() })
        val account = assertNotNull(IdentityWork.launchAccount(IdentityGate.currentAccountToken(), "push", backgroundScope) { awaitCancellation() })
        val reduced = IdentityWork.endDrainUnconfirmed(begin())
        assertTrue(reduced.toCancel.isEmpty())
        outcome(reduced)
        runCurrent()
        assertTrue(job.isActive)
        assertTrue(account.isActive)
    }

    @Test
    fun accountWorkSurvivesAProfileSwitchAndDiesAtAWindow() = runTest {
        val accountToken = assertNotNull(IdentityGate.currentAccountToken())
        val id = begin() // a profile drain does not refuse account work
        val job = assertNotNull(IdentityWork.launchAccount(accountToken, "push", backgroundScope) { awaitCancellation() })
        assertEquals(listOf(job), IdentityWork.jobsOf(profile = false))
        assertEquals(DrainEnd.Settled, drain(id)) // a profile drain does not wait for account work
        runCurrent()
        assertTrue(job.isActive)
        IdentityRuntime.reduce(BarrierEvent.WindowOpened(TransitionKind.AccountWipe))
        runCurrent()
        assertTrue(job.isCancelled)
        assertNull(IdentityWork.launchAccount(accountToken, "push2", backgroundScope) { })
    }

    @Test
    fun accountDrainWaitsForAccountWork() = runTest {
        assertNotNull(IdentityWork.launchAccount(IdentityGate.currentAccountToken(), "push", backgroundScope) { delay(700) })
        assertEquals(DrainEnd.Settled, drain(begin(TransitionKind.SignOut)))
        assertEquals(700, currentTime)
    }

    /** Start check and registration are one step: a job admitted before Begin is waited for and cancelled by its drain. */
    @Test
    fun registrationAtomicWithBegin() = runTest {
        withContext(Dispatchers.Default) {
            val scope = CoroutineScope(SupervisorJob() + Dispatchers.Default)
            var admitted = 0
            repeat(1_000) {
                reset()
                val t = token()
                val launched = async(Dispatchers.Default) { IdentityWork.launch(t, "race", scope) { awaitCancellation() } }
                val began = async(Dispatchers.Default) { begin() }
                val job = launched.await()
                val id = began.await()
                if (job != null) {
                    admitted++
                    // Admitted before Begin: the drain cannot settle while it runs.
                    assertNull(IdentityWork.tryEndDrain(id, deadline = false), "a drain settled past an admitted job")
                }
            }
            scope.cancel()
            println("registrationAtomicWithBegin: $admitted of 1000 admitted before Begin")
        }
    }

    /**
     * 4.3a point 2: a RemoteSend admission races the drain's end. Either it registers first and the
     * drain does not settle until it ends, or it is refused; never registered-then-cancelled with
     * the apply run.
     */
    @Test
    fun admissionRaceWithDrainEnd() = runTest {
        withContext(Dispatchers.Default) {
            val scope = CoroutineScope(SupervisorJob() + Dispatchers.Default)
            var admitted = 0
            var refused = 0
            repeat(1_000) {
                reset()
                val t = token()
                val id = begin()
                val launched = async(Dispatchers.Default) {
                    IdentityWork.launch(t, "send", scope, CommitKind.RemoteSend) { awaitCancellation() }
                }
                val ended = async(Dispatchers.Default) { IdentityWork.tryEndDrain(id, deadline = false) }
                val job = launched.await()
                val end = ended.await()
                if (job != null) {
                    admitted++
                    if (end != null) {
                        // The drain ended first; then the admission could only have been refused.
                        error("admitted after the drain ended")
                    }
                    assertIs<IdentityPhase.Draining>(IdentityGate.state.value.phase)
                } else {
                    refused++
                    assertNotNull(end, "refused but the drain did not end")
                    assertTrue(BarrierEffect.RunApply in end.effects)
                    assertTrue(end.toCancel.isEmpty())
                }
            }
            scope.cancel()
            println("admissionRaceWithDrainEnd: $admitted admitted, $refused refused")
        }
    }

    /** Review r2-2: the marker is scoped; once unmarked, the job counts for the next drain again. */
    @Test
    fun unmarkedJobIsWaitedForAgain() = runTest {
        var element: IdentityJobElement? = null
        assertNotNull(launchWork("caller") { element = coroutineContext[IdentityJobElement]; delay(800) })
        runCurrent()
        val job = assertNotNull(IdentityWork.markAwaitingBarrier(assertNotNull(element)))
        IdentityWork.unmarkAwaitingBarrier(job)
        assertFalse(IdentityWork.isAwaiting(job))
        assertEquals(DrainEnd.Settled, drain(begin()))
        assertEquals(800, currentTime)
    }

    /**
     * 5.11 point 5 (revision 9): a canceller holding a store lock runs the completion handler inline
     * (Unconfined) while another thread holds commit and wants that store lock. Removal takes only
     * the registry leaf, so this cannot deadlock.
     */
    @Test
    fun cancelInsideStoreLockDoesNotDeadlock() = runTest {
        withContext(Dispatchers.Default) {
            val storeLock = kotlinx.atomicfu.locks.SynchronizedObject()
            val inline = CoroutineScope(SupervisorJob() + Dispatchers.Unconfined)
            kotlinx.coroutines.withTimeout(30_000) {
                repeat(1_000) {
                    val job = assertNotNull(IdentityWork.launch(token(), "push", inline) { awaitCancellation() })
                    val canceller = async(Dispatchers.Default) {
                        kotlinx.atomicfu.locks.synchronized(storeLock) { job.cancel() }
                    }
                    val committer = async(Dispatchers.Default) {
                        IdentityLocks.withCommit { kotlinx.atomicfu.locks.synchronized(storeLock) { } }
                    }
                    canceller.await()
                    committer.await()
                    assertTrue(job.isCancelled)
                }
            }
            inline.cancel()
            assertTrue(IdentityWork.jobsOf(profile = true).isEmpty())
        }
    }

    @Test
    fun lockOrderChecksAroundTheLeaf() {
        kotlin.test.assertFailsWith<IllegalStateException> { IdentityLocks.withRegistry { IdentityLocks.withCommit { } } }
        kotlin.test.assertFailsWith<IllegalStateException> { IdentityLocks.withRegistry { IdentityLocks.withRegistry { } } }
        kotlin.test.assertFailsWith<IllegalStateException> { IdentityLocks.inCompletionHandler { IdentityLocks.withCommit { } } }
        // commit → registry is the allowed order
        assertEquals(1, IdentityLocks.withCommit { IdentityLocks.withRegistry { IdentityLocks.commitDepth } })
    }
}
