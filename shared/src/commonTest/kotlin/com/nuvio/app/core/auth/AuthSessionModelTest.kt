package com.nuvio.app.core.auth

import com.nuvio.app.core.auth.AuthEvent.Boot
import com.nuvio.app.core.auth.AuthEvent.GuestChosen
import com.nuvio.app.core.auth.AuthEvent.ResetFinished
import com.nuvio.app.core.auth.AuthEvent.ResetStarted
import com.nuvio.app.core.auth.AuthEvent.SessionErrorReported
import com.nuvio.app.core.auth.AuthEvent.SessionStartFinished
import com.nuvio.app.core.auth.AuthEvent.SessionStartStarted
import com.nuvio.app.core.auth.AuthEvent.ValidationFinished
import com.nuvio.app.core.auth.AuthEvent.WatchdogFired
import com.nuvio.app.core.auth.AuthOutput.ClearGuestId
import com.nuvio.app.core.auth.AuthOutput.ClearSupabaseSession
import com.nuvio.app.core.auth.AuthOutput.HideNotice
import com.nuvio.app.core.auth.AuthOutput.KickSessionRefresh
import com.nuvio.app.core.auth.AuthOutput.PersistNotice
import com.nuvio.app.core.auth.AuthOutput.PersistOwner
import com.nuvio.app.core.auth.AuthOutput.Publish
import com.nuvio.app.core.auth.AuthOutput.SaveGuestId
import com.nuvio.app.core.auth.AuthOutput.ShowNotice
import com.nuvio.app.core.auth.AuthOutput.StartValidation
import com.nuvio.app.core.auth.AuthOutput.WipeAccountData
import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertFalse
import kotlin.test.assertIs
import kotlin.test.assertNotEquals
import kotlin.test.assertNull
import kotlin.test.assertTrue

/**
 * The pure session reducer (spec section 3e). Every finding from the six review rounds of the
 * first attempt is a named sequence here (spec 5c), plus the added sequences. `Drop` outputs are
 * log lines and are left out of every assertion.
 */
class AuthSessionModelTest {

    private class Run(owner: String? = null, guestId: String? = null, notice: Boolean = false) {
        var state: AuthModelState = AuthModelState.Initial
        val all = mutableListOf<AuthOutput>()
        var cleared = false
        var last: List<AuthOutput> = emptyList()

        init {
            send(Boot(guestId = guestId, owner = owner, notice = notice))
        }

        fun send(event: AuthEvent): List<AuthOutput> {
            val step = reduce(state, event)
            state = step.state
            cleared = step.cleared
            last = step.outputs.filterNot { it is AuthOutput.Drop }
            all += last
            return last
        }

        val ticket: AuthTicket get() = AuthTicket(state.live.serial)

        fun startedValidation(): AuthTicket =
            last.filterIsInstance<StartValidation>().single().ticket

        fun wipes(): Int = all.count { it == WipeAccountData }
        fun notices(): Int = all.count { it == ShowNotice }

        /** Snapshot, validation started, verdict Valid: the account is published. */
        fun signInPublished(user: String, rt: String): AuthTicket {
            send(acct(user, rt))
            val t = startedValidation()
            send(ValidationFinished(t, SessionVerdict.Valid))
            assertEquals(account(user), state.published)
            return t
        }

        fun signOut() {
            send(ResetStarted(ResetKind.SignOut))
            send(ResetFinished(ResetKind.SignOut))
            send(Snap.NotAuthenticated)
        }
    }

    private companion object {
        fun acct(user: String, rt: String, refreshedFrom: String? = null) = Snap.Account(
            userId = user,
            email = "$user@example.test",
            accessToken = "at-$rt",
            refreshToken = rt,
            refreshedFrom = refreshedFrom,
        )

        fun account(user: String) = AuthState.Authenticated(userId = user, email = "$user@example.test", isAnonymous = false)
        fun guest(id: String) = AuthState.Authenticated(userId = id, email = null, isAnonymous = true)

        val lostResetClearingLibrary = listOf(
            ClearSupabaseSession, ClearGuestId, WipeAccountData, PersistOwner(null), PersistNotice(true), ShowNotice,
            Publish(AuthState.Unauthenticated),
        )
        val lostResetKeepingLibrary = lostResetClearingLibrary.drop(1)
    }

