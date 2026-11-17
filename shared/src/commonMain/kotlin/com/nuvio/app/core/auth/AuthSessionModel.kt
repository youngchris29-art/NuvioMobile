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
 * the live session" is a comparison of two numbers. A verdict also belongs to a serial: a new
 * serial is never accepted on an earlier session's validation (review r1-6).
 *
 * Local account data has an OWNER: none, a user id, or unknown (an install that never recorded one,
 * review r1-1). Every wipe is bracketed by a durable "wipe pending" marker that is cleared only once
 * the wipe succeeded (review r1-5); while it is set no account is published.
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
    /** Null while the identity is unresolved (a session without a user, review r1-2). */
    val userId: String?,
    val email: String?,
    val accessToken: String,
    val refreshToken: String,
    /** This is the session the library restored at launch (Storage, or its refresh), not a new start. */
    val restored: Boolean = false,
) : Live

/** Opaque to callers: the session serial live when it was taken. */
internal data class AuthTicket(val serial: Long)

internal enum class SessionStartKind { Email, SignUp, Qr }

internal enum class ResetKind { SignOut, ServerSwitch, DeleteAccount }

internal enum class SessionVerdict { Valid, Unreachable, Invalid, JwtExpired }

internal enum class SessionErrorKind { DeletedAccount, JwtExpired, Other }

internal sealed interface AuthEvent {
    data class Boot(
        val guestId: String?,
        val owner: String?,
        val notice: Boolean,
        /** No owner was ever recorded on this install (the first launch after the update, r1-1). */
        val ownerUnknown: Boolean = false,
        /** A wipe started and never confirmed its success (r1-5). */
        val wipePending: Boolean = false,
    ) : AuthEvent

    data object WatchdogFired : AuthEvent

    /** [verifiedUserId]: the user the server returned for a Valid verdict (r1-2). */
    data class ValidationFinished(
        val ticket: AuthTicket,
        val verdict: SessionVerdict,
        val verifiedUserId: String? = null,
    ) : AuthEvent

    data class SessionErrorReported(val ticket: AuthTicket, val kind: SessionErrorKind) : AuthEvent
    data class ResetStarted(val kind: ResetKind) : AuthEvent
    data class ResetFinished(val kind: ResetKind) : AuthEvent
    data class SessionStartStarted(val kind: SessionStartKind) : AuthEvent
    data class SessionStartFinished(val kind: SessionStartKind, val ok: Boolean) : AuthEvent
    data class GuestChosen(val guestId: String) : AuthEvent

    /** Fed by the driver right after a step whose outputs ran [AuthOutput.WipeAccountData]. */
    data class WipeFinished(val ok: Boolean) : AuthEvent
}

/** A library status, read fresh under the lane (see AuthSessionDriver.snapshotOf). */
internal sealed interface Snap : AuthEvent {
    data object Initializing : Snap
    data object RefreshFailure : Snap

    /**
     * [cleared]: the library's own `clearSession()` emitted it (`isSignOut = true`: a rejected
     * refresh, a `session_not_found`, a sign-out), as opposed to init finding no usable stored
     * session (`false`). Read only to resolve an unknown owner at launch.
     */
    data class NotAuthenticated(val cleared: Boolean = true) : Snap
    data object Scaffold : Snap
    data class Account(
        val userId: String?,
        val email: String?,
        val accessToken: String,
        val refreshToken: String,
        /** `(source as? Refresh)?.oldSession?.refreshToken`: the session this one was refreshed from. */
        val refreshedFrom: String?,
        /** Source is Storage or Refresh: the library restored or refreshed a session itself. */
        val restored: Boolean = false,
    ) : Snap
}

internal sealed interface AuthOutput {
    data class Publish(val state: AuthState) : AuthOutput
    /** null records "no owner" (the owner is then known to be nobody). */
    data class PersistOwner(val userId: String?) : AuthOutput
    data class PersistNotice(val pending: Boolean) : AuthOutput
    data class PersistWipePending(val pending: Boolean) : AuthOutput
    data object ShowNotice : AuthOutput
    data object HideNotice : AuthOutput
    data class SaveGuestId(val guestId: String) : AuthOutput
    data object ClearGuestId : AuthOutput

    /** Always the last output of its step; the driver answers with [AuthEvent.WipeFinished]. */
    data object WipeAccountData : AuthOutput
    data object ClearSupabaseSession : AuthOutput
    data object KickSessionRefresh : AuthOutput
    data class StartValidation(val ticket: AuthTicket, val accessToken: String) : AuthOutput
    data class Drop(val reason: String) : AuthOutput
}

