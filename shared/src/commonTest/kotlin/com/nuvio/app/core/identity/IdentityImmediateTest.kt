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

    @Test
    fun windowOpenedDuringASignOutDoesNotRunTheHookUntilTheDrainedHoldEnds() {
        var ran = 0
        IdentityImmediate.afterAccountOpen = { ran++ }
        IdentityRuntime.reduce(BarrierEvent.Begin(TransitionKind.SignOut))
        IdentityRuntime.reduce(BarrierEvent.DrainEnded(DrainEnd.Settled))
        IdentityImmediate.publishAuth(AuthState.Unauthenticated) { }
        IdentityImmediate.chainEnded()
        assertIs<IdentityPhase.Applying>(IdentityGate.state.value.phase)
        assertEquals(0, ran)
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