    // ── r1: verdicts after a sign-out or server switch ───────────────────────────────────────────

    @Test
    fun aValidationFinishingAfterASignOutIsDropped() {
        val run = Run()
        run.send(acct("A", "a1"))
        val t1 = run.startedValidation()
        run.signOut()
        run.send(ValidationFinished(t1, SessionVerdict.Valid))
        assertTrue(run.all.none { it == PersistOwner("A") })
        assertTrue(run.all.none { it is Publish && it.state == account("A") })
        assertEquals(1, run.wipes())
        assertEquals(0, run.notices())
        assertEquals(AuthState.Unauthenticated, run.state.published)
    }

    @Test
    fun aValidationFromBeforeAServerSwitchIsDroppedEvenIfTheSameTokensReturn() {
        val run = Run()
        run.send(acct("A", "a1"))
        val t1 = run.startedValidation()
        run.send(ResetStarted(ResetKind.ServerSwitch))
        run.send(ResetFinished(ResetKind.ServerSwitch))
        run.send(Boot(guestId = null, owner = null, notice = false))
        run.send(acct("A", "a1"))
        val t2 = run.startedValidation()
        assertNotEquals(t1, t2)
        assertEquals(emptyList(), run.send(ValidationFinished(t1, SessionVerdict.Valid)))
        assertEquals(AuthState.Loading, run.state.published)
        run.send(ValidationFinished(t2, SessionVerdict.Valid))
        assertEquals(account("A"), run.state.published)
    }

    @Test
    fun aLostResetIsOneStep() {
        val run = Run()
        run.signInPublished("A", "a1")
        assertEquals(lostResetKeepingLibrary, run.send(Snap.NotAuthenticated))
        assertNull(run.state.owner)
        assertTrue(run.state.noticePending)
    }

    // ── r2: stale statuses and failed starts ─────────────────────────────────────────────────────

    @Test
    fun aNotAuthenticatedWhileAGuestIsActiveDoesNothing() {
        val run = Run()
        run.send(GuestChosen("g1"))
        assertEquals(emptyList(), run.send(Snap.NotAuthenticated))
        assertEquals(guest("g1"), run.state.published)
    }

    @Test
    fun aFailedSignInKeepsTheInFlightValidation() {
        val run = Run()
        run.send(acct("A", "a1"))
        val t1 = run.startedValidation()
        run.send(SessionStartStarted(SessionStartKind.Email))
        run.send(SessionStartFinished(SessionStartKind.Email, ok = false))
        run.send(ValidationFinished(t1, SessionVerdict.Valid))
        assertEquals(account("A"), run.state.published)
    }

    @Test
    fun aSignUpWithoutASessionKeepsTheInFlightValidation() {
        val run = Run()
        run.send(acct("A", "a1"))
        val t1 = run.startedValidation()
        run.send(SessionStartStarted(SessionStartKind.SignUp))
        run.send(SessionStartFinished(SessionStartKind.SignUp, ok = true))
        run.send(ValidationFinished(t1, SessionVerdict.Valid))
        assertEquals(account("A"), run.state.published)
    }

    // ── r3: a new session's own validation ───────────────────────────────────────────────────────

    @Test
    fun aSignInPublishesItsOwnValidation() {
        val run = Run()
        run.send(Snap.NotAuthenticated)
        run.send(SessionStartStarted(SessionStartKind.Email))
        run.send(acct("B", "b1"))
        val tB = run.startedValidation()
        run.send(SessionStartFinished(SessionStartKind.Email, ok = true))
        run.send(ValidationFinished(tB, SessionVerdict.Valid))
        assertEquals(account("B"), run.state.published)
        assertEquals("B", run.state.owner)
    }

    @Test
    fun aQrImportPublishesItsOwnValidation() {
        val run = Run()
        run.send(Snap.NotAuthenticated)
        run.send(Snap.Scaffold)
        val scaffoldSerial = run.state.live.serial
        run.send(acct("B", "b1"))
        val tB = run.startedValidation()
        assertNotEquals(scaffoldSerial, tB.serial)
        run.send(ValidationFinished(tB, SessionVerdict.Valid))
        assertEquals(account("B"), run.state.published)
    }

