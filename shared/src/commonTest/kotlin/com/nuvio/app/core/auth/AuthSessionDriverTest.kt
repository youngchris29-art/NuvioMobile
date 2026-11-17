package com.nuvio.app.core.auth

import io.github.jan.supabase.auth.providers.builtin.Email
import io.github.jan.supabase.auth.status.RefreshFailureCause
import io.github.jan.supabase.auth.status.SessionSource
import io.github.jan.supabase.auth.status.SessionStatus
import io.github.jan.supabase.auth.user.UserInfo
import io.github.jan.supabase.auth.user.UserSession
import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertFailsWith
import kotlin.test.assertFalse
import kotlin.test.assertIs
import kotlin.test.assertNull
import kotlin.test.assertTrue
import kotlin.time.Duration.Companion.hours
import kotlin.time.Duration.Companion.milliseconds
import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.CompletableDeferred
import kotlinx.coroutines.ExperimentalCoroutinesApi
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.launch
import kotlinx.coroutines.test.TestScope
import kotlinx.coroutines.test.advanceTimeBy
import kotlinx.coroutines.test.runCurrent
import kotlinx.coroutines.test.runTest
import kotlinx.coroutines.currentCoroutineContext
import kotlinx.coroutines.ensureActive
import kotlinx.coroutines.yield

/**
 * The real driver against a fake status flow built from supabase-kt's own types and a recording
 * fake of [AuthEffects] (spec 5c, "driver tests"). This is the wiring the first attempt never drove.
 */
@OptIn(ExperimentalCoroutinesApi::class)
class AuthSessionDriverTest {

    private class FakeEffects(val flow: MutableStateFlow<SessionStatus>) : AuthEffects {
        val log = mutableListOf<String>()
        var published: AuthState = AuthState.Loading

        /** Access token → failure for [checkUser]; absent means valid. */
        val checkFailures = mutableMapOf<String, Throwable>()

        /** Access token → the user id the server returns (absent: none). */
        val checkUserIds = mutableMapOf<String, String>()
        var checkHook: suspend (String) -> Unit = {}
        var checkGate: CompletableDeferred<Unit>? = null
        var clearGate: CompletableDeferred<Unit>? = null
        var remoteSignOutGate: CompletableDeferred<Unit>? = null
        var wipeFailure: Throwable? = null
        var signIn: suspend (String) -> Unit = {}
        var remoteSignOutFailure: Throwable? = null

        fun count(entry: String) = log.count { it == entry }

        override fun publish(state: AuthState) {
            published = state
            log += "publish:${describe(state)}"
        }

        override fun persistOwner(userId: String?) { log += "owner:$userId" }
        override fun persistNotice(pending: Boolean) { log += "persistNotice:$pending" }
        override fun persistWipePending(pending: Boolean) { log += "wipePending:$pending" }
        override fun showNotice() { log += "showNotice" }
        override fun hideNotice() { log += "hideNotice" }
        override fun saveGuestId(guestId: String) { log += "saveGuest:$guestId" }
        override fun clearGuestId() { log += "clearGuest" }

        override fun wipeAccountData() {
            log += "wipe"
            wipeFailure?.let { throw it }
        }

        override suspend fun clearSupabaseSession() {
            log += "clear"
            clearGate?.await()
            // Like the library's settings removal: suspends, and a cancelled caller fails here.
            yield()
            currentCoroutineContext().ensureActive()
            log += "cleared"
            flow.value = SessionStatus.NotAuthenticated(true)
        }

        override suspend fun kickSessionRefresh() { log += "kick" }

        override suspend fun checkUser(accessToken: String): String? {
            log += "check:$accessToken"
            checkGate?.await()
            checkHook(accessToken)
            checkFailures[accessToken]?.let { throw it }
            return checkUserIds[accessToken]
        }

        override fun log(message: String) = Unit

        override suspend fun signInWithEmail(email: String, password: String) {
            log += "signIn:$email"
            signIn(email)
        }

        override suspend fun signUpWithEmail(email: String, password: String) { log += "signUp:$email" }

        override suspend fun signOutRemote() {
            log += "signOutRemote"
            remoteSignOutGate?.await()
            remoteSignOutFailure?.let { throw it }
            flow.value = SessionStatus.NotAuthenticated(true)
        }

