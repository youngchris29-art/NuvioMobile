package com.nuvio.app.core.auth

/*
 * The auth session model: a pure reducer that owns every decision about the session.
 *
 * Design: docs/batch-upstream-ports-spec-auth.md (section 3). The driver (AuthSessionDriver) feeds
 * events in under one lane and executes the returned outputs in order; nothing else decides.
 *
 * Identity is a SERIAL the reducer mints whenever it sees a different session. An access-token
 * rotation keeps the serial (the refresh-token lineage carried by supabase-kt's
 * `SessionSource.Refresh(oldSession)`); a new login always gets a new one, even for the same
 * account. Tickets handed to validation and sync callers are that serial, so "is this verdict about
 * the live session" is a comparison of two numbers.
 */

/** What the library's session currently is, as far as the app has observed it. */
internal sealed interface Live {
    val serial: Long
}

/** No status seen since boot. */
internal data class Booting(override val serial: Long) : Live

internal data class NoSession(override val serial: Long) : Live

internal data class Guest(override val serial: Long, val guestId: String) : Live

/** Anonymous Supabase session: QR-pairing scaffolding, never an account. */
internal data class Scaffold(override val serial: Long) : Live

internal data class Account(
    override val serial: Long,
    val userId: String,
    val email: String?,
    val accessToken: String,
    val refreshToken: String,
) : Live

/** Opaque to callers: the session serial live when it was taken. */
internal data class AuthTicket(val serial: Long)

internal enum class SessionStartKind { Email, SignUp, Qr }

internal enum class ResetKind { SignOut, ServerSwitch, DeleteAccount }

internal enum class SessionVerdict { Valid, Unreachable, Invalid, JwtExpired }

internal enum class SessionErrorKind { DeletedAccount, JwtExpired, Other }

internal sealed interface AuthEvent {
    data class Boot(val guestId: String?, val owner: String?, val notice: Boolean) : AuthEvent
    data object WatchdogFired : AuthEvent
    data class ValidationFinished(val ticket: AuthTicket, val verdict: SessionVerdict) : AuthEvent
    data class SessionErrorReported(val ticket: AuthTicket, val kind: SessionErrorKind) : AuthEvent
    data class ResetStarted(val kind: ResetKind) : AuthEvent
    data class ResetFinished(val kind: ResetKind) : AuthEvent
    data class SessionStartStarted(val kind: SessionStartKind) : AuthEvent
    data class SessionStartFinished(val kind: SessionStartKind, val ok: Boolean) : AuthEvent
    data class GuestChosen(val guestId: String) : AuthEvent
}

/** A library status, read fresh under the lane (see AuthSessionDriver.snapshotOf). */
internal sealed interface Snap : AuthEvent {
    data object Initializing : Snap
    data object RefreshFailure : Snap
    data object NotAuthenticated : Snap
    data object Scaffold : Snap
    data class Account(
        val userId: String,
        val email: String?,
        val accessToken: String,
        val refreshToken: String,
        /** `(source as? Refresh)?.oldSession?.refreshToken`: the session this one was refreshed from. */
        val refreshedFrom: String?,
    ) : Snap
}

internal sealed interface AuthOutput {
    data class Publish(val state: AuthState) : AuthOutput
    data class PersistOwner(val userId: String?) : AuthOutput
    data class PersistNotice(val pending: Boolean) : AuthOutput
    data object ShowNotice : AuthOutput
    data object HideNotice : AuthOutput
    data class SaveGuestId(val guestId: String) : AuthOutput
    data object ClearGuestId : AuthOutput
    data object WipeAccountData : AuthOutput
    data object ClearSupabaseSession : AuthOutput
    data object KickSessionRefresh : AuthOutput
    data class StartValidation(val ticket: AuthTicket, val accessToken: String) : AuthOutput
    data class Drop(val reason: String) : AuthOutput
}

internal data class AuthModelState(
    val nextSerial: Long,
    val live: Live,
    val published: AuthState,
    /** Persisted: user id of the account whose data is on the device (null: none). */
    val owner: String?,
    /** Persisted `signed_out_notice`. */
    val noticePending: Boolean,
    /** A user the server confirmed this run. */
    val validatedUserId: String?,
    /** Serial accepted without a server answer (validation unreachable, or JWT expired). */
    val trustedSerial: Long?,
    /** Serial whose validation is in flight. */
    val validationInFlight: Long?,
    val watchdogFired: Boolean,
) {
    companion object {
        /** Before the first Boot. Serial 0 is never live after a Boot. */
        val Initial = AuthModelState(
            nextSerial = 1,
            live = Booting(0),
            published = AuthState.Loading,
            owner = null,
            noticePending = false,
            validatedUserId = null,
            trustedSerial = null,
            validationInFlight = null,
            watchdogFired = false,
        )
    }
}

internal data class AuthStep(
    val state: AuthModelState,
    val outputs: List<AuthOutput>,
    /** For SessionErrorReported: the report cleared the live session. */
    val cleared: Boolean = false,
)