    @Test
    fun aSignInDropsThePreviousSessionsValidationAndPublishesItsOwn() {
        val run = Run()
        run.send(acct("A", "a1"))
        val tA = run.startedValidation()
        run.send(acct("B", "b1"))
        val tB = run.startedValidation()
        assertEquals(emptyList(), run.send(ValidationFinished(tA, SessionVerdict.Valid)))
        run.send(ValidationFinished(tB, SessionVerdict.Valid))
        assertEquals(account("B"), run.state.published)
    }

    // ── r5: an old validation failure after a newer start ────────────────────────────────────────

    @Test
    fun anOldValidationFailureAfterAGuestStartDoesNothing() {
        val run = Run(owner = "A")
        run.send(acct("A", "a1"))
        val tA = run.startedValidation()
        run.send(WatchdogFired)
        run.send(GuestChosen("g1"))
        assertEquals(emptyList(), run.send(ValidationFinished(tA, SessionVerdict.Invalid)))
        assertTrue(run.all.none { it == ClearSupabaseSession || it == WipeAccountData || it == ClearGuestId })
        assertEquals(guest("g1"), run.state.published)
    }

    @Test
    fun anOldValidationFailureAfterANewEmailSessionDoesNothing() {
        val run = Run(owner = "A")
        run.send(acct("A", "a1"))
        val tA = run.startedValidation()
        run.send(WatchdogFired)
        run.send(acct("B", "b1"))
        assertEquals(emptyList(), run.send(ValidationFinished(tA, SessionVerdict.Invalid)))
        assertEquals(0, run.wipes())
        assertIs<Account>(run.state.live)
    }

    @Test
    fun anOldValidationFailureAfterASignOutDoesNothingMore() {
        val run = Run()
        run.send(acct("A", "a1"))
        val tA = run.startedValidation()
        run.signOut()
        assertEquals(emptyList(), run.send(ValidationFinished(tA, SessionVerdict.Invalid)))
        assertEquals(1, run.wipes())
        assertEquals(0, run.notices())
    }

    // ── r6: refreshes, rotations, tickets ────────────────────────────────────────────────────────

    @Test
    fun aRefreshForAArrivingAfterBIsForeignAndNeverWipes() {
        val run = Run()
        run.send(acct("A", "a1"))
        val tA = run.startedValidation()
        val expired = run.send(ValidationFinished(tA, SessionVerdict.JwtExpired))
        assertEquals(KickSessionRefresh, expired.first())
        assertEquals(account("A"), run.state.published)
        run.signOut()
        run.signInPublished("B", "b1")
        val wipesBefore = run.wipes()
        val foreign = run.send(acct("A", "a2", refreshedFrom = "a1"))
        assertEquals(listOf(ClearSupabaseSession, Publish(AuthState.Unauthenticated)), foreign)
        assertEquals(wipesBefore, run.wipes())
        assertEquals(0, run.notices())
        assertEquals("B", run.state.owner)
        assertIs<NoSession>(run.state.live)
    }

    @Test
    fun aRefreshOfTheLiveSessionKeepsItsSerial() {
        val run = Run()
        run.signInPublished("B", "b1")
        val serial = run.state.live.serial
        assertEquals(emptyList(), run.send(acct("B", "b2", refreshedFrom = "b1")))
        assertEquals(serial, run.state.live.serial)
        assertEquals("b2", (run.state.live as Account).refreshToken)
    }

    @Test
    fun aTokenRotationDuringASyncCheckKeepsTheVerdict() {
        val run = Run()
        run.signInPublished("A", "a1")
        val t = run.ticket
        run.send(acct("A", "a2", refreshedFrom = "a1"))
        assertEquals(lostResetClearingLibrary, run.send(SessionErrorReported(t, SessionErrorKind.DeletedAccount)))
        assertTrue(run.cleared)
    }

    @Test
    fun aSyncVerdictTakenBeforeASignInAsBDoesNothing() {
        val run = Run()
        run.signInPublished("A", "a1")
        val t = run.ticket
        run.signOut()
        run.signInPublished("B", "b1")
        assertEquals(emptyList(), run.send(SessionErrorReported(t, SessionErrorKind.DeletedAccount)))
        assertFalse(run.cleared)
        assertEquals(account("B"), run.state.published)
        assertEquals(1, run.wipes())
    }

