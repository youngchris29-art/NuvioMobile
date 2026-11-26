package com.nuvio.app.core.identity

/*
 * The pure barrier reducer (fork-only). The phase is derived from two holds: a drained transition
 * (profile select / delete / slot removed, sign-out / delete account / server switch) and an auth
 * window (an account wipe or publish on the auth lane). The gate opens only when both are released,
 * and one closed period bumps the epoch exactly once, whichever hold ends last. One interleaving
 * rule: a drained profile transition applies only if no auth window opened since it began.
 *
 * Design: docs/batch-scope-identity-spec.md, section 3.4 (rows B1–B16, revision 7).
 */

/** Preempted: a window cut the drain short; never returns to Draining. */
internal enum class DrainedStage { Draining, Preempted, Applying }

internal data class DrainedOp(
    val kind: TransitionKind,
    val stage: DrainedStage,
    val windowsAtBegin: Long,
    val gated: Boolean = false,
)

internal data class BarrierState(
    val epoch: IdentityEpoch,
    /** The scope of the last Open period. */
    val scope: IdentityScope,
    /** Hold 1. */
    val drained: DrainedOp?,
    /** Hold 2: AccountWipe or AccountPublished (4.5). */
    val window: TransitionKind?,
    /** Counts every WindowOpened; the interleaving rule compares it. */
    val windowsOpened: Long,
    /** The account in AuthRepository.state (written inside the window, 4.5). */
    val latestAccount: AccountKey,
    val version: Long,
) {
    val phase: IdentityPhase
        get() = when {
            drained == null && window == null -> IdentityPhase.Open
            window == null && drained!!.stage == DrainedStage.Draining -> IdentityPhase.Draining(epoch)
            drained?.stage == DrainedStage.Applying -> IdentityPhase.Applying(epoch)
            else -> IdentityPhase.Closed(epoch)
        }

    /** The public kind: `drained?.kind ?: window`. */
    val kind: TransitionKind? get() = drained?.kind ?: window

    fun toPublic(): IdentityState = IdentityState(scope = scope, epoch = epoch, phase = phase, kind = kind)

    companion object {
        fun initial(slot: Int): BarrierState = BarrierState(
            epoch = IdentityEpoch.Initial,
            scope = IdentityScope(AccountKey.None, slot),
            drained = null,
            window = null,
            windowsOpened = 0,
            latestAccount = AccountKey.None,
            version = 0,
        )
    }
}

/**
 * Revision 6/7: the drain reports jobs and teardown separately. Settled = jobs done AND teardown
 * acknowledged (or no revoker required). TeardownUnconfirmed: the revoker returned false, the
 * revoker is missing while required, or teardownDone did not arrive by the deadline.
 */
internal enum class DrainEnd { Settled, JobsDeadline, TeardownUnconfirmed, Preempted }

/** Marks a finishing event whose slot the runtime fills under the commit lock ([withSlot]). */
internal const val SLOT_UNSET: Int = Int.MIN_VALUE

internal sealed interface BarrierEvent {
    /** Drained kinds only. */
    data class Begin(val kind: TransitionKind) : BarrierEvent

    /**
     * [slotAfter] is a W1 addition to the spec's signature: rows B4 and B6's pre-emption settle
     * without an apply, and settle needs the slot (a window body may have moved it).
     * [SLOT_UNSET] keeps the scope's slot (pure tests).
     */
    data class DrainEnded(val how: DrainEnd, val slotAfter: Int = SLOT_UNSET) : BarrierEvent

    /** Profile kinds; sent under the apply lock right before the body. [slotAfter] as in [DrainEnded]. */
    data class ApplyGate(val slotAfter: Int = SLOT_UNSET) : BarrierEvent
    data class ApplyFinished(val slotAfter: Int) : BarrierEvent
    data class ApplyThrew(val slotAfter: Int, val error: String) : BarrierEvent
    data class Abandoned(val slotAfter: Int) : BarrierEvent

    /** Immediate kinds only. */
    data class WindowOpened(val kind: TransitionKind) : BarrierEvent
    data class WindowAccount(val account: AccountKey) : BarrierEvent
    data class WindowClosed(val slotAfter: Int) : BarrierEvent
}

