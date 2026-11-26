package com.nuvio.app.core.identity

import co.touchlab.kermit.Logger
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.CoroutineStart
import kotlinx.coroutines.Job
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.first
import kotlinx.coroutines.flow.update
import kotlinx.coroutines.launch
import kotlinx.coroutines.withTimeoutOrNull
import kotlin.coroutines.AbstractCoroutineContextElement
import kotlin.coroutines.CoroutineContext

/*
 * The registry of deferred work stamped with an identity (fork-only). A barrier drains the jobs it
 * waits for (bounded, never joins) and cancels what its kind cancels.
 *
 * Design: docs/batch-scope-identity-spec.md, sections 4.3, 4.3a and 5.11 point 5 (revision 9).
 *
 * ---- Registry state (revision 10) ----
 *   jobs             Job → (name, WorkClass)          leaf    IdentityLocks.registry
 *   awaited          the drain in progress:           commit
 *                    (transitionId, teardownRequired, ackMatched)
 *   effectsInFlight  reducing sections whose revoke    commit
 *                    or cancels have not finished
 *   changes          wake-up counter for the drain    lock-free (StateFlow.update)
 *   (no awaiting marker: rule A. Work that requests a transition does not wait for it.)
 *
 * ---- Operations (lock; what it is atomic with) ----
 *   admit (launch, launchAccount)  commit, registry inside. The verdict (phase, epoch, account,
 *                                  serial, recovery) and the insert are one commit section, and the
 *                                  drain decision is a commit section too: a drain sees the job, or
 *                                  the job was refused (R3/R5/R7 once the phase left Draining).
 *   complete (invokeOnCompletion)  registry only (never commit: a canceller may hold a store
 *                                  lock), then signal outside. Only lowers a count.
 *   begin (beginTransition)        commit: B1/B21 and `awaited` in one section.
 *   drain decision (tryEndDrain)   commit, registry inside for the counts: DrainDecision and the
 *                                  DrainEnded reduce in one section; null while effectsInFlight > 0
 *                                  (deadline included).
 *   effects in flight              raised in the reducing section of every step carrying a Revoke or
 *                                  a CancelJobs (commit, same section as the reduce, empty snapshot
 *                                  included); cleared by IdentityEffects.run after the revoke
 *                                  returned and the cancels were issued (commit), then signal.
 *   cancel snapshot                inside the reducing section (commit, registry inside); issued
 *                                  after the lock, before effects-in-flight is cleared.
 *   apply gate (B6)                the runtime reads effectsInFlight in the ApplyGate reducing
 *                                  section (commit, under the apply lock): raised → EndPreempted.
 *   teardown ack (recordTeardown)  commit: counts only for `awaited.transitionId`.
 *   pre-emption wake               B10 makes the op Preempted and raises effects-in-flight; the
 *                                  drain cannot end (nor an account kind apply, B5) until the
 *                                  window's revoke returned and its cancels were issued.
 */

/**
 * Marks a coroutine (and its children) as registered identity work. The barrier reads it: a
 * transition requested from registered work is enqueued and not awaited (rule A).
 */
internal class IdentityJobElement(val token: IdentityToken?, val name: String) :
    AbstractCoroutineContextElement(Key) {
    companion object Key : CoroutineContext.Key<IdentityJobElement>
}

object IdentityWork {
    private val log = Logger.withTag("Identity")

    private class Entry(val name: String, val cls: WorkClass)

    /** The drain in progress: the Begin it belongs to, and whether its teardown was acknowledged. */
    private class Awaited(val transitionId: Long) {
        var teardownRequired = false
        var ackMatched = false
    }

    // Under IdentityLocks.registry (the leaf).
    private val jobs = mutableMapOf<Job, Entry>()

    // Under IdentityLocks.commit.
    private var awaited: Awaited? = null
    private var effectsInFlight = 0

    /** Bumped on every change the drain waits for; conflation is fine, the condition is re-read. */
    private val changes = MutableStateFlow(0L)

