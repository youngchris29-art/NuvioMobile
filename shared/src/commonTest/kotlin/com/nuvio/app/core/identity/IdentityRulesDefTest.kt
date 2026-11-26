package com.nuvio.app.core.identity

import com.nuvio.app.core.auth.AuthState
import kotlinx.coroutines.CompletableDeferred
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.NonCancellable
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.async
import kotlinx.coroutines.awaitCancellation
import kotlinx.coroutines.cancel
import kotlinx.coroutines.delay
import kotlinx.coroutines.launch
import kotlinx.coroutines.test.runTest
import kotlinx.coroutines.withContext
import kotlinx.coroutines.withTimeout
import kotlin.test.AfterTest
import kotlin.test.BeforeTest
import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertFailsWith
import kotlin.test.assertFalse
import kotlin.test.assertIs
import kotlin.test.assertNotNull
import kotlin.test.assertNull
import kotlin.test.assertTrue
import kotlin.time.TimeSource

/** Spec 4.8 (revision 12): rules D (follow-ups), E (pending slot removal) and F (cancels off the transition threads). */
class IdentityRulesDefTest {

    private val log = EventLog()
    private lateinit var ops: FakeProfileOps
    private val work = CoroutineScope(SupervisorJob() + Dispatchers.Default)

    @BeforeTest
    fun setUp() {
        ops = installDriverFakes(log)
        IdentityGate.afterFollowUpAdmitted = {}
    }

    @AfterTest
    fun tearDown() {
        IdentityGate.afterFollowUpAdmitted = {}
        work.cancel()
        resetIdentityForTest()
    }

    private fun real(block: suspend CoroutineScope.() -> Unit) = runTest { withContext(Dispatchers.Default) { withTimeout(15_000) { block() } } }

    private fun spinFor(ms: Long) {
        val t = TimeSource.Monotonic.markNow()
        while (t.elapsedNow().inWholeMilliseconds < ms) { /* hold this thread */ }
    }

    // ---- rule D ----

    /** P16: a select begins between the local commit and the follow-up's start; its drain counts the follow-up. */
    @Test
    fun followUpAdmittedWithCommit() = real {
        IdentityBarrier.drainDeadlineMs = 2_000
        var select: kotlinx.coroutines.Deferred<TransitionResult>? = null
        IdentityGate.afterFollowUpAdmitted = {
            select = async { IdentityBarrier.selectProfile(2) }
            // Hold the start until the select is draining and would find no other job.
            val t = TimeSource.Monotonic.markNow()
            while (IdentityGate.state.value.kind != TransitionKind.ProfileSelect && t.elapsedNow().inWholeMilliseconds < 3_000) { }
            spinFor(100)
        }
        val result = IdentityGate.commitWithFollowUp(IdentityGate.currentToken(), CommitKind.LocalWrite, "test", { log.add("local"); 1 }) {
            FollowUp("push", work) { delay(150); log.add("send") }
        }
        assertEquals(CommitResult.Committed(1), result)
        assertIs<TransitionResult.Done>(assertNotNull(select).await())
        assertEquals(listOf("local", "send", "apply 2"), log.all())
    }

    @Test
    fun refusedCommitAdmitsNoFollowUp() = real {
        val stale = assertNotNull(IdentityGate.currentToken())
        IdentityRuntime.authSerial = { 9 }
        var factoryRan = false
        val result = IdentityGate.commitWithFollowUp(stale, CommitKind.LocalWrite, "test", { log.add("local"); 1 }) {
            factoryRan = true
            FollowUp("push", work) { log.add("send") }
        }
        assertEquals(CommitResult.Rejected(RejectReason.AccountChanged), result)
        assertFalse(factoryRan)
        assertTrue(IdentityWork.jobsOf(profile = true).isEmpty())
        assertEquals(emptyList(), log.all())
    }

    @Test
    fun throwingBlockAdmitsNoFollowUp() = real {
        assertFailsWith<IllegalStateException> {
            IdentityGate.commitWithFollowUp<Int>(IdentityGate.currentToken(), CommitKind.LocalWrite, "test", { error("disk") }) {
                FollowUp("push", work) { log.add("send") }
            }
        }
        // A null follow-up admits nothing either.
        IdentityGate.commitWithFollowUp(IdentityGate.currentToken(), CommitKind.LocalWrite, "test", { 1 }) { null }
        assertTrue(IdentityWork.jobsOf(profile = true).isEmpty())
        delay(50)
        assertEquals(emptyList(), log.all())
    }

