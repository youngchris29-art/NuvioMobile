package com.nuvio.app.core.identity

import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.async
import kotlinx.coroutines.awaitAll
import kotlinx.coroutines.awaitCancellation
import kotlinx.coroutines.cancel
import kotlinx.coroutines.delay
import kotlinx.coroutines.launch
import kotlinx.coroutines.test.runTest
import kotlin.test.assertNull
import kotlinx.coroutines.currentCoroutineContext
import kotlinx.coroutines.flow.first
import kotlinx.coroutines.withContext
import kotlin.test.AfterTest
import kotlin.test.BeforeTest
import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertIs
import kotlin.test.assertNotNull
import kotlin.test.assertTrue
import kotlin.time.TimeSource

/** Spec 4.4 (revision 7): the real driver, real runtime and real work registry on real threads, with fake profile ops. */
class IdentityBarrierDriverTest {

    private val log = EventLog()
    private lateinit var ops: FakeProfileOps
    private val work = CoroutineScope(SupervisorJob() + Dispatchers.Default)

    @BeforeTest
    fun setUp() {
        ops = installDriverFakes(log)
    }

    @AfterTest
    fun tearDown() {
        work.cancel()
        resetIdentityForTest()
    }

    private fun epoch() = IdentityGate.state.value.epoch.value

    private fun real(block: suspend CoroutineScope.() -> Unit) = runTest { withContext(Dispatchers.Default) { block() } }

    @Test
    fun transitionsRunInCallOrder() = real {
        IdentityBarrier.debugHoldMs = { 30 }
        val first = async { IdentityBarrier.selectProfile(2) }
        eventually { IdentityGate.state.value.transitioning }
        val second = async { IdentityBarrier.selectProfile(3) }
        assertIs<TransitionResult.Done>(first.await())
        assertIs<TransitionResult.Done>(second.await())
        assertEquals(listOf("apply 2", "apply 3"), log.all())
        assertEquals(3, IdentityGate.state.value.scope.slot)
        assertEquals(3L, epoch())
    }

    @Test
    fun neverNested() = real {
        val revoker = RecordingRevoker(log)
        IdentityRevocation.revoker = revoker
        IdentityBarrier.debugHoldMs = { 10 }
        (2..6).map { slot -> async { IdentityBarrier.selectProfile(slot) } }.awaitAll()
            .forEach { assertIs<TransitionResult.Done>(it) }
        // Every Begin saw the previous transition finished: consecutive epochs, all Draining.
        assertEquals((1L..5L).toList(), revoker.states.map { it.epoch.value })
        assertTrue(revoker.states.all { it.phase is IdentityPhase.Draining })
        assertEquals((1L..5L).toList(), revoker.states.map { it.transitionId })
        assertEquals(6L, epoch())
    }

    @Test
    fun jobThatNeverEndsTimesOutThenCancels() = real {
        val job = assertNotNull(IdentityWork.launch(IdentityGate.currentToken(), "stuck", work) { awaitCancellation() })
        val start = TimeSource.Monotonic.markNow()
        assertIs<TransitionResult.Done>(IdentityBarrier.selectProfile(2))
        assertTrue(start.elapsedNow().inWholeMilliseconds >= 400)
        eventually { job.isCancelled }
        assertEquals(listOf("apply 2"), log.all())
    }

    @Test
    fun callerCancelledTransitionStillOpens() = real {
        IdentityBarrier.debugHoldMs = { 200 }
        val caller = launch { IdentityBarrier.selectProfile(2) }
        eventually { IdentityGate.state.value.transitioning }
        caller.cancel()
        eventually { log.count("apply 2") == 1 && !IdentityGate.state.value.transitioning }
        assertEquals(IdentityScope(accountA, 2), IdentityGate.state.value.scope)
        assertEquals(2L, epoch())
    }