/** What a wipe in progress continues with once its outcome is known. */
internal sealed interface AfterWipe {
    /** A lost session (with the notice) or an unknown owner's leftovers at launch (without). */
    data class Lost(val notice: Boolean) : AfterWipe
    data object Reset : AfterWipe
    data class Accept(val serial: Long) : AfterWipe
    data class GuestStart(val guestId: String) : AfterWipe
}

internal data class AuthModelState(
    val nextSerial: Long,
    val live: Live,
    val published: AuthState,
    /** Persisted: user id of the account whose data is on the device (null: none, or unknown). */
    val owner: String?,
    /** No owner was ever recorded: local data may belong to any account. */
    val ownerUnknown: Boolean,
    /** Persisted: a wipe started and has not succeeded yet. */
    val wipePending: Boolean,
    /** Persisted `signed_out_notice`. */
    val noticePending: Boolean,
    /** Serial the server confirmed this run (a verdict belongs to its serial, r1-6). */
    val validatedSerial: Long?,
    /** Serial accepted without a server answer (validation unreachable, or JWT expired). */
    val trustedSerial: Long?,
    /** Serial whose validation is in flight. */
    val validationInFlight: Long?,
    /** Serial whose account is the one published. */
    val acceptedSerial: Long?,
    /** Serial whose pre-accept wipe failed: not retried until a new serial or a new boot. */
    val wipeFailedSerial: Long?,
    val afterWipe: AfterWipe?,
    val watchdogFired: Boolean,
) {
    companion object {
        /** Before the first Boot. Serial 0 is never live after a Boot. */
        val Initial = AuthModelState(
            nextSerial = 1,
            live = Booting(0),
            published = AuthState.Loading,
            owner = null,
            ownerUnknown = false,
            wipePending = false,
            noticePending = false,
            validatedSerial = null,
            trustedSerial = null,
            validationInFlight = null,
            acceptedSerial = null,
            wipeFailedSerial = null,
            afterWipe = null,
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

    private fun publishedAccountId(): String? =
        (state.published as? AuthState.Authenticated)?.takeIf { !it.isAnonymous }?.userId

    private fun clearCaches() {
        state = state.copy(validatedSerial = null, trustedSerial = null, validationInFlight = null, acceptedSerial = null)
    }

    /** A live value of a different kind gets a new serial; the same kind keeps it. */
    private fun liveNoSession(): Live =
        state.live as? NoSession ?: NoSession(mint())

    private fun liveScaffold(): Live =
        state.live as? Scaffold ?: Scaffold(mint())

    /**
     * Every wipe goes through here: the durable marker first, then the wipe as the step's last
     * output. The driver answers with WipeFinished, which runs [after].
     */
    private fun startWipe(after: AfterWipe, reason: String) {
        state = state.copy(wipePending = true, afterWipe = after)
        emit(AuthOutput.Drop("wipe: $reason"))
        emit(AuthOutput.PersistWipePending(true))
        emit(AuthOutput.WipeAccountData)
    }

    /** The session vanished without a sign-out: wipe, notice, signed out (I3). */
    private fun lostReset(clearLibrary: Boolean, reason: String, notice: Boolean = true) {
        state = state.copy(live = NoSession(mint()))
        clearCaches()
        emit(AuthOutput.Drop("lost session: $reason"))
        if (clearLibrary) emit(AuthOutput.ClearSupabaseSession)
        emit(AuthOutput.ClearGuestId)
        startWipe(AfterWipe.Lost(notice), reason)
    }

    private fun wipeFinished(ok: Boolean) {
        val after = state.afterWipe
        if (after == null) {
            emit(AuthOutput.Drop("wipe outcome with no wipe in progress"))
            return
        }
        state = state.copy(afterWipe = null)
        if (ok) {
            state = state.copy(wipePending = false)
            emit(AuthOutput.PersistWipePending(false))
        } else {
            emit(AuthOutput.Drop("wipe failed: the marker stays set and no account is published"))
        }
        when (after) {
            is AfterWipe.Lost -> {
                // I6: the owner is cleared only after a wipe succeeded.
                if (ok) recordOwner(null)
                if (after.notice) {
                    state = state.copy(noticePending = true)
                    emit(AuthOutput.PersistNotice(true))
                    emit(AuthOutput.ShowNotice)
                }
                publishIfChanged(AuthState.Unauthenticated)
            }
            AfterWipe.Reset -> {
                if (ok) recordOwner(null)
                publish(AuthState.Unauthenticated)
            }
            is AfterWipe.Accept -> {
                val live = state.live
                if (!ok) {
                    state = state.copy(wipeFailedSerial = after.serial)
                    publishIfChanged(AuthState.Unauthenticated)
                } else if (live is Account && live.serial == after.serial && live.userId != null) {
                    finishAccept(live, live.userId)
                }
            }
            is AfterWipe.GuestStart -> {
                if (ok) {
                    recordOwner(null)
                    showGuest(after.guestId)
                } else {
                    publishIfChanged(AuthState.Unauthenticated)
                }
            }
        }
    }

    private fun recordOwner(userId: String?) {
        if (state.owner != userId || state.ownerUnknown) {
            state = state.copy(owner = userId, ownerUnknown = false)
            emit(AuthOutput.PersistOwner(userId))
        }
    }

    /** An account is about to be shown: wipe first when its data could be someone else's (AQ, r1-1, r1-5). */
    private fun accept(live: Account, userId: String) {
        val needsWipe = state.wipePending ||
            (state.ownerUnknown && !live.restored) ||
            (state.owner != null && state.owner != userId)
        if (!needsWipe) {
            finishAccept(live, userId)
            return
        }
        if (state.wipeFailedSerial == live.serial) return
        startWipe(AfterWipe.Accept(live.serial), "account $userId replaces the previous local data")
    }

    private fun finishAccept(live: Account, userId: String) {
        recordOwner(userId)
        state = state.copy(noticePending = false, acceptedSerial = live.serial)
        emit(AuthOutput.PersistNotice(false))
        emit(AuthOutput.HideNotice)
        publish(AuthState.Authenticated(userId = userId, email = live.email, isAnonymous = false))
    }

    private fun showGuest(guestId: String) {
        emit(AuthOutput.SaveGuestId(guestId))
        // Decision R: choosing guest acknowledges the notice.
        emit(AuthOutput.PersistNotice(false))
        emit(AuthOutput.HideNotice)
        publish(AuthState.Authenticated(userId = guestId, email = null, isAnonymous = true))
    }

    fun apply(event: AuthEvent) {
        when (event) {
            is AuthEvent.Boot -> {
                val serial = mint()
                val guestId = event.guestId
                state = state.copy(
                    live = if (guestId != null) Guest(serial, guestId) else Booting(serial),
                    owner = event.owner,
                    ownerUnknown = event.owner == null && event.ownerUnknown,
                    wipePending = event.wipePending,
                    noticePending = event.notice,
                    watchdogFired = false,
                    wipeFailedSerial = null,
                    afterWipe = null,
                )
                clearCaches()
                // A saved guest id means the local data is that guest's: with no owner ever
                // recorded (an upgrading guest), record "no account owner" now, with no wipe. Only
                // "unknown owner, no guest id, no usable stored session" clears leftovers.
                if (guestId != null && state.ownerUnknown) recordOwner(null)
                publish(
                    if (guestId != null) AuthState.Authenticated(userId = guestId, email = null, isAnonymous = true)
                    else AuthState.Loading,
                )
                if (event.notice) emit(AuthOutput.ShowNotice)
            }

            is AuthEvent.WipeFinished -> wipeFinished(event.ok)

            Snap.Initializing -> {
                // Fork rule: never re-enter Loading once the restore watchdog has fired.
                if (state.live !is Guest && !state.watchdogFired) publishIfChanged(AuthState.Loading)
            }

            // Upstream daa966d36 (I1): the session is still stored and the library retries.
            Snap.RefreshFailure -> Unit

            is Snap.NotAuthenticated -> {
                val live = state.live
                when {
                    live is Guest -> Unit
                    live is Account || (live is Booting && state.owner != null) ->
                        lostReset(clearLibrary = false, reason = "the library reported no session")
                    // r1-1: nobody ever recorded who owns the local data. A stored session the
                    // library rejected is a lost session (decision P); no usable stored session
                    // (absent or undecodable, which the library does not tell apart) clears the
                    // leftovers without the notice, so nothing reaches the next account.
                    live is Booting && state.ownerUnknown ->
                        if (event.cleared) {
                            lostReset(clearLibrary = false, reason = "the stored session of an unknown owner was rejected")
                        } else {
                            lostReset(clearLibrary = false, reason = "no usable stored session and no recorded owner", notice = false)
                        }
                    else -> {
                        state = state.copy(live = liveNoSession())
                        publishIfChanged(AuthState.Unauthenticated)
                    }
                }
            }

            Snap.Scaffold -> {
                if (state.live !is Guest) {
                    state = state.copy(live = liveScaffold(), acceptedSerial = null)
                    // I7: scaffolding is never shown as an account; a restored one shows Welcome at once.
                    if (state.published == AuthState.Loading || publishedAccountId() != null) {
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
                    SessionVerdict.Valid -> {
                        // r1-2: the server's user is the identity.
                        val verified = event.verifiedUserId ?: live.userId
                        if (verified != live.userId) {
                            state = state.copy(live = live.copy(userId = verified))
                            val shown = publishedAccountId()
                            if (shown != null && shown != verified) publish(AuthState.Unauthenticated)
                        }
                        state = state.copy(validatedSerial = live.serial)
                    }
                    SessionVerdict.Unreachable -> state = state.copy(trustedSerial = live.serial)
                    SessionVerdict.JwtExpired -> {
                        // Never refresh from app code (spec 3g): restart the library's own job.
                        state = state.copy(trustedSerial = live.serial)
                        emit(AuthOutput.KickSessionRefresh)
                    }
                    // The session is lost whoever it belonged to; what is wiped is the owner's
                    // data (decision P), not decided by the unresolved identity.
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

            is AuthEvent.ResetFinished -> startWipe(AfterWipe.Reset, "deliberate reset ${event.kind}")

            is AuthEvent.SessionStartStarted -> emit(AuthOutput.HideNotice)

            // Identity comes only from snapshots, so a failed start changes nothing (r2-2). The
            // driver feeds the live status before this event (r1-3), so a successful start's
            // session is already observed and the previous ticket retired.
            is AuthEvent.SessionStartFinished -> Unit

            is AuthEvent.GuestChosen -> {
                state = state.copy(live = Guest(mint(), event.guestId), noticePending = false)
                clearCaches()
                if (state.wipePending) {
                    // r1-5: an earlier wipe never completed; retry it before anything is shown.
                    startWipe(AfterWipe.GuestStart(event.guestId), "retry before guest ${event.guestId}")
                } else {
                    showGuest(event.guestId)
                }
            }
        }
    }

    private fun snapAccount(snap: Snap.Account) {
        val live = state.live
        // Pre-existing limit 2: an account session while a guest id is stored is never published.
        if (live is Guest) return
        val sameUserOrUnresolved = live is Account &&
            (snap.userId == live.userId || snap.userId == null || live.userId == null)
        if (live is Account && sameUserOrUnresolved &&
            (snap.refreshToken == live.refreshToken || snap.refreshedFrom == live.refreshToken)
        ) {
            // Lineage (rule 2): a re-emission or a rotation of the live session keeps its serial.
            state = state.copy(
                live = live.copy(
                    userId = live.userId ?: snap.userId,
                    email = snap.email ?: live.email,
                    accessToken = snap.accessToken,
                    refreshToken = snap.refreshToken,
                ),
            )
            return
        }
        if (live is Account && live.userId != null && snap.userId != null && live.userId != snap.userId &&
            snap.refreshedFrom != null
        ) {
            // Foreign refresh (rule 4, B2, I12): a refresh that started before a newer session was
            // imported landed over it. Clear it; no wipe, no notice, owner unchanged.
            state = state.copy(live = NoSession(mint()))
            clearCaches()
            emit(AuthOutput.Drop("foreign refresh for another user landed over the live session"))
            emit(AuthOutput.ClearSupabaseSession)
            publish(AuthState.Unauthenticated)
            return
        }
        // A different session (rules 3 and 5): new serial, validated before it is accepted (I8, r1-6).
        state = state.copy(
            live = Account(
                serial = mint(),
                userId = snap.userId,
                email = snap.email,
                accessToken = snap.accessToken,
                refreshToken = snap.refreshToken,
                restored = snap.restored && live is Booting,
            ),
            validationInFlight = null,
        )
        val shown = publishedAccountId()
        if (shown != null && shown != snap.userId) publish(AuthState.Unauthenticated)
    }

    /** Level-triggered: after every event, accept or validate based on the live state. */
    fun settle() {
        // A wipe in progress decides what is shown next (WipeFinished).
        if (state.afterWipe != null) return
        val live = state.live as? Account ?: return
        if (state.acceptedSerial == live.serial) return
        if (state.validatedSerial == live.serial || state.trustedSerial == live.serial) {
            // r1-2: never publish, compare owners or wipe on an unresolved identity.
            val userId = live.userId ?: return
            accept(live, userId)
        } else if (state.validationInFlight == null) {
            state = state.copy(validationInFlight = live.serial)
            emit(AuthOutput.StartValidation(AuthTicket(live.serial), live.accessToken))
        }
    }
}