    // ── Added sequences ──────────────────────────────────────────────────────────────────────────

    @Test
    fun aTokenRotationDuringValidationStillPublishes() {
        val run = Run()
        run.send(acct("A", "a1"))
        val tA = run.startedValidation()
        assertEquals(emptyList(), run.send(acct("A", "a2", refreshedFrom = "a1")))
        run.send(ValidationFinished(tA, SessionVerdict.Valid))
        assertEquals(account("A"), run.state.published)
    }

    @Test
    fun aSameAccountReSignInIsANewSession() {
        val run = Run()
        val tA1 = run.signInPublished("A", "a1")
        run.signOut()
        run.send(acct("A", "a9"))
        val tA2 = run.startedValidation()
        assertNotEquals(tA1, tA2)
        assertEquals(emptyList(), run.send(ValidationFinished(tA1, SessionVerdict.Valid)))
        run.send(ValidationFinished(tA2, SessionVerdict.Valid))
        assertEquals(account("A"), run.state.published)
        assertEquals(1, run.wipes())
    }

    @Test
    fun aSameAccountSignInFromWelcomeAfterTheWatchdogDoesNotWipe() {
        val run = Run(owner = "A")
        run.send(Snap.RefreshFailure)
        run.send(WatchdogFired)
        assertEquals(AuthState.Unauthenticated, run.state.published)
        run.send(acct("A", "a7"))
        run.send(ValidationFinished(run.startedValidation(), SessionVerdict.Valid))
        assertEquals(account("A"), run.state.published)
        assertEquals(0, run.wipes())
    }

    @Test
    fun aGuestIgnoresAccountStatuses() {
        val run = Run()
        run.send(GuestChosen("g1"))
        assertEquals(emptyList(), run.send(acct("A", "a1")))
        assertEquals(guest("g1"), run.state.published)
    }

    @Test
    fun guestToAccountAndBack() {
        val run = Run(guestId = "g1")
        assertEquals(guest("g1"), run.state.published)
        run.signOut()
        assertEquals(AuthState.Unauthenticated, run.state.published)
        val tA = run.signInPublished("A", "a1")
        run.signOut()
        run.send(GuestChosen("g2"))
        assertEquals(emptyList(), run.send(ValidationFinished(tA, SessionVerdict.Invalid)))
        assertEquals(guest("g2"), run.state.published)
        assertEquals(2, run.wipes())
        assertEquals(0, run.notices())
    }

    @Test
    fun aResetThatFailsMidwayStillPublishesSignedOut() {
        val run = Run()
        run.signInPublished("A", "a1")
        assertEquals(listOf(ClearGuestId, PersistNotice(false), HideNotice), run.send(ResetStarted(ResetKind.SignOut)))
        assertEquals(
            listOf(WipeAccountData, PersistOwner(null), Publish(AuthState.Unauthenticated)),
            run.send(ResetFinished(ResetKind.SignOut)),
        )
    }

    @Test
    fun twoAuthenticatedEmissionsInARow() {
        val same = Run()
        same.send(acct("A", "a1"))
        same.startedValidation()
        assertEquals(emptyList(), same.send(acct("A", "a1")))

        val switched = Run()
        switched.send(acct("A", "a1"))
        val tA = switched.startedValidation()
        switched.send(acct("B", "b1"))
        val tB = switched.startedValidation()
        assertEquals(emptyList(), switched.send(ValidationFinished(tA, SessionVerdict.Valid)))
        switched.send(ValidationFinished(tB, SessionVerdict.Valid))
        assertEquals(account("B"), switched.state.published)

        val conflated = Run()
        conflated.send(acct("B", "b1"))
        conflated.send(ValidationFinished(conflated.startedValidation(), SessionVerdict.Valid))
        assertEquals(account("B"), conflated.state.published)
    }

    @Test
    fun twoRotationsCollapsedIntoOneSnapshot() {
        val run = Run()
        run.signInPublished("A", "a1")
        val serial = run.state.live.serial
        assertEquals(emptyList(), run.send(acct("A", "a3", refreshedFrom = "a2")))
        assertNotEquals(serial, run.state.live.serial)
        assertEquals(account("A"), run.state.published)
        assertEquals(0, run.wipes())
    }

