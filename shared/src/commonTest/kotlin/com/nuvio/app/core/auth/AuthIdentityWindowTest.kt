package com.nuvio.app.core.auth

import com.nuvio.app.core.identity.AccountKey
import com.nuvio.app.core.identity.EventLog
import com.nuvio.app.core.identity.IdentityBarrier
import com.nuvio.app.core.identity.IdentityGate
import com.nuvio.app.core.identity.IdentityImmediate
import com.nuvio.app.core.identity.IdentityPhase
import com.nuvio.app.core.identity.IdentityRevocation
import com.nuvio.app.core.identity.IdentityRuntime
import com.nuvio.app.core.identity.RecordingRevoker
import com.nuvio.app.core.identity.RecoveryReason
import com.nuvio.app.core.identity.TransitionKind
import com.nuvio.app.core.identity.eventually
import com.nuvio.app.core.identity.resetIdentityForTest
import io.github.jan.supabase.auth.providers.builtin.Email
import io.github.jan.supabase.auth.status.SessionSource
import io.github.jan.supabase.auth.status.SessionStatus
import io.github.jan.supabase.auth.user.UserInfo
import io.github.jan.supabase.auth.user.UserSession
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.ExperimentalCoroutinesApi
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.cancel
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.isActive
import kotlinx.coroutines.launch
import kotlinx.coroutines.test.TestScope
import kotlinx.coroutines.test.runCurrent
import kotlinx.coroutines.test.runTest
import kotlinx.coroutines.withContext
import kotlin.concurrent.Volatile
import kotlin.test.AfterTest
import kotlin.test.BeforeTest
import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertFalse
import kotlin.test.assertNotNull
import kotlin.test.assertNull
import kotlin.test.assertTrue
import kotlin.time.Duration.Companion.hours

/*
 * W2 (spec 4.5, 5.5-5.7): the real auth driver with effects wired to the identity core the way
 * AuthRepository.RealAuthEffects is (publish and wipe as windows, the serial and chain hooks).
 */

private fun session(user: String, rt: String) = UserSession(
    accessToken = "at-$rt",
    refreshToken = rt,
    expiresIn = 3600,
    tokenType = "bearer",
    user = UserInfo(aud = "authenticated", id = user, email = "$user@example.test", isAnonymous = false),
)

private fun authenticated(user: String, rt: String) = SessionStatus.Authenticated(session(user, rt), SessionSource.SignIn(Email))

/** AuthEffects wired to IdentityImmediate like RealAuthEffects; records what the gate allowed at each step. */
private class IdentityWiredEffects(val flow: MutableStateFlow<SessionStatus>, val log: EventLog) : AuthEffects {
    @Volatile var shown: AuthState = AuthState.Loading
    var ticket: () -> Long = { 0 }
    var publishFails = false
    var serialChanges = 0
    var chainEnds = 0

    private fun gate(): String = if (IdentityGate.currentToken() == null) "closed" else "open"

    override fun publish(state: AuthState) {
        IdentityImmediate.publishAuth(state) {
            if (publishFails) error("publish write failed")
            shown = state
        }
        log.add("publish ${AccountKey.of(state)} gate=${gate()}")
    }

    override fun serialChanging() {
        val before = ticket()
        IdentityImmediate.serialChanging()
        serialChanges++
        log.add("serial changing ticket=$before gate=${gate()} account=${if (IdentityGate.currentAccountToken() == null) "closed" else "open"}")
    }

    override fun chainEnded() {
        IdentityImmediate.chainEnded()
        chainEnds++
    }

    override fun wipeAccountData() {
        IdentityImmediate.accountWipe { log.add("wipe gate=${gate()}") }
    }

    override fun persistOwner(userId: String?) {}
    override fun persistNotice(pending: Boolean) {}
    override fun persistWipePending(pending: Boolean) {}
    override fun showNotice() {}
    override fun hideNotice() {}
    override fun saveGuestId(guestId: String) {}
    override fun clearGuestId() {}
    override suspend fun clearSupabaseSession() { flow.value = SessionStatus.NotAuthenticated(true) }
    override suspend fun kickSessionRefresh() {}
    override suspend fun checkUser(accessToken: String): String? = accessToken.removePrefix("at-").substringBefore('-')
    override fun log(message: String) {}
    override fun trace(line: String) {}
    override suspend fun signInWithEmail(email: String, password: String) {}
    override suspend fun signUpWithEmail(email: String, password: String) {}
    override suspend fun signOutRemote() {
        log.add("signOutRemote gate=${gate()}")
        flow.value = SessionStatus.NotAuthenticated(true)
    }
    override suspend fun deleteAccountRemote() {}
    override suspend fun importTvLoginTokens(accessToken: String, refreshToken: String) {}
    override suspend fun ensureTvLoginScaffold() {}
}

@OptIn(ExperimentalCoroutinesApi::class)
class AuthWindowTest {
    private val log = EventLog()
    private val revoker = RecordingRevoker(log)

    @BeforeTest fun setUp() {
        resetIdentityForTest()
        IdentityRevocation.revoker = revoker
    }

