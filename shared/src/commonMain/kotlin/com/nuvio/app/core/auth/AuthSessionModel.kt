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

    /**
     * Fed by the driver after a step that ends in a gate output ([AuthOutput.isGate]): whether
     * that durable write succeeded (r3-4). A gate always ends its step (round 4): nothing the
     * reducer intends after it is emitted, or recorded in state, until the gate passed.
     */
    data class GatePassed(val output: AuthOutput) : AuthEvent
    data class GateFailed(val output: AuthOutput) : AuthEvent

    /**
     * Fork (W2 review r5 #1): fed by the driver when a Publish output threw: [target] was not
     * shown; [shown] is what the last completed publish showed. "Published" is only ever a
     * publish that completed.
     */
    data class PublishFailed(val target: AuthState, val shown: AuthState) : AuthEvent

    /** Fork (W2 review r5 #1): identity recovery retries the failed publish's target. */
    data object RetryPendingPublish : AuthEvent
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
    /**
     * A durable write whose outcome decides what the next launch does (r3-4, round 7): setting the
     * wipe-pending marker before a wipe, clearing it after one, the owner before an account, a
     * guest or a signed-out state is shown, and a new guest's id before the guest is shown. It is
     * always the last output of its step; the driver answers [AuthEvent.GatePassed] or
     * [AuthEvent.GateFailed], and nothing that depends on it is emitted or committed before that.
     */
    val isGate: Boolean
        get() = this is PersistWipePending || this is PersistOwner || this is SaveGuestId

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

/** What follows a durable owner write once it is confirmed (round 4). */
internal sealed interface OwnerThen {
    data class Accept(val serial: Long) : OwnerThen
    /** After a deliberate reset's wipe. */
    data object ResetDone : OwnerThen
    /** After a lost reset's or a leftovers' wipe (the notice, if any, is already raised). */
    data object LostDone : OwnerThen
    /** After a newly chosen guest's wipe. */
    data class GuestShow(val guestId: String) : OwnerThen
    /** The guest saved at boot, already shown. */
    data object BootGuest : OwnerThen
}

/** A gate output in flight: the reducer's intent waits for its outcome. */
internal sealed interface PendingGate {
    /** The wipe-pending marker; on success the wipe itself runs ([AuthModelState.afterWipe]). */
    data object Marker : PendingGate

    /** Round 7: clearing the marker after a successful wipe; [after] waits for it. */
    data class MarkerClear(val after: AfterWipe) : PendingGate
    data class Owner(val userId: String?, val then: OwnerThen) : PendingGate

    /** Round 7: a newly chosen guest's id; the guest is shown only once it is on disk. */
    data class GuestId(val guestId: String) : PendingGate

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
    /** The access token that validation is checking (r3-3: a rotation in flight re-validates). */
    val validationInFlightToken: String? = null,
    /** Serial whose account is the one published. */
    val acceptedSerial: Long?,
    /**
     * Serial whose pre-accept wipe or owner write failed (rounds 3 and 5). It is not accepted again
     * inside that failure's own follow-up chain; a later library status for the same session may
     * re-arm one retry (round 6), up to [MAX_ACCEPT_ATTEMPTS] attempts per serial per run.
     */
    val acceptBlockedSerial: Long?,
    /** Attempts made for [acceptBlockedSerial] so far. */
    val acceptAttempts: Int = 0,
    /** A later status for [acceptBlockedSerial] re-armed one retry (round 6). */
    val acceptRetryArmed: Boolean = false,
    /**
     * Serial whose identity is still unresolved after a validation that returned no user (r2-3):
     * not validated again until the library reports that session again, so an offline launch
     * does not loop.
     */
    val validationDeferredSerial: Long? = null,
    val afterWipe: AfterWipe?,
    val watchdogFired: Boolean,
    /** A gate output whose outcome is awaited; nothing else happens until it is known. */
    val pendingGate: PendingGate? = null,
    /**
     * Fork (scope identity W2, review r5 #1): a publish whose effect failed (the identity hook or
     * the write threw). [published] went back to what is really shown; this is the target that
     * RetryPendingPublish publishes again. Any other publish supersedes it.
     */
    val pendingPublish: AuthState? = null,
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
            acceptBlockedSerial = null,
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

/**
 * Fork (scope identity W2, review r6 #3): the two provisional publishes (the restore watchdog's
 * Welcome and a library re-initialisation's Loading) never supersede a failed identity publish
 * still owed (AuthModelState.pendingPublish): its retries are running. Every definitive publish
 * (a reset, a lost or replaced session, another account, a guest start) still supersedes it.
 */
internal object ProvisionalPublishRule {
    fun watchdogShowsWelcome(published: AuthState, pendingPublish: AuthState?): Boolean =
        published == AuthState.Loading && pendingPublish == null

