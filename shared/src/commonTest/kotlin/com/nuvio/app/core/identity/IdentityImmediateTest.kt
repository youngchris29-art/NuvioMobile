package com.nuvio.app.core.identity

import com.nuvio.app.core.auth.AuthState
import com.nuvio.app.core.profile.ActiveProfileProvider
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.async
import kotlinx.coroutines.cancel
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.isActive
import kotlinx.coroutines.test.runTest
import kotlinx.coroutines.withContext
import kotlin.test.AfterTest
import kotlin.test.BeforeTest
import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertIs
import kotlin.test.assertNotNull
import kotlin.test.assertNull
import kotlin.test.assertTrue

/**
 * Spec 4.5 (revision 7), driven directly: the auth-window semantics W2's AuthSessionDriver hooks
 * will call. The driver-level AuthWindowTest lands in W2.
 */
class IdentityImmediateTest {

    private val log = EventLog()
    private val scope = CoroutineScope(SupervisorJob() + Dispatchers.Default)

    @BeforeTest
    fun setUp() {
        installDriverFakes(log)
        IdentityImmediate.afterOpenScope = scope
    }

    @AfterTest
    fun tearDown() {
        scope.cancel()
        resetIdentityForTest()
    }

    @Test
    fun publishWithoutChangeOpensNoWindow() {
        val before = IdentityGate.state.value
        IdentityImmediate.publishAuth(AuthState.Authenticated("user-a", null, isAnonymous = false)) { log.add("write") }
        IdentityImmediate.chainEnded()
        assertEquals(listOf("write"), log.all())
        assertEquals(before, IdentityGate.state.value)
    }

    @Test
    fun wipeToPublishIsOneWindow() {
        val token = assertNotNull(IdentityGate.currentToken())
        val transitions = ActiveProfileProvider.transition.value.version
        IdentityImmediate.accountWipe { log.add("wipe") }
        assertNull(IdentityGate.currentToken())
        assertNull(IdentityGate.currentAccountToken())
        IdentityImmediate.publishAuth(AuthState.Unauthenticated) { log.add("write") }
        assertNull(IdentityGate.currentToken())
        IdentityImmediate.chainEnded()
        val after = IdentityGate.state.value
        assertEquals(IdentityState(IdentityScope(AccountKey.None, 1), IdentityEpoch(2), IdentityPhase.Open, null), after)
        assertEquals(Verdict.Reject(RejectReason.AccountChanged), IdentityGate.check(token, CommitKind.LocalWrite))
        // The wipe and the account hook each ran inside one profile transition (both ends bumped).
        assertEquals(transitions + 4, ActiveProfileProvider.transition.value.version)
    }

    @Test
    fun serialChangeClosesTheGateUntilTheChainEnds() {
        val token = assertNotNull(IdentityGate.currentToken())
        IdentityImmediate.serialChanging()
        IdentityRuntime.authSerial = { 2 }
        assertNull(IdentityGate.currentToken())
        assertEquals(Verdict.Reject(RejectReason.WritesClosed), IdentityGate.check(token, CommitKind.RemoteSend))
        IdentityImmediate.serialChanging() // a second change in the same chain opens nothing new
        IdentityImmediate.chainEnded()
        val fresh = assertNotNull(IdentityGate.currentToken())
        assertEquals(2, fresh.authSerial)
        assertEquals(IdentityEpoch(2), fresh.epoch)
    }

    /** Review r2-1: a throwing hook leaves the window on the account auth still shows. */
    @Test
    fun throwingHookRecordsNoAccount() {
        IdentityImmediate.onAccountPublished = { if (it == accountB) error("ensureLoaded failed") }
        var written = false
        kotlin.test.assertFailsWith<IllegalStateException> {
            IdentityImmediate.publishAuth(AuthState.Authenticated("user-b", null, isAnonymous = false)) { written = true }
        }
        assertTrue(!written)
        assertNull(IdentityGate.currentToken())
        assertEquals(accountA, IdentityRuntime.snapshot().latestAccount)
        IdentityImmediate.chainEnded()
        assertEquals(IdentityScope(accountA, 1), IdentityGate.state.value.scope)
        // W2 review r5 #1: the intended publish (B) did not happen, so recovery holds (no token for
        // A or B) until it is retried successfully or superseded.
        assertEquals(RecoveryReason.FailedPublish, IdentityGate.state.value.recovery)
        assertNull(IdentityGate.currentToken())
    }