    /** Rule B′ (review r5-1): the apply changes the active slot, then throws: Recovery(FailedApply), no token, Failed. */
    @Test
    fun throwAfterSlotMutationEntersRecovery() = real {
        ops.afterMutation = { error("fan-out failed after the slot write") }
        val result = assertIs<TransitionResult.Failed>(IdentityBarrier.selectProfile(2))
        assertTrue("fan-out failed" in result.error)
        assertEquals(IdentityPhase.Recovery(IdentityEpoch(1)), result.final.phase)
        assertEquals(RecoveryReason.FailedApply, result.final.recovery)
        assertEquals(2, ops.active) // the body did mutate
        assertNull(IdentityGate.currentToken())
        assertNull(IdentityGate.currentAccountToken())
    }

    /** Re-read finding: a queued select that applies nothing (its session changed) does not clear FailedApply. */
    @Test
    fun noOpSelectDoesNotClearFailedApply() = real {
        ops.afterMutation = { if (it == 2) error("fan-out failed") }
        assertIs<TransitionResult.Failed>(IdentityBarrier.selectProfile(2))
        IdentityImmediate.serialChanging()
        val queued = async { IdentityBarrier.selectProfile(3) }
        delay(50)
        IdentityRuntime.authSerial = { 2 } // the session changed while the select waited
        IdentityImmediate.chainEnded()
        assertIs<TransitionResult.Preempted>(queued.await())
        assertEquals(RecoveryReason.FailedApply, IdentityGate.state.value.recovery)
        assertNull(IdentityGate.currentToken())
    }

    @Test
    fun selectFromFailedApplyClears() = real {
        ops.afterMutation = { if (it == 2) error("fan-out failed") }
        assertIs<TransitionResult.Failed>(IdentityBarrier.selectProfile(2))
        assertIs<IdentityPhase.Recovery>(IdentityGate.state.value.phase)
        val done = assertIs<TransitionResult.Done>(IdentityBarrier.selectProfile(3)) // B20a, then B7 clears
        assertEquals(IdentityState(IdentityScope(accountA, 3), IdentityEpoch(2), IdentityPhase.Open, null), done.final)
        assertEquals(accountA, assertNotNull(IdentityGate.currentToken()).scope.account)
    }

    @Test
    fun teardownDeadlineReleasesWithoutApply() = real {
        IdentityBarrier.drainDeadlineMs = 2_000
        val revoker = RecordingRevoker(log)
        IdentityRevocation.revoker = revoker
        IdentityRevocation.required = true
        val start = TimeSource.Monotonic.markNow()
        val failed = assertIs<TransitionResult.Failed>(IdentityBarrier.selectProfile(2))
        val elapsed = start.elapsedNow().inWholeMilliseconds
        assertTrue(elapsed in 2_000..3_500, "failed after $elapsed ms")
        assertEquals(IdentityState(IdentityScope(accountA, 1), IdentityEpoch(1), IdentityPhase.Open, null), failed.final)
        assertEquals(0, log.count("apply 2"))

        // A second select whose teardown is acknowledged succeeds.
        revoker.onRevoke = { IdentityBarrier.teardownDone(it.transitionId) }
        val done = assertIs<TransitionResult.Done>(IdentityBarrier.selectProfile(2))
        assertEquals(IdentityScope(accountA, 2), done.final.scope)
        assertEquals(2L, done.final.epoch.value)
    }

    @Test
    fun revokerFalseFailsSelectAtOnce() = real {
        IdentityBarrier.drainDeadlineMs = 2_000
        val revoker = RecordingRevoker(log).also { it.result = false }
        IdentityRevocation.revoker = revoker
        IdentityRevocation.required = true
        assertNotNull(IdentityWork.launch(IdentityGate.currentToken(), "stuck", work) { awaitCancellation() })
        val start = TimeSource.Monotonic.markNow()
        val failed = assertIs<TransitionResult.Failed>(IdentityBarrier.selectProfile(2))
        assertTrue(start.elapsedNow().inWholeMilliseconds < 1_000, "did not fail at once")
        assertEquals(IdentityEpoch(1), failed.final.epoch)
        assertEquals(IdentityPhase.Open, failed.final.phase)
        assertEquals(0, log.count("apply 2"))
    }