    fun initializingShowsLoading(liveIsGuest: Boolean, watchdogFired: Boolean, pendingPublish: AuthState?): Boolean =
        !liveIsGuest && !watchdogFired && pendingPublish == null
}

/** What a boot makes of a guest id found on disk (round 8). */
internal data class BootResolution(val trustedGuestId: String?, val clearStaleGuestId: Boolean)

/**
 * Round 8: whether a guest id found on disk can be trusted is decided from durable state that is
 * already gated, never from a flag held in memory. A guest is only ever shown after the owner was
 * durably recorded as "no account" (a guest start wipes and records nobody first), and the owner
 * names an account only after that account was accepted, which cannot happen while a guest is
 * live. So a guest id next to a recorded account owner is stale by construction: a guest-id save
 * that failed after storing, or a guest-id clear that failed, at reset, lost reset or server
 * switch. Boot ignores it (the account's session path runs) and clears it, best-effort. An owner
 * that is unknown (an install that never recorded one) or recorded as nobody keeps the guest:
 * the data is the guest's.
 */
internal fun resolveBoot(guestId: String?, owner: String?): BootResolution = when {
    guestId == null -> BootResolution(trustedGuestId = null, clearStaleGuestId = false)
    owner != null -> BootResolution(trustedGuestId = null, clearStaleGuestId = true)
    else -> BootResolution(trustedGuestId = guestId, clearStaleGuestId = false)
}

/** Attempts per session serial per run to make an account's data its own (round 6). */
internal const val MAX_ACCEPT_ATTEMPTS = 3

private class StepBuilder(var state: AuthModelState) {
    val outputs = mutableListOf<AuthOutput>()
    var cleared = false

    /** Kept outside [state] so a `state.copy(live = X(mint()))` cannot lose the increment. */
    var nextSerial = state.nextSerial

    private fun mint(): Long = nextSerial++

    private fun emit(output: AuthOutput) {
        // Round 4: a gate ends its step. Anything planned after it would be state for an output
        // the driver may never run.
        check(outputs.none { it.isGate }) { "output $output emitted after a gate in the same step" }
        outputs += output
    }

    private fun publish(target: AuthState) {
        state = state.copy(published = target, pendingPublish = null)
        emit(AuthOutput.Publish(target))
    }

    private fun publishIfChanged(target: AuthState) {
        if (state.published != target) publish(target)
    }

    private fun publishedAccountId(): String? =
        (state.published as? AuthState.Authenticated)?.takeIf { !it.isAnonymous }?.userId

    private fun clearCaches() {
        state = state.copy(
            validatedSerial = null,
            trustedSerial = null,
            validationInFlight = null,
            validationInFlightToken = null,
            acceptedSerial = null,
            validationDeferredSerial = null,
        )
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
        state = state.copy(wipePending = true, afterWipe = after, pendingGate = PendingGate.Marker)
        emit(AuthOutput.Drop("wipe: $reason"))
        emit(AuthOutput.PersistWipePending(true))
    }