    /** Review r3-3: the hook loads B's state, then throws; the gate reopens on A only after A was reloaded. */
    @Test
    fun hookThatMutatesThenThrowsIsRecoveredBeforeTheGateOpens() {
        var loaded: AccountKey = accountA
        IdentityImmediate.onAccountPublished = { a ->
            loaded = a
            if (a == accountB) error("fan-out failed after ensureLoaded(B)")
        }
        kotlin.test.assertFailsWith<IllegalStateException> {
            IdentityImmediate.publishAuth(AuthState.Authenticated("user-b", null, isAnonymous = false)) { }
        }
        assertEquals(accountB, loaded) // mutated before throwing
        assertNull(IdentityGate.currentToken()) // the window holds
        IdentityImmediate.chainEnded()
        assertEquals(accountA, loaded) // recovered under the same window
        assertEquals(IdentityScope(accountA, 1), IdentityGate.state.value.scope)
        // W2 review r5 #1: memory is A's again, but the gate stays closed until B's publish succeeds.
        assertEquals(RecoveryReason.FailedPublish, IdentityGate.state.value.recovery)
        assertNull(IdentityGate.currentToken())
        IdentityImmediate.onAccountPublished = { loaded = it }
        IdentityImmediate.publishAuth(AuthState.Authenticated("user-b", null, isAnonymous = false)) { }
        IdentityImmediate.chainEnded()
        assertEquals(accountB, assertNotNull(IdentityGate.currentToken()).scope.account)
    }

    /** Rule B (review r4-1): publish and recovery both fail: Recovery, no token, every commit and launch refused. */
    @Test
    fun doubleFailureMintsNoToken() = runTest {
        val tokenA = assertNotNull(IdentityGate.currentToken())
        IdentityImmediate.onAccountPublished = { error("everything fails") }
        kotlin.test.assertFailsWith<IllegalStateException> {
            IdentityImmediate.publishAuth(AuthState.Authenticated("user-b", null, isAnonymous = false)) { }
        }
        IdentityImmediate.chainEnded()
        assertEquals(IdentityPhase.Recovery(IdentityEpoch(1)), IdentityGate.state.value.phase) // P3: reached Recovery
        assertEquals(RecoveryReason.FailedPublish, IdentityGate.state.value.recovery)
        assertNull(IdentityGate.currentToken())
        assertNull(IdentityGate.currentAccountToken())
        assertEquals(CommitResult.Rejected(RejectReason.WritesClosed), IdentityGate.commit(tokenA, CommitKind.LocalWrite) { 1 })
        assertEquals(Verdict.Reject(RejectReason.WritesClosed), IdentityGate.checkAccount(AccountToken(accountA, 1)))
        assertNull(IdentityWork.launch(tokenA, "save", backgroundScope, CommitKind.RemoteSend) { })
        assertEquals(PersistedResult.Parked, IdentityGate.commitPersisted("account:user-a", 1) { it })
    }

    @Test
    fun recoveryClearsOnSuccessfulPublish() {
        IdentityImmediate.onAccountPublished = { error("everything fails") }
        runCatching { IdentityImmediate.publishAuth(AuthState.Authenticated("user-b", null, isAnonymous = false)) { } }
        IdentityImmediate.chainEnded()
        assertIs<IdentityPhase.Recovery>(IdentityGate.state.value.phase)
        // The retry (W2: retryIdentityRecovery) re-publishes the shown state A: a window, the hook, the write.
        var ranFor: AccountKey? = null
        IdentityImmediate.onAccountPublished = { ranFor = it }
        IdentityImmediate.publishAuth(AuthState.Authenticated("user-a", null, isAnonymous = false)) { }
        IdentityImmediate.chainEnded()
        assertEquals(accountA, ranFor)
        assertEquals(IdentityPhase.Open, IdentityGate.state.value.phase)
        assertEquals(accountA, assertNotNull(IdentityGate.currentToken()).scope.account)
        assertEquals(IdentityEpoch(2), IdentityGate.state.value.epoch)
    }

    @Test
    fun throwingWipeEntersRecovery() {
        kotlin.test.assertFailsWith<IllegalStateException> { IdentityImmediate.accountWipe { error("disk full") } }
        IdentityImmediate.chainEnded()
        assertEquals(RecoveryReason.FailedWipe, IdentityGate.state.value.recovery)
        assertIs<IdentityPhase.Recovery>(IdentityGate.state.value.phase)
        assertNull(IdentityGate.currentToken())
        // A completed wipe clears it.
        IdentityImmediate.accountWipe { }
        IdentityImmediate.chainEnded()
        assertEquals(IdentityPhase.Open, IdentityGate.state.value.phase)
    }