    @Test
    fun missingRequiredRevokerFailsSelect() = real {
        IdentityBarrier.drainDeadlineMs = 2_000
        IdentityRevocation.required = true
        val start = TimeSource.Monotonic.markNow()
        val failed = assertIs<TransitionResult.Failed>(IdentityBarrier.selectProfile(2))
        assertTrue(start.elapsedNow().inWholeMilliseconds < 1_000)
        assertEquals(IdentityEpoch(1), failed.final.epoch)
        assertEquals(0, log.count("apply 2"))
    }

    @Test
    fun revokerFalseSignOutProceeds() = real {
        IdentityRevocation.revoker = RecordingRevoker(log).also { it.result = false }
        IdentityRevocation.required = true
        assertNotNull(IdentityWork.launch(IdentityGate.currentToken(), "save", work) { delay(150); log.add("job end") })
        val result = IdentityBarrier.accountReset(TransitionKind.SignOut) { log.add("block"); Result.success(Unit) }
        assertTrue(result.isSuccess)
        assertEquals(listOf("revoke SignOut", "job end", "block"), log.all())
        assertEquals(2L, epoch())
        assertEquals(IdentityPhase.Open, IdentityGate.state.value.phase)
    }

    @Test
    fun windowBeforeGateReturnsPreempted() = real {
        IdentityBarrier.beforeApplyLock = {
            IdentityImmediate.serialChanging()
            IdentityImmediate.chainEnded()
        }
        val result = assertIs<TransitionResult.Preempted>(IdentityBarrier.selectProfile(2))
        assertEquals(0, log.count("apply 2"))
        assertEquals(IdentityPhase.Open, result.final.phase)
        assertEquals(2L, result.final.epoch.value) // one bump for the one closed period
        assertEquals(1, result.final.scope.slot)
    }

    @Test
    fun windowAfterGateWaitsForApply() = real {
        var wipe: kotlinx.coroutines.Job? = null
        ops.onApply = {
            wipe = work.launch {
                IdentityImmediate.accountWipe { log.add("wipe") }
                IdentityImmediate.chainEnded()
            }
            spinUntil { IdentityRuntime.snapshot().window != null }
            log.add("apply body end")
        }
        val done = assertIs<TransitionResult.Done>(IdentityBarrier.selectProfile(2))
        assertNotNull(wipe).join()
        assertEquals(listOf("apply body end", "apply 2", "wipe"), log.all())
        assertEquals(IdentityPhase.Open, done.final.phase)
        assertEquals(2L, epoch())
    }

    @Test
    fun accountResetRunsBlockAfterDrain() = real {
        assertNotNull(IdentityWork.launch(IdentityGate.currentToken(), "save", work) { delay(150); log.add("job end") })
        val result = IdentityBarrier.accountReset(TransitionKind.SignOut) {
            log.add("block ${IdentityGate.state.value.phase::class.simpleName}")
            Result.success(Unit)
        }
        assertTrue(result.isSuccess)
        assertEquals(listOf("job end", "block Applying"), log.all())
        assertEquals(2L, epoch())
    }

    @Test
    fun accountResetPassesTheBlocksFailureThrough() = real {
        val result = IdentityBarrier.accountReset(TransitionKind.DeleteAccount) { error("server said no") }
        assertTrue(result.isFailure)
        assertEquals(IdentityPhase.Open, IdentityGate.state.value.phase)
        assertEquals(2L, epoch())
        assertTrue(IdentityBarrier.accountReset(TransitionKind.ProfileSelect) { Result.success(Unit) }.isFailure)
    }