    /** The session vanished without a sign-out: wipe, notice, signed out (I3). */
    private fun lostReset(clearLibrary: Boolean, reason: String, notice: Boolean = true) {
        state = state.copy(live = NoSession(mint()))
        clearCaches()
        emit(AuthOutput.Drop("lost session: $reason"))
        if (clearLibrary) emit(AuthOutput.ClearSupabaseSession)
        // Best-effort (round 8): a guest id left on disk is never trusted over a recorded account
        // owner at the next boot (resolveBoot), so its failure cannot leak data either way.
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
            // Round 7: clearing the marker is a gate. Until it is confirmed the marker stays
            // pending (in memory too), and nothing that depends on the wipe is shown.
            state = state.copy(pendingGate = PendingGate.MarkerClear(after))
            emit(AuthOutput.PersistWipePending(false))
            return
        }
        emit(AuthOutput.Drop("wipe failed: the marker stays set and no account is published"))
        continueAfterWipe(after, completed = false)
    }

    /**
     * What follows a wipe. [completed]: the wipe ran AND its marker is durably cleared. Otherwise
     * the marker stays pending, nothing new is shown, and the next account or guest start wipes
     * (and clears) again first; nothing can have been created in between, so that repeat wipe
     * never destroys new data.
     */
    private fun continueAfterWipe(after: AfterWipe, completed: Boolean) {
        when (after) {
            is AfterWipe.Lost -> {
                if (after.notice) {
                    state = state.copy(noticePending = true)
                    emit(AuthOutput.PersistNotice(true))
                    emit(AuthOutput.ShowNotice)
                }
                // I6: the owner is cleared only after a wipe succeeded (a gate; round 4: the
                // publish waits for it).
                if (completed) recordOwner(null, OwnerThen.LostDone) else ownerConfirmed(OwnerThen.LostDone)
            }
            AfterWipe.Reset -> {
                if (completed) recordOwner(null, OwnerThen.ResetDone) else ownerConfirmed(OwnerThen.ResetDone)
            }
            is AfterWipe.Accept -> {
                val live = state.live
                if (!completed) {
                    acceptFailed(after.serial)
                    publishIfChanged(AuthState.Unauthenticated)
                } else if (live is Account && live.serial == after.serial && live.userId != null) {
                    finishAccept(live, live.userId)
                }
            }
            is AfterWipe.GuestStart -> {
                if (completed) recordOwner(null, OwnerThen.GuestShow(after.guestId)) else leaveFailedGuestStart()
            }
        }
    }

    /**
     * r3-2: a guest whose pre-start wipe could not run is not a guest: no guest id was saved, and
     * the next account session must be validated (and retry the wipe) instead of being ignored.
     */
    private fun leaveFailedGuestStart() {
        if (state.live is Guest) state = state.copy(live = NoSession(mint()))
        publishIfChanged(AuthState.Unauthenticated)
    }

    private fun gatePassed(output: AuthOutput) {
        val pending = state.pendingGate
        state = state.copy(pendingGate = null)
        when {
            pending == PendingGate.Marker && output is AuthOutput.PersistWipePending && output.pending ->
                // The marker is on disk: now the wipe may run (the step's last output again).
                emit(AuthOutput.WipeAccountData)
            pending is PendingGate.MarkerClear && output is AuthOutput.PersistWipePending && !output.pending -> {
                state = state.copy(wipePending = false)
                continueAfterWipe(pending.after, completed = true)
            }
            pending is PendingGate.GuestId && output is AuthOutput.SaveGuestId && output.guestId == pending.guestId ->
                guestSaved(pending.guestId)
            pending is PendingGate.Owner && output is AuthOutput.PersistOwner && output.userId == pending.userId -> {
                // Only a confirmed write changes the owner (round-4 finding 1).
                state = state.copy(owner = pending.userId, ownerUnknown = false)
                ownerConfirmed(pending.then)
            }
            else -> emit(AuthOutput.Drop("gate outcome $output does not match the pending gate $pending"))
        }
    }

