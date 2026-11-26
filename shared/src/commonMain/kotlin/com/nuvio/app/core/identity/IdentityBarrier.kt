package com.nuvio.app.core.identity

import co.touchlab.kermit.Logger
import com.nuvio.app.core.coroutines.uncaughtCoroutineLogger
import com.nuvio.app.core.profile.ActiveProfileProvider
import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.CoroutineDispatcher
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.CompletableDeferred
import kotlinx.coroutines.CoroutineStart
import kotlinx.coroutines.Job
import kotlinx.coroutines.channels.Channel
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.NonCancellable
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.currentCoroutineContext
import kotlinx.coroutines.delay
import kotlinx.coroutines.flow.first
import kotlinx.coroutines.isActive
import kotlinx.coroutines.launch
import kotlinx.coroutines.withContext
import kotlinx.coroutines.withTimeoutOrNull

/*
 * The barrier driver (fork-only): one lane serializes every drained transition. It feeds events
 * into BarrierModel (through IdentityRuntime) and executes the returned effects; it makes no
 * barrier decision of its own. Nothing calls it in W1.
 *
 * Design: docs/batch-scope-identity-spec.md, section 4.4 (revision 7).
 */

sealed interface TransitionResult {
    data class Done(val final: IdentityState) : TransitionResult
    /** Apply skipped: an auth window opened since the transition began. */
    data class Preempted(val final: IdentityState) : TransitionResult
    data class Failed(val error: String, val final: IdentityState) : TransitionResult
}

/**
 * The profile mutations the apply bodies run (W1 seam). `ProfileRepository.applySelection` and
 * `applyActiveRemoved` are W2's additions, so W1 cannot call them; W2 installs the real
 * implementation in [IdentityBarrier.profileOps].
 */
internal interface IdentityProfileOps {
    fun applySelection(slot: Int)
    fun applyActiveRemoved()
    /** Whether ProfileRepository.state still lists [slot] (SlotRemoved revalidation, 5.2). */
    fun isListed(slot: Int): Boolean
}

private object UninstalledProfileOps : IdentityProfileOps {
    override fun applySelection(slot: Int) = error("IdentityBarrier.profileOps not installed")
    override fun applyActiveRemoved() = error("IdentityBarrier.profileOps not installed")
    override fun isListed(slot: Int): Boolean = error("IdentityBarrier.profileOps not installed")
}

object IdentityBarrier {
    private val log = Logger.withTag("Identity")

    /** The lane's own scope: a cancelled caller stops waiting, the transition continues (P3). */
    private val scope: CoroutineScope =
        CoroutineScope(SupervisorJob() + Dispatchers.Default + uncaughtCoroutineLogger("IdentityBarrier"))

    /**
     * The lane (review r3-2): a FIFO queue, filled synchronously at call time, consumed by ONE
     * coroutine. Order is the order of the calls by construction, never the dispatcher's start order;
     * an accepted request runs whatever happens to its caller.
     */
    private val lane = Channel<Request>(Channel.UNLIMITED)

    private class Request(
        val kind: TransitionKind,
        val body: Body,
        /** The registered job marked awaiting at call time, unmarked when this request ends. */
        val marked: Job?,
        val done: CompletableDeferred<Outcome> = CompletableDeferred(),
    )

    /** The single lane coroutine; started by the first request. */
    private val consumer: Job = scope.launch(start = CoroutineStart.LAZY) {
        for (request in lane) process(request)
    }

    /**
     * One request, start to end, on the single lane coroutine. The awaiting marker is cleared in
     * this same finally, before the loop takes the next request (review r3-1): the next drain on the
     * lane always counts the job again.
     */
    private suspend fun process(request: Request) {
        try {
            request.done.complete(execute(request.kind, request.body))
        } catch (t: Throwable) {
            if (t is CancellationException && !currentCoroutineContext().isActive) {
                request.done.cancel()
                throw t
            }
            log.e(t) { "[Identity] ${request.kind} threw out of the lane" }
            request.done.completeExceptionally(t)
        } finally {
            request.marked?.let(IdentityWork::unmarkAwaitingBarrier)
        }
    }
    internal var applyDispatcher: CoroutineDispatcher = Dispatchers.Main