    @Test
    fun failedWipeNotClearedByPublish() {
        runCatching { IdentityImmediate.accountWipe { error("disk full") } }
        IdentityImmediate.chainEnded()
        IdentityImmediate.publishAuth(AuthState.Authenticated("user-a", null, isAnonymous = false)) { }
        IdentityImmediate.chainEnded()
        assertEquals(RecoveryReason.FailedWipe, IdentityGate.state.value.recovery)
        assertNull(IdentityGate.currentToken())
    }

    @Test
    fun throwingWriteRecordsNoAccount() {
        kotlin.test.assertFailsWith<IllegalStateException> {
            IdentityImmediate.publishAuth(AuthState.Authenticated("user-b", null, isAnonymous = false)) { error("write failed") }
        }
        IdentityImmediate.chainEnded()
        assertEquals(accountA, IdentityGate.state.value.scope.account)
    }

    @Test
    fun chainEndedWithoutAWindowDoesNothing() {
        val before = IdentityGate.state.value
        IdentityImmediate.chainEnded()
        assertEquals(before, IdentityGate.state.value)
    }

    @Test
    fun afterAccountOpenRunsOnlyWhenTheAccountChanged() = runTest {
        withContext(Dispatchers.Default) {
            val ran = MutableStateFlow(0)
            IdentityImmediate.afterAccountOpen = {
                // Outside every lock, after Open.
                assertEquals(0, IdentityLocks.commitDepth)
                assertIs<IdentityPhase.Open>(IdentityGate.state.value.phase)
                ran.value += 1
            }
            IdentityImmediate.serialChanging()
            IdentityImmediate.chainEnded() // same account: no hook
            IdentityImmediate.publishAuth(AuthState.Authenticated("user-b", null, isAnonymous = false)) { }
            IdentityImmediate.chainEnded()
            eventually { ran.value == 1 }
            kotlinx.coroutines.delay(100)
            assertEquals(1, ran.value)
        }
    }

    /** Revision 8 (W1 review #4): the hook waits for the drained hold, then fires exactly once at B7. */
    @Test
    fun windowOpenedDuringASignOutRunsTheHookWhenTheDrainedHoldEnds() = runTest {
        withContext(Dispatchers.Default) {
            val ran = MutableStateFlow(0)
            IdentityImmediate.afterAccountOpen = { ran.value += 1 }
            IdentityRuntime.reduce(BarrierEvent.Begin(TransitionKind.SignOut))
            IdentityRuntime.reduce(BarrierEvent.DrainEnded(DrainEnd.Settled))
            IdentityImmediate.publishAuth(AuthState.Unauthenticated) { }
            IdentityImmediate.chainEnded()
            assertIs<IdentityPhase.Applying>(IdentityGate.state.value.phase)
            kotlinx.coroutines.delay(100)
            assertEquals(0, ran.value)
            IdentityRuntime.reduce(BarrierEvent.ApplyFinished(1)) // B7: the final Open
            assertIs<IdentityPhase.Open>(IdentityGate.state.value.phase)
            assertEquals(AccountKey.None, IdentityGate.state.value.scope.account)
            eventually { ran.value == 1 }
            kotlinx.coroutines.delay(100)
            assertEquals(1, ran.value)
        }
    }

    /** No token for account B exists before the auth state shows B, and none for A after it stopped being A. */
    @Test
    fun tokenNeverPrecedesAuthState() = runTest {
        withContext(Dispatchers.Default) {
            val auth = MutableStateFlow<AccountKey>(accountA)
            val probe = async(Dispatchers.Default) {
                var checks = 0
                while (isActive && checks < 200_000) {
                    val before = auth.value
                    val token = IdentityGate.currentToken()
                    val after = auth.value
                    if (token != null && before == after) {
                        assertEquals(before, token.scope.account, "token for ${token.scope.account} while auth shows $before")
                    }
                    checks++
                }
                checks
            }
            repeat(200) { i ->
                val next = if (i % 2 == 0) accountB else accountA
                val id = (next as AccountKey.Account).userId
                IdentityImmediate.publishAuth(AuthState.Authenticated(id, null, isAnonymous = false)) { auth.value = next }
                IdentityImmediate.chainEnded()
            }
            assertTrue(probe.await() > 0)
            assertEquals(accountA, IdentityGate.state.value.scope.account)
        }
    }
}