    /** The persisted claim: the follow-up is admitted with the claim, so an otherwise empty drain waits for it. */
    @Test
    fun persistedClaimFollowUpSurvivesEmptyDrain() = real {
        IdentityBarrier.drainDeadlineMs = 2_000
        var select: kotlinx.coroutines.Deferred<TransitionResult>? = null
        IdentityGate.afterFollowUpAdmitted = {
            select = async { IdentityBarrier.selectProfile(2) }
            val t = TimeSource.Monotonic.markNow()
            while (IdentityGate.state.value.kind != TransitionKind.ProfileSelect && t.elapsedNow().inWholeMilliseconds < 3_000) { }
            spinFor(100)
        }
        val result = IdentityGate.commitPersistedWithFollowUp("account:user-a", 1, "claim", { token -> log.add("record ${token.scope.slot}"); 7 }) { _, _ ->
            FollowUp("stop-scrobble", work) { delay(150); log.add("stop sent") }
        }
        assertEquals(PersistedResult.Recorded(7), result)
        assertIs<TransitionResult.Done>(assertNotNull(select).await())
        assertEquals(listOf("record 1", "stop sent", "apply 2"), log.all())
    }

    /** D + F: a follow-up admitted LAZY and cancel-requested before it starts ends; it never runs or lingers. */
    @Test
    fun followUpCancelRequestedBeforeStartEnds() = real {
        var admittedJob: kotlinx.coroutines.Job? = null
        IdentityGate.afterFollowUpAdmitted = {
            admittedJob = IdentityWork.jobsOf(profile = true).single()
            // A window opens before the follow-up starts: B10 marks it and dispatches its cancel.
            IdentityImmediate.serialChanging()
            val t = TimeSource.Monotonic.markNow()
            while (admittedJob?.isCancelled != true && t.elapsedNow().inWholeMilliseconds < 3_000) { }
        }
        IdentityGate.commitWithFollowUp(IdentityGate.currentToken(), CommitKind.LocalWrite, "test", { 1 }) {
            FollowUp("push", work) { log.add("send") }
        }
        val job = assertNotNull(admittedJob)
        eventually { job.isCompleted }
        assertTrue(job.isCancelled)
        assertTrue(IdentityWork.jobsOf(profile = true).isEmpty())
        IdentityImmediate.chainEnded()
        assertEquals(emptyList(), log.all())
    }

    /** F: a cancel-requested job's cleanup cannot commit or admit a follow-up (its token is refused). */
    @Test
    fun cancelRequestedJobCannotCommitOrAdmit() = real {
        val outcomes = CompletableDeferred<Pair<CommitResult<Int>, CommitResult<Int>>>()
        val token = assertNotNull(IdentityGate.currentToken())
        assertNotNull(IdentityWork.launch(token, "save", work) {
            try {
                awaitCancellation()
            } finally {
                withContext(NonCancellable) {
                    // Non-blocking cleanup that still tries to write after the switch began.
                    eventually { !IdentityGate.state.value.transitioning }
                    val plain = IdentityGate.commit(token, CommitKind.LocalWrite) { 1 }
                    val withFollowUp = IdentityGate.commitWithFollowUp(token, CommitKind.LocalWrite, "cleanup", { 2 }) {
                        FollowUp("late-push", work) { log.add("late send") }
                    }
                    outcomes.complete(plain to withFollowUp)
                }
            }
        })
        assertIs<TransitionResult.Done>(IdentityBarrier.selectProfile(2)) // its drain cancels the job at the deadline
        val (plain, withFollowUp) = outcomes.await()
        assertEquals(CommitResult.Rejected(RejectReason.StaleEpoch), plain) // R5 protects the new profile's stores
        assertEquals(CommitResult.Rejected(RejectReason.StaleEpoch), withFollowUp)
        delay(50)
        assertEquals(listOf("apply 2"), log.all())
    }

    // ---- rule E ----

    /** P17: a removal requested during a 3 s window is applied after it closes. */
    @Test
    fun slotRemovalSurvivesLongWindow() = real {
        val token = assertNotNull(IdentityGate.currentAccountToken())
        ops.listed = setOf(2, 3)
        IdentityImmediate.serialChanging() // a long window (no account change)
        IdentityBarrier.requestSlotRemoved(1, token)
        delay(3_000)
        assertEquals(emptyList(), log.all())
        IdentityImmediate.chainEnded()
        eventually { log.count("removed") == 1 }
        assertNull(IdentityRuntime.snapshot().pendingRemoval)
    }