    @Test
    fun aStoredSessionThatFailsToLoadIsALostSession() {
        val run = Run(owner = "A")
        run.send(Snap.Initializing)
        assertEquals(lostResetKeepingLibrary, run.send(Snap.NotAuthenticated))
    }

    @Test
    fun noStoredSessionAndNoOwnerIsAPlainSignedOut() {
        val run = Run()
        assertEquals(listOf(Publish(AuthState.Unauthenticated)), run.send(Snap.NotAuthenticated))
        assertEquals(0, run.wipes())
    }

    @Test
    fun anOfflineColdLaunchWithAnExpiredTokenNeverWipes() {
        val run = Run(owner = "A")
        run.send(Snap.Initializing)
        repeat(3) { assertEquals(emptyList(), run.send(Snap.RefreshFailure)) }
        assertEquals(listOf(Publish(AuthState.Unauthenticated)), run.send(WatchdogFired))
        assertEquals(0, run.wipes())
        assertEquals(0, run.notices())
        run.send(acct("A", "a2", refreshedFrom = "a1"))
        assertIs<Account>(run.state.live)
        run.send(ValidationFinished(run.startedValidation(), SessionVerdict.Valid))
        assertEquals(account("A"), run.state.published)
        assertEquals(0, run.wipes())
    }

    @Test
    fun anOfflineColdLaunchWithAValidTokenPublishesFromCache() {
        val run = Run(owner = "A")
        run.send(acct("A", "a1"))
        run.send(ValidationFinished(run.startedValidation(), SessionVerdict.Unreachable))
        assertEquals(account("A"), run.state.published)
        assertNull(run.state.validatedUserId)
        assertEquals(0, run.wipes())
    }

    @Test
    fun aRevokedSessionWipesOnceInEitherOrder() {
        val validationFirst = Run(owner = "A")
        validationFirst.send(acct("A", "a1"))
        val t1 = validationFirst.startedValidation()
        assertEquals(lostResetClearingLibrary, validationFirst.send(ValidationFinished(t1, SessionVerdict.Invalid)))
        assertEquals(emptyList(), validationFirst.send(Snap.NotAuthenticated))
        assertEquals(1, validationFirst.wipes())
        assertEquals(1, validationFirst.notices())

        val libraryFirst = Run(owner = "A")
        libraryFirst.send(acct("A", "a1"))
        val t2 = libraryFirst.startedValidation()
        assertEquals(lostResetKeepingLibrary, libraryFirst.send(Snap.NotAuthenticated))
        assertEquals(emptyList(), libraryFirst.send(ValidationFinished(t2, SessionVerdict.Invalid)))
        assertEquals(1, libraryFirst.wipes())
        assertEquals(1, libraryFirst.notices())
    }

    @Test
    fun theNoticeLifecycle() {
        val run = Run(notice = true)
        assertEquals(listOf(Publish(AuthState.Loading), ShowNotice), run.last)
        assertEquals(listOf(HideNotice), run.send(SessionStartStarted(SessionStartKind.Email)))
        run.send(acct("A", "a1"))
        val publish = run.send(ValidationFinished(run.startedValidation(), SessionVerdict.Valid))
        assertTrue(PersistNotice(false) in publish && HideNotice in publish)
        assertFalse(run.state.noticePending)

        val guestRun = Run(notice = true)
        val guestOutputs = guestRun.send(GuestChosen("g1"))
        assertEquals(listOf(SaveGuestId("g1"), PersistNotice(false), HideNotice, Publish(guest("g1"))), guestOutputs)

        val switchRun = Run(notice = true)
        assertEquals(
            listOf(ClearGuestId, PersistNotice(false), HideNotice),
            switchRun.send(ResetStarted(ResetKind.ServerSwitch)),
        )
        assertFalse(switchRun.state.noticePending)
    }

    @Test
    fun initializingAfterTheWatchdogDoesNotReturnToLoading() {
        val run = Run()
        run.send(WatchdogFired)
        assertEquals(emptyList(), run.send(Snap.Initializing))
        assertEquals(AuthState.Unauthenticated, run.state.published)
    }