    @Test
    fun beginWaitsForOpenWindow() = real {
        IdentityImmediate.serialChanging()
        val select = async { IdentityBarrier.selectProfile(2) }
        delay(150)
        assertEquals(0, log.count("apply 2"))
        assertEquals(TransitionKind.AccountWipe, IdentityGate.state.value.kind)
        IdentityImmediate.chainEnded()
        assertIs<TransitionResult.Done>(select.await())
        assertEquals(3L, epoch()) // the window's period, then the select's
    }

    @Test
    fun revokeRunsBeforeDrainAndApply() = real {
        IdentityRevocation.revoker = RecordingRevoker(log)
        assertNotNull(IdentityWork.launch(IdentityGate.currentToken(), "save", work) { delay(100); log.add("job end") })
        assertIs<TransitionResult.Done>(IdentityBarrier.selectProfile(2))
        assertEquals(listOf("revoke ProfileSelect", "job end", "apply 2"), log.all())
    }

    @Test
    fun deleteActiveProfileRechecksTheAccount() = real {
        val stale = AccountToken(accountA, authSerial = 99)
        assertIs<TransitionResult.Done>(IdentityBarrier.deleteActiveProfile(1, nextSlot = 2, token = stale))
        assertEquals(0, log.count("apply 2"))
        val token = assertNotNull(IdentityGate.currentAccountToken())
        assertIs<TransitionResult.Done>(IdentityBarrier.deleteActiveProfile(1, nextSlot = null, token = token))
        assertEquals(listOf("removed"), log.all())
    }

    @Test
    fun slotRemovedRevalidatesAtApply() = real {
        val token = assertNotNull(IdentityGate.currentAccountToken())
        // Slot 1 is still listed: nothing applies.
        IdentityBarrier.requestSlotRemoved(1, token)
        eventually { epoch() == 2L }
        assertEquals(emptyList(), log.all())
        ops.listed = setOf(2, 3)
        IdentityBarrier.requestSlotRemoved(1, assertNotNull(IdentityGate.currentAccountToken()))
        eventually { epoch() == 3L }
        assertEquals(listOf("removed"), log.all())
    }

    @Test
    fun queuedDeleteAfterOtherSelectAppliesNothing() = real {
        IdentityBarrier.debugHoldMs = { 100 }
        val token = assertNotNull(IdentityGate.currentAccountToken())
        val select = async { IdentityBarrier.selectProfile(2) }
        eventually { IdentityGate.state.value.transitioning }
        // The delete of slot 1 (the active slot when it was requested) queues behind the select.
        val delete = async { IdentityBarrier.deleteActiveProfile(1, nextSlot = 3, token = token) }
        assertIs<TransitionResult.Done>(select.await())
        assertIs<TransitionResult.Done>(delete.await())
        assertEquals(listOf("apply 2"), log.all())
        assertEquals(2, ops.active)
        assertEquals(IdentityScope(accountA, 2), IdentityGate.state.value.scope)
    }

    @Test
    fun accountJobSurvivesProfileSwitchDiesAtAccountReset() = real {
        var push: kotlinx.coroutines.Job? = null
        ops.onApply = {
            // Admitted during the select's apply: account work is allowed through a profile barrier.
            push = IdentityWork.launchAccount(IdentityGate.currentAccountToken(), "push", work) { awaitCancellation() }
        }
        assertIs<TransitionResult.Done>(IdentityBarrier.selectProfile(2))
        val job = assertNotNull(push)
        delay(50)
        assertTrue(job.isActive, "account work must survive a profile switch")
        val result = IdentityBarrier.accountReset(TransitionKind.SignOut) {
            log.add("block cancelled=${job.isCancelled}")
            Result.success(Unit)
        }
        assertTrue(result.isSuccess)
        assertEquals("block cancelled=true", log.all().last())
    }