    /** Decision F. Also bounds the wait for an open window before Begin and before the result. */
    internal var drainDeadlineMs: Long = 2_000
    internal var debugHoldMs: () -> Long = { 0 }
    internal var profileOps: IdentityProfileOps = UninstalledProfileOps

    /** Tests only: runs on the apply dispatcher after DrainEnded and before the apply lock. */
    internal var beforeApplyLock: () -> Unit = {}

    suspend fun selectProfile(slot: Int): TransitionResult {
        // The account token (account AND auth serial) the select was requested under. A select
        // queued behind an account change or a same-account session replacement (a window that
        // ended before its Begin, so B6 cannot see it) must not switch the new session's slot:
        // rechecked under the apply lock against the full token (review r2-5). Nothing applied →
        // Preempted (revision 9).
        val requestedUnder = IdentityLocks.withCommit {
            AccountToken(IdentityRuntime.snapshot().latestAccount, IdentityRuntime.authSerial())
        }
        return run(
            TransitionKind.ProfileSelect,
            Body.Profile {
                val stillApplies = IdentityLocks.withCommit {
                    IdentityRuntime.snapshot().latestAccount == requestedUnder.account &&
                        IdentityRuntime.authSerial() == requestedUnder.authSerial
                }
                if (!stillApplies) {
                    log.i { "[Identity] select of slot $slot: session changed while queued, nothing applied" }
                    return@Profile false
                }
                profileOps.applySelection(slot)
                true
            },
        ).result
    }

    /** After a successful server delete (or the guest filter) of the ACTIVE profile: select [nextSlot], or show the picker if null. */
    suspend fun deleteActiveProfile(slot: Int, nextSlot: Int?, token: AccountToken): TransitionResult =
        run(
            TransitionKind.ActiveProfileDelete,
            Body.Profile {
                // Under the apply lock, in one commit read (5.3 step 4, revision 8): the account
                // token holds AND the deleted slot is still the active one. A select that ran while
                // this delete waited makes it a no-op (Done, nothing applied).
                val stillApplies = IdentityLocks.withCommit {
                    IdentityGate.decideAccountLocked(token) == Verdict.Commit && IdentityRuntime.activeSlot() == slot
                }
                if (!stillApplies) {
                    log.i { "[Identity] active delete of slot $slot: account changed or slot no longer active, nothing applied" }
                    return@Profile true // a no-op delete is Done (5.3 step 4)
                }
                if (nextSlot != null) profileOps.applySelection(nextSlot) else profileOps.applyActiveRemoved()
                true
            },
        ).result

    /** Fire-and-forget; revalidated at apply (5.2). */
    fun requestSlotRemoved(slot: Int, token: AccountToken) {
        // Enqueued now, in call order (no launch); not awaited.
        enqueue(
                TransitionKind.SlotRemoved,
                Body.Profile {
                    val still = IdentityGate.commitAccount(token, "slotRemoved") {
                        !profileOps.isListed(slot) && IdentityRuntime.activeSlot() == slot
                    }
                    if (still is CommitResult.Committed && still.value) {
                        profileOps.applyActiveRemoved()
                    } else {
                        log.i { "[Identity] slot removed: no longer applies, nothing applied" }
                    }
                    true // a no-op slot removal is Done (5.2 step 3)
                },
                marked = null,
            )
    }

    /** Never refuses; returns [block]'s result (a thrown error as a failure). */
    suspend fun accountReset(kind: TransitionKind, block: suspend () -> Result<Unit>): Result<Unit> {
        if (!kind.isAccountKind) return Result.failure(IllegalArgumentException("accountReset with $kind"))
        val outcome = run(kind, Body.Account(block))
        return outcome.accountResult ?: Result.failure(IllegalStateException((outcome.result as? TransitionResult.Failed)?.error ?: "no result"))
    }

