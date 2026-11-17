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
        var markerFailure: Throwable? = null

        fun count(entry: String) = log.count { it == entry }

        /** What the owner store holds; a failed write leaves it unchanged (round 4). */
        var diskOwner: String? = null
        var ownerWriteFails: (String?) -> Boolean = { false }

        /** Every account shown, with the owner on disk at that moment. */
        val accountsShown = mutableListOf<Pair<String, String?>>()

        /** Every account shown while the durable wipe marker was still set (round 7). */
        val accountsShownWithMarkerSet = mutableListOf<String>()

        override fun publish(state: AuthState) {
            published = state
            log += "publish:${describe(state)}"
            if (state is AuthState.Authenticated && !state.isAnonymous) {
                accountsShown += state.userId to diskOwner
                if (diskMarker) accountsShownWithMarkerSet += state.userId
                if (diskGuestId != null) accountsShownWithGuestOnDisk += state.userId
            }
        }

        override fun persistOwner(userId: String?) {
            log += "owner:$userId"
            if (ownerWriteFails(userId)) throw IllegalStateException("owner not durable")
            diskOwner = userId
        }
        override fun persistNotice(pending: Boolean) { log += "persistNotice:$pending" }
        /** What the marker store holds; a failed write leaves it unchanged (round 7). */
        var diskMarker = false
        var markerClearFails: () -> Boolean = { false }

        override fun persistWipePending(pending: Boolean) {
            log += "wipePending:$pending"
            if (pending) markerFailure?.let { throw it }
            if (!pending && markerClearFails()) throw IllegalStateException("marker clear not durable")
            diskMarker = pending
        }
        override fun showNotice() { log += "showNotice" }
        override fun hideNotice() { log += "hideNotice" }
        /** What the guest-id store holds; a failed clear leaves it (round 7). */
        var diskGuestId: String? = null
        var guestClearFails: () -> Boolean = { false }
        val accountsShownWithGuestOnDisk = mutableListOf<String>()

        /** A failed save that still reached the store (round 8): the setter wrote, the flush failed. */
        var guestSaveFailsAfterStoring = false

        override fun saveGuestId(guestId: String) {
            log += "saveGuest:$guestId"
            diskGuestId = guestId
            if (guestSaveFailsAfterStoring) throw IllegalStateException("guest id flush failed")
        }

        override fun clearGuestId() {
            log += "clearGuest"
            if (guestClearFails()) throw IllegalStateException("guest id clear not durable")
            diskGuestId = null
        }

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

    private class Rig(
        val scope: TestScope,
        owner: String? = null,
        guestId: String? = null,
        longWatchdog: Boolean = true,
        wipePending: Boolean = false,
    ) {
        val flow = MutableStateFlow<SessionStatus>(SessionStatus.Initializing)
        val effects = FakeEffects(flow)
        val driver = if (longWatchdog) {
            AuthSessionDriver(effects, scope.backgroundScope, restoreTimeout = 1.hours)
        } else {
            AuthSessionDriver(effects, scope.backgroundScope)
        }

        init {
            effects.diskOwner = owner
            effects.diskMarker = wipePending
            effects.diskGuestId = guestId
            driver.start(AuthEvent.Boot(guestId = guestId, owner = owner, notice = false, wipePending = wipePending), { flow })
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
            listOf("clear", "cleared", "clearGuest", "wipePending:true", "wipe", "wipePending:false", "persistNotice:true", "showNotice", "owner:null", "publish:Unauthenticated"),
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

    @Test
    fun aMarkerWriteThatFailsStopsTheStepBeforeTheWipe() = runTest {
        // r3-4, driven end to end: the gate failure skips the wipe and the reducer publishes signed-out.
        val rig = Rig(this)
        rig.signedIn("A", "a1")
        rig.effects.markerFailure = IllegalStateException("not durable")
        val result = rig.driver.signOut()
        assertTrue(result.isFailure)
        assertFalse("wipe" in rig.effects.log)
        assertEquals(AuthState.Unauthenticated, rig.effects.published)
    }

    // ── Review round 4: a failed owner write, driven end to end ─────────────────────────────────

    @Test
    fun aFailedOwnerWriteNeverShowsTheAccountWhileTheDiskOwnerIsStaleAndARestartKeepsItsData() = runTest {
        val rig = Rig(this, owner = "A")
        var failuresLeft = 1
        rig.effects.ownerWriteFails = { it == "B" && failuresLeft-- > 0 }
        rig.effects.signIn = { rig.flow.value = authenticated("B", "b1") }
        rig.driver.signInWithEmail("B", "pw")
        rig.settle()
        assertEquals("A", rig.effects.diskOwner)
        assertFalse(rig.effects.published is AuthState.Authenticated)
        // A new session for B: the owner write is retried before B is shown.
        rig.effects.signIn = { rig.flow.value = authenticated("B", "b2") }
        rig.driver.signInWithEmail("B", "pw")
        rig.settle()
        assertEquals(account("B"), rig.effects.published)
        assertTrue(rig.effects.accountsShown.all { (user, disk) -> disk == user }, "${rig.effects.accountsShown}")
        // Restart with what is on disk: restoring B must not wipe B's data.
        val wipesBefore = rig.effects.count("wipe")
        val restored = MutableStateFlow<SessionStatus>(authenticated("B", "b2", SessionSource.Storage))
        rig.driver.restart(AuthEvent.Boot(guestId = null, owner = rig.effects.diskOwner, notice = false), { restored })
        rig.settle()
        assertEquals(wipesBefore, rig.effects.count("wipe"))
        assertEquals(account("B"), rig.effects.published)
    }

    @Test
    fun aFailedOwnerWriteAfterASignOutStillShowsSignedOut() = runTest {
        val rig = Rig(this)
        rig.signedIn("A", "a1")
        rig.effects.ownerWriteFails = { true }
        rig.driver.signOut()
        rig.settle()
        assertEquals(AuthState.Unauthenticated, rig.effects.published)
    }

    @Test
    fun aFailedOwnerWriteAfterALostSessionStillShowsSignedOut() = runTest {
        val rig = Rig(this)
        rig.signedIn("A", "a1")
        rig.effects.ownerWriteFails = { true }
        rig.flow.value = SessionStatus.NotAuthenticated(true)
        rig.settle()
        assertEquals(AuthState.Unauthenticated, rig.effects.published)
        assertEquals(1, rig.effects.count("showNotice"))
    }

    @Test
    fun aFailedOwnerWriteBeforeAGuestLeavesNoInvisibleGuestAndASignInWorks() = runTest {
        val rig = Rig(this, owner = "A")
        rig.effects.ownerWriteFails = { it == null }
        rig.driver.chooseGuest("g1")
        rig.settle()
        assertEquals(AuthState.Unauthenticated, rig.effects.published)
        assertFalse("saveGuest:g1" in rig.effects.log)
        rig.effects.ownerWriteFails = { false }
        rig.effects.signIn = { rig.flow.value = authenticated("B", "b1") }
        rig.driver.signInWithEmail("B", "pw")
        rig.settle()
        assertEquals(account("B"), rig.effects.published)
    }

    // ── Review round 5: a permanently failing owner write never loops ────────────────────────────

    @Test
    fun aPermanentlyFailingOwnerWriteIsTriedOnceAndLeavesTheLaneUsable() = runTest {
        // Known "no owner", no pending wipe. Every owner write fails; after 20 attempts the fake
        // gives up failing, so a loop ends (and fails the count below) instead of hanging.
        val rig = Rig(this, owner = null)
        var attempts = 0
        rig.effects.ownerWriteFails = { attempts++; attempts <= 20 }
        rig.effects.signIn = { rig.flow.value = authenticated("B", "b1") }
        rig.driver.signInWithEmail("B", "pw")
        rig.settle()
        assertEquals(1, attempts)
        assertEquals(AuthState.Unauthenticated, rig.effects.published)
        assertEquals(1, rig.effects.log.count { it == "publish:Unauthenticated" })
        assertTrue(rig.effects.accountsShown.isEmpty())
        // The lane is free: a status event and commands are handled.
        rig.flow.value = SessionStatus.NotAuthenticated(true)
        rig.settle()
        assertEquals(1, rig.effects.count("showNotice"))
        rig.driver.chooseGuest("g1")
        rig.settle()
        assertEquals(AuthState.Authenticated("g1", null, true), rig.effects.published)
        assertTrue(rig.driver.signOut().isSuccess)
        rig.settle()
        // The write starts succeeding: the next B session is validated, written and shown.
        rig.effects.ownerWriteFails = { false }
        rig.effects.signIn = { rig.flow.value = authenticated("B", "b2") }
        rig.driver.signInWithEmail("B", "pw")
        rig.settle()
        assertEquals(account("B"), rig.effects.published)
        assertEquals("B", rig.effects.diskOwner)
        assertTrue(rig.effects.accountsShown.all { (user, disk) -> disk == user })
    }

    // ── Review round 6: a transient owner-write failure recovers on the next library status ──────

    /** Restored B as one session, the first owner write fails, then B's token refreshes. */
    private fun TestScope.restoredBWithOneFailedOwnerWrite(): Rig {
        val rig = Rig(this, owner = null)
        var failuresLeft = 1
        rig.effects.ownerWriteFails = { it == "B" && failuresLeft-- > 0 }
        rig.flow.value = authenticated("B", "b1", SessionSource.Storage)
        rig.settle()
        assertEquals(AuthState.Unauthenticated, rig.effects.published)
        assertEquals(null, rig.effects.diskOwner)
        return rig
    }

    @Test
    fun anOwnerWriteThatFailsOnceSucceedsOnTheSameSessionsNextRefresh() = runTest {
        val rig = restoredBWithOneFailedOwnerWrite()
        rig.flow.value = authenticated("B", "b2", SessionSource.Refresh(session("B", "b1")))
        rig.settle()
        assertEquals(account("B"), rig.effects.published)
        assertEquals("B", rig.effects.diskOwner)
        assertTrue(rig.effects.accountsShown.all { (user, disk) -> disk == user })
    }

    @Test
    fun anOwnerWriteThatAlwaysFailsIsTriedThreeTimesThenNoMore() = runTest {
        val rig = Rig(this, owner = null)
        var attempts = 0
        rig.effects.ownerWriteFails = { attempts++; true }
        rig.flow.value = authenticated("B", "b1", SessionSource.Storage)
        rig.settle()
        var previous = "b1"
        (2..6).forEach { n ->
            rig.flow.value = authenticated("B", "b$n", SessionSource.Refresh(session("B", previous)))
            previous = "b$n"
            rig.settle()
        }
        assertEquals(3, attempts)
        // What the user sees during the retries: Welcome, published once, no Loading flicker.
        assertEquals(1, rig.effects.log.count { it == "publish:Unauthenticated" })
        assertFalse("publish:Loading" in rig.effects.log.drop(1))
        assertTrue(rig.effects.accountsShown.isEmpty())
        // The lane is still usable.
        rig.driver.chooseGuest("g1")
        assertEquals(AuthState.Authenticated("g1", null, true), rig.effects.published)
    }

    @Test
    fun aRetryNeverRacesASignOut() = runTest {
        val rig = restoredBWithOneFailedOwnerWrite()
        assertTrue(rig.driver.signOut().isSuccess)
        rig.settle()
        assertEquals(AuthState.Unauthenticated, rig.effects.published)
        assertEquals(1, rig.effects.log.count { it == "owner:B" })
        assertTrue(rig.effects.accountsShown.isEmpty())
    }

    @Test
    fun aRetryNeverTakesOverAChosenGuest() = runTest {
        val rig = restoredBWithOneFailedOwnerWrite()
        rig.driver.chooseGuest("g1")
        rig.settle()
        // The library still holds B and refreshes it; the guest stays and B is not retried.
        rig.flow.value = authenticated("B", "b2", SessionSource.Refresh(session("B", "b1")))
        rig.settle()
        assertEquals(AuthState.Authenticated("g1", null, true), rig.effects.published)
        assertEquals(1, rig.effects.log.count { it == "owner:B" })
    }

    @Test
    fun aRetryNeverResurrectsALostSession() = runTest {
        val rig = restoredBWithOneFailedOwnerWrite()
        rig.flow.value = SessionStatus.NotAuthenticated(true)
        rig.settle()
        assertEquals(AuthState.Unauthenticated, rig.effects.published)
        assertEquals(1, rig.effects.log.count { it == "owner:B" })
        assertTrue(rig.effects.accountsShown.isEmpty())
    }

    // ── Review round 7 ───────────────────────────────────────────────────────────────────────────

    @Test
    fun aFailedMarkerClearNeverShowsTheAccountAndARestartKeepsItsData() = runTest {
        // B owns the data; an earlier interrupted wipe left the marker set. B's accept wipes, and
        // clearing the marker fails once.
        val rig = Rig(this, owner = "B", wipePending = true)
        var clearFailures = 1
        rig.effects.markerClearFails = { clearFailures-- > 0 }
        rig.flow.value = authenticated("B", "b1", SessionSource.Storage)
        rig.settle()
        assertTrue(rig.effects.accountsShownWithMarkerSet.isEmpty(), "${rig.effects.accountsShownWithMarkerSet}")
        assertEquals(AuthState.Unauthenticated, rig.effects.published)
        // The next library status for the same session retries; now the clear works.
        rig.flow.value = authenticated("B", "b2", SessionSource.Refresh(session("B", "b1")))
        rig.settle()
        assertEquals(account("B"), rig.effects.published)
        assertTrue(rig.effects.accountsShownWithMarkerSet.isEmpty())
        assertFalse(rig.effects.diskMarker)
        // B creates data; a restart from what is on disk must not wipe it.
        val wipes = rig.effects.count("wipe")
        val restored = MutableStateFlow<SessionStatus>(authenticated("B", "b2", SessionSource.Storage))
        rig.driver.restart(AuthEvent.Boot(guestId = null, owner = rig.effects.diskOwner, notice = false, wipePending = rig.effects.diskMarker), { restored })
        rig.settle()
        assertEquals(wipes, rig.effects.count("wipe"))
        assertEquals(account("B"), rig.effects.published)
    }

    @Test
    fun aStatusAlreadyFedByReconciliationIsNotFedAgainByTheQueuedCollector() = runTest {
        // B's first owner write fails. While a failed sign-in call holds the lane, B's session
        // refreshes and the collector queues behind it.
        val rig = Rig(this, owner = null)
        var ownerAttempts = 0
        rig.effects.ownerWriteFails = { ownerAttempts++; ownerAttempts <= 2 }
        rig.flow.value = authenticated("B", "b1", SessionSource.Storage)
        rig.settle()
        assertEquals(1, ownerAttempts)
        rig.effects.signIn = {
            rig.flow.value = authenticated("B", "b2", SessionSource.Refresh(session("B", "b1")))
            yield()
            throw IllegalStateException("wrong password")
        }
        assertTrue(rig.driver.signInWithEmail("x", "pw").isFailure)
        rig.settle()
        // One later status, one retry: the same emission is not fed twice.
        assertEquals(2, ownerAttempts)
        assertEquals(AuthState.Unauthenticated, rig.effects.published)
        // A genuinely later refresh still has its attempt, and this one succeeds.
        rig.flow.value = authenticated("B", "b3", SessionSource.Refresh(session("B", "b2")))
        rig.settle()
        assertEquals(3, ownerAttempts)
        assertEquals(account("B"), rig.effects.published)
    }

    @Test
    fun aGuestIdThatCouldNotBeClearedAtSignOutNeverBootsOverTheNextAccount() = runTest {
        // Round 8 replaces round 7's in-memory block: a guest signs out, its id cannot be
        // cleared, B signs in. B may be shown; the next launch decides from the durable owner.
        val rig = Rig(this, guestId = "g1")
        rig.effects.guestClearFails = { true }
        assertTrue(rig.driver.signOut().isFailure)
        rig.settle()
        assertEquals(AuthState.Unauthenticated, rig.effects.published)
        assertEquals("g1", rig.effects.diskGuestId)
        rig.effects.signIn = { rig.flow.value = authenticated("B", "b1") }
        rig.driver.signInWithEmail("B", "pw")
        rig.settle()
        assertEquals(account("B"), rig.effects.published)
        assertEquals("B", rig.effects.diskOwner)
        val restored = MutableStateFlow<SessionStatus>(authenticated("B", "b1", SessionSource.Storage))
        rig.driver.restart(
            AuthEvent.Boot(guestId = rig.effects.diskGuestId, owner = rig.effects.diskOwner, notice = false, wipePending = rig.effects.diskMarker),
            { restored },
        )
        rig.settle()
        assertEquals(account("B"), rig.effects.published)
        assertTrue("clearGuest" in rig.effects.log.takeLast(8), "${rig.effects.log.takeLast(8)}")
    }

    // ── Review round 8: a stale guest id on disk never boots over an account ─────────────────────

    @Test
    fun aGuestSaveThatFailedButStoredTheIdNeverBootsOverTheNextAccount() = runTest {
        val rig = Rig(this, owner = null)
        rig.effects.guestSaveFailsAfterStoring = true
        rig.driver.chooseGuest("g1")
        rig.settle()
        assertEquals(AuthState.Unauthenticated, rig.effects.published)
        assertEquals("g1", rig.effects.diskGuestId)
        rig.effects.signIn = { rig.flow.value = authenticated("B", "b1") }
        rig.driver.signInWithEmail("B", "pw")
        rig.settle()
        assertEquals(account("B"), rig.effects.published)
        // Cold launch from what is on disk: the stale guest id must not win over B.
        val restored = MutableStateFlow<SessionStatus>(authenticated("B", "b1", SessionSource.Storage))
        rig.driver.restart(
            AuthEvent.Boot(guestId = rig.effects.diskGuestId, owner = rig.effects.diskOwner, notice = false, wipePending = rig.effects.diskMarker),
            { restored },
        )
        rig.settle()
        assertEquals(account("B"), rig.effects.published)
    }

    @Test
    fun aGuestClearThatFailsDuringAServerSwitchFailsTheSwitch() = runTest {
        val rig = Rig(this, guestId = "g1")
        rig.effects.guestClearFails = { true }
        // The switch must not report success after a failed step it depends on.
        assertTrue(rig.driver.prepareForServerSwitch().isFailure)
    }

    @Test
    fun aGuestIdLeftOnDiskByAServerSwitchNeverBootsOverTheNextAccount() = runTest {
        val rig = Rig(this, guestId = "g1")
        rig.effects.guestClearFails = { true }
        rig.driver.prepareForServerSwitch()
        rig.settle()
        assertEquals("g1", rig.effects.diskGuestId)
        // Reinitialisation reads the process cache, which (Android) already lost the id.
        rig.effects.guestClearFails = { false }
        val newServer = MutableStateFlow<SessionStatus>(SessionStatus.NotAuthenticated(false))
        rig.driver.restart(AuthEvent.Boot(guestId = null, owner = rig.effects.diskOwner, notice = false), { newServer })
        rig.settle()
        rig.effects.signIn = { newServer.value = authenticated("C", "c1") }
        rig.driver.signInWithEmail("C", "pw")
        rig.settle()
        assertEquals(account("C"), rig.effects.published)
        // A cold launch reads the disk, where the old guest id survived.
        val restored = MutableStateFlow<SessionStatus>(authenticated("C", "c1", SessionSource.Storage))
        rig.driver.restart(
            AuthEvent.Boot(guestId = rig.effects.diskGuestId, owner = rig.effects.diskOwner, notice = false, wipePending = rig.effects.diskMarker),
            { restored },
        )
        rig.settle()
        assertEquals(account("C"), rig.effects.published)
    }
}