    @Test
    fun afterAccountOpenFiresOnDriverSettle() = real {
        val ran = kotlinx.coroutines.flow.MutableStateFlow(0)
        IdentityImmediate.afterAccountOpen = { ran.value += 1 }
        val result = IdentityBarrier.accountReset(TransitionKind.SignOut) {
            // The auth chain inside the hold: wipe, publish None, chain end (B12: drained still Applying).
            IdentityImmediate.accountWipe { log.add("wipe") }
            IdentityImmediate.publishAuth(com.nuvio.app.core.auth.AuthState.Unauthenticated) { log.add("write") }
            IdentityImmediate.chainEnded()
            delay(50)
            log.add("hook before settle=${ran.value}")
            Result.success(Unit)
        }
        assertTrue(result.isSuccess)
        eventually { ran.value == 1 }
        assertEquals("hook before settle=0", log.all().last())
        assertEquals(IdentityScope(AccountKey.None, 1), IdentityGate.state.value.scope)
        // A same-account settle does not fire it.
        assertIs<TransitionResult.Done>(IdentityBarrier.selectProfile(2))
        delay(100)
        assertEquals(1, ran.value)
    }

    @Test
    fun queuedSelectAcrossAnAccountChangeAppliesNothing() = real {
        // A window holds the lane's Begin; it changes the account before the queued select begins.
        IdentityImmediate.serialChanging()
        val select = async { IdentityBarrier.selectProfile(2) }
        delay(100)
        IdentityImmediate.publishAuth(com.nuvio.app.core.auth.AuthState.Authenticated("user-b", null, isAnonymous = false)) { }
        IdentityImmediate.chainEnded()
        assertIs<TransitionResult.Preempted>(select.await()) // revision 9: nothing applied
        assertEquals(emptyList(), log.all())
        assertEquals(IdentityScope(accountB, 1), IdentityGate.state.value.scope)
    }

    /** Review r2-5: same account, new session (serial): the queued select applies nothing. */
    @Test
    fun queuedSelectAcrossASameAccountSessionReplacementAppliesNothing() = real {
        IdentityImmediate.serialChanging()
        val select = async { IdentityBarrier.selectProfile(2) }
        delay(100)
        IdentityRuntime.authSerial = { 2 } // the replaced session, same account A
        IdentityImmediate.publishAuth(com.nuvio.app.core.auth.AuthState.Authenticated("user-a", null, isAnonymous = false)) { }
        IdentityImmediate.chainEnded()
        assertIs<TransitionResult.Preempted>(select.await())
        assertEquals(emptyList(), log.all())
        assertEquals(IdentityScope(accountA, 1), IdentityGate.state.value.scope)
        // A select requested under the new session applies.
        assertIs<TransitionResult.Done>(IdentityBarrier.selectProfile(2))
        assertEquals(listOf("apply 2"), log.all())
    }

    /** Review r2-2: account work that awaited a profile switch and survived counts for the next account drain. */
    @Test
    fun survivingAccountJobIsDrainedByALaterSignOut() = real {
        assertNotNull(IdentityWork.launchAccount(IdentityGate.currentAccountToken(), "push", work) {
            assertEquals(TransitionResult.Requested, IdentityBarrier.selectProfile(2)) // rule A
            delay(250)
            log.add("push end")
        })
        eventually { log.count("apply 2") == 1 }
        eventually { !IdentityGate.state.value.transitioning }
        val result = IdentityBarrier.accountReset(TransitionKind.SignOut) { log.add("block"); Result.success(Unit) }
        assertTrue(result.isSuccess)
        assertEquals(listOf("apply 2", "push end", "block"), log.all())
    }