    @AfterTest fun tearDown() = resetIdentityForTest()

    private class Rig(scope: TestScope, log: EventLog) {
        val flow = MutableStateFlow<SessionStatus>(SessionStatus.Initializing)
        val effects = IdentityWiredEffects(flow, log)
        val driver = AuthSessionDriver(effects, scope.backgroundScope, restoreTimeout = 1.hours)
        val test = scope

        init {
            effects.ticket = { driver.currentTicket().serial }
            IdentityRuntime.authSerial = { driver.currentTicket().serial }
            driver.start(AuthEvent.Boot(guestId = null, owner = null, notice = false, wipePending = false), { flow })
            scope.runCurrent()
        }

        fun signedIn(user: String, rt: String) {
            flow.value = authenticated(user, rt)
            test.runCurrent()
        }
    }

    @Test
    fun serialChangeClosesGateBeforeTicket() = runTest {
        val rig = Rig(this, log)
        rig.signedIn("A", "A-1")
        val changes = log.all().filter { it.startsWith("serial changing") }
        assertTrue(changes.isNotEmpty(), "${log.all()}")
        // At the moment of every serial change the ticket still held the old serial and no token could be minted.
        assertTrue(changes.all { it.endsWith("gate=closed account=closed") }, "$changes")
        assertEquals(AccountKey.Account("A"), IdentityGate.state.value.scope.account)
        assertNotNull(IdentityGate.currentToken())
    }

    @Test
    fun lostSessionWipeToPublishIsOneWindow() = runTest {
        val rig = Rig(this, log)
        rig.signedIn("A", "A-1")
        val epochBefore = IdentityGate.state.value.epoch
        val revokesBefore = revoker.states.size
        assertTrue(rig.driver.reportSessionError(rig.driver.currentTicket(), SessionErrorKind.DeletedAccount))
        runCurrent()
        val tail = log.all().dropWhile { !it.startsWith("wipe") }
        assertTrue(tail.first().endsWith("gate=closed"), "$tail")
        assertTrue(tail.any { it == "publish None gate=closed" }, "$tail")
        // One window from the wipe to the publish (revoked at its open and, if it opened as a
        // publish window on the serial change, once more when the wipe retargeted it).
        val kinds = revoker.states.drop(revokesBefore).map { it.kind }
        assertTrue(kinds.size in 1..2 && kinds.last() == TransitionKind.AccountWipe, "$kinds")
        assertEquals(epochBefore.next(), IdentityGate.state.value.epoch, "one bump")
        assertEquals(IdentityPhase.Open, IdentityGate.state.value.phase)
        assertEquals(AuthState.Unauthenticated, rig.effects.shown)
    }

    @Test
    fun tokenNeverPrecedesAuthState() = runTest {
        val rig = Rig(this, log)
        val violations = mutableListOf<String>()
        val probeScope = CoroutineScope(SupervisorJob() + Dispatchers.Default)
        probeScope.launch {
            while (isActive) {
                // A token naming X is minted only after the auth state shows X…
                val token = IdentityGate.currentToken()
                val shownAfter = AccountKey.of(rig.effects.shown)
                if (token != null && token.scope.account != AccountKey.None && token.scope.account != shownAfter) {
                    violations += "token ${token.scope.account} while shown $shownAfter"
                }
                // …and never after it stopped showing it.
                val shownBefore = AccountKey.of(rig.effects.shown)
                val later = IdentityGate.currentToken()
                if (later != null && later.scope.account != shownBefore && AccountKey.of(rig.effects.shown) == shownBefore) {
                    violations += "token ${later.scope.account} after shown $shownBefore"
                }
            }
        }
        repeat(20) { round ->
            val user = if (round % 2 == 0) "A" else "B"
            rig.signedIn(user, "$user-$round")
            rig.flow.value = SessionStatus.NotAuthenticated(true)
            runCurrent()
        }
        probeScope.cancel()
        assertEquals(emptyList(), violations)
    }

    /** W2 fix round: a sign-in from Welcome never reports the wipe kind (no "Signing out…"). */
    @Test
    fun signInNeverReportsTheWipeKind() = runTest {
        val rig = Rig(this, log)
        rig.signedIn("A", "A-1")
        assertTrue(revoker.states.isNotEmpty())
        assertTrue(revoker.states.none { it.kind == TransitionKind.AccountWipe }, "${revoker.states.map { it.kind }}")
    }

    /** …and a lost session shows the wipe kind before its wipe body runs. */
    @Test
    fun lostSessionReportsTheWipeKindBeforeTheWipe() = runTest {
        val rig = Rig(this, log)
        rig.signedIn("A", "A-1")
        val before = revoker.states.size
        assertTrue(rig.driver.reportSessionError(rig.driver.currentTicket(), SessionErrorKind.DeletedAccount))
        runCurrent()
        val kinds = revoker.states.drop(before).map { it.kind }
        assertEquals(TransitionKind.AccountWipe, kinds.last(), "$kinds")
        val all = log.all()
        assertTrue(all.indexOf("revoke AccountWipe") in 0 until all.indexOfFirst { it.startsWith("wipe gate=") }, "$all")
    }