    private fun gateFailed(output: AuthOutput) {
        val pending = state.pendingGate
        state = state.copy(pendingGate = null)
        emit(AuthOutput.Drop("durable write failed: $output"))
        when {
            pending == PendingGate.Marker && output is AuthOutput.PersistWipePending && output.pending -> {
                // The marker is not on disk, so the wipe never started; local data and the
                // recorded owner are still consistent. Keep the marker in memory so the next
                // account or guest retries, and carry on as a failed wipe.
                state = state.copy(wipePending = true)
                wipeFinished(ok = false)
            }
            pending is PendingGate.MarkerClear && output is AuthOutput.PersistWipePending && !output.pending -> {
                // Round 7: the wipe ran but the marker is still set on disk. Treat it as an
                // incomplete wipe: the marker stays pending, nothing is shown, and the next
                // account or guest start wipes and clears again (the retry policy for accounts).
                state = state.copy(wipePending = true)
                continueAfterWipe(pending.after, completed = false)
            }
            pending is PendingGate.GuestId && output is AuthOutput.SaveGuestId ->
                // Round 7: a guest whose id is not on disk is not shown (the next launch would
                // not know it, and its data would reach the next account unwiped).
                leaveFailedGuestStart()
            pending is PendingGate.Owner && output is AuthOutput.PersistOwner -> {
                // Narrow check: a write that reported failure may still have reached the disk (a
                // setter fills the cache before the flush fails; a later flush persists it). So
                // what the disk holds is now unknown: the next identity wipes first and its owner
                // write is never skipped. Only a confirmed write (GatePassed) makes it known again.
                state = state.copy(owner = null, ownerUnknown = true)
                ownerGateFailed(pending.then)
            }
            else -> emit(AuthOutput.Drop("gate outcome $output does not match the pending gate $pending"))
        }
    }

    private fun ownerGateFailed(then: OwnerThen) {
        when (then) {
                // What the owner write was for is never shown.
                is OwnerThen.Accept -> {
                    acceptFailed(then.serial)
                    publishIfChanged(AuthState.Unauthenticated)
                }
                OwnerThen.ResetDone, OwnerThen.LostDone -> publishIfChanged(AuthState.Unauthenticated)
                is OwnerThen.GuestShow -> leaveFailedGuestStart()
                // The boot guest is already shown and owns its data; the next boot records it again.
                OwnerThen.BootGuest -> Unit
        }
    }

    /**
     * Records [userId] as the owner, then continues with [then]. If the stored owner already is
     * [userId] it continues at once; otherwise the write is a gate that ends this step, and the
     * owner changes in state only when [AuthEvent.GatePassed] confirms it.
     */
    private fun recordOwner(userId: String?, then: OwnerThen) {
        if (state.owner == userId && !state.ownerUnknown) {
            ownerConfirmed(then)
            return
        }
        state = state.copy(pendingGate = PendingGate.Owner(userId, then))
        emit(AuthOutput.PersistOwner(userId))
    }

    private fun ownerConfirmed(then: OwnerThen) {
        when (then) {
            is OwnerThen.Accept -> {
                val live = state.live
                val userId = (live as? Account)?.userId
                if (live is Account && live.serial == then.serial && userId != null) {
                    state = state.copy(noticePending = false, acceptedSerial = live.serial)
                    emit(AuthOutput.PersistNotice(false))
                    emit(AuthOutput.HideNotice)
                    publish(AuthState.Authenticated(userId = userId, email = live.email, isAnonymous = false))
                }
            }
            OwnerThen.ResetDone -> publish(AuthState.Unauthenticated)
            OwnerThen.LostDone -> publishIfChanged(AuthState.Unauthenticated)
            is OwnerThen.GuestShow -> showGuest(then.guestId)
            OwnerThen.BootGuest -> Unit
        }
    }