    /**
     * Review r2-4: a window pre-empts a sign-out drain; its cancels are issued before the driver may
     * apply, even when another job's completion wakes the drain loop first.
     */
    @Test
    fun windowCancelsAreIssuedBeforeAPreemptedSignOutApplies() = real {
        val revoker = RecordingRevoker(log)
        revoker.onRevoke = { state ->
            if (state.phase is IdentityPhase.Closed) {
                val t = kotlin.time.TimeSource.Monotonic.markNow()
                while (t.elapsedNow().inWholeMilliseconds < 300) { /* the window's slow main-thread revoke */ }
            }
        }
        IdentityRevocation.revoker = revoker
        IdentityBarrier.drainDeadlineMs = 2_000
        val stuck = assertNotNull(IdentityWork.launch(IdentityGate.currentToken(), "stuck", work) { awaitCancellation() })
        assertNotNull(IdentityWork.launch(IdentityGate.currentToken(), "short", work) { delay(150) })
        val signOut = async {
            IdentityBarrier.accountReset(TransitionKind.SignOut) {
                log.add("block stuck cancelled=${stuck.isCancelled}")
                Result.success(Unit)
            }
        }
        eventually { IdentityGate.state.value.phase is IdentityPhase.Draining }
        val auth = launch(Dispatchers.Default) {
            delay(50)
            IdentityImmediate.serialChanging() // B10: pre-empts; the "short" job completes during the slow revoke
            IdentityImmediate.chainEnded()
        }
        assertTrue(signOut.await().isSuccess)
        auth.join()
        assertTrue(log.all().contains("block stuck cancelled=true"), "${log.all()}")
    }

    /** Review r3-2: requests run in call order, even when both are queued before the lane starts either. */
    @Test
    fun requestsRunInCallOrderByConstruction() = real {
        repeat(20) { round ->
            val gate = kotlinx.coroutines.CompletableDeferred<Unit>()
            val holder = async { IdentityBarrier.accountReset(TransitionKind.ServerSwitch) { gate.await(); Result.success(Unit) } }
            eventually { IdentityGate.state.value.kind == TransitionKind.ServerSwitch }
            // Both calls take their place in the queue synchronously, in this order.
            val a = async(start = kotlinx.coroutines.CoroutineStart.UNDISPATCHED) { IdentityBarrier.selectProfile(2) }
            val b = async(start = kotlinx.coroutines.CoroutineStart.UNDISPATCHED) { IdentityBarrier.selectProfile(3) }
            gate.complete(Unit)
            holder.await(); a.await(); b.await()
            assertEquals(3, ops.active, "round $round: ${log.all()}")
        }
        assertEquals((1..20).flatMap { listOf("apply 2", "apply 3") }, log.all())
    }


    /** Rule A: a registered job requests a select; the call returns Requested at once; the select drains and waits for that job; it applies once. */
    @Test
    fun transitionFromJobReturnsRequested() = real {
        val returned = kotlinx.coroutines.CompletableDeferred<TransitionResult>()
        assertNotNull(IdentityWork.launch(IdentityGate.currentToken(), "caller", work) {
            returned.complete(IdentityBarrier.selectProfile(2))
            delay(200)
            log.add("job end")
        })
        assertEquals(TransitionResult.Requested, returned.await())
        eventually { log.count("apply 2") == 1 }
        assertEquals(listOf("job end", "apply 2"), log.all()) // the select's drain waited for the job
        delay(100)
        assertEquals(1, log.count("apply 2"))
    }

    /** Rule A (review r4-2): one child requests a switch while a sibling pushes; the sign-out drain still waits for the parent. */
    @Test
    fun childOfJobRequestingTransitionDoesNotExemptParent() = real {
        IdentityBarrier.drainDeadlineMs = 2_000
        val signOutRequested = kotlinx.coroutines.CompletableDeferred<Unit>()
        val signOut = async {
            signOutRequested.await()
            IdentityBarrier.accountReset(TransitionKind.SignOut) { log.add("block"); Result.success(Unit) }
        }
        assertNotNull(IdentityWork.launch(IdentityGate.currentToken(), "parent", work) {
            launch { delay(300); log.add("push end") } // sibling still pushing
            launch {
                signOutRequested.complete(Unit)
                delay(50)
                assertEquals(TransitionResult.Requested, IdentityBarrier.selectProfile(2))
            }
        })
        assertTrue(signOut.await().isSuccess)
        assertEquals("push end", log.all().first())
        assertTrue(log.all().indexOf("push end") < log.all().indexOf("block"))
    }