        override suspend fun deleteAccountRemote() { log += "deleteRemote" }
        override suspend fun importTvLoginTokens(accessToken: String, refreshToken: String) { log += "import" }
        override suspend fun ensureTvLoginScaffold() { log += "scaffold" }
    }

    private class Rig(val scope: TestScope, owner: String? = null, guestId: String? = null, longWatchdog: Boolean = true) {
        val flow = MutableStateFlow<SessionStatus>(SessionStatus.Initializing)
        val effects = FakeEffects(flow)
        val driver = if (longWatchdog) {
            AuthSessionDriver(effects, scope.backgroundScope, restoreTimeout = 1.hours)
        } else {
            AuthSessionDriver(effects, scope.backgroundScope)
        }

        init {
            driver.start(AuthEvent.Boot(guestId = guestId, owner = owner, notice = false), { flow })
            scope.runCurrent()
        }

        fun settle() = scope.runCurrent()

        fun signedIn(user: String, rt: String) {
            flow.value = authenticated(user, rt)
            settle()
            assertEquals(account(user), effects.published)
        }
    }

    private companion object {
        fun session(user: String?, rt: String, anonymous: Boolean = false) = UserSession(
            accessToken = "at-$rt",
            refreshToken = rt,
            expiresIn = 3600,
            tokenType = "bearer",
            user = user?.let { UserInfo(aud = "authenticated", id = it, email = "$it@example.test", isAnonymous = anonymous) },
        )

        fun authenticated(user: String?, rt: String, source: SessionSource = SessionSource.SignIn(Email)) =
            SessionStatus.Authenticated(session(user, rt), source)

        fun account(user: String) = AuthState.Authenticated(userId = user, email = "$user@example.test", isAnonymous = false)

        fun describe(state: AuthState): String = when (state) {
            AuthState.Loading -> "Loading"
            AuthState.Unauthenticated -> "Unauthenticated"
            is AuthState.Authenticated -> if (state.isAnonymous) "Guest(${state.userId})" else "Account(${state.userId})"
        }
    }

    // ── Review findings, driven end to end ───────────────────────────────────────────────────────

    @Test
    fun aSignInWaitsForALostResetToFinish() = runTest {
        val rig = Rig(this)
        rig.effects.checkFailures["at-a1"] = RuntimeException("Session not found")
        rig.effects.clearGate = CompletableDeferred()
        rig.effects.signIn = { rig.flow.value = authenticated("B", "b1") }
        rig.flow.value = authenticated("A", "a1")
        rig.settle()
        assertEquals(listOf("clear"), rig.effects.log.filter { it == "clear" })

        val signIn = launch { rig.driver.signInWithEmail("B", "pw") }
        rig.settle()
        assertFalse("signIn:B" in rig.effects.log)

        rig.effects.clearGate!!.complete(Unit)
        rig.settle()
        val log = rig.effects.log
        assertTrue(log.indexOf("wipe") < log.indexOf("publish:Unauthenticated"))
        assertTrue(log.indexOf("publish:Unauthenticated") < log.indexOf("signIn:B"))
        assertEquals(1, rig.effects.count("wipe"))
        signIn.join()
        rig.settle()
        assertEquals(account("B"), rig.effects.published)
        assertEquals(1, rig.effects.count("wipe"))
    }

    @Test
    fun aNotAuthenticatedSupersededDuringASignInIsNeverActedOn() = runTest {
        val rig = Rig(this, owner = "A")
        rig.signedIn("A", "a1")
        rig.effects.signIn = {
            rig.flow.value = SessionStatus.NotAuthenticated(true)
            // Let the collector take this emission and queue on the lane before it is superseded.
            yield()
            rig.flow.value = authenticated("A", "a2")
        }
        rig.driver.signInWithEmail("A", "pw")
        rig.settle()
        assertEquals(0, rig.effects.count("wipe"))
        assertEquals(0, rig.effects.count("showNotice"))
        assertEquals(account("A"), rig.effects.published)
        assertEquals("a2", (rig.driver.modelStateForTest.live as Account).refreshToken)
    }