    /**
     * Start check and registration are one step under the commit lock; the job starts after the lock.
     * [kind] is Start for new work (refused while Draining) or RemoteSend for the send that finishes
     * a write already committed (allowed while Draining for the same epoch). Returns null when refused.
     */
    fun launch(
        token: IdentityToken?,
        name: String,
        scope: CoroutineScope,
        kind: CommitKind = CommitKind.Start,
        block: suspend CoroutineScope.() -> Unit,
    ): Job? = admit(name, scope, IdentityJobElement(token, name), block) {
        IdentityGate.decideLocked(token, kind) to token?.let { WorkClass.Profile(it.scope) }
    }

    /** Account-level work (pushes of account data): class Account, cancelled by account kinds and windows only. */
    fun launchAccount(
        token: AccountToken?,
        name: String,
        scope: CoroutineScope,
        block: suspend CoroutineScope.() -> Unit,
    ): Job? = admit(name, scope, IdentityJobElement(null, name), block) {
        IdentityGate.decideAccountLocked(token) to token?.let { WorkClass.Account(it.account) }
    }

    private fun admit(
        name: String,
        scope: CoroutineScope,
        element: IdentityJobElement,
        block: suspend CoroutineScope.() -> Unit,
        decide: () -> Pair<Verdict, WorkClass?>,
    ): Job? {
        var verdict: Verdict = Verdict.Commit
        val job = IdentityLocks.withCommit {
            val (v, cls) = decide()
            verdict = v
            if (v != Verdict.Commit || cls == null) return@withCommit null
            val job = scope.launch(element, start = CoroutineStart.LAZY, block = block)
            IdentityLocks.withRegistry { jobs[job] = Entry(name, cls) }
            job
        }
        if (job == null) {
            log.i { "[Identity] work refused $name ${(verdict as? Verdict.Reject)?.reason}" }
            return null
        }
        job.invokeOnCompletion {
            IdentityLocks.inCompletionHandler {
                IdentityLocks.withRegistry { jobs.remove(job) }
            }
            bump()
        }
        job.start()
        return job
    }

    /**
     * B1 and the awaited teardown id in one section (4.3a point 4). Returns the Begin's reduced
     * step; the drain awaits its op's transitionId only if the Begin was accepted.
     */
    internal fun beginTransition(kind: TransitionKind): Reduced = IdentityLocks.withCommit {
        val reduced = IdentityRuntime.reduceStep(BarrierEvent.Begin(kind))
        val op = reduced.state.drained
        if (op != null && reduced.effects.any { it is BarrierEffect.AwaitDrain }) awaited = Awaited(op.transitionId)
        reduced
    }

    /**
     * Waits for the drain of [transitionId] to end and returns the DrainEnded reducing section
     * (4.3a points 2–3): a loop over [tryEndDrain] on every registry, ack or pre-emption change,
     * then the deadline decision. Never joins a job. [epoch] is for the log.
     */
    internal suspend fun awaitDrained(
        epoch: IdentityEpoch,
        transitionId: Long,
        deadlineMs: Long,
        teardownRequired: Boolean,
    ): Reduced {
        IdentityLocks.withCommit {
            awaited?.takeIf { it.transitionId == transitionId }?.teardownRequired = teardownRequired
        }
        var ended: Reduced? = null
        withTimeoutOrNull(deadlineMs) {
            changes.first {
                ended = tryEndDrain(transitionId, deadline = false)
                ended != null
            }
        }
        // Rule C: the deadline decision returns null only while effects are in flight (a revoke
        // and its cancels, run synchronously on the thread that reduced): wait for that signal.
        if (ended == null) {
            changes.first {
                ended = tryEndDrain(transitionId, deadline = true)
                ended != null
            }
        }
        val result = ended!!
        if (result.effects.none { it is BarrierEffect.RunApply || it is BarrierEffect.EndPreempted || it is BarrierEffect.EndFailed }) {
            log.e { "[Identity] drain of transition $transitionId (epoch ${epoch.value}) ended out of order" }
        }
        return result
    }