    @Test
    fun throwingChainClosesWindow() = runTest {
        val rig = Rig(this, log)
        rig.effects.publishFails = true
        rig.signedIn("A", "A-1")
        val state = IdentityGate.state.value
        assertTrue(state.phase is IdentityPhase.Open || state.phase is IdentityPhase.Recovery, "${state.phase}")
        assertNull(IdentityRuntime.snapshot().window)
    }

    @Test
    fun publishWithoutChangeOpensNoWindow() = runTest {
        val rig = Rig(this, log)
        rig.signedIn("A", "A-1")
        val revokes = revoker.states.size
        val epoch = IdentityGate.state.value.epoch
        rig.effects.publish(AuthState.Authenticated("A", "A@example.test", isAnonymous = false))
        assertEquals(revokes, revoker.states.size)
        assertEquals(epoch, IdentityGate.state.value.epoch)
    }
}

/** W2 (5.5): a deliberate sign-out through the real driver and the real barrier. */
class AuthBarrierOrderTest {
    private val log = EventLog()
    private val revoker = RecordingRevoker(log)
    private val scope = CoroutineScope(SupervisorJob() + Dispatchers.Default)

    @BeforeTest fun setUp() {
        resetIdentityForTest()
        IdentityRevocation.revoker = revoker
    }

    @AfterTest fun tearDown() {
        scope.cancel()
        resetIdentityForTest()
    }

    @Test
    fun signOutBeginsDrainsThenResetsWipesAndPublishes() = runTest {
        withContext(Dispatchers.Default) {
            val flow = MutableStateFlow<SessionStatus>(SessionStatus.Initializing)
            val effects = IdentityWiredEffects(flow, log)
            val driver = AuthSessionDriver(effects, scope, restoreTimeout = 1.hours)
            effects.ticket = { driver.currentTicket().serial }
            IdentityRuntime.authSerial = { driver.currentTicket().serial }
            driver.start(AuthEvent.Boot(guestId = null, owner = null, notice = false, wipePending = false), { flow })
            flow.value = authenticated("A", "A-1")
            eventually { AccountKey.of(effects.shown) == AccountKey.Account("A") && IdentityGate.state.value.phase == IdentityPhase.Open }
            val epoch = IdentityGate.state.value.epoch
            val start = log.all().size

            val result = IdentityBarrier.accountReset(TransitionKind.SignOut) { driver.signOut() }
            assertTrue(result.isSuccess, "$result")
            eventually { IdentityGate.state.value.phase == IdentityPhase.Open }

            val order = log.all().drop(start)
            val begin = order.indexOf("revoke SignOut")
            val remote = order.indexOfFirst { it.startsWith("signOutRemote") }
            val wipe = order.indexOfFirst { it.startsWith("wipe") }
            val publish = order.indexOf("publish None gate=closed")
            assertTrue(begin in 0 until remote && remote < wipe && wipe < publish, "$order")
            assertEquals("signOutRemote gate=closed", order[remote], "the gate is closed from Begin on")
            assertEquals(epoch.next(), IdentityGate.state.value.epoch, "one bump for the whole sign-out")
            assertEquals(AccountKey.None, IdentityGate.state.value.scope.account)
            assertEquals(AuthState.Unauthenticated, effects.shown)
        }
    }

    /** Rule B (W2): the retry re-publishes inside the lane as one chain and clears FailedPublish. */
    @Test
    fun retryIdentityRecoveryRunsInLane() = runTest {
        withContext(Dispatchers.Default) {
            val flow = MutableStateFlow<SessionStatus>(SessionStatus.Initializing)
            val effects = IdentityWiredEffects(flow, log)
            val driver = AuthSessionDriver(effects, scope, restoreTimeout = 1.hours)
            effects.ticket = { driver.currentTicket().serial }
            IdentityRuntime.authSerial = { driver.currentTicket().serial }
            var hookFails = true
            IdentityImmediate.onAccountPublished = { if (hookFails) error("fan-out failed") }
            driver.start(AuthEvent.Boot(guestId = null, owner = null, notice = false, wipePending = false), { flow })
            flow.value = authenticated("A", "A-1")
            eventually { IdentityGate.state.value.recovery == RecoveryReason.FailedPublish }
            assertNull(IdentityGate.currentToken())

            hookFails = false
            val chainsBefore = effects.chainEnds
            val shown = AuthState.Authenticated("A", "A@example.test", isAnonymous = false)
            assertTrue(driver.inChain { effects.publish(shown) }.isSuccess)
            assertTrue(effects.chainEnds > chainsBefore, "the retry's chain was ended by the driver")
            assertNull(IdentityGate.state.value.recovery)
            assertEquals(IdentityPhase.Open, IdentityGate.state.value.phase)
            assertEquals(AccountKey.Account("A"), IdentityGate.state.value.scope.account)
            assertNotNull(IdentityGate.currentToken())
            assertFalse(effects.publishFails)
        }
    }
}