/** Fills the slot of every finishing event with [slot] (read by the runtime under the commit lock, 4.1). */
internal fun BarrierEvent.withSlot(slot: Int): BarrierEvent = when (this) {
    is BarrierEvent.DrainEnded -> copy(slotAfter = slot)
    is BarrierEvent.ApplyGate -> copy(slotAfter = slot)
    is BarrierEvent.ApplyFinished -> copy(slotAfter = slot)
    is BarrierEvent.ApplyThrew -> copy(slotAfter = slot)
    is BarrierEvent.Abandoned -> copy(slotAfter = slot)
    is BarrierEvent.WindowClosed -> copy(slotAfter = slot)
    is BarrierEvent.Begin, is BarrierEvent.WindowOpened, is BarrierEvent.WindowAccount -> this
}

internal sealed interface BarrierEffect {
    /** Synchronous Swift revocation (4.6). */
    data class Revoke(val state: IdentityState) : BarrierEffect
    data class AwaitDrain(val epoch: IdentityEpoch) : BarrierEffect
    data class CancelJobs(val epoch: IdentityEpoch, val logNames: Boolean) : BarrierEffect
    data object RunApply : BarrierEffect

    /** ApplyGate passed. */
    data object Proceed : BarrierEffect

    /** The transition ends without applying. */
    data object EndPreempted : BarrierEffect

    /** Teardown unconfirmed, profile kind: ends without applying (B3a). */
    data object EndFailed : BarrierEffect
    data object SignalPreempted : BarrierEffect
    data class Log(val line: String) : BarrierEffect
}

internal data class BarrierStep(
    val state: BarrierState,
    val effects: List<BarrierEffect>,
    val published: IdentityState?,
)

internal object BarrierModel {

    fun reduce(state: BarrierState, event: BarrierEvent): BarrierStep {
        val (after, effects) = transition(state, event)
        val before = state.toPublic()
        val next = after.toPublic()
        return if (next != before) {
            BarrierStep(after.copy(version = state.version + 1), effects, next)
        } else {
            BarrierStep(after.copy(version = state.version), effects, null)
        }
    }

    private fun transition(s: BarrierState, event: BarrierEvent): Pair<BarrierState, List<BarrierEffect>> {
        val e = s.epoch
        val drained = s.drained
        return when (event) {
            is BarrierEvent.Begin -> when {
                !event.kind.drains -> unchanged(s, "wrong lane: begin ${event.kind}") // B16
                drained != null || s.window != null -> unchanged(s, "begin refused: held") // B13
                else -> { // B1
                    val next = s.copy(drained = DrainedOp(event.kind, DrainedStage.Draining, s.windowsOpened))
                    next to listOf(BarrierEffect.Revoke(next.toPublic()), BarrierEffect.AwaitDrain(e))
                }
            }

            is BarrierEvent.DrainEnded -> when {
                drained == null -> outOfOrder(s, event)
                drained.stage == DrainedStage.Draining -> drainEndedWhileDraining(s, drained, event)
                drained.stage == DrainedStage.Preempted -> if (drained.kind.isProfileKind) {
                    // B4
                    s.release(event.slotAfter) to listOf(BarrierEffect.EndPreempted)
                } else {
                    // B5
                    s.copy(drained = drained.copy(stage = DrainedStage.Applying)) to listOf(BarrierEffect.RunApply)
                }
                else -> outOfOrder(s, event)
            }

            is BarrierEvent.ApplyGate -> when {
                drained == null || drained.stage != DrainedStage.Applying ||
                    !drained.kind.isProfileKind || drained.gated -> outOfOrder(s, event)
                // B6
                s.windowsOpened == drained.windowsAtBegin ->
                    s.copy(drained = drained.copy(gated = true)) to listOf(BarrierEffect.Proceed)
                else -> s.release(event.slotAfter) to listOf(BarrierEffect.EndPreempted)
            }

            is BarrierEvent.ApplyFinished -> if (drained.mayFinish()) {
                s.release(event.slotAfter) to emptyList() // B7
            } else {
                outOfOrder(s, event)
            }

            is BarrierEvent.ApplyThrew -> if (drained.mayFinish()) {
                s.release(event.slotAfter) to listOf(BarrierEffect.Log("apply threw: ${event.error}")) // B8
            } else {
                outOfOrder(s, event)
            }

            is BarrierEvent.Abandoned -> if (drained != null) {
                // B9
                s.release(event.slotAfter) to listOf(
                    BarrierEffect.CancelJobs(e, logNames = true),
                    BarrierEffect.Log("abandoned ${drained.kind} at ${drained.stage}"),
                )
            } else {
                outOfOrder(s, event)
            }

            is BarrierEvent.WindowOpened -> when {
                event.kind.drains -> unchanged(s, "wrong lane: window ${event.kind}") // B16
                s.window != null -> unchanged(s, "nested window ${event.kind}") // B14
                else -> { // B10
                    val phaseBefore = s.phase
                    val preempts = drained?.stage == DrainedStage.Draining
                    val next = s.copy(
                        window = event.kind,
                        windowsOpened = s.windowsOpened + 1,
                        drained = if (preempts) drained!!.copy(stage = DrainedStage.Preempted) else drained,
                    )
                    val effects = buildList {
                        if (phaseBefore is IdentityPhase.Open || phaseBefore is IdentityPhase.Draining) {
                            add(BarrierEffect.Revoke(next.toPublic()))
                        }
                        add(BarrierEffect.CancelJobs(e, logNames = false))
                        if (preempts) add(BarrierEffect.SignalPreempted)
                    }
                    next to effects
                }
            }

            is BarrierEvent.WindowAccount -> if (s.window != null) {
                s.copy(latestAccount = event.account) to emptyList() // B11
            } else {
                outOfOrder(s, event)
            }

            is BarrierEvent.WindowClosed -> if (s.window != null) {
                s.copy(window = null).settle(s, event.slotAfter) to emptyList() // B12
            } else {
                outOfOrder(s, event)
            }
        }
    }

