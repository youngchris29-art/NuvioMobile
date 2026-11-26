package com.nuvio.app.core.identity

import kotlinx.atomicfu.locks.SynchronizedObject
import kotlinx.atomicfu.locks.synchronized
import kotlinx.coroutines.delay
import kotlinx.coroutines.withTimeout
import kotlin.time.TimeSource

/** A thread-safe ordered record of what happened, shared by the fakes of one test. */
internal class EventLog {
    private val lock = SynchronizedObject()
    private val entries = mutableListOf<String>()

    fun add(entry: String) = synchronized(lock) { entries.add(entry) }
    fun all(): List<String> = synchronized(lock) { entries.toList() }
    fun indexOf(entry: String): Int = all().indexOf(entry)
    fun count(entry: String): Int = all().count { it == entry }
}

/** Profile ops over a fake active slot; the runtime reads [active] as its slot. */
internal class FakeProfileOps(private val log: EventLog) : IdentityProfileOps {
    private val lock = SynchronizedObject()
    private var activeSlot = 1
    var listed: Set<Int> = setOf(1, 2, 3)
    var onApply: (Int) -> Unit = {}

    val active: Int get() = synchronized(lock) { activeSlot }

    /** Runs after the slot was changed (a body that mutates, then throws). */
    var afterMutation: (Int) -> Unit = {}

    override fun applySelection(slot: Int) {
        onApply(slot)
        synchronized(lock) { activeSlot = slot }
        log.add("apply $slot")
        afterMutation(slot)
    }

    override fun applyActiveRemoved() {
        log.add("removed")
    }

    override fun isListed(slot: Int): Boolean = slot in listed
}

/** A revoker that records each call and returns [result]; [onRevoke] runs inside the call. */
internal class RecordingRevoker(private val log: EventLog) : IdentityRevoker {
    @kotlin.concurrent.Volatile
    var result: Boolean = true
    var onRevoke: (IdentityState) -> Unit = {}
    private val lock = SynchronizedObject()
    private val seen = mutableListOf<IdentityState>()

    val states: List<IdentityState> get() = synchronized(lock) { seen.toList() }

    override fun revoke(state: IdentityState): Boolean {
        synchronized(lock) { seen.add(state) }
        log.add("revoke ${state.kind}")
        onRevoke(state)
        return result
    }
}

/** Installs the fakes on the real driver (lane on Default, apply on Default). */
internal fun installDriverFakes(log: EventLog, deadlineMs: Long = 400): FakeProfileOps {
    val ops = FakeProfileOps(log)
    resetIdentityForTest(slot = 1, serial = 1, activeSlot = { ops.active })
    IdentityRuntime.setForTest(
        BarrierState.initial(1).copy(scope = IdentityScope(accountA, 1), latestAccount = accountA, epoch = IdentityEpoch(1)),
    )
    IdentityBarrier.profileOps = ops
    IdentityBarrier.drainDeadlineMs = deadlineMs
    return ops
}

/** Real-time poll for a condition other threads make true. */
internal suspend fun eventually(timeoutMs: Long = 3_000, condition: () -> Boolean) {
    withTimeout(timeoutMs) {
        while (!condition()) delay(5)
    }
}

/** Busy-waits (no suspension) for [condition]: for use inside synchronous apply bodies. */
internal fun spinUntil(timeoutMs: Long = 3_000, condition: () -> Boolean) {
    val start = TimeSource.Monotonic.markNow()
    while (!condition()) {
        check(start.elapsedNow().inWholeMilliseconds < timeoutMs) { "spinUntil timed out" }
    }
}
