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
 * Revision 8 (4.3a): the registry, the awaited teardown id and the barrier state are guarded by ONE
 * lock, IdentityLocks.commit. Admission decides and registers in one section; a drain ends by
 * deciding and reducing DrainEnded in one section; cancellation snapshots are taken in the
 * reducing section. Jobs carry a WorkClass fixed at admission, never an epoch.
 *
 * Design: docs/batch-scope-identity-spec.md, sections 4.3 and 4.3a.
 */

/** Marks a coroutine as registered identity work; the driver reads it to mark awaiting-barrier callers. */
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

    // Every field below is read and written only under IdentityLocks.commit.
    private val jobs = mutableMapOf<Job, Entry>()
    private val awaiting = mutableSetOf<Job>()
    private var awaited: Awaited? = null

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
    ): Job? {
        var verdict: Verdict = Verdict.Commit
        val job = IdentityLocks.withCommit {
            verdict = IdentityGate.decideLocked(token, kind)
            if (verdict != Verdict.Commit) return@withCommit null
            val job = scope.launch(IdentityJobElement(token, name), start = CoroutineStart.LAZY, block = block)
            jobs[job] = Entry(name, WorkClass.Profile(token!!.scope))
            job
        }
        return started(job, name, verdict)
    }

    /** Account-level work (pushes of account data): class Account, cancelled by account kinds and windows only. */
    fun launchAccount(
        token: AccountToken?,
        name: String,
        scope: CoroutineScope,
        block: suspend CoroutineScope.() -> Unit,
    ): Job? {
        var verdict: Verdict = Verdict.Commit
        val job = IdentityLocks.withCommit {
            verdict = IdentityGate.decideAccountLocked(token)
            if (verdict != Verdict.Commit) return@withCommit null
            val job = scope.launch(IdentityJobElement(null, name), start = CoroutineStart.LAZY, block = block)
            jobs[job] = Entry(name, WorkClass.Account(token!!.account))
            job
        }
        return started(job, name, verdict)
    }

    private fun started(job: Job?, name: String, verdict: Verdict): Job? {
        if (job == null) {
            log.i { "[Identity] work refused $name ${(verdict as? Verdict.Reject)?.reason}" }
            return null
        }
        job.invokeOnCompletion { remove(job) }
        job.start()
        return job
    }

    private fun remove(job: Job) {
        IdentityLocks.withCommit {
            jobs.remove(job)
            awaiting.remove(job)
        }
        bump()
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
     * then one deadline call, which never returns null. Never joins a job. [epoch] is for the log.
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
        val result = ended ?: tryEndDrain(transitionId, deadline = true)!!
        if (result.effects.none { it is BarrierEffect.RunApply || it is BarrierEffect.EndPreempted || it is BarrierEffect.EndFailed }) {
            log.e { "[Identity] drain of transition $transitionId (epoch ${epoch.value}) ended out of order" }
        }
        return result
    }

    /**
     * One section: decide over the registry and the ack (DrainDecision) and, with an outcome,
     * reduce DrainEnded in the same section. Null = keep waiting (only when [deadline] is false).
     * A pre-empted op (B10 ran) is decided as at the deadline, so B4/B5 end it at once.
     */
    internal fun tryEndDrain(transitionId: Long, deadline: Boolean): Reduced? = IdentityLocks.withCommit {
        val op = IdentityRuntime.snapshot().drained
        val wait = awaited?.takeIf { it.transitionId == transitionId }
        if (op == null || op.transitionId != transitionId || wait == null) {
            // Not this drain's op: out of order. The deadline call still reduces (B15 logs it).
            return@withCommit if (deadline) endLocked(DrainEnd.JobsDeadline) else null
        }
        val now = deadline || op.stage == DrainedStage.Preempted
        val view = DrainView(
            profileJobs = jobs.count { (job, e) -> job !in awaiting && e.cls is WorkClass.Profile },
            accountJobs = jobs.count { (job, e) -> job !in awaiting && e.cls is WorkClass.Account },
            ackMatched = wait.ackMatched,
        )
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
        jobs.filter { (_, e) -> CancelPolicy.cancels(kind, e.cls) }.map { (job, e) -> CancelTarget(job, e.name, logNames) }

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

    /** The calling job awaits a transition; the drain does not wait for it (it is still cancelled at the end). */
    internal fun markAwaitingBarrier(job: Job) {
        IdentityLocks.withCommit { if (job in jobs) awaiting.add(job) }
        bump()
    }

    private fun bump() {
        changes.update { it + 1 }
    }

    /** Tests only: the registered jobs of [cls]'s type. */
    internal fun jobsOf(profile: Boolean): List<Job> = IdentityLocks.withCommit {
        jobs.filter { (_, e) -> (e.cls is WorkClass.Profile) == profile }.keys.toList()
    }

    /** Tests only: cancels and forgets everything. */
    internal fun resetForTest() {
        val all = IdentityLocks.withCommit {
            val all = jobs.keys.toList()
            jobs.clear()
            awaiting.clear()
            awaited = null
            all
        }
        all.forEach { it.cancel() }
        bump()
    }
}
