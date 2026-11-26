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
import kotlin.concurrent.Volatile
import kotlin.coroutines.AbstractCoroutineContextElement
import kotlin.coroutines.CoroutineContext

/*
 * The registry of deferred work stamped with an identity (fork-only). A barrier drains the jobs it
 * waits for (bounded, never joins) and cancels what its kind cancels.
 *
 * Design: docs/batch-scope-identity-spec.md, sections 4.3, 4.3a and 5.11 point 5 (revision 9).
 *
 * ---- Registry state ----
 *   jobs        Job → (name, WorkClass)        leaf  IdentityLocks.registry
 *   awaiting    Job → count of transitions it   leaf  IdentityLocks.registry
 *               is waiting for (mark/unmark)
 *   awaited     the drain in progress:          commit
 *               (transitionId, teardownRequired, ackMatched)
 *   pending     cancellation snapshots taken    commit
 *               but not yet issued (count)
 *   changes     wake-up counter for the drain   lock-free (StateFlow.update)
 *
 * ---- Operations (lock taken; what it is atomic with) ----
 *   admit (launch, launchAccount)   commit, then registry inside: the verdict and the insert are one
 *                                   commit section, so a drain decision sees the job or the job
 *                                   was refused (R3/R5/R7 once the phase left Draining).
 *   complete (invokeOnCompletion)   registry only (never commit: a canceller may hold a store
 *                                   lock), then signal outside. Only lowers a count; the loop
 *                                   decides again.
 *   mark / unmark awaiting          registry only, then signal. Marked by the driver when the
 *                                   call arrives (before it queues on the lane) and unmarked in the
 *                                   lane's finally of that same transition, so the marker never
 *                                   outlives the wait and the next drain on the lane sees the job
 *                                   counted again.
 *   begin (beginTransition)         commit: B1 and `awaited` in one section.
 *   drain decision (tryEndDrain)    commit, registry inside for the counts: DrainDecision and the
 *                                   DrainEnded reduce in one section. Refuses to end while
 *                                   `pending` > 0.
 *   cancel snapshot                 inside the reducing section (commit, registry inside); issued
 *                                   after the lock by IdentityEffects.run, which then clears its
 *                                   `pending` mark (commit) and signals.
 *   teardown ack (recordTeardown)   commit: counts only for `awaited.transitionId`.
 *   pre-emption wake                B10's reduce makes the op Preempted; its cancel snapshot is
 *                                   `pending`, so the driver cannot end the drain (and apply an
 *                                   account kind, B5) until the window's cancels were issued.
 */

/**
 * Marks a coroutine as registered identity work. [job] is the job the registry holds (set at
 * admission, before the job starts), so a child coroutine or withContext that inherits this
 * element still names the registered job (review r2-3).
 */
internal class IdentityJobElement(val token: IdentityToken?, val name: String) :
    AbstractCoroutineContextElement(Key) {
    @Volatile
    var job: Job? = null
        internal set

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
    private val awaiting = mutableMapOf<Job, Int>()

    // Under IdentityLocks.commit.
    private var awaited: Awaited? = null
    private var pending = 0

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
            element.job = job
            IdentityLocks.withRegistry { jobs[job] = Entry(name, cls) }
            job
        }
        if (job == null) {
            log.i { "[Identity] work refused $name ${(verdict as? Verdict.Reject)?.reason}" }
            return null
        }
        job.invokeOnCompletion {
            IdentityLocks.inCompletionHandler {
                IdentityLocks.withRegistry {
                    jobs.remove(job)
                    awaiting.remove(job)
                }
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
        // The deadline decision returns null only while a reducing section's cancellations are
        // still being issued (synchronously, on the thread that reduced): wait for that signal.
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
     * deadline, so B4/B5 end it at once. Null = keep waiting: before the deadline, or while a
     * cancellation snapshot is pending (review r2-4: an auth window's cancels are issued before
     * the driver may apply).
     */
    internal fun tryEndDrain(transitionId: Long, deadline: Boolean): Reduced? = IdentityLocks.withCommit {
        if (pending > 0) return@withCommit null
        val op = IdentityRuntime.snapshot().drained
        val wait = awaited?.takeIf { it.transitionId == transitionId }
        if (op == null || op.transitionId != transitionId || wait == null) {
            // Not this drain's op: out of order. The deadline call still reduces (B15 logs it).
            return@withCommit if (deadline) endLocked(DrainEnd.JobsDeadline) else null
        }
        val now = deadline || op.stage == DrainedStage.Preempted
        val view = IdentityLocks.withRegistry {
            DrainView(
                profileJobs = jobs.count { (job, e) -> job !in awaiting && e.cls is WorkClass.Profile },
                accountJobs = jobs.count { (job, e) -> job !in awaiting && e.cls is WorkClass.Account },
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
     * cancels, per CancelPolicy, awaiting-barrier jobs included.
     */
    internal fun cancelSnapshotLocked(kind: TransitionKind, logNames: Boolean): List<CancelTarget> =
        IdentityLocks.withRegistry {
            jobs.filter { (_, e) -> CancelPolicy.cancels(kind, e.cls) }.map { (job, e) -> CancelTarget(job, e.name, logNames) }
        }

    /** Under the commit lock: a reducing section took a non-empty snapshot. */
    internal fun cancellationPendingLocked() {
        pending++
    }

    /** Outside every lock: cancels a reducing section's snapshot (never joins), then clears its pending mark. */
    internal fun cancelTargets(targets: List<CancelTarget>) {
        if (targets.isEmpty()) return
        try {
            targets.forEach {
                it.job.cancel()
                if (it.logName) log.w { "[Identity] drain cancelled ${it.name}" }
            }
        } finally {
            IdentityLocks.withCommit { pending-- }
            bump()
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

    /**
     * The registered job of [element] waits for a transition: drains do not wait for it until
     * [unmarkAwaitingBarrier]. Returns the marked job (null when the element's job is not registered).
     */
    internal fun markAwaitingBarrier(element: IdentityJobElement): Job? {
        val job = element.job ?: return null
        val marked = IdentityLocks.withRegistry {
            if (job in jobs) {
                awaiting[job] = (awaiting[job] ?: 0) + 1
                true
            } else {
                false
            }
        }
        bump()
        return job.takeIf { marked }
    }

    internal fun unmarkAwaitingBarrier(job: Job) {
        IdentityLocks.withRegistry {
            val n = awaiting[job] ?: return@withRegistry
            if (n <= 1) awaiting.remove(job) else awaiting[job] = n - 1
        }
        bump()
    }

    private fun bump() {
        changes.update { it + 1 }
    }

    /** Tests only: the registered jobs of the profile (true) or account (false) class. */
    internal fun jobsOf(profile: Boolean): List<Job> = IdentityLocks.withRegistry {
        jobs.filter { (_, e) -> (e.cls is WorkClass.Profile) == profile }.keys.toList()
    }

    /** Tests only: whether [job] is marked awaiting. */
    internal fun isAwaiting(job: Job): Boolean = IdentityLocks.withRegistry { job in awaiting }

    /** Tests only: cancels and forgets everything. */
    internal fun resetForTest() {
        val all = IdentityLocks.withCommit {
            awaited = null
            pending = 0
            IdentityLocks.withRegistry {
                val all = jobs.keys.toList()
                jobs.clear()
                awaiting.clear()
                all
            }
        }
        all.forEach { it.cancel() }
        bump()
    }
}
