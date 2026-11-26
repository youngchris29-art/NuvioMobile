package com.nuvio.app.core.identity

import co.touchlab.kermit.Logger
import kotlinx.atomicfu.locks.SynchronizedObject
import kotlinx.atomicfu.locks.synchronized
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
 * The registry of deferred work stamped with an identity (fork-only). A barrier drains the jobs of
 * its epoch (bounded, never joins) and cancels what is left.
 *
 * Design: docs/batch-scope-identity-spec.md, section 4.3 (revision 7).
 */

/** Marks a coroutine as registered identity work; the driver reads it to mark awaiting-barrier callers. */
internal class IdentityJobElement(val token: IdentityToken?, val name: String) :
    AbstractCoroutineContextElement(Key) {
    companion object Key : CoroutineContext.Key<IdentityJobElement>
}

object IdentityWork {
    private val log = Logger.withTag("Identity")

    /** Leaf lock (5.11): guards every field below. */
    private val registryLock = SynchronizedObject()
    private val jobs = mutableMapOf<Long, MutableMap<Job, String>>()
    private val awaiting = mutableSetOf<Job>()

    /** Highest epoch whose teardown Swift acknowledged; whose drain a window pre-empted. */
    private var teardownAcked: Long = -1
    private var preempted: Long = -1

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
            register(token!!.epoch, job, name)
            job
        }
        return started(job, name, verdict)
    }

    /** Account-level work (pushes of account data): registered under the epoch current at launch. */
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
            register(IdentityRuntime.snapshot().epoch, job, name)
            job
        }
        return started(job, name, verdict)
    }

    private fun register(epoch: IdentityEpoch, job: Job, name: String) = synchronized(registryLock) {
        jobs.getOrPut(epoch.value) { mutableMapOf() }[job] = name
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
        synchronized(registryLock) {
            val iterator = jobs.entries.iterator()
            while (iterator.hasNext()) {
                val entry = iterator.next()
                if (entry.value.remove(job) != null && entry.value.isEmpty()) iterator.remove()
            }
            awaiting.remove(job)
        }
        bump()
    }

    /**
     * Returns at the first of: (a) every job of [epoch] not marked awaiting-barrier has completed
     * and (if [teardownRequired]) [recordTeardown] arrived → Settled; (b) [deadlineMs] →
     * TeardownUnconfirmed if teardown was required and has not arrived, else JobsDeadline;
     * (c) [signalPreempted] → Preempted. Never joins a job.
     */
    internal suspend fun awaitDrained(epoch: IdentityEpoch, deadlineMs: Long, teardownRequired: Boolean): DrainEnd {
        val ended = withTimeoutOrNull(deadlineMs) {
            changes.first { drainOutcome(epoch, teardownRequired) != null }
            drainOutcome(epoch, teardownRequired)
        }
        if (ended != null) return ended
        return synchronized(registryLock) {
            when {
                preempted >= epoch.value -> DrainEnd.Preempted
                teardownRequired && teardownAcked < epoch.value -> DrainEnd.TeardownUnconfirmed
                else -> DrainEnd.JobsDeadline
            }
        }
    }

    private fun drainOutcome(epoch: IdentityEpoch, teardownRequired: Boolean): DrainEnd? = synchronized(registryLock) {
        when {
            preempted >= epoch.value -> DrainEnd.Preempted
            jobs[epoch.value].orEmpty().keys.all { it in awaiting } &&
                (!teardownRequired || teardownAcked >= epoch.value) -> DrainEnd.Settled
            else -> null
        }
    }

    /** Snapshot under the registry lock, cancel outside it (awaiting-barrier jobs included). */
    internal fun cancel(epoch: IdentityEpoch, logNames: Boolean) {
        val snapshot = synchronized(registryLock) { jobs[epoch.value]?.toList().orEmpty() }
        snapshot.forEach { (job, name) ->
            job.cancel()
            if (logNames) log.w { "[Identity] drain cancelled $name" }
        }
    }

    internal fun signalPreempted(epoch: IdentityEpoch) {
        synchronized(registryLock) { if (epoch.value > preempted) preempted = epoch.value }
        bump()
    }

    /**
     * A drained transition begins at [epoch]: forget an acknowledgement recorded for it earlier.
     * Revision 7's B3a releases a failed profile transition with the SAME epoch, so a retry runs at
     * that epoch again and must not inherit the failed attempt's acknowledgement. Called by the
     * driver after Begin and before the revoke.
     */
    internal fun beginDrain(epoch: IdentityEpoch) {
        synchronized(registryLock) { if (teardownAcked >= epoch.value) teardownAcked = epoch.value - 1 }
    }

    /** Swift acknowledged teardown for [epoch] (through IdentityBarrier.teardownDone). */
    internal fun recordTeardown(epoch: Long) {
        synchronized(registryLock) { if (epoch > teardownAcked) teardownAcked = epoch }
        bump()
    }

    /** The calling job awaits a transition; the drain does not wait for it (it is still cancelled at the end). */
    internal fun markAwaitingBarrier(job: Job) {
        synchronized(registryLock) {
            if (jobs.values.any { job in it }) awaiting.add(job)
        }
        bump()
    }

    private fun bump() {
        changes.update { it + 1 }
    }

    /** Tests only. */
    internal fun jobsFor(epoch: IdentityEpoch): List<Job> =
        synchronized(registryLock) { jobs[epoch.value]?.keys?.toList().orEmpty() }

    /** Tests only: cancels and forgets everything. */
    internal fun resetForTest() {
        val all = synchronized(registryLock) {
            val all = jobs.values.flatMap { it.keys }
            jobs.clear()
            awaiting.clear()
            teardownAcked = -1
            preempted = -1
            all
        }
        all.forEach { it.cancel() }
        bump()
    }
}
