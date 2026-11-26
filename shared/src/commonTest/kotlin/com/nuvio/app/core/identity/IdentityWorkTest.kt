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
import kotlin.test.assertNotNull
import kotlin.test.assertNull
import kotlin.test.assertTrue

/** Spec 4.3 (revision 7), on virtual time except the atomicity stress test. */
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

    private fun begin() {
        IdentityRuntime.reduce(BarrierEvent.Begin(TransitionKind.ProfileSelect))
    }

    private fun TestScope.launchWork(name: String, kind: CommitKind = CommitKind.Start, block: suspend CoroutineScope.() -> Unit) =
        IdentityWork.launch(token(), name, backgroundScope, kind, block)

    @Test
    fun jobFinishingInTimeSettles() = runTest {
        assertNotNull(launchWork("short") { delay(500) })
        begin()
        assertEquals(DrainEnd.Settled, IdentityWork.awaitDrained(epoch, 2_000, teardownRequired = false))
        assertEquals(500, currentTime)
    }

    @Test
    fun jobNeverEndingHitsDeadlineAt2000ms() = runTest {
        val job = assertNotNull(launchWork("stuck") { awaitCancellation() })
        begin()
        assertEquals(DrainEnd.JobsDeadline, IdentityWork.awaitDrained(epoch, 2_000, teardownRequired = false))
        assertEquals(2_000, currentTime)
        assertTrue(job.isActive)
        IdentityWork.cancel(epoch, logNames = true)
        runCurrent()
        assertTrue(job.isCancelled)
    }

    @Test
    fun teardownMissingIsTeardownUnconfirmed() = runTest {
        begin()
        assertEquals(DrainEnd.TeardownUnconfirmed, IdentityWork.awaitDrained(epoch, 2_000, teardownRequired = true))
        assertEquals(2_000, currentTime)
    }

    @Test
    fun teardownArrivingSettles() = runTest {
        begin()
        backgroundScope.launch { delay(300); IdentityBarrier.teardownDone(epoch.value) }
        assertEquals(DrainEnd.Settled, IdentityWork.awaitDrained(epoch, 2_000, teardownRequired = true))
        assertEquals(300, currentTime)
    }

    @Test
    fun staleTeardownAckIsForgottenAtBegin() = runTest {
        // Revision 7: a B3a failure keeps the epoch, so a retry runs at the same epoch.
        IdentityBarrier.teardownDone(epoch.value)
        IdentityWork.beginDrain(epoch)
        begin()
        assertEquals(DrainEnd.TeardownUnconfirmed, IdentityWork.awaitDrained(epoch, 2_000, teardownRequired = true))
    }

    @Test
    fun teardownWinsOverJobs() = runTest {
        assertNotNull(launchWork("stuck") { awaitCancellation() })
        begin()
        assertEquals(DrainEnd.TeardownUnconfirmed, IdentityWork.awaitDrained(epoch, 2_000, teardownRequired = true))
    }

    @Test
    fun deadlineIsTotalNotPerJob() = runTest {
        assertNotNull(launchWork("first") { delay(1_500) })
        begin()
        backgroundScope.launch {
            delay(1_000)
            // The send that finishes a committed write, launched mid-drain.
            assertNotNull(IdentityWork.launch(IdentityToken(IdentityScope(accountA, 1), epoch, 5), "second", backgroundScope, CommitKind.RemoteSend) { delay(1_500) })
        }
        assertEquals(DrainEnd.JobsDeadline, IdentityWork.awaitDrained(epoch, 2_000, teardownRequired = false))
        assertEquals(2_000, currentTime)
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
        begin()
        val job = assertNotNull(IdentityWork.launch(t, "send", backgroundScope, CommitKind.RemoteSend) { delay(100) })
        assertEquals(listOf(job), IdentityWork.jobsFor(epoch))
        assertEquals(DrainEnd.Settled, IdentityWork.awaitDrained(epoch, 2_000, teardownRequired = false))
        assertEquals(100, currentTime)
        assertTrue(IdentityWork.jobsFor(epoch).isEmpty())
    }

    @Test
    fun staleTokenRefused() = runTest {
        val t = token()
        begin()
        IdentityRuntime.reduce(BarrierEvent.DrainEnded(DrainEnd.Settled))
        IdentityRuntime.reduce(BarrierEvent.ApplyGate())
        IdentityRuntime.reduce(BarrierEvent.ApplyFinished(1))
        assertNull(IdentityWork.launch(t, "old", backgroundScope, CommitKind.RemoteSend) { })
        assertNotNull(IdentityWork.launch(token(), "fresh", backgroundScope) { })
    }

    @Test
    fun preemptEndsDrain() = runTest {
        assertNotNull(launchWork("stuck") { awaitCancellation() })
        begin()
        backgroundScope.launch { delay(300); IdentityWork.signalPreempted(epoch) }
        assertEquals(DrainEnd.Preempted, IdentityWork.awaitDrained(epoch, 2_000, teardownRequired = true))
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
        begin()
        val before = currentTime
        IdentityWork.cancel(epoch, logNames = false)
        assertEquals(before, currentTime)
        runCurrent()
        assertTrue(job.isCancelled)
        assertFalse(job.isCompleted) // still in its cleanup; nobody waited for it
    }

    @Test
    fun awaitingBarrierJobNotWaitedButCancelled() = runTest {
        val job = assertNotNull(launchWork("caller") { awaitCancellation() })
        IdentityWork.markAwaitingBarrier(job)
        begin()
        assertEquals(DrainEnd.Settled, IdentityWork.awaitDrained(epoch, 2_000, teardownRequired = false))
        assertEquals(0, currentTime)
        IdentityWork.cancel(epoch, logNames = true)
        runCurrent()
        assertTrue(job.isCancelled)
    }

    @Test
    fun accountWorkRegistersUnderTheCurrentEpochAndStopsAtAWindow() = runTest {
        val accountToken = assertNotNull(IdentityGate.currentAccountToken())
        begin() // a profile drain does not refuse account work
        val job = assertNotNull(IdentityWork.launchAccount(accountToken, "push", backgroundScope) { awaitCancellation() })
        assertEquals(listOf(job), IdentityWork.jobsFor(epoch))
        IdentityRuntime.reduce(BarrierEvent.WindowOpened(TransitionKind.AccountWipe))
        assertNull(IdentityWork.launchAccount(accountToken, "push2", backgroundScope) { })
    }

    /** Start check and registration are one step: a job admitted before Begin is in the drain's snapshot. */
    @Test
    fun registrationAtomicWithBegin() = runTest {
        withContext(Dispatchers.Default) {
            val scope = CoroutineScope(SupervisorJob() + Dispatchers.Default)
            var admitted = 0
            repeat(1_000) {
                reset()
                val t = token()
                val launched = async(Dispatchers.Default) { IdentityWork.launch(t, "race", scope) { awaitCancellation() } }
                val drained = async(Dispatchers.Default) { begin(); IdentityWork.jobsFor(epoch) }
                val job = launched.await()
                val snapshot = drained.await()
                if (job != null) {
                    admitted++
                    assertTrue(job in snapshot, "admitted job missing from the drain's snapshot")
                }
            }
            scope.cancel()
            // Both orders must have occurred at least once for the test to mean anything; log the split.
            println("registrationAtomicWithBegin: $admitted of 1000 admitted before Begin")
        }
    }
}