    @Test
    fun aSignInIsPublishedWhenAuthenticatedArrivesBeforeTheCallReturns() = runTest {
        val rig = Rig(this)
        rig.flow.value = SessionStatus.NotAuthenticated(false)
        rig.settle()
        rig.effects.signIn = { rig.flow.value = authenticated("B", "b1") }
        assertTrue(rig.driver.signInWithEmail("B", "pw").isSuccess)
        rig.settle()
        assertTrue(rig.effects.log.indexOf("check:at-b1") < rig.effects.log.indexOf("publish:Account(B)"))
        assertEquals(account("B"), rig.effects.published)
    }

    @Test
    fun reportSessionErrorWithAnOldTicketReturnsFalse() = runTest {
        val rig = Rig(this)
        rig.signedIn("A", "a1")
        val ticketA = rig.driver.currentTicket()
        assertTrue(rig.driver.signOut().isSuccess)
        rig.settle()
        rig.signedIn("B", "b1")
        val wipes = rig.effects.count("wipe")
        assertFalse(rig.driver.reportSessionError(ticketA, SessionErrorKind.DeletedAccount))
        assertEquals(wipes, rig.effects.count("wipe"))
        assertEquals(account("B"), rig.effects.published)
    }

    @Test
    fun aCurrentTicketDeletedAccountReportClearsTheSession() = runTest {
        val rig = Rig(this)
        rig.signedIn("A", "a1")
        val ticket = rig.driver.currentTicket()
        rig.flow.value = authenticated("A", "a2", SessionSource.Refresh(session("A", "a1")))
        rig.settle()
        assertTrue(rig.driver.reportSessionError(ticket, SessionErrorKind.DeletedAccount))
        rig.settle()
        assertEquals(
            listOf("clear", "cleared", "clearGuest", "wipePending:true", "wipe", "wipePending:false", "owner:null", "persistNotice:true", "showNotice", "publish:Unauthenticated"),
            rig.effects.log.takeLast(10),
        )
        assertEquals(1, rig.effects.count("wipe"))
    }

    // ── Resets ───────────────────────────────────────────────────────────────────────────────────

    @Test
    fun aWipeThatThrowsStillPublishesAndSignOutReturnsFailure() = runTest {
        val rig = Rig(this)
        rig.signedIn("A", "a1")
        rig.effects.wipeFailure = IllegalStateException("disk")
        val result = rig.driver.signOut()
        assertTrue(result.isFailure)
        assertEquals("disk", result.exceptionOrNull()?.message)
        val tail = rig.effects.log.dropWhile { it != "wipe" }
        // r1-5: the owner stays (its data may remain) and the marker stays set; signed-out is published.
        assertEquals(listOf("wipe", "publish:Unauthenticated"), tail)
        assertTrue("wipePending:true" in rig.effects.log)
        assertFalse("wipePending:false" in rig.effects.log)
        assertEquals(AuthState.Unauthenticated, rig.effects.published)
    }

    @Test
    fun aCancelledSignOutStillFinishesTheReset() = runTest {
        val rig = Rig(this)
        rig.signedIn("A", "a1")
        rig.effects.remoteSignOutGate = CompletableDeferred()
        val job = launch { rig.driver.signOut() }
        rig.settle()
        assertTrue("signOutRemote" in rig.effects.log)
        assertFalse("wipe" in rig.effects.log)
        job.cancel()
        rig.settle()
        assertTrue(job.isCancelled)
        assertEquals(1, rig.effects.count("wipe"))
        assertEquals(AuthState.Unauthenticated, rig.effects.published)
        assertTrue(rig.effects.log.indexOf("wipe") < rig.effects.log.lastIndexOf("owner:null"))
        // r1-4: the fallback clear ran to the end (non-cancellable) before the wipe.
        assertTrue("cleared" in rig.effects.log)
        assertTrue(rig.effects.log.indexOf("cleared") < rig.effects.log.indexOf("wipe"))
    }

    @Test
    fun aGuestSignOutClearsTheLibraryLocallyWithoutARemoteCall() = runTest {
        val rig = Rig(this, guestId = "g1")
        assertEquals(AuthState.Authenticated("g1", null, true), rig.effects.published)
        assertTrue(rig.driver.signOut().isSuccess)
        assertFalse("signOutRemote" in rig.effects.log)
        assertTrue("clear" in rig.effects.log)
        assertTrue("clearGuest" in rig.effects.log)
        assertEquals(AuthState.Unauthenticated, rig.effects.published)
    }