    @Test
    fun accountResetFromJobIsNotAwaited() = real {
        val returned = kotlinx.coroutines.CompletableDeferred<Result<Unit>>()
        assertNotNull(IdentityWork.launch(IdentityGate.currentToken(), "caller", work) {
            returned.complete(IdentityBarrier.accountReset(TransitionKind.SignOut) { log.add("block"); Result.success(Unit) })
        })
        val result = returned.await()
        assertIs<TransitionNotAwaited>(result.exceptionOrNull())
        eventually { log.count("block") == 1 && !IdentityGate.state.value.transitioning }
        assertEquals(2L, epoch())
    }

    /** Rule B: a profile transition is refused at Begin in Recovery (B20); an account one clears it with a wipe. */
    @Test
    fun profileBeginRefusedInRecovery() = real {
        IdentityImmediate.onAccountPublished = { error("hook fails") }
        runCatching { IdentityImmediate.publishAuth(com.nuvio.app.core.auth.AuthState.Authenticated("user-b", null, isAnonymous = false)) { } }
        IdentityImmediate.chainEnded()
        assertIs<IdentityPhase.Recovery>(IdentityGate.state.value.phase)
        val failed = assertIs<TransitionResult.Failed>(IdentityBarrier.selectProfile(2))
        assertEquals("recovery required", failed.error)
        assertEquals(0, log.count("apply 2"))
    }

    @Test
    fun signOutFromRecoveryClears() = real {
        IdentityImmediate.onAccountPublished = { if (it == accountB) error("hook fails") else error("recovery fails") }
        runCatching { IdentityImmediate.publishAuth(com.nuvio.app.core.auth.AuthState.Authenticated("user-b", null, isAnonymous = false)) { } }
        IdentityImmediate.chainEnded()
        assertIs<IdentityPhase.Recovery>(IdentityGate.state.value.phase)
        IdentityImmediate.onAccountPublished = {}
        val result = IdentityBarrier.accountReset(TransitionKind.SignOut) {
            IdentityImmediate.accountWipe { log.add("wipe") }
            IdentityImmediate.publishAuth(com.nuvio.app.core.auth.AuthState.Unauthenticated) { log.add("write") }
            IdentityImmediate.chainEnded()
            Result.success(Unit)
        }
        assertTrue(result.isSuccess)
        assertEquals(IdentityPhase.Open, IdentityGate.state.value.phase)
        assertEquals(AccountKey.None, IdentityGate.state.value.scope.account)
        assertNotNull(IdentityGate.currentToken())
    }

    /**
     * Rule C (review r4-3): an account drain awaits teardown with no registered jobs; a window whose
     * revoker sleeps 500 ms pre-empts it; the ack and the deadline both arrive during that revoke;
     * the reset block starts only after the revoke returned.
     */
    @Test
    fun drainWaitsForWindowRevokeWithEmptySnapshot() = real {
        IdentityBarrier.drainDeadlineMs = 300
        IdentityRevocation.required = true
        val revoker = RecordingRevoker(log)
        revoker.onRevoke = { state ->
            if (state.phase is IdentityPhase.Closed) {
                val t = kotlin.time.TimeSource.Monotonic.markNow()
                while (t.elapsedNow().inWholeMilliseconds < 500) { /* slow main-thread revoke */ }
                log.add("window revoke end")
            } else {
                // The sign-out's own revoke: acknowledge teardown 100 ms later, during the window's revoke.
                work.launch { delay(100); IdentityBarrier.teardownDone(state.transitionId) }
            }
        }
        IdentityRevocation.revoker = revoker
        val signOut = async { IdentityBarrier.accountReset(TransitionKind.SignOut) { log.add("block"); Result.success(Unit) } }
        eventually { IdentityGate.state.value.kind == TransitionKind.SignOut }
        val auth = launch(Dispatchers.Default) {
            delay(30)
            IdentityImmediate.serialChanging() // B10: empty snapshot, slow revoke
            IdentityImmediate.chainEnded()
        }
        assertTrue(signOut.await().isSuccess)
        auth.join()
        val all = log.all()
        assertTrue(all.indexOf("window revoke end") in 0 until all.indexOf("block"), "$all")
    }

