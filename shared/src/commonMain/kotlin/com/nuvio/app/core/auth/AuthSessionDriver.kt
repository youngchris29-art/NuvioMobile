package com.nuvio.app.core.auth

import io.github.jan.supabase.auth.status.SessionSource
import io.github.jan.supabase.auth.status.SessionStatus
import kotlin.concurrent.Volatile
import kotlin.time.Duration
import kotlin.time.Duration.Companion.seconds
import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.CoroutineStart
import kotlinx.coroutines.Job
import kotlinx.coroutines.NonCancellable
import kotlinx.coroutines.cancelAndJoin
import kotlinx.coroutines.delay
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.launch
import kotlinx.coroutines.sync.Mutex
import kotlinx.coroutines.sync.withLock
import kotlinx.coroutines.withContext

/*
 * The session driver: one lane (a coroutine Mutex) around every reducer step, every library
 * mutation the app issues and every user-started session start or reset. It feeds events into
 * [reduce] and executes the returned outputs in order; it makes no session decision of its own.
 *
 * Design: docs/batch-upstream-ports-spec-auth.md, section 3f.
 */

/**
 * Everything the driver does to the outside world. One body per reducer output, plus the
 * user-started library calls that run inside the lane. Implemented for real in AuthRepository and
 * by a recording fake in AuthSessionDriverTest.
 */
internal interface AuthEffects {
    fun publish(state: AuthState)
    /** Throws when the owner could not be durably written (a gate, r3-4). */
    fun persistOwner(userId: String?)
    fun persistNotice(pending: Boolean)

    /** Throws when the marker could not be durably written (a gate when set, r3-4). */
    fun persistWipePending(pending: Boolean)
    fun showNotice()
    fun hideNotice()
    fun saveGuestId(guestId: String)
    fun clearGuestId()
    fun wipeAccountData()
    suspend fun clearSupabaseSession()

    /** Restarts the library's own session job for the live session; never a refresh by the app (I5). */
    suspend fun kickSessionRefresh()

    /**
     * Asks the server who [accessToken] belongs to and returns that user's id (null if the answer
     * carried none); throws on any failure (classified by the driver).
     */
    suspend fun checkUser(accessToken: String): String?
    fun log(message: String)

    // User-started library calls, run inside the lane.
    suspend fun signInWithEmail(email: String, password: String)
    suspend fun signUpWithEmail(email: String, password: String)
    suspend fun signOutRemote()
    suspend fun deleteAccountRemote()
    suspend fun importTvLoginTokens(accessToken: String, refreshToken: String)
    suspend fun ensureTvLoginScaffold()
}

/** What a [AuthSessionDriver.Lane.send] did: `cleared` for a session error, the first output failure. */
internal data class Sent(val cleared: Boolean, val failure: Throwable?)

/** A library status as the reducer's snapshot event. */
internal fun snapshotOf(status: SessionStatus): Snap = when (status) {
    is SessionStatus.Initializing -> Snap.Initializing
    is SessionStatus.RefreshFailure -> Snap.RefreshFailure
    is SessionStatus.NotAuthenticated -> Snap.NotAuthenticated(cleared = status.isSignOut)
    is SessionStatus.Authenticated -> {
        val user = status.session.user
        if (user?.isAnonymous == true) {
            Snap.Scaffold
        } else {
            Snap.Account(
                // r1-2: a session without a user has an unresolved identity, never "".
                userId = user?.id?.takeIf { it.isNotBlank() },
                email = user?.email,
                accessToken = status.session.accessToken,
                refreshToken = status.session.refreshToken,
                refreshedFrom = (status.source as? SessionSource.Refresh)?.oldSession?.refreshToken,
                restored = status.source is SessionSource.Storage || status.source is SessionSource.Refresh,
            )
        }
    }
}

/** Upstream's validation classifier: expired JWT, invalid session, anything else unreachable. */
internal fun Throwable.validationVerdict(): SessionVerdict = when {
    isJwtExpiredError() -> SessionVerdict.JwtExpired
    isInvalidSessionError() -> SessionVerdict.Invalid
    else -> SessionVerdict.Unreachable
}