/** One event in, the new state and the outputs to run in order. Pure. */
internal fun reduce(state: AuthModelState, event: AuthEvent): AuthStep {
    val b = StepBuilder(state)
    b.apply(event)
    b.settle()
    return AuthStep(b.state.copy(nextSerial = b.nextSerial), b.outputs.toList(), b.cleared)
}

private class StepBuilder(var state: AuthModelState) {
    val outputs = mutableListOf<AuthOutput>()
    var cleared = false

    /** Kept outside [state] so a `state.copy(live = X(mint()))` cannot lose the increment. */
    var nextSerial = state.nextSerial

    private fun mint(): Long = nextSerial++

    private fun emit(output: AuthOutput) {
        outputs += output
    }

    private fun publish(target: AuthState) {
        state = state.copy(published = target)
        emit(AuthOutput.Publish(target))
    }

    private fun publishIfChanged(target: AuthState) {
        if (state.published != target) publish(target)
    }

    private fun clearCaches() {
        state = state.copy(validatedUserId = null, trustedSerial = null, validationInFlight = null)
    }

    /** A live value of a different kind gets a new serial; the same kind keeps it. */
    private fun liveNoSession(): Live =
        state.live as? NoSession ?: NoSession(mint())

    private fun liveScaffold(): Live =
        state.live as? Scaffold ?: Scaffold(mint())

    /** The session vanished without a sign-out: wipe, notice, signed out. One step (I3). */
    private fun lostReset(clearLibrary: Boolean, reason: String) {
        state = state.copy(live = NoSession(mint()), owner = null, noticePending = true)
        clearCaches()
        emit(AuthOutput.Drop("lost session: $reason"))
        if (clearLibrary) emit(AuthOutput.ClearSupabaseSession)
        emit(AuthOutput.ClearGuestId)
        emit(AuthOutput.WipeAccountData)
        emit(AuthOutput.PersistOwner(null))
        emit(AuthOutput.PersistNotice(true))
        emit(AuthOutput.ShowNotice)
        publish(AuthState.Unauthenticated)
    }

    private fun accept(account: Account) {
        // Decision AQ (spec C7): signing into a different account wipes the previous account's
        // local data first. The first sign-in after the update never wipes: owner is unset then.
        val previousOwner = state.owner
        if (previousOwner != null && previousOwner != account.userId) {
            emit(AuthOutput.Drop("account switch: wiping the previous account's local data"))
            emit(AuthOutput.WipeAccountData)
        }
        if (previousOwner != account.userId) {
            state = state.copy(owner = account.userId)
            emit(AuthOutput.PersistOwner(account.userId))
        }
        state = state.copy(noticePending = false)
        emit(AuthOutput.PersistNotice(false))
        emit(AuthOutput.HideNotice)
        publish(AuthState.Authenticated(userId = account.userId, email = account.email, isAnonymous = false))
    }

