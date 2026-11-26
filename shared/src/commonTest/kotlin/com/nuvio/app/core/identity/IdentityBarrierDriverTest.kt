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

    @Test
    fun applyThrowsStillOpensAndBumps() = real {
        ops.onApply = { error("apply failed") }
        val result = assertIs<TransitionResult.Failed>(IdentityBarrier.selectProfile(2))
        assertTrue("apply failed" in result.error)
        assertEquals(IdentityPhase.Open, result.final.phase)
        assertEquals(2L, result.final.epoch.value)
        assertEquals(1, result.final.scope.slot)
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
    fun jobAwaitingBarrierIsNotWaitedFor() = real {
        val token = IdentityGate.currentToken()
        val job = assertNotNull(IdentityWork.launch(token, "caller", work) { IdentityBarrier.selectProfile(2) })
        val start = TimeSource.Monotonic.markNow()
        eventually { log.count("apply 2") == 1 && !IdentityGate.state.value.transitioning }
        assertTrue(start.elapsedNow().inWholeMilliseconds < 400, "the drain waited for its caller")
        eventually { job.isCancelled || job.isCompleted }
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
        assertIs<TransitionResult.Done>(select.await())
        assertEquals(emptyList(), log.all())
        assertEquals(IdentityScope(accountB, 1), IdentityGate.state.value.scope)
    }
}
