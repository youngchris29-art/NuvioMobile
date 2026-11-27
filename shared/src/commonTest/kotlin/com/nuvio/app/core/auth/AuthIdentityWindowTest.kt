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
import kotlinx.coroutines.test.advanceTimeBy
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
import kotlin.time.Duration.Companion.seconds

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
    /** Audit #5: fail only the publishes this picks. */
    var failPublish: (AuthState) -> Boolean = { false }
    val traces = mutableListOf<String>()
    var serialChanges = 0
    var chainEnds = 0

    private fun gate(): String = if (IdentityGate.currentToken() == null) "closed" else "open"

    override fun publish(state: AuthState) {
        IdentityImmediate.publishAuth(state) {
            if (publishFails || failPublish(state)) error("publish write failed")
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
    override fun trace(line: String) { traces += line }
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
                // With the shown account unchanged across the token read, a token can only name
                // that account (or None): never one not yet shown, never one no longer shown.
                // (A change between the reads is a legitimate later chain, not a violation.)
                val shownBefore = AccountKey.of(rig.effects.shown)
                val token = IdentityGate.currentToken()
                val shownAfter = AccountKey.of(rig.effects.shown)
                if (token != null && shownBefore == shownAfter && token.scope.account != AccountKey.None && token.scope.account != shownAfter) {
                    violations += "token ${token.scope.account} while shown $shownAfter"
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

/** W2 review r5 #1: a failed account publish is retried as its TARGET until it completes. */
@OptIn(ExperimentalCoroutinesApi::class)
class FailedPublishRetryTest {
    private val log = EventLog()

    @BeforeTest fun setUp() {
        resetIdentityForTest()
        IdentityRevocation.revoker = RecordingRevoker(log)
    }

    @AfterTest fun tearDown() = resetIdentityForTest()

    private class Rig(scope: TestScope, log: EventLog, timeout: kotlin.time.Duration = 1.hours) {
        val flow = MutableStateFlow<SessionStatus>(SessionStatus.Initializing)
        val effects = IdentityWiredEffects(flow, log)
        val driver = AuthSessionDriver(effects, scope.backgroundScope, restoreTimeout = timeout)

        init {
            effects.ticket = { driver.currentTicket().serial }
            IdentityRuntime.authSerial = { driver.currentTicket().serial }
            driver.start(AuthEvent.Boot(guestId = null, owner = null, notice = false, wipePending = false), { flow })
            scope.runCurrent()
        }
    }

    /**
     * r6 #3: the real 10 s restore watchdog fires while the retries (every 5 s, up to 6) still run;
     * it must not supersede the owed publish. The fourth retry (t = 20 s) succeeds.
     */
    @Test
    fun watchdogDoesNotSupersedeTheOwedPublish() = runTest {
        var failures = 4
        failingHook { failures-- > 0 }
        val rig = Rig(this, log, timeout = 10.seconds)
        rig.flow.value = authenticated("A", "A-1")
        runCurrent() // the restore publish fails (failure 1)
        for (retryAt in 1..3) {
            advanceTimeBy(5_000); runCurrent()
            assertTrue(rig.driver.retryPendingPublish().isSuccess)
            assertEquals(RecoveryReason.FailedPublish, IdentityGate.state.value.recovery, "retry $retryAt at ${retryAt * 5} s")
            assertTrue(rig.effects.shown != AuthState.Unauthenticated, "the watchdog did not publish Welcome over the owed publish")
        }
        assertTrue(rig.driver.modelStateForTest.watchdogFired, "the 10 s watchdog has fired by now")
        advanceTimeBy(5_000); runCurrent()
        assertTrue(rig.driver.retryPendingPublish().isSuccess) // t = 20 s: succeeds
        assertEquals(AccountKey.Account("A"), AccountKey.of(rig.effects.shown))
        assertEquals(null, IdentityGate.state.value.recovery)
    }

    /** A required fan-out step throws for account A (the hook); recovery restores None without throwing. */
    private fun failingHook(failures: () -> Boolean) {
        IdentityImmediate.onAccountPublished = { account -> if (account is AccountKey.Account && failures()) error("fan-out step failed") }
    }

    @Test
    fun restoreOfAThatFailsIsRetriedAsA() = runTest {
        var failing = true
        failingHook { failing }
        val rig = Rig(this, log)
        rig.flow.value = authenticated("A", "A-1")
        runCurrent()
        // Recovery holds; A is not shown and the reducer does not claim it was.
        assertEquals(RecoveryReason.FailedPublish, IdentityGate.state.value.recovery)
        assertTrue(AccountKey.of(rig.effects.shown) != AccountKey.Account("A"))
        assertEquals(rig.effects.shown, rig.driver.modelStateForTest.published, "published = what a completed publish showed")
        assertEquals(AuthState.Authenticated("A", "A@example.test", false), rig.driver.modelStateForTest.pendingPublish)

        failing = false
        assertTrue(rig.driver.retryPendingPublish().isSuccess)
        assertEquals(AccountKey.Account("A"), AccountKey.of(rig.effects.shown))
        assertEquals(IdentityPhase.Open, IdentityGate.state.value.phase)
        assertEquals(AccountKey.Account("A"), IdentityGate.state.value.scope.account)
        assertEquals(null, rig.driver.modelStateForTest.pendingPublish)
    }

    @Test
    fun givingUpAfterSixLeavesTheReducerConsistentForAManualSignIn() = runTest {
        var failing = true
        failingHook { failing }
        val rig = Rig(this, log)
        rig.flow.value = authenticated("A", "A-1")
        runCurrent()
        repeat(6) { assertTrue(rig.driver.retryPendingPublish().isSuccess) } // each publish fails again
        assertEquals(RecoveryReason.FailedPublish, IdentityGate.state.value.recovery)
        // What the reducer believes is shown is what is shown (Welcome follows on the Swift side).
        assertEquals(rig.effects.shown, rig.driver.modelStateForTest.published)

        // A later manual sign-in (a new session for A) is published normally.
        failing = false
        rig.flow.value = authenticated("A", "A-2")
        runCurrent()
        assertEquals(AccountKey.Account("A"), AccountKey.of(rig.effects.shown))
        assertEquals(IdentityPhase.Open, IdentityGate.state.value.phase)
        assertEquals(null, IdentityGate.state.value.recovery)
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

/**
 * Audit #5: a step's failed publish is fed to the reducer before the step's follow-up, so a later
 * successful publish of the follow-up supersedes it (no stale owed publish, no stale Recovery).
 */
class PublishFailedOrderTest {
    @BeforeTest fun setUp() { resetIdentityForTest(); IdentityRevocation.revoker = RecordingRevoker(EventLog()) }
    @AfterTest fun tearDown() = resetIdentityForTest()

    @Test
    fun aLaterSuccessfulPublishSupersedesTheFailedOne() = runTest {
        for (owner in listOf(null, "A")) {
            resetIdentityForTest(); IdentityRevocation.revoker = RecordingRevoker(EventLog())
            val flow = MutableStateFlow<SessionStatus>(SessionStatus.Initializing)
            val effects = IdentityWiredEffects(flow, EventLog())
            val driver = AuthSessionDriver(effects, backgroundScope, restoreTimeout = 1.hours)
            effects.ticket = { driver.currentTicket().serial }
            IdentityRuntime.authSerial = { driver.currentTicket().serial }
            driver.start(AuthEvent.Boot(guestId = null, owner = owner, notice = false, wipePending = false), { flow })
            runCurrent()
            flow.value = authenticated("A", "A-1")
            runCurrent()
            assertEquals(AccountKey.Account("A"), AccountKey.of(effects.shown), "owner=$owner")
            // A session claiming A whose server user is B: the validation step publishes Welcome
            // (fails here), then accepts B; its gates' follow-ups publish B in the same chain.
            effects.failPublish = { it == AuthState.Unauthenticated }
            flow.value = authenticated("A", "B-2")
            runCurrent()
            effects.failPublish = { false }
            val model = driver.modelStateForTest
            assertEquals(AccountKey.Account("B"), AccountKey.of(effects.shown), "owner=$owner: B shown")
            assertEquals(null, model.pendingPublish, "owner=$owner: nothing owed after B's publish (${effects.traces.takeLast(12)})")
            assertEquals(AccountKey.Account("B"), AccountKey.of(model.published), "owner=$owner")
            assertEquals(null, IdentityGate.state.value.recovery, "owner=$owner")
        }
    }
}