    /**
     * Rule A, source 2 (review r5-2): a server-switch block reuses an operation that calls
     * accountReset. It returns TransitionNotAwaited, the outer reset completes, the nested one runs
     * after it, and a later select is not stuck.
     */
    @Test
    fun nestedRequestFromLaneBodyIsNotAwaited() = real {
        kotlinx.coroutines.withTimeout(5_000) {
            val outer = IdentityBarrier.accountReset(TransitionKind.ServerSwitch) {
                val nested = IdentityBarrier.accountReset(TransitionKind.SignOut) { log.add("nested block"); Result.success(Unit) }
                log.add("nested returned ${nested.exceptionOrNull() is TransitionNotAwaited}")
                // A withContext inside the block (like the apply dispatcher) still carries the lane element.
                withContext(Dispatchers.Default) {
                    log.add("inner select ${IdentityBarrier.selectProfile(3) == TransitionResult.Requested}")
                }
                log.add("outer block")
                Result.success(Unit)
            }
            assertTrue(outer.isSuccess)
            eventually { log.count("nested block") == 1 && log.count("apply 3") == 1 }
            assertEquals(listOf("nested returned true", "inner select true", "outer block", "nested block", "apply 3"), log.all())
            assertIs<TransitionResult.Done>(IdentityBarrier.selectProfile(2))
        }
    }

    /** Rule A, source 3: a window body requests a select: Requested at once; it runs after the window closes. */
    @Test
    fun requestFromWindowBodyIsNotAwaited() = real {
        var returned: TransitionResult? = null
        IdentityImmediate.onAccountPublished = {
            // Unconfined runs the call inline on this (window-body) thread until it would suspend.
            CoroutineScope(Dispatchers.Unconfined).launch { returned = IdentityBarrier.selectProfile(2) }
            log.add("hook returned ${returned == TransitionResult.Requested}")
        }
        // Same account and serial, so the queued select still applies once the window closes.
        IdentityImmediate.serialChanging()
        IdentityImmediate.publishAuth(com.nuvio.app.core.auth.AuthState.Authenticated("user-a", null, isAnonymous = false)) { }
        assertEquals(0, log.count("apply 2")) // not before the window closes
        IdentityImmediate.chainEnded()
        eventually { log.count("apply 2") == 1 }
        assertEquals(listOf("hook returned true", "apply 2"), log.all())
    }

    /** Rule A: no false positive for an ordinary caller, even while ANOTHER thread is in a window body (per-thread depth). */
    @Test
    fun ordinaryCallerAwaitsWhileAnotherThreadIsInAWindowBody() = real {
        val inBody = kotlinx.coroutines.flow.MutableStateFlow(false)
        val release = kotlinx.coroutines.flow.MutableStateFlow(false)
        val auth = launch(Dispatchers.Default) {
            IdentityLocks.inWindowBody {
                assertEquals(IdentityBarrier.NotAwaitedSource.WindowBody, IdentityBarrier.mustNotAwait(kotlin.coroutines.EmptyCoroutineContext))
                inBody.value = true
                while (!release.value) { /* hold this thread inside the body */ }
            }
        }
        inBody.first { it }
        val elsewhere = withContext(Dispatchers.Default) { IdentityBarrier.mustNotAwait(currentCoroutineContext()) }
        release.value = true
        auth.join()
        assertNull(elsewhere)
        assertNull(IdentityBarrier.mustNotAwait(currentCoroutineContext()))
    }
}