    @Test
    fun aRestoredScaffoldSessionShowsWelcomeAtOnce() {
        val run = Run()
        assertEquals(listOf(Publish(AuthState.Unauthenticated)), run.send(Snap.Scaffold))
        assertIs<Scaffold>(run.state.live)
        assertNull(run.state.owner)
    }

    @Test
    fun aScaffoldNeverLeavesAnAccountPublished() {
        val run = Run()
        run.signInPublished("A", "a1")
        assertEquals(listOf(Publish(AuthState.Unauthenticated)), run.send(Snap.Scaffold))
        assertEquals("A", run.state.owner)
        assertEquals(0, run.wipes())
    }

    @Test
    fun aDeletedAccountFromSyncClearsTheLiveSession() {
        val run = Run()
        run.signInPublished("A", "a1")
        assertEquals(lostResetClearingLibrary, run.send(SessionErrorReported(run.ticket, SessionErrorKind.DeletedAccount)))
        assertTrue(run.cleared)
    }

    @Test
    fun aJwtExpiredSyncErrorKicksTheLibraryRefreshAndKeepsTheState() {
        val run = Run()
        run.signInPublished("A", "a1")
        assertEquals(listOf(KickSessionRefresh), run.send(SessionErrorReported(run.ticket, SessionErrorKind.JwtExpired)))
        assertFalse(run.cleared)
        assertEquals(emptyList(), run.send(SessionErrorReported(run.ticket, SessionErrorKind.Other)))
        assertEquals(account("A"), run.state.published)
    }

    @Test
    fun aRefreshFailureNeverChangesWhatIsPublished() {
        val run = Run(owner = "A")
        run.signInPublished("A", "a1")
        assertEquals(emptyList(), run.send(Snap.RefreshFailure))
        assertEquals(account("A"), run.state.published)
        assertEquals(0, run.wipes())
    }

    @Test
    fun aGuestBootPublishesTheGuestAtOnce() {
        val run = Run(guestId = "g1")
        assertEquals(listOf(Publish(guest("g1"))), run.last)
        assertEquals(emptyList(), run.send(Snap.Initializing))
        assertEquals(emptyList(), run.send(WatchdogFired))
    }

    @Test
    fun aDeliberateResetNeverRaisesTheNotice() {
        listOf(ResetKind.SignOut, ResetKind.ServerSwitch, ResetKind.DeleteAccount).forEach { kind ->
            val run = Run()
            run.signInPublished("A", "a1")
            run.send(ResetStarted(kind))
            run.send(ResetFinished(kind))
            run.send(Snap.NotAuthenticated)
            assertEquals(1, run.wipes(), "$kind")
            assertEquals(0, run.notices(), "$kind")
            assertNull(run.state.owner)
        }
    }

    // ── Decision AQ (spec C7): a different account wipes the previous account's data ────────────

    @Test
    fun signingIntoADifferentAccountWipesThePreviousAccountsData() {
        val run = Run(owner = "A")
        run.send(Snap.RefreshFailure)
        run.send(WatchdogFired)
        run.send(acct("B", "b1"))
        val accept = run.send(ValidationFinished(run.startedValidation(), SessionVerdict.Valid))
        assertEquals(
            listOf(WipeAccountData, PersistOwner("B"), PersistNotice(false), HideNotice, Publish(account("B"))),
            accept,
        )
        assertEquals("B", run.state.owner)
        assertEquals(0, run.notices())
    }

    @Test
    fun sameAccountNoWipe() {
        val run = Run(owner = "A")
        run.send(acct("A", "a1"))
        val accept = run.send(ValidationFinished(run.startedValidation(), SessionVerdict.Unreachable))
        assertEquals(listOf(PersistNotice(false), HideNotice, Publish(account("A"))), accept)
        assertEquals(0, run.wipes())
    }

    @Test
    fun noOwnerNoWipe() {
        val run = Run(owner = null)
        run.send(acct("B", "b1"))
        val accept = run.send(ValidationFinished(run.startedValidation(), SessionVerdict.Valid))
        assertEquals(listOf(PersistOwner("B"), PersistNotice(false), HideNotice, Publish(account("B"))), accept)
        assertEquals(0, run.wipes())
    }
}
