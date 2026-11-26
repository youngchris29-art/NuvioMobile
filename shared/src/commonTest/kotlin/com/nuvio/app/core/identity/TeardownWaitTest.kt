package com.nuvio.app.core.identity

import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.SupervisorJob
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
import kotlin.test.assertTrue

/** Spec 4.6 (revision 7): a profile apply waits for confirmed teardown; an account kind does not. */
class TeardownWaitTest {

    private val log = EventLog()
    private lateinit var revoker: RecordingRevoker
    private val swift = CoroutineScope(SupervisorJob() + Dispatchers.Default)

    @BeforeTest
    fun setUp() {
        installDriverFakes(log, deadlineMs = 600)
        revoker = RecordingRevoker(log)
        IdentityRevocation.revoker = revoker
        IdentityRevocation.required = true
    }

    @AfterTest
    fun tearDown() {
        swift.cancel()
        resetIdentityForTest()
    }

    private fun real(block: suspend CoroutineScope.() -> Unit) = runTest { withContext(Dispatchers.Default) { block() } }

    @Test
    fun drainSettlesOnlyAfterTeardownDone() = real {
        revoker.onRevoke = { state ->
            swift.launch {
                delay(200)
                log.add("teardown done")
                IdentityBarrier.teardownDone(state.transitionId)
            }
        }
        assertIs<TransitionResult.Done>(IdentityBarrier.selectProfile(2))
        assertEquals(listOf("revoke ProfileSelect", "teardown done", "apply 2"), log.all())
    }

    @Test
    fun deadlineFailsASelectClosed() = real {
        val failed = assertIs<TransitionResult.Failed>(IdentityBarrier.selectProfile(2))
        assertEquals("teardown unconfirmed", failed.error)
        assertEquals(IdentityEpoch(1), failed.final.epoch)
        assertEquals(IdentityPhase.Open, failed.final.phase)
        assertEquals(listOf("revoke ProfileSelect"), log.all())
    }

    @Test
    fun deadlineLetsASignOutProceed() = real {
        val result = IdentityBarrier.accountReset(TransitionKind.SignOut) { log.add("block"); Result.success(Unit) }
        assertTrue(result.isSuccess)
        assertEquals(listOf("revoke SignOut", "block"), log.all())
        assertEquals(2L, IdentityGate.state.value.epoch.value)
    }

    @Test
    fun aMissingRevokerFailsASelectAndLetsASignOutProceed() = real {
        IdentityRevocation.revoker = null
        assertIs<TransitionResult.Failed>(IdentityBarrier.selectProfile(2))
        assertEquals(IdentityEpoch(1), IdentityGate.state.value.epoch)
        assertTrue(IdentityBarrier.accountReset(TransitionKind.ServerSwitch) { log.add("block"); Result.success(Unit) }.isSuccess)
        assertEquals(listOf("block"), log.all())
        assertEquals(2L, IdentityGate.state.value.epoch.value)
    }

    @Test
    fun lateAckOfAFailedAttemptDoesNotSatisfyTheRetry() = real {
        // A presented player that never disappears: the select fails closed at the same epoch.
        assertIs<TransitionResult.Failed>(IdentityBarrier.selectProfile(2))
        IdentityBarrier.teardownDone(1) // late, for the failed attempt (transition 1): ignored
        // The retry runs at the same epoch; without its own acknowledgement it fails too.
        assertIs<TransitionResult.Failed>(IdentityBarrier.selectProfile(2))
        assertEquals(0, log.count("apply 2"))
        revoker.onRevoke = { state -> swift.launch { delay(100); IdentityBarrier.teardownDone(state.transitionId) } }
        assertIs<TransitionResult.Done>(IdentityBarrier.selectProfile(2))
        assertEquals(2L, IdentityGate.state.value.epoch.value)
    }
}