    /**
     * Swift reports that the shell and the root deep-link cover unmounted after the revoke of
     * [transitionId] (the `IdentityState.transitionId` it was revoked with; 4.6, revision 8).
     */
    fun teardownDone(transitionId: Long) {
        IdentityWork.recordTeardown(transitionId)
    }

    private sealed interface Body {
        /** Returns false when the body applied nothing and the result is Preempted (a queued select, revision 9). */
        fun interface Profile : Body { fun apply(): Boolean }
        class Account(val block: suspend () -> Result<Unit>) : Body
    }

    private class Outcome(val result: TransitionResult, val accountResult: Result<Unit>? = null)

    private suspend fun run(kind: TransitionKind, body: Body): Outcome {
        // A registered job (or a child/withContext of one: the element names the registered job,
        // review r2-3) that awaits a transition is not waited for by drains while it waits: marked
        // here, at call time, and unmarked by the lane when this request ends (process's finally).
        val marked = currentCoroutineContext()[IdentityJobElement]?.let(IdentityWork::markAwaitingBarrier)
        // Mark and enqueue are both non-suspending: no cancellation point between them.
        return enqueue(kind, body, marked).await()
    }

    /** Synchronous: the request is accepted (its place in the FIFO taken) before this returns. */
    private fun enqueue(kind: TransitionKind, body: Body, marked: Job?): CompletableDeferred<Outcome> {
        val request = Request(kind, body, marked)
        val sent = lane.trySend(request).isSuccess
        consumer.start()
        if (!sent) {
            // Unlimited and never closed: cannot happen. Fail the request without leaking the mark.
            marked?.let(IdentityWork::unmarkAwaitingBarrier)
            request.done.completeExceptionally(IllegalStateException("identity lane closed"))
        }
        return request.done
    }

    private suspend fun execute(kind: TransitionKind, body: Body): Outcome {
        var began = false
        var finished = false
        try {
            val begin = begin(kind) ?: return Outcome(
                TransitionResult.Failed("an auth window stayed open", IdentityRuntime.state.value),
            )
            began = true
            val epoch = begin.state.epoch
            val transitionId = begin.state.drained!!.transitionId
            val ok = IdentityEffects.run(begin)

            // Revision 7: a profile kind whose revoke failed skips the drain. Revision 8: the
            // drain's end is decided and reduced by IdentityWork in one section (4.3a).
            val drained = if (kind.isProfileKind && !ok) {
                IdentityWork.endDrainUnconfirmed(transitionId)
            } else {
                val hold = debugHoldMs()
                if (hold > 0) delay(hold)
                IdentityWork.awaitDrained(epoch, transitionId, drainDeadlineMs, teardownRequired = ok && IdentityRevocation.required)
            }
            IdentityEffects.run(drained)
            val effects = drained.effects
            when {
                BarrierEffect.EndPreempted in effects -> {
                    finished = true
                    return Outcome(TransitionResult.Preempted(awaitFinal()))
                }
                BarrierEffect.EndFailed in effects -> {
                    finished = true
                    return Outcome(TransitionResult.Failed("teardown unconfirmed", awaitFinal()))
                }
                BarrierEffect.RunApply !in effects -> {
                    log.e { "[Identity] $kind: no apply after its drain ended (transition $transitionId)" }
                    return Outcome(TransitionResult.Failed("out of order after the drain", IdentityRuntime.state.value))
                }
            }

            return when (body) {
                is Body.Profile -> {
                    val applied = applyProfile(body)
                    finished = true
                    val final = awaitFinal()
                    Outcome(
                        when (applied) {
                            null -> TransitionResult.Done(final)
                            PREEMPTED -> TransitionResult.Preempted(final)
                            else -> TransitionResult.Failed(applied, final)
                        },
                    )
                }
                is Body.Account -> {
                    val result = try {
                        body.block()
                    } catch (t: Throwable) {
                        if (t is CancellationException && !currentCoroutineContext().isActive) throw t
                        Result.failure(t)
                    }
                    val end = result.exceptionOrNull()?.let {
                        BarrierEvent.ApplyThrew(SLOT_UNSET, it.message ?: it::class.simpleName ?: "error")
                    } ?: BarrierEvent.ApplyFinished(SLOT_UNSET)
                    IdentityEffects.run(IdentityRuntime.reduceStep(end))
                    finished = true
                    Outcome(TransitionResult.Done(awaitFinal()), result)
                }
            }
        } finally {
            if (began && !finished) {
                withContext(NonCancellable) {
                    IdentityEffects.run(IdentityRuntime.reduceStep(BarrierEvent.Abandoned(SLOT_UNSET)))
                }
            }
        }
    }