    @Test
    fun aFailedRemoteSignOutFallsBackToALocalClearAndReportsTheFailure() = runTest {
        val rig = Rig(this)
        rig.signedIn("A", "a1")
        rig.effects.remoteSignOutFailure = IllegalStateException("offline")
        val result = rig.driver.signOut()
        assertEquals("offline", result.exceptionOrNull()?.message)
        assertTrue(rig.effects.log.indexOf("signOutRemote") < rig.effects.log.indexOf("clear"))
        assertEquals(1, rig.effects.count("wipe"))
        rig.settle()
        assertEquals(0, rig.effects.count("showNotice"))
    }

    @Test
    fun aServerSwitchAndADeletedAccountResetWithoutANotice() = runTest {
        val rig = Rig(this)
        rig.signedIn("A", "a1")
        assertTrue(rig.driver.prepareForServerSwitch().isSuccess)
        rig.settle()
        rig.signedIn("B", "b1")
        assertTrue(rig.driver.deleteAccount().isSuccess)
        rig.settle()
        assertEquals(2, rig.effects.count("wipe"))
        assertEquals(0, rig.effects.count("showNotice"))
        assertTrue(rig.effects.log.indexOf("deleteRemote") < rig.effects.log.lastIndexOf("signOutRemote"))
    }

    // ── Watchdog, guest, restart ─────────────────────────────────────────────────────────────────

    @Test
    fun theWatchdogFiresAfterTenSecondsOfVirtualTime() = runTest {
        val rig = Rig(this, longWatchdog = false)
        assertEquals(AuthState.Loading, rig.effects.published)
        advanceTimeBy(9_999.milliseconds)
        runCurrent()
        assertEquals(AuthState.Loading, rig.effects.published)
        advanceTimeBy(2.milliseconds)
        runCurrent()
        assertEquals(AuthState.Unauthenticated, rig.effects.published)
        rig.flow.value = SessionStatus.Initializing
        runCurrent()
        assertEquals(AuthState.Unauthenticated, rig.effects.published)
    }

    @Test
    fun aGuestTappedWhileTheLaneIsFreeIsAppliedAtOnce() = runTest {
        val rig = Rig(this)
        rig.driver.chooseGuest("g1")
        assertEquals(AuthState.Authenticated("g1", null, true), rig.effects.published)
    }

    @Test
    fun aGuestTappedWhileTheLaneIsBusyIsAppliedAfterIt() = runTest {
        val rig = Rig(this)
        val gate = CompletableDeferred<Unit>()
        rig.effects.signIn = { gate.await() }
        val signIn = launch { rig.driver.signInWithEmail("A", "pw") }
        rig.settle()
        val guest = rig.driver.chooseGuest("g1")
        assertFalse(guest.isCompleted)
        assertFalse("saveGuest:g1" in rig.effects.log)
        gate.complete(Unit)
        signIn.join()
        rig.settle()
        assertTrue(guest.isCompleted)
        assertEquals(AuthState.Authenticated("g1", null, true), rig.effects.published)
    }

    @Test
    fun aRestartDropsTheOldClientsValidation() = runTest {
        val rig = Rig(this)
        rig.effects.checkGate = CompletableDeferred()
        rig.flow.value = authenticated("A", "a1")
        rig.settle()
        assertTrue("check:at-a1" in rig.effects.log)
        val newFlow = MutableStateFlow<SessionStatus>(SessionStatus.Initializing)
        rig.driver.restart(AuthEvent.Boot(guestId = null, owner = null, notice = false), { newFlow })
        rig.effects.checkGate!!.complete(Unit)
        rig.settle()
        assertEquals(AuthState.Loading, rig.effects.published)
        rig.flow.value = authenticated("C", "c1")
        rig.settle()
        assertFalse("check:at-c1" in rig.effects.log)
    }

