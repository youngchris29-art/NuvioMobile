package com.nuvio.app.core.identity

import co.touchlab.kermit.Logger
import com.nuvio.app.core.build.AppBuildConfig
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
import kotlin.coroutines.AbstractCoroutineContextElement
import kotlin.coroutines.CoroutineContext

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

    /**
     * Revision 10, rule A: requested from inside registered work; enqueued in call order and not
     * awaited. The requesting job is drained and cancelled like any other job.
     */
    data object Requested : TransitionResult
}

/**
 * Rule A, source 2 (revision 11): the lane consumer runs every request inside this element, so an
 * apply body, an account block and any `withContext` inside them carry it; a barrier request made
 * there is enqueued and not awaited (the lane cannot wait on itself).
 */
internal class IdentityLaneElement : AbstractCoroutineContextElement(Key) {
    companion object Key : CoroutineContext.Key<IdentityLaneElement>
}

/** `accountReset` requested where it must not await (rule A): enqueued, not awaited. */
class TransitionNotAwaited(kind: TransitionKind) :
    IllegalStateException("$kind requested from registered work: enqueued, not awaited")

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
        /** Rule E: the pending removal a SlotRemoved request was scheduled for. */
        val removal: PendingRemoval? = null,
        val done: CompletableDeferred<Outcome> = CompletableDeferred(),
    )

    /** The single lane coroutine; started by the first request. */
    private val consumer: Job = scope.launch(start = CoroutineStart.LAZY) {
        for (request in lane) process(request)
    }

    /** One request, start to end, on the single lane coroutine. */
    private suspend fun process(request: Request) {
        try {
            if (request.removal != null) IdentityLocks.withCommit { if (queuedRemoval == request.removal) queuedRemoval = null }
            request.done.complete(withContext(IdentityLaneElement()) { execute(request.kind, request.body, request.removal) })
        } catch (t: Throwable) {
            if (t is CancellationException && !currentCoroutineContext().isActive) {
                request.done.cancel()
                throw t
            }
            log.e(t) { "[Identity] ${request.kind} threw out of the lane" }
            request.done.completeExceptionally(t)
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
                    return@Profile ProfileApply.NothingPreempted
                }
                profileOps.applySelection(slot)
                ProfileApply.Applied
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
                    return@Profile ProfileApply.NothingDone // a no-op delete is Done (5.3 step 4)
                }
                if (nextSlot != null) profileOps.applySelection(nextSlot) else profileOps.applyActiveRemoved()
                ProfileApply.Applied
            },
        ).result

    /**
     * Fire-and-forget (rule E): the barrier model records the removal (B23) and schedules it at the
     * tail of the lane at the first Open where it can still apply; revalidated at apply (5.2).
     */
    fun requestSlotRemoved(slot: Int, token: AccountToken) {
        checkNotInCompletionHandler()
        IdentityEffects.run(IdentityRuntime.reduceStep(BarrierEvent.SlotRemovalRequested(slot, token)))
    }

    /** The removal last enqueued and not yet taken by the lane (dedupe; under the commit lock). */
    private var queuedRemoval: PendingRemoval? = null

    /** Rule E's ScheduleSlotRemoval effect: one request at the tail of the lane, not twice for the same removal. */
    internal fun scheduleSlotRemoval(removal: PendingRemoval) {
        val fresh = IdentityLocks.withCommit {
            if (queuedRemoval == removal) false else { queuedRemoval = removal; true }
        }
        if (!fresh) return
        val token = AccountToken(removal.account, removal.serial)
        enqueue(
            TransitionKind.SlotRemoved,
            Body.Profile {
                val still = IdentityGate.commitAccount(token, "slotRemoved") {
                    !profileOps.isListed(removal.slot) && IdentityRuntime.activeSlot() == removal.slot
                }
                if (still is CommitResult.Committed && still.value) {
                    profileOps.applyActiveRemoved()
                    ProfileApply.Applied
                } else {
                    log.i { "[Identity] slot removed: no longer applies, nothing applied" }
                    ProfileApply.NothingDone // a no-op slot removal is Done (5.2 step 3)
                }
            },
            removal,
        )
    }

    /** Rule F: the DEBUG check also covers the barrier entry points (no barrier call from a completion handler). */
    private fun checkNotInCompletionHandler() {
        if (IdentityLocks.strictLockOrder && IdentityThreadDepth.handler() > 0) {
            error("[Identity] barrier request from a completion handler (rule F)")
        }
    }

    /** Never refuses; returns [block]'s result (a thrown error as a failure). */
    suspend fun accountReset(kind: TransitionKind, block: suspend () -> Result<Unit>): Result<Unit> {
        if (!kind.isAccountKind) return Result.failure(IllegalArgumentException("accountReset with $kind"))
        val outcome = run(kind, Body.Account(block))
        if (outcome.result == TransitionResult.Requested) return Result.failure(TransitionNotAwaited(kind))
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
        fun interface Profile : Body { fun apply(): ProfileApply }
        class Account(val block: suspend () -> Result<Unit>) : Body
    }

    /** What a profile body did: only [Applied] clears FailedApply (B7). */
    private enum class ProfileApply {
        Applied,
        /** Nothing applied; the result is Done (a no-op delete or slot removal). */
        NothingDone,
        /** Nothing applied; the result is Preempted (a queued select whose session changed, revision 9). */
        NothingPreempted,
    }

    private class Outcome(val result: TransitionResult, val accountResult: Result<Unit>? = null)

    private suspend fun run(kind: TransitionKind, body: Body): Outcome {
        checkNotInCompletionHandler()
        // Enqueued first, exactly once, before any suspension point (a caller cancelled at the
        // await below leaves its request accepted).
        val done = enqueue(kind, body)
        val source = mustNotAwait(currentCoroutineContext())
        if (source != null) {
            if (source != NotAwaitedSource.RegisteredWork && AppBuildConfig.IS_DEBUG_BUILD) {
                log.e { "[Identity] $kind requested from the ${source.name} (not awaited): move the code after it into the block" }
            }
            return Outcome(TransitionResult.Requested)
        }
        return done.await()
    }

    internal enum class NotAwaitedSource { RegisteredWork, LaneBody, WindowBody }

    /**
     * Rule A, the one "must not await" predicate (revision 11): registered work (source 1), a lane
     * body (source 2), or this thread inside a synchronous window body (source 3, per thread).
     * Null for an ordinary caller: Swift on main, no element, not in a window body.
     */
    internal fun mustNotAwait(context: CoroutineContext): NotAwaitedSource? = when {
        context[IdentityJobElement] != null -> NotAwaitedSource.RegisteredWork
        context[IdentityLaneElement] != null -> NotAwaitedSource.LaneBody
        IdentityLocks.windowBodyDepth > 0 -> NotAwaitedSource.WindowBody
        else -> null
    }

    /** Synchronous: the request is accepted (its place in the FIFO taken) before this returns. */
    private fun enqueue(kind: TransitionKind, body: Body, removal: PendingRemoval? = null): CompletableDeferred<Outcome> {
        val request = Request(kind, body, removal)
        val sent = lane.trySend(request).isSuccess
        consumer.start()
        if (!sent) request.done.completeExceptionally(IllegalStateException("identity lane closed")) // unlimited, never closed
        return request.done
    }

    private suspend fun execute(kind: TransitionKind, body: Body, removal: PendingRemoval? = null): Outcome {
        var began = false
        var finished = false
        try {
            // Rule E: a scheduled removal that is no longer the pending one (overwritten by a newer
            // request, or dropped on an identity change) runs nothing.
            if (removal != null && IdentityRuntime.snapshot().pendingRemoval != removal) {
                return Outcome(TransitionResult.Done(IdentityRuntime.state.value))
            }
            val begin = when (val b = begin(kind, removal)) {
                is BeginOutcome.Began -> b.step
                is BeginOutcome.Refused -> return Outcome(TransitionResult.Failed(b.why, IdentityRuntime.state.value))
            }
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

    private sealed interface BeginOutcome {
        class Began(val step: Reduced) : BeginOutcome
        class Refused(val why: String) : BeginOutcome
    }

    /**
     * Waits (bounded) for no window and no drained op (Open or Recovery), then Begin. B20: a
     * profile kind is refused in Recovery. Profile kinds give up at the deadline; account kinds
     * keep waiting.
     */
    private suspend fun begin(kind: TransitionKind, removal: PendingRemoval?): BeginOutcome {
        var waited = 0L
        while (true) {
            val free = withTimeoutOrNull(drainDeadlineMs) {
                IdentityRuntime.state.first { it.phase.isFreeForBegin() }
            }
            if (free != null) {
                val step = IdentityWork.beginTransition(kind, removal)
                if (step.state.drained?.kind == kind && step.effects.any { it is BarrierEffect.AwaitDrain }) {
                    return BeginOutcome.Began(step)
                }
                IdentityEffects.run(step)
                if (BarrierEffect.EndFailed in step.effects) return BeginOutcome.Refused("recovery required") // B20
                continue // B13: a window opened in between; wait again
            }
            waited += drainDeadlineMs
            if (kind.isProfileKind) {
                log.e { "[Identity] $kind: an auth window stayed open ${waited} ms, not started" }
                return BeginOutcome.Refused("an auth window stayed open")
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
                    IdentityEffects.run(
                        IdentityRuntime.reduceStep(BarrierEvent.ApplyFinished(SLOT_UNSET, applied = applied == ProfileApply.Applied)),
                    )
                    when (applied) {
                        ProfileApply.Applied, ProfileApply.NothingDone -> null
                        ProfileApply.NothingPreempted -> PREEMPTED
                    }
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

    /** The state once the window and drained holds are released (Open or Recovery; a window still open is awaited, bounded). */
    private suspend fun awaitFinal(): IdentityState =
        withTimeoutOrNull(drainDeadlineMs) { IdentityRuntime.state.first { it.phase.isFreeForBegin() } }
            ?: IdentityRuntime.state.value

    /** Open, or only the recovery hold: no window and no drained op. Exhaustive on purpose. */
    private fun IdentityPhase.isFreeForBegin(): Boolean = when (this) {
        IdentityPhase.Open, is IdentityPhase.Recovery -> true
        is IdentityPhase.Draining, is IdentityPhase.Closed, is IdentityPhase.Applying -> false
    }

    private const val PREEMPTED = "\u0000preempted"

    /** Tests only. */
    internal fun resetForTest() {
        drainDeadlineMs = 2_000
        IdentityLocks.withCommit { queuedRemoval = null }
        debugHoldMs = { 0 }
        profileOps = UninstalledProfileOps
        beforeApplyLock = {}
        applyDispatcher = Dispatchers.Default
    }
}