    fun apply(event: AuthEvent) {
        when (event) {
            is AuthEvent.Boot -> {
                val serial = mint()
                val guestId = event.guestId
                state = state.copy(
                    live = if (guestId != null) Guest(serial, guestId) else Booting(serial),
                    owner = event.owner,
                    noticePending = event.notice,
                    watchdogFired = false,
                )
                clearCaches()
                publish(
                    if (guestId != null) AuthState.Authenticated(userId = guestId, email = null, isAnonymous = true)
                    else AuthState.Loading,
                )
                if (event.notice) emit(AuthOutput.ShowNotice)
            }

            Snap.Initializing -> {
                // Fork rule: never re-enter Loading once the restore watchdog has fired.
                if (state.live !is Guest && !state.watchdogFired) publishIfChanged(AuthState.Loading)
            }

            // Upstream daa966d36 (I1): the session is still stored and the library retries.
            Snap.RefreshFailure -> Unit

            Snap.NotAuthenticated -> {
                val live = state.live
                when {
                    live is Guest -> Unit
                    live is Account || (live is Booting && state.owner != null) ->
                        lostReset(clearLibrary = false, reason = "the library reported no session")
                    else -> {
                        state = state.copy(live = liveNoSession())
                        publishIfChanged(AuthState.Unauthenticated)
                    }
                }
            }

            Snap.Scaffold -> {
                if (state.live !is Guest) {
                    state = state.copy(live = liveScaffold())
                    val published = state.published
                    // I7: scaffolding is never shown as an account; a restored one shows Welcome at once.
                    if (published == AuthState.Loading || (published is AuthState.Authenticated && !published.isAnonymous)) {
                        publish(AuthState.Unauthenticated)
                    }
                }
            }

            is Snap.Account -> snapAccount(event)

            AuthEvent.WatchdogFired -> {
                state = state.copy(watchdogFired = true)
                // Decision Q: a restore still pending after the timeout shows Welcome.
                if (state.published == AuthState.Loading) publish(AuthState.Unauthenticated)
            }

            is AuthEvent.ValidationFinished -> {
                val live = state.live
                if (live !is Account || event.ticket.serial != live.serial || state.validationInFlight != event.ticket.serial) {
                    emit(AuthOutput.Drop("stale validation verdict ${event.verdict} for serial ${event.ticket.serial}"))
                    return
                }
                state = state.copy(validationInFlight = null)
                when (event.verdict) {
                    SessionVerdict.Valid -> state = state.copy(validatedUserId = live.userId)
                    SessionVerdict.Unreachable -> state = state.copy(trustedSerial = live.serial)
                    SessionVerdict.JwtExpired -> {
                        // Never refresh from app code (spec 3g): restart the library's own job.
                        state = state.copy(trustedSerial = live.serial)
                        emit(AuthOutput.KickSessionRefresh)
                    }
                    SessionVerdict.Invalid -> lostReset(clearLibrary = true, reason = "validation rejected the session")
                }
            }

            is AuthEvent.SessionErrorReported -> {
                val live = state.live
                if (live !is Account || event.ticket.serial != live.serial) {
                    emit(AuthOutput.Drop("stale session error ${event.kind} for serial ${event.ticket.serial}"))
                    return
                }
                when (event.kind) {
                    SessionErrorKind.DeletedAccount -> {
                        lostReset(clearLibrary = true, reason = "a sync call reported the account deleted")
                        cleared = true
                    }
                    SessionErrorKind.JwtExpired -> emit(AuthOutput.KickSessionRefresh)
                    SessionErrorKind.Other -> Unit
                }
            }

            is AuthEvent.ResetStarted -> {
                state = state.copy(live = NoSession(mint()), noticePending = false)
                clearCaches()
                emit(AuthOutput.ClearGuestId)
                // Upstream for sign-out; decision R for a server switch.
                emit(AuthOutput.PersistNotice(false))
                emit(AuthOutput.HideNotice)
            }

            is AuthEvent.ResetFinished -> {
                // I6: the owner is cleared only after the wipe ran.
                state = state.copy(owner = null)
                emit(AuthOutput.WipeAccountData)
                emit(AuthOutput.PersistOwner(null))
                publish(AuthState.Unauthenticated)
            }

            is AuthEvent.SessionStartStarted -> emit(AuthOutput.HideNotice)

            // Identity comes only from snapshots, so a failed start changes nothing (r2-2).
            is AuthEvent.SessionStartFinished -> Unit

            is AuthEvent.GuestChosen -> {
                state = state.copy(live = Guest(mint(), event.guestId), noticePending = false)
                clearCaches()
                emit(AuthOutput.SaveGuestId(event.guestId))
                // Decision R: choosing guest acknowledges the notice.
                emit(AuthOutput.PersistNotice(false))
                emit(AuthOutput.HideNotice)
                publish(AuthState.Authenticated(userId = event.guestId, email = null, isAnonymous = true))
            }
        }
    }

    private fun snapAccount(snap: Snap.Account) {
        val live = state.live
        // Pre-existing limit 2: an account session while a guest id is stored is never published.
        if (live is Guest) return
        if (live is Account && live.userId == snap.userId &&
            (snap.refreshToken == live.refreshToken || snap.refreshedFrom == live.refreshToken)
        ) {
            // Lineage (rule 2): a re-emission or a rotation of the live session keeps its serial.
            state = state.copy(
                live = live.copy(email = snap.email, accessToken = snap.accessToken, refreshToken = snap.refreshToken),
            )
            return
        }
        if (live is Account && live.userId != snap.userId && snap.refreshedFrom != null) {
            // Foreign refresh (rule 4, B2, I12): a refresh that started before a newer session was
            // imported landed over it. Clear it; no wipe, no notice, owner unchanged.
            state = state.copy(live = NoSession(mint()))
            clearCaches()
            emit(AuthOutput.Drop("foreign refresh for another user landed over the live session"))
            emit(AuthOutput.ClearSupabaseSession)
            publish(AuthState.Unauthenticated)
            return
        }
        // A different session (rules 3 and 5): new serial, validated before it is published (I8).
        state = state.copy(
            live = Account(
                serial = mint(),
                userId = snap.userId,
                email = snap.email,
                accessToken = snap.accessToken,
                refreshToken = snap.refreshToken,
            ),
            validationInFlight = null,
        )
        val published = state.published
        if (published is AuthState.Authenticated && !published.isAnonymous && published.userId != snap.userId) {
            publish(AuthState.Unauthenticated)
        }
    }

    /** Level-triggered: after every event, publish or validate based on the live state. */
    fun settle() {
        val live = state.live as? Account ?: return
        val published = state.published
        if (published is AuthState.Authenticated && !published.isAnonymous && published.userId == live.userId) return
        if (state.validatedUserId == live.userId || state.trustedSerial == live.serial) {
            accept(live)
        } else if (state.validationInFlight == null) {
            state = state.copy(validationInFlight = live.serial)
            emit(AuthOutput.StartValidation(AuthTicket(live.serial), live.accessToken))
        }
    }
}