    @Test
    fun aJwtExpiredValidationPublishesFromCacheAndKicksTheLibrary() = runTest {
        val rig = Rig(this, owner = "A")
        rig.effects.checkFailures["at-a1"] = RuntimeException("JWT expired")
        rig.flow.value = authenticated("A", "a1", SessionSource.Storage)
        rig.settle()
        assertEquals(account("A"), rig.effects.published)
        assertEquals(1, rig.effects.count("kick"))
        rig.flow.value = authenticated("A", "a2", SessionSource.Refresh(session("A", "a1")))
        rig.settle()
        assertEquals(0, rig.effects.count("wipe"))
        assertEquals(account("A"), rig.effects.published)
    }

    @Test
    fun aRefreshFailureStatusNeverChangesWhatIsPublished() = runTest {
        val rig = Rig(this, owner = "A")
        rig.signedIn("A", "a1")
        rig.flow.value = SessionStatus.RefreshFailure(RefreshFailureCause.NetworkError(RuntimeException("offline")))
        rig.settle()
        assertEquals(account("A"), rig.effects.published)
        assertEquals(0, rig.effects.count("wipe"))
    }

    // ── Public-call contract and mapping ─────────────────────────────────────────────────────────

    @Test
    fun noExceptionEscapesAPublicCall() = runTest {
        val rig = Rig(this)
        rig.effects.signIn = { throw IllegalStateException("bad password") }
        assertEquals("bad password", rig.driver.signInWithEmail("A", "pw").exceptionOrNull()?.message)
        rig.effects.signIn = { throw CancellationException("cancelled") }
        assertFailsWith<CancellationException> { rig.driver.signInWithEmail("A", "pw") }
        rig.effects.remoteSignOutFailure = IllegalStateException("offline")
        rig.signedIn("A", "a1")
        assertTrue(rig.driver.signOut().isFailure)
        // The lane is free again after every failure.
        rig.driver.chooseGuest("g1")
        assertEquals(AuthState.Authenticated("g1", null, true), rig.effects.published)
    }

    @Test
    fun snapshotOfMapsEveryStatus() {
        assertEquals(Snap.Initializing, snapshotOf(SessionStatus.Initializing))
        assertEquals(Snap.NotAuthenticated(cleared = true), snapshotOf(SessionStatus.NotAuthenticated(true)))
        assertEquals(Snap.NotAuthenticated(cleared = false), snapshotOf(SessionStatus.NotAuthenticated(false)))
        val noUser = snapshotOf(authenticated(null, "x1", SessionSource.Storage))
        assertIs<Snap.Account>(noUser)
        assertNull(noUser.userId)
        assertTrue(noUser.restored)
        assertFalse((snapshotOf(authenticated("A", "a1")) as Snap.Account).restored)
        assertEquals(
            Snap.RefreshFailure,
            snapshotOf(SessionStatus.RefreshFailure(RefreshFailureCause.NetworkError(RuntimeException("offline")))),
        )
        val refreshed = snapshotOf(authenticated("A", "a2", SessionSource.Refresh(session("A", "a1"))))
        assertEquals(Snap.Account("A", "A@example.test", "at-a2", "a2", refreshedFrom = "a1", restored = true), refreshed)
        listOf(SessionSource.SignIn(Email), SessionSource.Storage, SessionSource.Unknown).forEach { source ->
            val snap = snapshotOf(authenticated("A", "a1", source))
            assertIs<Snap.Account>(snap)
            assertNull(snap.refreshedFrom, "$source")
        }
        assertEquals(Snap.Scaffold, snapshotOf(SessionStatus.Authenticated(session("anon", "s1", anonymous = true), SessionSource.AnonymousSignIn)))
    }

    @Test
    fun theClassifiersFollowUpstreamMarkers() {
        assertEquals(SessionVerdict.JwtExpired, RuntimeException("JWT expired").validationVerdict())
        assertEquals(SessionVerdict.Invalid, RuntimeException("Session not found").validationVerdict())
        assertEquals(SessionVerdict.Invalid, RuntimeException("User does not exist").validationVerdict())
        assertEquals(SessionVerdict.Unreachable, RuntimeException("Unable to resolve host").validationVerdict())
        assertEquals(SessionErrorKind.JwtExpired, RuntimeException("JWT expired").sessionErrorKind())
        assertEquals(SessionErrorKind.DeletedAccount, RuntimeException("insert violates foreign key constraint on auth.users").sessionErrorKind())
        assertEquals(SessionErrorKind.Other, RuntimeException("timeout").sessionErrorKind())
    }