    /** The pre-accept wipe or owner write for [serial] failed: block it (rounds 3, 5, 6). */
    private fun acceptFailed(serial: Long) {
        val attempts = if (state.acceptBlockedSerial == serial) state.acceptAttempts + 1 else 1
        state = state.copy(acceptBlockedSerial = serial, acceptAttempts = attempts, acceptRetryArmed = false)
        emit(AuthOutput.Drop("accept attempt $attempts of $MAX_ACCEPT_ATTEMPTS failed for serial $serial"))
    }

    /** An account is about to be shown: wipe first when its data could be someone else's (AQ, r1-1, r1-5). */
    private fun accept(live: Account, userId: String) {
        // Round 5: a serial whose wipe or owner write failed is not accepted again in this run,
        // on any branch (wipe needed or not). Checked first, so a permanently failing write is
        // tried once per session and never re-emitted from the same reduction.
        if (state.acceptBlockedSerial == live.serial) {
            if (!state.acceptRetryArmed) return
            // Round 6: a retry re-armed by a later library status; consumed now.
            state = state.copy(acceptRetryArmed = false)
        }
        val needsWipe = state.wipePending ||
            (state.ownerUnknown && !live.restored) ||
            (state.owner != null && state.owner != userId)
        if (!needsWipe) {
            finishAccept(live, userId)
            return
        }
        startWipe(AfterWipe.Accept(live.serial), "account $userId replaces the previous local data")
    }

    private fun finishAccept(live: Account, userId: String) {
        recordOwner(userId, OwnerThen.Accept(live.serial))
    }

    private fun showGuest(guestId: String) {
        state = state.copy(pendingGate = PendingGate.GuestId(guestId))
        emit(AuthOutput.SaveGuestId(guestId))
    }

    private fun guestSaved(guestId: String) {
        // Decision R: choosing guest acknowledges the notice.
        emit(AuthOutput.PersistNotice(false))
        emit(AuthOutput.HideNotice)
        publish(AuthState.Authenticated(userId = guestId, email = null, isAnonymous = true))
    }