    /**
     * One section: decide over the registry and the ack (DrainDecision) and, with an outcome,
     * reduce DrainEnded in the same section. A pre-empted op (B10 ran) is decided as at the
     * deadline, so B4/B5 end it at once. Null = keep waiting: before the deadline, or while
     * effects are in flight (rule C: a window's revoke and cancels finish before the driver may
     * apply), deadline included.
     */
    internal fun tryEndDrain(transitionId: Long, deadline: Boolean): Reduced? = IdentityLocks.withCommit {
        if (effectsInFlight > 0) return@withCommit null
        val op = IdentityRuntime.snapshot().drained
        val wait = awaited?.takeIf { it.transitionId == transitionId }
        if (op == null || op.transitionId != transitionId || wait == null) {
            // Not this drain's op: out of order. The deadline call still reduces (B15 logs it).
            return@withCommit if (deadline) endLocked(DrainEnd.JobsDeadline) else null
        }
        val now = deadline || op.stage == DrainedStage.Preempted
        val view = IdentityLocks.withRegistry {
            DrainView(
                profileJobs = jobs.count { (_, e) -> e.cls is WorkClass.Profile },
                accountJobs = jobs.count { (_, e) -> e.cls is WorkClass.Account },
                ackMatched = wait.ackMatched,
            )
        }
        val how = DrainDecision.decide(op.kind, view, wait.teardownRequired, now) ?: return@withCommit null
        endLocked(how)
    }

    /** A profile transition whose revoke failed ends at once (revision 7, B3a), in one section. */
    internal fun endDrainUnconfirmed(transitionId: Long): Reduced = IdentityLocks.withCommit {
        if (awaited?.transitionId != transitionId) log.e { "[Identity] unconfirmed end for transition $transitionId not awaited" }
        endLocked(DrainEnd.TeardownUnconfirmed)
    }

    /** Under the commit lock: reduce DrainEnded and stop awaiting. */
    private fun endLocked(how: DrainEnd): Reduced {
        awaited = null
        return IdentityRuntime.reduceStep(BarrierEvent.DrainEnded(how))
    }

    /**
     * Under the commit lock (called from the reducing section): the jobs a CancelJobs for [kind]
     * cancels, per CancelPolicy.
     */
    internal fun cancelSnapshotLocked(kind: TransitionKind, logNames: Boolean): List<CancelTarget> =
        IdentityLocks.withRegistry {
            jobs.filter { (_, e) -> CancelPolicy.cancels(kind, e.cls) }.map { (job, e) -> CancelTarget(job, e.name, logNames) }
        }

    /** Under the commit lock (the reducing section): a step carrying a Revoke or a CancelJobs. */
    internal fun raiseEffectsInFlightLocked() {
        effectsInFlight++
    }

    /** Under the commit lock: read by the runtime for ApplyGate (B6, rule C). */
    internal fun effectsInFlightLocked(): Int = effectsInFlight

    /** After the revoke returned and the cancels were issued (IdentityEffects.run's finally). */
    internal fun clearEffectsInFlight() {
        IdentityLocks.withCommit { if (effectsInFlight > 0) effectsInFlight-- }
        bump()
    }

    /** Outside every lock: cancels a reducing section's snapshot (never joins). */
    internal fun cancelTargets(targets: List<CancelTarget>) {
        targets.forEach {
            it.job.cancel()
            if (it.logName) log.w { "[Identity] drain cancelled ${it.name}" }
        }
    }

    /** B10's SignalPreempted: wakes the drain loop, which sees the op Preempted and ends it. */
    internal fun signalPreempted() = bump()

    /** Swift's echo; accepted only when [transitionId] is the one the current drain awaits (4.3a point 4). */
    internal fun recordTeardown(transitionId: Long) {
        val accepted = IdentityLocks.withCommit {
            val wait = awaited?.takeIf { it.transitionId == transitionId }
            wait?.ackMatched = true
            wait != null
        }
        if (accepted) bump() else log.i { "[Identity] teardown ack for transition $transitionId ignored (not awaited)" }
    }

    private fun bump() {
        changes.update { it + 1 }
    }

    /** Tests only: the registered jobs of the profile (true) or account (false) class. */
    internal fun jobsOf(profile: Boolean): List<Job> = IdentityLocks.withRegistry {
        jobs.filter { (_, e) -> (e.cls is WorkClass.Profile) == profile }.keys.toList()
    }

    /** Tests only: cancels and forgets everything. */
    internal fun resetForTest() {
        val all = IdentityLocks.withCommit {
            awaited = null
            effectsInFlight = 0
            IdentityLocks.withRegistry {
                val all = jobs.keys.toList()
                jobs.clear()
                all
            }
        }
        all.forEach { it.cancel() }
        bump()
    }
}
