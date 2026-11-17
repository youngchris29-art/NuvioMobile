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
import com.nuvio.app.core.auth.AuthOutput.PersistWipePending
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

    private class Run(
        owner: String? = null,
        guestId: String? = null,
        notice: Boolean = false,
        ownerUnknown: Boolean = false,
        wipePending: Boolean = false,
    ) {
        var state: AuthModelState = AuthModelState.Initial
        val all = mutableListOf<AuthOutput>()
        var cleared = false
        var last: List<AuthOutput> = emptyList()

        /** What the driver reports after a wipe output (the fake cleaner succeeds unless told). */
        var wipeOk = true

        /** Whether the durable gate writes succeed (r3-4). */
        var markerWriteOk = true
        var ownerWriteOk = true

        init {
            send(Boot(guestId = guestId, owner = owner, notice = notice, ownerUnknown = ownerUnknown, wipePending = wipePending))
        }

        private fun gateOk(output: AuthOutput): Boolean = when (output) {
            is PersistWipePending -> markerWriteOk
            is PersistOwner -> ownerWriteOk
            else -> true
        }

        /**
         * Reduces [event] and, like the driver, answers a step ending in a gate with GatePassed or
         * GateFailed, and a wipe output with WipeFinished.
         */
        fun send(event: AuthEvent): List<AuthOutput> {
            val collected = mutableListOf<AuthOutput>()
            var next: AuthEvent? = event
            var first = true
            var reductions = 0
            while (next != null) {
                // Round 5: one external event may only lead to a bounded chain of follow-ups.
                check(++reductions <= 20) { "event $event did not settle: ${collected.takeLast(6)}" }
                val step = reduce(state, next)
                state = step.state
                if (first) cleared = step.cleared
                first = false
                collected += step.outputs
                val gate = step.outputs.lastOrNull()?.takeIf { it.isGate }
                next = when {
                    gate != null -> if (gateOk(gate)) AuthEvent.GatePassed(gate) else AuthEvent.GateFailed(gate)
                    WipeAccountData in step.outputs -> AuthEvent.WipeFinished(wipeOk)
                    else -> null
                }
            }
            last = collected.filterNot { it is AuthOutput.Drop }
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
            send(Snap.NotAuthenticated())
        }
    }

    private companion object {
        fun acct(user: String?, rt: String, refreshedFrom: String? = null, restored: Boolean = refreshedFrom != null) = Snap.Account(
            userId = user,
            email = user?.let { "$it@example.test" },
            accessToken = "at-$rt",
            refreshToken = rt,
            refreshedFrom = refreshedFrom,
            restored = restored,
        )

        fun account(user: String) = AuthState.Authenticated(userId = user, email = "$user@example.test", isAnonymous = false)
        fun guest(id: String) = AuthState.Authenticated(userId = id, email = null, isAnonymous = true)

        val lostResetClearingLibrary = listOf(
            ClearSupabaseSession, ClearGuestId, PersistWipePending(true), WipeAccountData, PersistWipePending(false),
            PersistNotice(true), ShowNotice, PersistOwner(null), Publish(AuthState.Unauthenticated),
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
        assertEquals(lostResetKeepingLibrary, run.send(Snap.NotAuthenticated()))
        assertNull(run.state.owner)
        assertTrue(run.state.noticePending)
    }

    // ── r2: stale statuses and failed starts ─────────────────────────────────────────────────────

    @Test
    fun aNotAuthenticatedWhileAGuestIsActiveDoesNothing() {
        val run = Run()
        run.send(GuestChosen("g1"))
        assertEquals(emptyList(), run.send(Snap.NotAuthenticated()))
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
        run.send(Snap.NotAuthenticated())
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
        run.send(Snap.NotAuthenticated())
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
        // r2-2: the new guest does not inherit A's data, so its start wipes once.
        run.send(GuestChosen("g1"))
        assertEquals(1, run.wipes())
        assertEquals(emptyList(), run.send(ValidationFinished(tA, SessionVerdict.Invalid)))
        assertTrue(run.all.none { it == ClearSupabaseSession || it == ClearGuestId })
        assertEquals(1, run.wipes())
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
            listOf(PersistWipePending(true), WipeAccountData, PersistWipePending(false), PersistOwner(null), Publish(AuthState.Unauthenticated)),
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
        val outputs = run.send(acct("A", "a3", refreshedFrom = "a2"))
        assertNotEquals(serial, run.state.live.serial)
        // r1-6: not in the lineage, so it gets its own validation; same user, so it stays shown meanwhile.
        assertEquals(listOf(StartValidation(AuthTicket(run.state.live.serial), "at-a3")), outputs)
        assertEquals(account("A"), run.state.published)
        assertEquals(0, run.wipes())
    }

    @Test
    fun aStoredSessionThatFailsToLoadIsALostSession() {
        val run = Run(owner = "A")
        run.send(Snap.Initializing)
        assertEquals(lostResetKeepingLibrary, run.send(Snap.NotAuthenticated()))
    }

    @Test
    fun noStoredSessionAndNoOwnerIsAPlainSignedOut() {
        val run = Run()
        assertEquals(listOf(Publish(AuthState.Unauthenticated)), run.send(Snap.NotAuthenticated()))
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
        assertNull(run.state.validatedSerial)
        assertEquals(0, run.wipes())
    }

    @Test
    fun aRevokedSessionWipesOnceInEitherOrder() {
        val validationFirst = Run(owner = "A")
        validationFirst.send(acct("A", "a1"))
        val t1 = validationFirst.startedValidation()
        assertEquals(lostResetClearingLibrary, validationFirst.send(ValidationFinished(t1, SessionVerdict.Invalid)))
        assertEquals(emptyList(), validationFirst.send(Snap.NotAuthenticated()))
        assertEquals(1, validationFirst.wipes())
        assertEquals(1, validationFirst.notices())

        val libraryFirst = Run(owner = "A")
        libraryFirst.send(acct("A", "a1"))
        val t2 = libraryFirst.startedValidation()
        assertEquals(lostResetKeepingLibrary, libraryFirst.send(Snap.NotAuthenticated()))
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
            run.send(Snap.NotAuthenticated())
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
            listOf(PersistWipePending(true), WipeAccountData, PersistWipePending(false), PersistOwner("B"), PersistNotice(false), HideNotice, Publish(account("B"))),
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

    // ── Review r1-1: an install that never recorded an owner ─────────────────────────────────────

    @Test
    fun aRejectedStoredSessionOfAnUnknownOwnerThenASignInAsBNeverHandsBTheOldData() {
        // The exact finding: first launch after the update, A's stored session is rejected before
        // any Authenticated, then B signs in.
        val run = Run(ownerUnknown = true)
        run.send(Snap.Initializing)
        assertEquals(lostResetKeepingLibrary, run.send(Snap.NotAuthenticated(cleared = true)))
        assertEquals(1, run.notices())
        assertFalse(run.state.ownerUnknown)
        run.send(acct("B", "b1"))
        run.send(ValidationFinished(run.startedValidation(), SessionVerdict.Valid))
        assertEquals(account("B"), run.state.published)
        assertEquals(1, run.wipes())
        assertTrue(run.all.indexOf(WipeAccountData) < run.all.indexOf(Publish(account("B"))))
    }

    @Test
    fun noUsableStoredSessionAndAnUnknownOwnerClearsTheLeftoversWithoutTheNotice() {
        val run = Run(ownerUnknown = true)
        assertEquals(
            listOf(ClearGuestId, PersistWipePending(true), WipeAccountData, PersistWipePending(false), PersistOwner(null), Publish(AuthState.Unauthenticated)),
            run.send(Snap.NotAuthenticated(cleared = false)),
        )
        assertEquals(0, run.notices())
        assertFalse(run.state.ownerUnknown)
        // Recorded as nobody now: a later sign-in does not wipe again.
        run.send(acct("B", "b1"))
        run.send(ValidationFinished(run.startedValidation(), SessionVerdict.Valid))
        assertEquals(1, run.wipes())
    }

    @Test
    fun theRestoredSessionOfAnUnknownOwnerBecomesTheOwnerWithoutAWipe() {
        val run = Run(ownerUnknown = true)
        run.send(acct("A", "a1", restored = true))
        val accept = run.send(ValidationFinished(run.startedValidation(), SessionVerdict.Valid))
        assertEquals(listOf(PersistOwner("A"), PersistNotice(false), HideNotice, Publish(account("A"))), accept)
        assertEquals(0, run.wipes())
        assertEquals("A", run.state.owner)
        assertFalse(run.state.ownerUnknown)
    }

    @Test
    fun aRestoredRefreshAfterTheWatchdogIsStillTheStoredSession() {
        val run = Run(ownerUnknown = true)
        run.send(Snap.RefreshFailure)
        run.send(WatchdogFired)
        run.send(acct("A", "a2", refreshedFrom = "a1"))
        run.send(ValidationFinished(run.startedValidation(), SessionVerdict.Unreachable))
        assertEquals(account("A"), run.state.published)
        assertEquals(0, run.wipes())
    }

    @Test
    fun anotherAccountWhileTheOwnerIsUnknownWipesFirst() {
        val run = Run(ownerUnknown = true)
        run.send(Snap.RefreshFailure)
        run.send(WatchdogFired)
        run.send(acct("B", "b1"))
        val accept = run.send(ValidationFinished(run.startedValidation(), SessionVerdict.Valid))
        assertEquals(
            listOf(PersistWipePending(true), WipeAccountData, PersistWipePending(false), PersistOwner("B"), PersistNotice(false), HideNotice, Publish(account("B"))),
            accept,
        )
    }

    // ── Review r1-2: a session whose identity is unresolved ──────────────────────────────────────

    @Test
    fun aSessionWithoutAUserIsNeverPublishedComparedOrWipedOffline() {
        val run = Run(owner = "A")
        run.send(acct(null, "x1", restored = true))
        assertEquals(emptyList(), run.send(ValidationFinished(run.startedValidation(), SessionVerdict.Unreachable)))
        assertEquals(AuthState.Loading, run.state.published)
        assertEquals(listOf(Publish(AuthState.Unauthenticated)), run.send(WatchdogFired))
        assertEquals(0, run.wipes())
        assertEquals("A", run.state.owner)
        assertTrue(run.all.none { it is PersistOwner })
    }

    @Test
    fun aSessionWithoutAUserTakesTheIdentityTheServerReturns() {
        val same = Run(owner = "A")
        same.send(acct(null, "x1", restored = true))
        same.send(ValidationFinished(same.startedValidation(), SessionVerdict.Valid, verifiedUserId = "A"))
        assertEquals(AuthState.Authenticated("A", null, false), same.state.published)
        assertEquals(0, same.wipes())

        val other = Run(owner = "A")
        other.send(acct(null, "x1"))
        other.send(ValidationFinished(other.startedValidation(), SessionVerdict.Valid, verifiedUserId = "B"))
        assertEquals(AuthState.Authenticated("B", null, false), other.state.published)
        assertEquals(1, other.wipes())
        assertEquals("B", other.state.owner)
    }

    @Test
    fun theServersUserReplacesTheSnapshotsUser() {
        val run = Run(owner = "A")
        run.send(acct("A", "a1"))
        run.send(ValidationFinished(run.startedValidation(), SessionVerdict.Valid, verifiedUserId = "B"))
        assertEquals("B", run.state.owner)
        assertEquals(1, run.wipes())
    }

    // ── Review r1-5: a wipe that fails ───────────────────────────────────────────────────────────

    @Test
    fun aFailedWipeDuringAnAccountSwitchPublishesNoAccountAndKeepsTheMarker() {
        val run = Run(owner = "A")
        run.send(Snap.RefreshFailure)
        run.send(WatchdogFired)
        run.wipeOk = false
        run.send(acct("B", "b1"))
        val accept = run.send(ValidationFinished(run.startedValidation(), SessionVerdict.Valid))
        assertEquals(listOf(PersistWipePending(true), WipeAccountData), accept)
        assertEquals(AuthState.Unauthenticated, run.state.published)
        assertEquals("A", run.state.owner)
        assertTrue(run.state.wipePending)
        // Not retried in a loop for the same session.
        assertEquals(emptyList(), run.send(Snap.RefreshFailure))
    }

    @Test
    fun aFailedWipeWithAnAccountPublishedUnpublishesIt() {
        val run = Run()
        run.signInPublished("A", "a1")
        run.wipeOk = false
        run.send(acct("B", "b1"))
        assertEquals(AuthState.Unauthenticated, run.state.published)
        run.send(ValidationFinished(run.startedValidation(), SessionVerdict.Valid))
        assertEquals(AuthState.Unauthenticated, run.state.published)
        assertEquals("A", run.state.owner)
    }

    @Test
    fun theNextBootRetriesAPendingWipeBeforeTheAccount() {
        val run = Run(owner = "A", wipePending = true)
        run.send(acct("B", "b1", restored = true))
        val accept = run.send(ValidationFinished(run.startedValidation(), SessionVerdict.Valid))
        assertEquals(
            listOf(PersistWipePending(true), WipeAccountData, PersistWipePending(false), PersistOwner("B"), PersistNotice(false), HideNotice, Publish(account("B"))),
            accept,
        )
        assertFalse(run.state.wipePending)
    }

    @Test
    fun aPendingWipeIsRetriedEvenForTheSameAccount() {
        val run = Run(owner = "A", wipePending = true)
        run.send(acct("A", "a1", restored = true))
        run.send(ValidationFinished(run.startedValidation(), SessionVerdict.Valid))
        assertEquals(1, run.wipes())
        assertEquals(account("A"), run.state.published)
    }

    @Test
    fun aPendingWipeIsRetriedBeforeAGuest() {
        val run = Run(owner = "A", wipePending = true)
        val outputs = run.send(GuestChosen("g1"))
        assertEquals(
            listOf(PersistWipePending(true), WipeAccountData, PersistWipePending(false), PersistOwner(null), SaveGuestId("g1"), PersistNotice(false), HideNotice, Publish(guest("g1"))),
            outputs,
        )
    }

    @Test
    fun aFailedLostResetWipeKeepsTheOwnerAndStillPublishesSignedOut() {
        val run = Run()
        run.signInPublished("A", "a1")
        run.wipeOk = false
        assertEquals(
            listOf(ClearGuestId, PersistWipePending(true), WipeAccountData, PersistNotice(true), ShowNotice, Publish(AuthState.Unauthenticated)),
            run.send(Snap.NotAuthenticated()),
        )
        assertEquals("A", run.state.owner)
        assertTrue(run.state.wipePending)
    }

    @Test
    fun aFailedResetWipeStillPublishesSignedOutAndKeepsTheOwner() {
        val run = Run()
        run.signInPublished("A", "a1")
        run.wipeOk = false
        run.send(ResetStarted(ResetKind.SignOut))
        assertEquals(listOf(PersistWipePending(true), WipeAccountData, Publish(AuthState.Unauthenticated)), run.send(ResetFinished(ResetKind.SignOut)))
        assertEquals("A", run.state.owner)
        assertTrue(run.state.wipePending)
    }

    // ── Review r1-6: a verdict belongs to its serial ─────────────────────────────────────────────

    @Test
    fun aNewSessionForThePublishedUserIsNotAcceptedOnTheOldVerdict() {
        val run = Run()
        run.signInPublished("A", "a1")
        val outputs = run.send(acct("A", "a9"))
        val t = outputs.filterIsInstance<StartValidation>().single().ticket
        assertEquals(run.state.live.serial, t.serial)
        assertEquals(lostResetClearingLibrary, run.send(ValidationFinished(t, SessionVerdict.Invalid)))
    }

    @Test
    fun aNewSessionForAnUnpublishedValidatedUserNeedsItsOwnValidation() {
        val run = Run()
        run.send(acct("A", "a1"))
        run.send(ValidationFinished(run.startedValidation(), SessionVerdict.Valid))
        run.send(ResetStarted(ResetKind.ServerSwitch))
        run.send(ResetFinished(ResetKind.ServerSwitch))
        run.send(Snap.NotAuthenticated())
        val outputs = run.send(acct("A", "a2"))
        assertTrue(outputs.any { it is StartValidation })
        assertEquals(AuthState.Unauthenticated, run.state.published)
    }

    // ── Upgrading without an account (follow-up to r1-1) ────────────────────────────────────────

    @Test
    fun anUpgradingGuestKeepsTheirDataAndStaysAGuest() {
        val run = Run(guestId = "g1", ownerUnknown = true)
        assertEquals(listOf(Publish(guest("g1")), PersistOwner(null)), run.last)
        assertFalse(run.state.ownerUnknown)
        // The library has no session: init reports NotAuthenticated(isSignOut = false).
        assertEquals(emptyList(), run.send(Snap.Initializing))
        assertEquals(emptyList(), run.send(Snap.NotAuthenticated(cleared = false)))
        assertEquals(emptyList(), run.send(WatchdogFired))
        assertEquals(0, run.wipes())
        assertEquals(0, run.notices())
        assertEquals(guest("g1"), run.state.published)
    }

    @Test
    fun anUpgradingGuestWithAStoredAccountSessionStaysAGuestAndNothingIsWiped() {
        val run = Run(guestId = "g1", ownerUnknown = true)
        assertEquals(emptyList(), run.send(acct("A", "a1", restored = true)))
        assertEquals(emptyList(), run.send(Snap.NotAuthenticated(cleared = true)))
        assertEquals(0, run.wipes())
        assertEquals(guest("g1"), run.state.published)
        assertNull(run.state.owner)
    }

    @Test
    fun anUpgradingGuestWhoSignsOutGetsTheUsualSignOutWipeOnly() {
        val run = Run(guestId = "g1", ownerUnknown = true)
        run.signOut()
        assertEquals(1, run.wipes())
        assertEquals(0, run.notices())
        assertEquals(AuthState.Unauthenticated, run.state.published)
    }

    @Test
    fun anUpgradingQrScaffoldIsNeverWipedButTheNextAccountIs() {
        val run = Run(ownerUnknown = true)
        assertEquals(listOf(Publish(AuthState.Unauthenticated)), run.send(Snap.Scaffold))
        assertEquals(0, run.wipes())
        run.send(acct("B", "b1"))
        run.send(ValidationFinished(run.startedValidation(), SessionVerdict.Valid))
        // Leftovers of whoever used the box before are wiped before B's account is shown.
        assertEquals(1, run.wipes())
        assertTrue(run.all.indexOf(WipeAccountData) < run.all.indexOf(Publish(account("B"))))
    }

    @Test
    fun anUpgradingAccountWhoseStoredSessionLoadsLateIsNeverWiped() {
        // The stored session is still being read (or refreshed) when the collector starts: the
        // library stays Initializing or retries, and never reports NotAuthenticated meanwhile.
        val run = Run(ownerUnknown = true)
        run.send(Snap.Initializing)
        run.send(Snap.RefreshFailure)
        run.send(WatchdogFired)
        run.send(acct("A", "a1", restored = true))
        run.send(ValidationFinished(run.startedValidation(), SessionVerdict.Valid))
        assertEquals(account("A"), run.state.published)
        assertEquals(0, run.wipes())
        assertEquals("A", run.state.owner)
    }

    // ── Review r2-2: a newly chosen guest never inherits an account's data ──────────────────────

    @Test
    fun aGuestChosenWhileAnUnknownOwnersSessionIsRestoringWipesFirst() {
        // First launch after the update: A's stored session is still restoring when the watchdog
        // shows Welcome, and the viewer picks guest.
        val run = Run(ownerUnknown = true)
        run.send(Snap.Initializing)
        run.send(Snap.RefreshFailure)
        run.send(WatchdogFired)
        assertEquals(
            listOf(PersistWipePending(true), WipeAccountData, PersistWipePending(false), PersistOwner(null), SaveGuestId("g1"), PersistNotice(false), HideNotice, Publish(guest("g1"))),
            run.send(GuestChosen("g1")),
        )
        assertFalse(run.state.ownerUnknown)
        assertNull(run.state.owner)
    }

    @Test
    fun aRestoreThatFinishesAfterTheGuestChoiceNeverPublishesTheAccountOrWipesAgain() {
        val run = Run(ownerUnknown = true)
        run.send(Snap.RefreshFailure)
        run.send(WatchdogFired)
        run.send(GuestChosen("g1"))
        assertEquals(emptyList(), run.send(acct("A", "a2", refreshedFrom = "a1")))
        assertEquals(emptyList(), run.send(Snap.RefreshFailure))
        assertEquals(guest("g1"), run.state.published)
        assertEquals(1, run.wipes())
        assertNull(run.state.owner)
    }

    @Test
    fun aGuestChosenOverARecordedAccountOwnerWipesFirst() {
        val run = Run(owner = "A")
        run.send(Snap.RefreshFailure)
        run.send(WatchdogFired)
        val outputs = run.send(GuestChosen("g1"))
        assertTrue(outputs.indexOf(WipeAccountData) < outputs.indexOf(Publish(guest("g1"))))
        assertEquals(1, run.wipes())
        assertNull(run.state.owner)
    }

    @Test
    fun aGuestChosenWithNoOwnerDoesNotWipe() {
        val run = Run()
        run.send(Snap.NotAuthenticated(cleared = false))
        assertEquals(listOf(SaveGuestId("g1"), PersistNotice(false), HideNotice, Publish(guest("g1"))), run.send(GuestChosen("g1")))
        assertEquals(0, run.wipes())
    }

    @Test
    fun aFailedWipeBeforeAGuestShowsNoGuest() {
        val run = Run(owner = "A")
        run.wipeOk = false
        run.send(GuestChosen("g1"))
        assertEquals(AuthState.Unauthenticated, run.state.published)
        assertTrue(run.all.none { it is SaveGuestId })
        assertEquals("A", run.state.owner)
    }

    // ── Review r2-3: an unresolved identity is resolved only by a validation ────────────────────

    @Test
    fun anUnreachableVerdictForAnUnresolvedSessionNeverCountsForALaterUser() {
        val run = Run(owner = "B")
        run.send(acct(null, "x1", restored = true))
        val t1 = run.startedValidation()
        assertEquals(emptyList(), run.send(ValidationFinished(t1, SessionVerdict.Unreachable)))
        // A later status of the same session now names a user; it must be validated, not accepted.
        val again = run.send(acct("A", "x2", refreshedFrom = "x1"))
        assertEquals(listOf(StartValidation(AuthTicket(t1.serial), "at-x2")), again)
        assertNull((run.state.live as Account).userId)
        assertEquals(0, run.wipes())
        assertTrue(run.all.none { it is Publish && (it.state as? AuthState.Authenticated)?.isAnonymous == false })
        // Only the server's answer resolves it.
        run.send(ValidationFinished(AuthTicket(t1.serial), SessionVerdict.Valid, verifiedUserId = "A"))
        assertEquals(AuthState.Authenticated("A", null, false), run.state.published)
        assertEquals(1, run.wipes())
    }

    @Test
    fun anUnresolvedSessionIsNotValidatedInALoopOffline() {
        val run = Run(owner = "A")
        run.send(acct(null, "x1", restored = true))
        run.send(ValidationFinished(run.startedValidation(), SessionVerdict.Unreachable))
        assertEquals(emptyList(), run.send(Snap.RefreshFailure))
        assertEquals(emptyList(), run.send(WatchdogFired).filterIsInstance<StartValidation>())
        assertTrue(run.all.count { it is StartValidation } == 1)
    }

    @Test
    fun aValidVerdictWithoutAUserLeavesTheIdentityUnresolved() {
        val run = Run(owner = "A")
        run.send(acct(null, "x1", restored = true))
        assertEquals(emptyList(), run.send(ValidationFinished(run.startedValidation(), SessionVerdict.Valid, verifiedUserId = null)))
        assertEquals(AuthState.Loading, run.state.published)
        assertNull(run.state.validatedSerial)
    }

    // ── Review round 3 ───────────────────────────────────────────────────────────────────────────

    @Test
    fun aFailedGuestStartWipeLeavesNoInvisibleGuestAndASignInStillWorks() {
        // r3-2: the guest's pre-start wipe fails; a later email sign-in must not be ignored.
        val run = Run(owner = "A")
        run.wipeOk = false
        run.send(GuestChosen("g1"))
        assertEquals(AuthState.Unauthenticated, run.state.published)
        assertIs<NoSession>(run.state.live)
        assertTrue(run.state.wipePending)
        run.wipeOk = true
        run.send(acct("B", "b1"))
        val accept = run.send(ValidationFinished(run.startedValidation(), SessionVerdict.Valid))
        assertTrue(WipeAccountData in accept)
        assertEquals(account("B"), run.state.published)
        assertFalse(run.state.wipePending)
    }

    @Test
    fun aTokenRotationDuringAnUnresolvedValidationValidatesTheNewToken() {
        // r3-3: the unresolved session rotates while its first check is in flight; the
        // inconclusive answer about the old token must not defer the new one.
        val run = Run(owner = "A")
        run.send(acct(null, "x1", restored = true))
        val t = run.startedValidation()
        assertEquals(emptyList(), run.send(acct(null, "x2", refreshedFrom = "x1")))
        assertEquals(
            listOf(StartValidation(t, "at-x2")),
            run.send(ValidationFinished(t, SessionVerdict.Unreachable)),
        )
        run.send(ValidationFinished(t, SessionVerdict.Valid, verifiedUserId = "A"))
        assertEquals(AuthState.Authenticated("A", null, false), run.state.published)
    }

    @Test
    fun anUnresolvedSessionStillReachesWelcomeAndALaterStatusUndefers() {
        val run = Run(owner = "A")
        run.send(acct(null, "x1", restored = true))
        run.send(ValidationFinished(run.startedValidation(), SessionVerdict.Unreachable))
        assertEquals(listOf(Publish(AuthState.Unauthenticated)), run.send(WatchdogFired))
        val again = run.send(acct(null, "x2", refreshedFrom = "x1"))
        assertEquals(1, again.filterIsInstance<StartValidation>().size)
    }

    @Test
    fun aMarkerThatIsNotDurablyWrittenStartsNoWipeAndShowsNoAccount() {
        // r3-4: owner A's data, B signs in, the wipe-pending marker cannot be written.
        val run = Run(owner = "A")
        run.markerWriteOk = false
        run.send(acct("B", "b1"))
        val accept = run.send(ValidationFinished(run.startedValidation(), SessionVerdict.Valid))
        assertEquals(listOf(PersistWipePending(true), Publish(AuthState.Unauthenticated)), accept)
        assertEquals(0, run.wipes())
        assertTrue(run.all.none { it is Publish && it.state == account("B") })
        assertEquals("A", run.state.owner)
        assertTrue(run.state.wipePending)
        // The next session retries the marker first, then the wipe.
        run.markerWriteOk = true
        run.send(ResetStarted(ResetKind.SignOut))
        run.send(ResetFinished(ResetKind.SignOut))
        run.send(acct("B", "b2"))
        run.send(ValidationFinished(run.startedValidation(), SessionVerdict.Valid))
        assertEquals(account("B"), run.state.published)
    }

    @Test
    fun aLostResetWhoseMarkerFailsStillPublishesSignedOutWithTheNotice() {
        val run = Run()
        run.signInPublished("A", "a1")
        run.markerWriteOk = false
        assertEquals(
            listOf(ClearGuestId, PersistWipePending(true), PersistNotice(true), ShowNotice, Publish(AuthState.Unauthenticated)),
            run.send(Snap.NotAuthenticated()),
        )
        assertEquals(0, run.wipes())
        assertEquals("A", run.state.owner)
    }

    @Test
    fun anOwnerThatIsNotDurablyWrittenNeverShowsTheAccount() {
        val run = Run(owner = "A")
        run.ownerWriteOk = false
        run.send(acct("B", "b1"))
        val accept = run.send(ValidationFinished(run.startedValidation(), SessionVerdict.Valid))
        assertEquals(
            listOf(PersistWipePending(true), WipeAccountData, PersistWipePending(false), PersistOwner("B"), Publish(AuthState.Unauthenticated)),
            accept,
        )
        assertEquals(AuthState.Unauthenticated, run.state.published)
        // No loop: the same session is not accepted again in this run.
        assertEquals(emptyList(), run.send(Snap.RefreshFailure))
    }

    @Test
    fun aFailedOwnerWriteForTheBootGuestKeepsTheGuest() {
        val run = Run()
        run.ownerWriteOk = false
        run.send(Boot(guestId = "g1", owner = null, notice = false, ownerUnknown = true))
        assertEquals(guest("g1"), run.state.published)
        assertIs<Guest>(run.state.live)
    }

    @Test
    fun aFailedOwnerWriteAfterAResetStillPublishesSignedOut() {
        val run = Run()
        run.signInPublished("A", "a1")
        run.ownerWriteOk = false
        run.send(ResetStarted(ResetKind.SignOut))
        run.send(ResetFinished(ResetKind.SignOut))
        assertEquals(AuthState.Unauthenticated, run.state.published)
    }

    // ── Review round 4: a gate ends its step ─────────────────────────────────────────────────────

    @Test
    fun aGateIsAlwaysTheLastOutputOfItsStep() {
        // Every step of a long mixed sequence: nothing follows a gate output.
        val run = Run(owner = "A", ownerUnknown = false)
        val events = listOf(
            acct("B", "b1"), Snap.RefreshFailure, ResetStarted(ResetKind.SignOut), ResetFinished(ResetKind.SignOut),
            Snap.NotAuthenticated(), GuestChosen("g1"),
        )
        var state = run.state
        events.forEach { event ->
            listOf(event).forEach { e ->
                val step = reduce(state, e)
                state = step.state
                val gateIndex = step.outputs.indexOfFirst { it.isGate }
                if (gateIndex >= 0) assertEquals(step.outputs.lastIndex, gateIndex, "$e: ${step.outputs}")
            }
        }
    }

    @Test
    fun aFailedOwnerWriteLeavesTheConfirmedOwnerAndTheNextSessionWritesItAgain() {
        val run = Run(owner = "A")
        run.ownerWriteOk = false
        run.send(acct("B", "b1"))
        run.send(ValidationFinished(run.startedValidation(), SessionVerdict.Valid))
        assertEquals("A", run.state.owner)
        run.ownerWriteOk = true
        run.send(acct("B", "b2"))
        val accept = run.send(ValidationFinished(run.startedValidation(), SessionVerdict.Valid))
        assertTrue(accept.indexOf(PersistOwner("B")) < accept.indexOf(Publish(account("B"))), "$accept")
        assertEquals("B", run.state.owner)
    }

    // ── Review round 5: a permanently failing gate never repeats without a new event ────────────

    private fun gateWrites(outputs: List<AuthOutput>) = outputs.count { it.isGate }

    @Test
    fun aPermanentlyFailingOwnerWriteForAnAccountIsNotRetriedOnAnyAcceptBranch() {
        // No wipe needed (known no owner).
        val noWipe = Run(owner = null)
        noWipe.ownerWriteOk = false
        noWipe.send(acct("B", "b1"))
        assertEquals(1, gateWrites(noWipe.send(ValidationFinished(noWipe.startedValidation(), SessionVerdict.Valid))))
        assertEquals(0, gateWrites(noWipe.send(Snap.RefreshFailure)))
        // Round 6: a later status of the same session retries, up to the bound, then never again.
        assertEquals(1, gateWrites(noWipe.send(acct("B", "b2", refreshedFrom = "b1"))))
        assertEquals(1, gateWrites(noWipe.send(acct("B", "b3", refreshedFrom = "b2"))))
        assertEquals(0, gateWrites(noWipe.send(acct("B", "b4", refreshedFrom = "b3"))))
        assertEquals(0, gateWrites(noWipe.send(Snap.RefreshFailure)))
        assertEquals(AuthState.Unauthenticated, noWipe.state.published)
        // Wipe needed (another owner): marker and owner each written once.
        val withWipe = Run(owner = "A")
        withWipe.ownerWriteOk = false
        withWipe.send(acct("B", "b1"))
        assertEquals(2, gateWrites(withWipe.send(ValidationFinished(withWipe.startedValidation(), SessionVerdict.Valid))))
        assertEquals(0, gateWrites(withWipe.send(Snap.RefreshFailure)))
        // Owner already confirmed as B: no write at all, so nothing to fail.
        val confirmed = Run(owner = "B")
        confirmed.ownerWriteOk = false
        confirmed.send(acct("B", "b1"))
        assertEquals(0, gateWrites(confirmed.send(ValidationFinished(confirmed.startedValidation(), SessionVerdict.Valid))))
        assertEquals(account("B"), confirmed.state.published)
    }

    @Test
    fun aPermanentlyFailingMarkerOrOwnerWriteEndsForEveryContinuation() {
        // Marker before an account, a reset, a lost session and a guest.
        val markerAccept = Run(owner = "A").apply { markerWriteOk = false }
        markerAccept.send(acct("B", "b1"))
        markerAccept.send(ValidationFinished(markerAccept.startedValidation(), SessionVerdict.Valid))
        assertEquals(0, gateWrites(markerAccept.send(Snap.RefreshFailure)))
        val markerReset = Run().apply { signInPublished("A", "a1"); markerWriteOk = false }
        markerReset.send(ResetStarted(ResetKind.SignOut))
        markerReset.send(ResetFinished(ResetKind.SignOut))
        assertEquals(0, gateWrites(markerReset.send(Snap.NotAuthenticated())))
        val markerGuest = Run(owner = "A").apply { markerWriteOk = false }
        markerGuest.send(GuestChosen("g1"))
        assertEquals(0, gateWrites(markerGuest.send(Snap.RefreshFailure)))
        // Owner after a reset, a lost session, a new guest and the boot guest.
        val ownerReset = Run().apply { signInPublished("A", "a1"); ownerWriteOk = false }
        ownerReset.send(ResetStarted(ResetKind.SignOut))
        assertEquals(2, gateWrites(ownerReset.send(ResetFinished(ResetKind.SignOut))))
        assertEquals(0, gateWrites(ownerReset.send(Snap.NotAuthenticated())))
        val ownerLost = Run().apply { signInPublished("A", "a1"); ownerWriteOk = false }
        assertEquals(2, gateWrites(ownerLost.send(Snap.NotAuthenticated())))
        assertEquals(0, gateWrites(ownerLost.send(Snap.RefreshFailure)))
        val ownerGuest = Run(owner = "A").apply { ownerWriteOk = false }
        assertEquals(2, gateWrites(ownerGuest.send(GuestChosen("g1"))))
        assertEquals(0, gateWrites(ownerGuest.send(Snap.RefreshFailure)))
        val bootGuest = Run().apply { ownerWriteOk = false }
        assertEquals(1, gateWrites(bootGuest.send(Boot(guestId = "g1", owner = null, notice = false, ownerUnknown = true))))
        assertEquals(0, gateWrites(bootGuest.send(Snap.RefreshFailure)))
    }

    // ── Review round 6: the same session retries on a later library status ──────────────────────

    @Test
    fun aMarkerThatFailsOnceForAnAccountIsRetriedOnTheNextStatus() {
        val run = Run(owner = "A")
        run.markerWriteOk = false
        run.send(acct("B", "b1"))
        run.send(ValidationFinished(run.startedValidation(), SessionVerdict.Valid))
        assertEquals(AuthState.Unauthenticated, run.state.published)
        run.markerWriteOk = true
        run.send(acct("B", "b2", refreshedFrom = "b1"))
        assertEquals(account("B"), run.state.published)
        assertEquals(1, run.wipes())
        assertEquals("B", run.state.owner)
    }

    @Test
    fun aWipeThatFailsOnceForAnAccountIsRetriedOnTheNextStatus() {
        val run = Run(owner = "A")
        run.wipeOk = false
        run.send(acct("B", "b1"))
        run.send(ValidationFinished(run.startedValidation(), SessionVerdict.Valid))
        assertEquals(AuthState.Unauthenticated, run.state.published)
        run.wipeOk = true
        run.send(acct("B", "b2", refreshedFrom = "b1"))
        assertEquals(account("B"), run.state.published)
        assertEquals(2, run.wipes())
    }

    @Test
    fun aRetryIsNeverArmedInsideTheFailuresOwnChain() {
        // Only an external status re-arms: the failing reduction and its follow-ups make one
        // attempt, and a status that is not this session's (a refresh failure) re-arms nothing.
        val run = Run(owner = null)
        run.ownerWriteOk = false
        run.send(acct("B", "b1"))
        assertEquals(1, gateWrites(run.send(ValidationFinished(run.startedValidation(), SessionVerdict.Valid))))
        assertEquals(0, gateWrites(run.send(Snap.RefreshFailure)))
        assertEquals(0, gateWrites(run.send(WatchdogFired)))
        assertFalse(run.state.acceptRetryArmed)
    }

    @Test
    fun aNewSessionStartsItsOwnAttemptsAfterTheBound() {
        val run = Run(owner = null)
        run.ownerWriteOk = false
        run.send(acct("B", "b1"))
        run.send(ValidationFinished(run.startedValidation(), SessionVerdict.Valid))
        run.send(acct("B", "b2", refreshedFrom = "b1"))
        run.send(acct("B", "b3", refreshedFrom = "b2"))
        assertEquals(MAX_ACCEPT_ATTEMPTS, run.state.acceptAttempts)
        run.ownerWriteOk = true
        run.send(acct("B", "c1"))
        run.send(ValidationFinished(run.startedValidation(), SessionVerdict.Valid))
        assertEquals(account("B"), run.state.published)
    }
}