/** Upstream's sync classifier (daa966d36). */
internal fun Throwable.sessionErrorKind(): SessionErrorKind = when {
    isJwtExpiredError() -> SessionErrorKind.JwtExpired
    isDeletedAccountError() -> SessionErrorKind.DeletedAccount
    else -> SessionErrorKind.Other
}

internal class AuthSessionDriver(
    private val effects: AuthEffects,
    private val scope: CoroutineScope,
    private val restoreTimeout: Duration = 10.seconds,
) {
    private val lane = Mutex()

    /** Read and written only under [lane]. */
    private var state: AuthModelState = AuthModelState.Initial

    /** Written under [lane], read lock-free by callers taking a ticket before their request. */
    @Volatile
    private var ticket: AuthTicket = AuthTicket(AuthModelState.Initial.live.serial)

    private var collectorJob: Job? = null

    /** The flow the collector watches, and the status value last fed to the reducer (lane only). */
    private var statusFlow: StateFlow<SessionStatus>? = null
    private var lastFed: SessionStatus? = null
    private var watchdogJob: Job? = null

    fun currentTicket(): AuthTicket = ticket

    /** For tests: the model state after the last step. */
    internal val modelStateForTest: AuthModelState get() = state

    /**
     * First start. Boot is reduced before this returns: the lane is free at launch, and an
     * undispatched start runs the step on the caller's thread (so a stored guest shows at once).
     */
    fun start(boot: AuthEvent.Boot, status: () -> StateFlow<SessionStatus>, collectDelay: Duration? = null) {
        scope.launch(start = CoroutineStart.UNDISPATCHED) { lane.withLock { step(boot) } }
        launchWatchers(status, collectDelay)
    }

    /** Server switch: drop the collector and watchdog of the old client, Boot again, watch the new one. */
    suspend fun restart(boot: AuthEvent.Boot, status: () -> StateFlow<SessionStatus>, collectDelay: Duration? = null) {
        collectorJob?.cancelAndJoin()
        watchdogJob?.cancelAndJoin()
        lane.withLock {
            statusFlow = null
            lastFed = null
            step(boot)
        }
        launchWatchers(status, collectDelay)
    }

    private fun launchWatchers(status: () -> StateFlow<SessionStatus>, collectDelay: Duration?) {
        watchdogJob = scope.launch {
            delay(restoreTimeout)
            lane.withLock { step(AuthEvent.WatchdogFired) }
        }
        collectorJob = scope.launch {
            if (collectDelay != null) {
                effects.log("debug.authRestoreStallSeconds active: delaying session-status collection by $collectDelay")
                delay(collectDelay)
            }
            val flow = status()
            lane.withLock { statusFlow = flow }
            // Snapshot rule: the emission only wakes the collector; the status reduced is the one
            // live when the lane is held, so a superseded status is never acted on.
            flow.collect { lane.withLock { feed(flow.value) } }
        }
    }

    /** A user-started start or reset. The block's [Lane.send] reduces without re-locking. */
    suspend fun <T> exclusive(block: suspend Lane.() -> T): T = lane.withLock {
        val held = Lane()
        try {
            held.block()
        } finally {
            // A reset that started always finishes, so a cancelled sign-out still publishes.
            val open = held.openReset
            if (open != null) withContext(NonCancellable) { held.send(AuthEvent.ResetFinished(open)) }
        }
    }

    /**
     * Non-suspending callers (guest): runs at once when the lane is free (undispatched), else
     * queues behind the holder.
     */
    fun launchExclusive(block: suspend Lane.() -> Unit): Job =
        scope.launch(start = CoroutineStart.UNDISPATCHED) { exclusive(block) }

    suspend fun reportSessionError(ticket: AuthTicket, kind: SessionErrorKind): Boolean =
        lane.withLock {
            reconcile()
            step(AuthEvent.SessionErrorReported(ticket, kind)).cleared
        }

    inner class Lane internal constructor() {
        internal var openReset: ResetKind? = null
            private set

        /** Which library call a sign-out makes (a guest has no remote session to end). */
        val liveIsGuest: Boolean get() = state.live is Guest

        suspend fun send(event: AuthEvent): Sent {
            when (event) {
                is AuthEvent.ResetStarted -> openReset = event.kind
                is AuthEvent.ResetFinished -> openReset = null
                else -> Unit
            }
            return step(event)
        }

        /**
         * Brackets one session-start library call; identity still comes only from snapshots. The
         * library emits the new session inside the call, so the live status is fed before the lane
         * is released (r1-3): the previous session's ticket is retired in this hold, and a verdict
         * queued behind it can no longer match.
         */
        suspend fun sessionStart(kind: SessionStartKind, call: suspend () -> Unit) {
            send(AuthEvent.SessionStartStarted(kind))
            val result = attempt(call)
            withContext(NonCancellable) {
                reconcile()
                send(AuthEvent.SessionStartFinished(kind, result.isSuccess))
            }
            result.getOrThrow()
        }
    }

    // ── User-started commands. No exception but CancellationException leaves them (I10). ────────

    suspend fun signInWithEmail(email: String, password: String): Result<Unit> = command {
        exclusive { sessionStart(SessionStartKind.Email) { effects.signInWithEmail(email, password) } }
    }

    suspend fun signUpWithEmail(email: String, password: String): Result<Unit> = command {
        exclusive { sessionStart(SessionStartKind.SignUp) { effects.signUpWithEmail(email, password) } }
    }

    suspend fun importTvLoginTokens(accessToken: String, refreshToken: String): Result<Unit> = command {
        exclusive { sessionStart(SessionStartKind.Qr) { effects.importTvLoginTokens(accessToken, refreshToken) } }
    }

    suspend fun ensureTvLoginScaffold(): Result<Unit> = command {
        exclusive { sessionStart(SessionStartKind.Qr) { effects.ensureTvLoginScaffold() } }
    }

    suspend fun signOut(): Result<Unit> = command {
        exclusive {
            val guest = liveIsGuest
            send(AuthEvent.ResetStarted(ResetKind.SignOut))
            val remote = if (guest) null else attempt { effects.signOutRemote() }
            // B6: the fallback local clear; a guest always clears any stale library session. It
            // runs with the rest of the reset, non-cancellable (r1-4): a cancelled sign-out must
            // not wipe and publish signed-out while the session is still stored.
            val (fallback, finished) = withContext(NonCancellable) {
                val clear = if (remote == null || remote.isFailure) attempt { effects.clearSupabaseSession() } else null
                clear to send(AuthEvent.ResetFinished(ResetKind.SignOut))
            }
            // A guest's local clear is best-effort (it had no session to end); only its
            // cancellation is passed on.
            val fallbackFailure = fallback?.exceptionOrNull()?.takeIf { remote != null || it is CancellationException }
            throwFirst(remote?.exceptionOrNull(), fallbackFailure, finished.failure)
        }
    }

    suspend fun deleteAccount(): Result<Unit> = command {
        exclusive {
            // A failed delete request resets nothing.
            effects.deleteAccountRemote()
            send(AuthEvent.ResetStarted(ResetKind.DeleteAccount))
            val remote = attempt { effects.signOutRemote() }
            val (fallback, finished) = withContext(NonCancellable) {
                val clear = if (remote.isFailure) attempt { effects.clearSupabaseSession() } else null
                clear to send(AuthEvent.ResetFinished(ResetKind.DeleteAccount))
            }
            throwFirst(remote.exceptionOrNull(), fallback?.exceptionOrNull(), finished.failure)
        }
    }

    suspend fun prepareForServerSwitch(): Result<Unit> = command {
        exclusive {
            send(AuthEvent.ResetStarted(ResetKind.ServerSwitch))
            val (clear, finished) = withContext(NonCancellable) {
                attempt { effects.clearSupabaseSession() } to send(AuthEvent.ResetFinished(ResetKind.ServerSwitch))
            }
            throwFirst(clear.exceptionOrNull(), finished.failure)
        }
    }

    fun chooseGuest(guestId: String): Job = launchExclusive { send(AuthEvent.GuestChosen(guestId)) }

    // ── Steps ────────────────────────────────────────────────────────────────────────────────────

    /** Feeds a status value to the reducer and remembers it as observed. */
    private suspend fun feed(status: SessionStatus): Sent {
        lastFed = status
        return step(snapshotOf(status))
    }

    /**
     * Under the lane, before an event that carries a ticket or closes a session start: feed the
     * live status if the collector has not reduced it yet (r1-3). Plumbing only; the reducer decides.
     */
    private suspend fun reconcile() {
        val flow = statusFlow ?: return
        val current = flow.value
        if (current !== lastFed) feed(current)
    }

    private suspend fun step(event: AuthEvent): Sent {
        val result = reduce(state, event)
        state = result.state
        ticket = AuthTicket(result.state.live.serial)
        var failure: Throwable? = null
        var wipeRan = false
        var wipeOk = true
        var gate: AuthOutput? = null
        var gateOk = true
        withContext(NonCancellable) {
            for (output in result.outputs) {
                if (output.isGate) gate = output
                if (output == AuthOutput.WipeAccountData) wipeRan = true
                try {
                    run(output)
                } catch (e: Throwable) {
                    // I3: a failing output never skips the ones after it. A gate is always the
                    // step's last output (the reducer guarantees it), so nothing follows it here.
                    effects.log("Auth output $output failed: $e")
                    if (output == AuthOutput.WipeAccountData) wipeOk = false
                    if (output.isGate) gateOk = false
                    if (failure == null) failure = e
                }
            }
        }
        // r1-5 and round 4: a gate's or a wipe's outcome goes back to the reducer, which decides
        // what follows it.
        val gateOutput = gate
        val followUp = when {
            gateOutput != null -> if (gateOk) AuthEvent.GatePassed(gateOutput) else AuthEvent.GateFailed(gateOutput)
            wipeRan -> AuthEvent.WipeFinished(wipeOk)
            else -> null
        }
        if (followUp != null) {
            val next = step(followUp)
            if (failure == null) failure = next.failure
        }
        return Sent(result.cleared, failure)
    }

    private suspend fun run(output: AuthOutput) {
        when (output) {
            is AuthOutput.Publish -> effects.publish(output.state)
            is AuthOutput.PersistOwner -> effects.persistOwner(output.userId)
            is AuthOutput.PersistNotice -> effects.persistNotice(output.pending)
            is AuthOutput.PersistWipePending -> effects.persistWipePending(output.pending)
            AuthOutput.ShowNotice -> effects.showNotice()
            AuthOutput.HideNotice -> effects.hideNotice()
            is AuthOutput.SaveGuestId -> effects.saveGuestId(output.guestId)
            AuthOutput.ClearGuestId -> effects.clearGuestId()
            AuthOutput.WipeAccountData -> effects.wipeAccountData()
            AuthOutput.ClearSupabaseSession -> effects.clearSupabaseSession()
            AuthOutput.KickSessionRefresh -> effects.kickSessionRefresh()
            is AuthOutput.StartValidation -> launchValidation(output.ticket, output.accessToken)
            is AuthOutput.Drop -> effects.log(output.reason)
        }
    }

    /** Outside the lane: only the verdict is reduced under it. */
    private fun launchValidation(ticket: AuthTicket, accessToken: String) {
        scope.launch {
            var verifiedUserId: String? = null
            val verdict = try {
                verifiedUserId = effects.checkUser(accessToken)
                SessionVerdict.Valid
            } catch (e: CancellationException) {
                throw e
            } catch (e: Throwable) {
                e.validationVerdict().also { effects.log("Session validation for serial ${ticket.serial}: $it ($e)") }
            }
            lane.withLock {
                // r1-3: a session started while this verdict queued is observed first.
                reconcile()
                step(AuthEvent.ValidationFinished(ticket, verdict, verifiedUserId))
            }
        }
    }
}

/** Runs [call], keeping its failure (CancellationException included) instead of throwing it. */
private suspend fun attempt(call: suspend () -> Unit): Result<Unit> =
    try {
        call()
        Result.success(Unit)
    } catch (e: Throwable) {
        Result.failure(e)
    }

/** A cancellation among the failures wins, so the caller's cancellation still propagates. */
private fun throwFirst(vararg failures: Throwable?) {
    val present = failures.filterNotNull()
    present.firstOrNull { it is CancellationException }?.let { throw it }
    present.firstOrNull()?.let { throw it }
}

/** I10: every exported suspend call turns any non-cancellation failure into a Result. */
private suspend fun command(block: suspend () -> Unit): Result<Unit> =
    try {
        block()
        Result.success(Unit)
    } catch (e: CancellationException) {
        throw e
    } catch (e: Throwable) {
        Result.failure(e)
    }
