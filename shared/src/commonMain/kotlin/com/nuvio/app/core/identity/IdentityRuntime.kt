package com.nuvio.app.core.identity

import com.nuvio.app.core.auth.AuthRepository
import com.nuvio.app.core.build.AppBuildConfig
import com.nuvio.app.core.profile.ActiveProfileProvider
import kotlinx.atomicfu.locks.SynchronizedObject
import kotlinx.atomicfu.locks.synchronized
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asStateFlow
import kotlin.concurrent.Volatile

/*
 * The identity runtime (fork-only): the one BarrierState, its StateFlow, and the two
 * synchronous locks.
 *
 * Lock order (5.11), outermost first: IdentityBarrier lane → auth lane → apply → AddonRepository
 * profileLock → commit (reentrant on the same thread) → store-internal locks → IdentityWork
 * registry (leaf).
 *
 * Design: docs/batch-scope-identity-spec.md, sections 2, 4.1, 5.11, 5.12.
 */

/** Per-thread nesting depths of the two locks (platform thread-locals). */
internal expect object IdentityThreadDepth {
    fun commit(): Int
    fun setCommit(value: Int)
    fun apply(): Int
    fun setApply(value: Int)
}

internal object IdentityLocks {
    /** Short: decision + one local write, or a reduce + the StateFlow assignment (5.12). */
    val commit = SynchronizedObject()

    /** Synchronous apply bodies only. */
    val apply = SynchronizedObject()

    /**
     * 5.11 point 1: requesting [apply] on a thread inside [commit] is a lock-order bug. Checked
     * in debug builds (tests set it).
     */
    @Volatile
    var strictLockOrder: Boolean = AppBuildConfig.IS_DEBUG_BUILD

    /** How deep this thread is inside [withApply]; W2's guarded slot setter reads it. */
    val applyDepth: Int get() = IdentityThreadDepth.apply()

    /** How deep this thread is inside [withCommit]. */
    val commitDepth: Int get() = IdentityThreadDepth.commit()

    fun <T> withCommit(block: () -> T): T = synchronized(commit) {
        IdentityThreadDepth.setCommit(IdentityThreadDepth.commit() + 1)
        try {
            block()
        } finally {
            IdentityThreadDepth.setCommit(IdentityThreadDepth.commit() - 1)
        }
    }

    fun <T> withApply(block: () -> T): T {
        if (strictLockOrder && IdentityThreadDepth.commit() > 0) {
            error("[Identity] apply lock requested inside the commit lock (lock order, 5.11)")
        }
        return synchronized(apply) {
            IdentityThreadDepth.setApply(IdentityThreadDepth.apply() + 1)
            try {
                block()
            } finally {
                IdentityThreadDepth.setApply(IdentityThreadDepth.apply() - 1)
            }
        }
    }
}

internal object IdentityRuntime {
    /** Read and written only under [IdentityLocks.commit]. */
    private var model: BarrierState = BarrierState.initial(slot = 1)
    private val _state = MutableStateFlow(model.toPublic())
    val state: StateFlow<IdentityState> = _state.asStateFlow()

    @Volatile
    var authSerial: () -> Long = { AuthRepository.sessionTicket().serial }

    @Volatile
    var activeSlot: () -> Int = { ActiveProfileProvider.activeProfileId }

    /** The account of the last Open period; a settle to Open with another account fires afterAccountOpen (4.5, revision 8). */
    private var lastOpenAccount: AccountKey = model.scope.account

    /**
     * Reduces AND publishes under the commit lock, so the StateFlow sees states in reduction order
     * and a delayed publish can never overwrite a later one. Returns the effects; the job
     * cancellation and the afterAccountOpen launch run after the lock is released.
     * (Tests use this; the driver and the auth windows go through [reduceStep] + IdentityEffects.)
     */
    fun reduce(event: BarrierEvent): List<BarrierEffect> {
        val reduced = reduceStep(event)
        IdentityEffects.run(reduced)
        return reduced.step.effects
    }

    /**
     * One reducing section: the reduce, the publish, the cancellation snapshot of every
     * CancelJobs effect (4.3a point 5) and the account-open check, all under the commit lock.
     * Reentrant: IdentityWork calls it inside its own commit section (tryEndDrain, beginTransition).
     */
    fun reduceStep(event: BarrierEvent): Reduced = IdentityLocks.withCommit {
        val step = BarrierModel.reduce(model, event.withSlot(activeSlot()))
        model = step.state
        step.published?.let { _state.value = it }
        val toCancel = step.effects.filterIsInstance<BarrierEffect.CancelJobs>()
            .flatMap { IdentityWork.cancelSnapshotLocked(it.kind, it.logNames) }
        var accountOpened = false
        val published = step.published
        if (published != null && published.phase is IdentityPhase.Open) {
            if (published.scope.account != lastOpenAccount) accountOpened = true
            lastOpenAccount = published.scope.account
        }
        Reduced(step, toCancel, accountOpened)
    }

    fun snapshot(): BarrierState = IdentityLocks.withCommit { model }

    /** Boot, before the first reduce: the slot the restored profile cache made active. */
    fun seedSlot(slot: Int) {
        IdentityLocks.withCommit {
            if (model.phase !is IdentityPhase.Open || model.version != 0L) return@withCommit
            model = model.copy(scope = model.scope.copy(slot = slot))
            _state.value = model.toPublic()
            lastOpenAccount = model.scope.account
        }
    }

    /** Tests only: a fresh Open state. */
    internal fun resetForTest(slot: Int = 1, serial: Long = 0, activeSlot: (() -> Int)? = null) {
        IdentityLocks.withCommit {
            model = BarrierState.initial(slot)
            _state.value = model.toPublic()
            lastOpenAccount = model.scope.account
        }
        authSerial = { serial }
        this.activeSlot = activeSlot ?: { slot }
    }

    /** Tests only: replace the model (a concrete state for the gate tests). */
    internal fun setForTest(state: BarrierState) {
        IdentityLocks.withCommit {
            model = state
            _state.value = state.toPublic()
            lastOpenAccount = state.scope.account
        }
    }
}

/** One reducing section's output: the step, the jobs to cancel after the lock, and whether an account change reached Open. */
internal class Reduced(
    val step: BarrierStep,
    val toCancel: List<CancelTarget>,
    val accountOpened: Boolean,
) {
    val state: BarrierState get() = step.state
    val effects: List<BarrierEffect> get() = step.effects
}

/** A job picked for cancellation inside a reducing section. */
internal class CancelTarget(val job: kotlinx.coroutines.Job, val name: String, val logName: Boolean)