    // ── Review round 1 ──────────────────────────────────────────────────────────────────────────

    @Test
    fun anOldVerdictQueuedDuringASignInNeverClearsTheNewSession() = runTest {
        // r1-3: A's validation finishes Invalid and queues on the lane while sign-in B holds it;
        // B is installed and the lane released before the collector has observed B.
        val rig = Rig(this, owner = "A")
        rig.effects.checkFailures["at-a1"] = RuntimeException("Session not found")
        rig.effects.checkGate = CompletableDeferred()
        rig.flow.value = authenticated("A", "a1", SessionSource.Storage)
        rig.settle()
        assertTrue("check:at-a1" in rig.effects.log)
        rig.effects.signIn = {
            rig.effects.checkGate!!.complete(Unit)
            yield()
            yield()
            rig.flow.value = authenticated("B", "b1")
        }
        rig.driver.signInWithEmail("B", "pw")
        rig.settle()
        assertEquals(0, rig.effects.count("showNotice"))
        assertFalse("clear" in rig.effects.log)
        assertEquals(account("B"), rig.effects.published)
        // The only wipe is decision AQ's account switch (A's data before B), never a lost reset.
        assertEquals(1, rig.effects.count("wipe"))
    }

    @Test
    fun aQueuedSyncReportForTheOldSessionIsDroppedAfterASignIn() = runTest {
        val rig = Rig(this)
        rig.signedIn("A", "a1")
        val ticketA = rig.driver.currentTicket()
        rig.effects.signIn = { rig.flow.value = authenticated("A", "a7") }
        rig.driver.signInWithEmail("A", "pw")
        assertFalse(rig.driver.reportSessionError(ticketA, SessionErrorKind.DeletedAccount))
        rig.settle()
        assertEquals(0, rig.effects.count("wipe"))
        assertEquals(account("A"), rig.effects.published)
    }

    @Test
    fun aCancelledServerSwitchStillClearsTheLibraryBeforeTheWipe() = runTest {
        val rig = Rig(this)
        rig.signedIn("A", "a1")
        rig.effects.clearGate = CompletableDeferred()
        val job = launch { rig.driver.prepareForServerSwitch() }
        rig.settle()
        job.cancel()
        rig.effects.clearGate!!.complete(Unit)
        rig.settle()
        assertTrue("cleared" in rig.effects.log)
        assertTrue(rig.effects.log.indexOf("cleared") < rig.effects.log.indexOf("wipe"))
    }

    @Test
    fun aSessionWithoutAUserIsPublishedAsTheServersUser() = runTest {
        val rig = Rig(this, owner = "A")
        rig.effects.checkUserIds["at-x1"] = "A"
        rig.flow.value = authenticated(null, "x1", SessionSource.Storage)
        rig.settle()
        assertEquals(AuthState.Authenticated("A", null, false), rig.effects.published)
        assertEquals(0, rig.effects.count("wipe"))
    }

    @Test
    fun aSessionWithoutAUserIsNeverPublishedOffline() = runTest {
        val rig = Rig(this, owner = "A")
        rig.effects.checkFailures["at-x1"] = RuntimeException("Unable to resolve host")
        rig.flow.value = authenticated(null, "x1", SessionSource.Storage)
        rig.settle()
        assertEquals(AuthState.Loading, rig.effects.published)
        assertEquals(0, rig.effects.count("wipe"))
    }

    @Test
    fun aFailedSwitchWipeLeavesNoAccountPublished() = runTest {
        val rig = Rig(this, owner = "A")
        rig.effects.wipeFailure = IllegalStateException("disk")
        rig.effects.signIn = { rig.flow.value = authenticated("B", "b1") }
        rig.driver.signInWithEmail("B", "pw")
        rig.settle()
        assertTrue("owner:B" !in rig.effects.log)
        assertEquals(AuthState.Unauthenticated, rig.effects.published)
        assertFalse("wipePending:false" in rig.effects.log)
    }
}