    /** Waits (bounded) for no window, then Begin. Profile kinds give up at the deadline; account kinds keep waiting. */
    private suspend fun begin(kind: TransitionKind): Reduced? {
        var waited = 0L
        while (true) {
            val open = withTimeoutOrNull(drainDeadlineMs) {
                IdentityRuntime.state.first { it.phase is IdentityPhase.Open }
            }
            if (open != null) {
                val step = IdentityWork.beginTransition(kind)
                if (step.state.drained?.kind == kind && step.effects.any { it is BarrierEffect.AwaitDrain }) return step
                IdentityEffects.run(step) // B13: a window opened in between; wait again
                continue
            }
            waited += drainDeadlineMs
            if (kind.isProfileKind) {
                log.e { "[Identity] $kind: an auth window stayed open ${waited} ms, not started" }
                return null
            }
            log.e { "[Identity] $kind: an auth window still open after ${waited} ms, waiting" }
        }
    }

    /** Runs a profile apply body; null = applied, [PREEMPTED], or the error. */
    private suspend fun applyProfile(body: Body.Profile): String? = withContext(applyDispatcher) {
        beforeApplyLock()
        IdentityLocks.withApply {
            val gate = IdentityRuntime.reduceStep(BarrierEvent.ApplyGate())
            IdentityEffects.run(gate)
            when {
                BarrierEffect.Proceed in gate.effects -> try {
                    val applied = ActiveProfileProvider.changing { body.apply() }
                    IdentityEffects.run(IdentityRuntime.reduceStep(BarrierEvent.ApplyFinished(SLOT_UNSET)))
                    if (applied) null else PREEMPTED
                } catch (t: Throwable) {
                    val error = t.message ?: t::class.simpleName ?: "error"
                    IdentityEffects.run(IdentityRuntime.reduceStep(BarrierEvent.ApplyThrew(SLOT_UNSET, error)))
                    error
                }
                BarrierEffect.EndPreempted in gate.effects -> PREEMPTED
                else -> {
                    // Out of order: release the hold (B9).
                    IdentityEffects.run(IdentityRuntime.reduceStep(BarrierEvent.Abandoned(SLOT_UNSET)))
                    "out of order at ApplyGate"
                }
            }
        }
    }

    /** The state once both holds are released (a window still open is awaited, bounded). */
    private suspend fun awaitFinal(): IdentityState =
        withTimeoutOrNull(drainDeadlineMs) { IdentityRuntime.state.first { it.phase is IdentityPhase.Open } }
            ?: IdentityRuntime.state.value

    private const val PREEMPTED = "\u0000preempted"

    /** Tests only. */
    internal fun resetForTest() {
        drainDeadlineMs = 2_000
        debugHoldMs = { 0 }
        profileOps = UninstalledProfileOps
        beforeApplyLock = {}
        applyDispatcher = Dispatchers.Default
    }
}