    private fun drainEndedWhileDraining(
        s: BarrierState,
        drained: DrainedOp,
        event: BarrierEvent.DrainEnded,
    ): Pair<BarrierState, List<BarrierEffect>> {
        val e = s.epoch
        val applying = s.copy(drained = drained.copy(stage = DrainedStage.Applying))
        return when (event.how) {
            DrainEnd.Settled -> // B2
                applying to listOf(BarrierEffect.CancelJobs(e, logNames = false), BarrierEffect.RunApply)
            DrainEnd.JobsDeadline -> // B3 (decision F)
                applying to listOf(
                    BarrierEffect.CancelJobs(e, logNames = true),
                    BarrierEffect.Log("drain deadline: jobs still running, cancelled"),
                    BarrierEffect.RunApply,
                )
            DrainEnd.TeardownUnconfirmed -> if (drained.kind.isProfileKind) {
                // B3a (revision 7): released at once; with no window open, Open with the same
                // epoch and scope (nothing changed, no bump, no cancellation). A window open here
                // would settle at B12; in this state it cannot be (B10 makes Draining Preempted).
                s.copy(drained = null) to listOf(
                    BarrierEffect.Log("teardown unconfirmed: ${drained.kind} failed closed"),
                    BarrierEffect.EndFailed,
                )
            } else {
                // B3b: account kinds proceed closed.
                applying to listOf(
                    BarrierEffect.CancelJobs(e, logNames = true),
                    BarrierEffect.Log("teardown unconfirmed: ${drained.kind} proceeds closed"),
                    BarrierEffect.RunApply,
                )
            }
            // Only sent after B10 made the stage Preempted; Draining here is out of order.
            DrainEnd.Preempted -> outOfOrder(s, event)
        }
    }

    /** B7/B8: an account kind applying, or a profile kind that passed the gate. */
    private fun DrainedOp?.mayFinish(): Boolean =
        this != null && stage == DrainedStage.Applying && (kind.isAccountKind || gated)

    /** Drops the drained hold and settles if that released the last hold. */
    private fun BarrierState.release(slotAfter: Int): BarrierState = copy(drained = null).settle(this, slotAfter)

    /** settle(s): if both holds are now null and the phase before was not Open, bump once. */
    private fun BarrierState.settle(before: BarrierState, slotAfter: Int): BarrierState {
        if (drained != null || window != null || before.phase is IdentityPhase.Open) return this
        val slot = if (slotAfter == SLOT_UNSET) scope.slot else slotAfter
        return copy(epoch = epoch.next(), scope = IdentityScope(latestAccount, slot))
    }

    private fun unchanged(s: BarrierState, line: String) = s to listOf<BarrierEffect>(BarrierEffect.Log(line))

    private fun outOfOrder(s: BarrierState, event: BarrierEvent) =
        // No event payload in the line: WindowAccount carries a user id.
        unchanged(s, "out-of-order: ${event::class.simpleName} in ${s.phase::class.simpleName} drained=${s.drained} window=${s.window}") // B15
}