    fun apply(event: AuthEvent) {
        when (event) {
            is AuthEvent.Boot -> {
                val serial = mint()
                val boot = resolveBoot(event.guestId, event.owner)
                val guestId = boot.trustedGuestId
                state = state.copy(
                    live = if (guestId != null) Guest(serial, guestId) else Booting(serial),
                    owner = event.owner,
                    ownerUnknown = event.owner == null && event.ownerUnknown,
                    wipePending = event.wipePending,
                    noticePending = event.notice,
                    watchdogFired = false,
                    acceptBlockedSerial = null,
                    acceptAttempts = 0,
                    acceptRetryArmed = false,
                    afterWipe = null,
                    pendingGate = null,
                )
                clearCaches()
                // A saved guest id means the local data is that guest's: with no owner ever
                // recorded (an upgrading guest), record "no account owner" now, with no wipe. Only
                // "unknown owner, no guest id, no usable stored session" clears leftovers.
                publish(
                    if (guestId != null) AuthState.Authenticated(userId = guestId, email = null, isAnonymous = true)
                    else AuthState.Loading,
                )
                if (event.notice) emit(AuthOutput.ShowNotice)
                if (boot.clearStaleGuestId) {
                    emit(AuthOutput.Drop("boot: guest id ${event.guestId} is stale, account ${event.owner} owns the data"))
                    // Best-effort; if it fails the next boot decides the same way again.
                    emit(AuthOutput.ClearGuestId)
                }
                // Last, after the guest is shown: if this write fails the guest still stands and
                // the next boot records it again (r3-4; the guest is the saved one, its own data).
                if (guestId != null && state.ownerUnknown) recordOwner(null, OwnerThen.BootGuest)
            }

            is AuthEvent.WipeFinished -> wipeFinished(event.ok)

            is AuthEvent.PublishFailed -> state = state.copy(published = event.shown, pendingPublish = event.target)

            AuthEvent.RetryPendingPublish -> state.pendingPublish?.let { publish(it) }

            is AuthEvent.GatePassed -> gatePassed(event.output)

            is AuthEvent.GateFailed -> gateFailed(event.output)

            Snap.Initializing -> {
                // Fork rule: never re-enter Loading once the restore watchdog has fired.
                if (ProvisionalPublishRule.initializingShowsLoading(state.live is Guest, state.watchdogFired, state.pendingPublish)) {
                    publishIfChanged(AuthState.Loading)
                }
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
                // Decision Q: a restore still pending after the timeout shows Welcome. Fork (W2
                // review r6 #3): never over a failed identity publish still owed (its retries run).
                if (ProvisionalPublishRule.watchdogShowsWelcome(state.published, state.pendingPublish)) publish(AuthState.Unauthenticated)
            }

            is AuthEvent.ValidationFinished -> {
                val live = state.live
                if (live !is Account || event.ticket.serial != live.serial || state.validationInFlight != event.ticket.serial) {
                    emit(AuthOutput.Drop("stale validation verdict ${event.verdict} for serial ${event.ticket.serial}"))
                    return
                }
                val checkedToken = state.validationInFlightToken
                state = state.copy(validationInFlight = null, validationInFlightToken = null)
                // r2-3: an identity is resolved only by a Valid verdict that returns the user. Any
                // other verdict taken while it is unresolved never counts for it later.
                val unresolved = live.userId == null
                if (unresolved && event.verdict != SessionVerdict.Invalid && (event.verdict != SessionVerdict.Valid || event.verifiedUserId == null)) {
                    // r3-3: if the token rotated while this check ran, the current token is checked
                    // now (settle) instead of deferring until a status that was already consumed.
                    if (checkedToken == live.accessToken) state = state.copy(validationDeferredSerial = live.serial)
                    if (event.verdict == SessionVerdict.JwtExpired) emit(AuthOutput.KickSessionRefresh)
                    emit(AuthOutput.Drop("identity still unresolved after ${event.verdict}; validating again on the next status"))
                    return
                }
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
                // Best-effort (round 8): see resolveBoot.
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
                // r1-5 and r2-2: a newly chosen guest never inherits data it does not own. Wipe first
                // when an earlier wipe never completed, when no owner was ever recorded, or when a
                // recorded account owns the local data. (A guest id already saved at boot keeps its
                // data: see Boot.) An account session the library may still be restoring is ignored
                // while the guest is live (limit 2) and cleared by the guest's sign-out.
                if (state.wipePending || state.ownerUnknown || state.owner != null) {
                    startWipe(AfterWipe.GuestStart(event.guestId), "before guest ${event.guestId}")
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
                // r2-3: the identity is never filled from a snapshot; only a validation resolves it.
                // A new status for an unresolved session lets its validation run again.
                live = live.copy(
                    email = if (live.userId != null) snap.email ?: live.email else live.email,
                    accessToken = snap.accessToken,
                    refreshToken = snap.refreshToken,
                ),
                validationDeferredSerial = if (live.userId == null) null else state.validationDeferredSerial,
                // Round 6: a later status for a session whose accept failed re-arms one retry,
                // within the per-run bound. Never inside the failure's own chain (round 5).
                acceptRetryArmed = state.acceptRetryArmed ||
                    (state.acceptBlockedSerial == live.serial && state.acceptAttempts < MAX_ACCEPT_ATTEMPTS),
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
        // A gate or a wipe in progress decides what is shown next (GatePassed, WipeFinished).
        if (state.afterWipe != null || state.pendingGate != null) return
        val live = state.live as? Account ?: return
        if (state.acceptedSerial == live.serial) return
        if (state.validatedSerial == live.serial || state.trustedSerial == live.serial) {
            // r1-2: never publish, compare owners or wipe on an unresolved identity.
            val userId = live.userId ?: return
            accept(live, userId)
        } else if (state.validationInFlight == null && state.validationDeferredSerial != live.serial) {
            state = state.copy(validationInFlight = live.serial, validationInFlightToken = live.accessToken)
            emit(AuthOutput.StartValidation(AuthTicket(live.serial), live.accessToken))
        }
    }
}