    @Test
    fun slotRemovalDroppedOnAccountChange() = real {
        val token = assertNotNull(IdentityGate.currentAccountToken())
        ops.listed = setOf(2, 3)
        IdentityImmediate.serialChanging()
        IdentityBarrier.requestSlotRemoved(1, token)
        assertNotNull(IdentityRuntime.snapshot().pendingRemoval)
        IdentityImmediate.publishAuth(AuthState.Authenticated("user-b", null, isAnonymous = false)) { }
        IdentityImmediate.chainEnded()
        assertNull(IdentityRuntime.snapshot().pendingRemoval) // dropped at the settle on B
        delay(200)
        assertEquals(emptyList(), log.all())
    }

    @Test
    fun slotRemovalRevalidatedAtApply() = real {
        val token = assertNotNull(IdentityGate.currentAccountToken())
        ops.listed = setOf(2, 3)
        IdentityImmediate.serialChanging()
        IdentityBarrier.requestSlotRemoved(1, token)
        ops.listed = setOf(1, 2, 3) // listed again before it runs
        IdentityImmediate.chainEnded()
        eventually { IdentityRuntime.snapshot().pendingRemoval == null && !IdentityGate.state.value.transitioning }
        delay(100)
        assertEquals(emptyList(), log.all())
    }

    /** A sign-out queued first runs first; the removal (for the old session) then applies nothing. */
    @Test
    fun pendingRemovalDoesNotDelayAccountReset() = real {
        val token = assertNotNull(IdentityGate.currentAccountToken())
        ops.listed = setOf(2, 3)
        IdentityImmediate.serialChanging()
        val signOut = async {
            IdentityBarrier.accountReset(TransitionKind.SignOut) {
                IdentityImmediate.accountWipe { }
                IdentityImmediate.publishAuth(AuthState.Unauthenticated) { }
                IdentityImmediate.chainEnded()
                log.add("sign-out block")
                Result.success(Unit)
            }
        }
        delay(50)
        IdentityBarrier.requestSlotRemoved(1, token)
        IdentityImmediate.chainEnded() // the removal is scheduled at the tail, behind the sign-out
        assertTrue(signOut.await().isSuccess)
        delay(200)
        assertEquals(listOf("sign-out block"), log.all())
        assertNull(IdentityRuntime.snapshot().pendingRemoval)
    }

    // ---- rule F ----

    /** P18: an Unconfined job whose cancellation cleanup blocks until Open: the select still applies. */
    @Test
    fun inlineCancellationCleanupDoesNotStall() = real {
        val inline = CoroutineScope(SupervisorJob() + Dispatchers.Unconfined)
        val cleanupDone = CompletableDeferred<Unit>()
        assertNotNull(IdentityWork.launch(IdentityGate.currentToken(), "bad-cleanup", inline) {
            try {
                awaitCancellation()
            } finally {
                // Violates the contract on purpose: blocks its thread until the barrier is Open.
                val t = TimeSource.Monotonic.markNow()
                while (IdentityGate.state.value.phase !is IdentityPhase.Open || IdentityGate.state.value.epoch.value < 2) {
                    check(t.elapsedNow().inWholeMilliseconds < 10_000) { "stalled" }
                }
                cleanupDone.complete(Unit)
            }
        })
        assertIs<TransitionResult.Done>(IdentityBarrier.selectProfile(2))
        cleanupDone.await()
        assertEquals(listOf("apply 2"), log.all())
        inline.cancel()
    }

    @Test
    fun cancelRequestedJobNotCounted() = real {
        IdentityBarrier.drainDeadlineMs = 2_000
        // A job whose cleanup takes long, cancelled by a window.
        assertNotNull(IdentityWork.launch(IdentityGate.currentToken(), "slow-cleanup", work) {
            try { awaitCancellation() } finally { withContext(NonCancellable) { delay(5_000) } }
        })
        IdentityImmediate.serialChanging()
        IdentityImmediate.chainEnded()
        // A later select's drain does not wait for the cancel-requested job.
        val start = TimeSource.Monotonic.markNow()
        assertIs<TransitionResult.Done>(IdentityBarrier.selectProfile(2))
        assertTrue(start.elapsedNow().inWholeMilliseconds < 1_000, "the drain waited for a cancel-requested job")
    }

    @Test
    fun cancelsDispatchedBeforeApply() = real {
        val jobs = (1..3).map { i -> assertNotNull(IdentityWork.launch(IdentityGate.currentToken(), "save $i", work) { awaitCancellation() }) }
        var marked: List<Boolean>? = null
        ops.onApply = { marked = jobs.map { it.isCancelled || IdentityWork.isCancelRequested(it) } }
        assertIs<TransitionResult.Done>(IdentityBarrier.selectProfile(2))
        assertEquals(listOf(true, true, true), marked)
    }
}
