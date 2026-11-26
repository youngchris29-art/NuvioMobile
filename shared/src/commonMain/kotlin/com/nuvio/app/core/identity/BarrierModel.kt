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
    /** Revision 8: the Begin's id; Swift echoes it in teardownDone. */
    val transitionId: Long,
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
    /** Revision 8: counts every accepted Begin; the next Begin's transitionId. */
    val transitionsBegun: Long,
    /** The account in AuthRepository.state (written inside the window, 4.5). */
    val latestAccount: AccountKey,
    val version: Long,
    /** Hold 3 (revision 10, rule B): recovery required. */
    val recovery: RecoveryReason? = null,
) {
    val phase: IdentityPhase
        get() = when {
            drained == null && window == null && recovery == null -> IdentityPhase.Open
            drained == null && window == null -> IdentityPhase.Recovery(epoch)
            // An account drain begun from Recovery (B21) is not Draining: old tokens of this epoch
            // must not commit while recovery holds (rule B: nothing writes), so it reads Closed.
            window == null && recovery == null && drained!!.stage == DrainedStage.Draining -> IdentityPhase.Draining(epoch)
            drained?.stage == DrainedStage.Applying -> IdentityPhase.Applying(epoch)
            else -> IdentityPhase.Closed(epoch)
        }

    /** No hold at all. */
    val allReleased: Boolean get() = drained == null && window == null && recovery == null

    /** The public kind: `drained?.kind ?: window`. */
    val kind: TransitionKind? get() = drained?.kind ?: window

    fun toPublic(): IdentityState =
        IdentityState(
            scope = scope, epoch = epoch, phase = phase, kind = kind,
            transitionId = drained?.transitionId ?: 0, recovery = recovery,
        )

    companion object {
        fun initial(slot: Int): BarrierState = BarrierState(
            epoch = IdentityEpoch.Initial,
            scope = IdentityScope(AccountKey.None, slot),
            drained = null,
            window = null,
            windowsOpened = 0,
            transitionsBegun = 0,
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

    /**
     * Profile kinds; sent under the apply lock right before the body. [slotAfter] as in [DrainEnded].
     * [effectsBusy] (revision 10, rule C) is filled by the runtime: effects of an earlier step are
     * still in flight, which ends the transition EndPreempted.
     */
    data class ApplyGate(val slotAfter: Int = SLOT_UNSET, val effectsBusy: Boolean = false) : BarrierEvent
    data class ApplyFinished(val slotAfter: Int) : BarrierEvent
    data class ApplyThrew(val slotAfter: Int, val error: String) : BarrierEvent
    data class Abandoned(val slotAfter: Int) : BarrierEvent

    /** Immediate kinds only. */
    data class WindowOpened(val kind: TransitionKind) : BarrierEvent
    data class WindowAccount(val account: AccountKey) : BarrierEvent
    data class WindowClosed(val slotAfter: Int) : BarrierEvent

    /** Revision 10, rule B: a publish and its recovery failed, or a wipe threw (inside a window). */
    data class RecoveryRequired(val reason: RecoveryReason) : BarrierEvent

    /** Revision 10, rule B: the account wipe completed (inside a window). */
    data object WipeSucceeded : BarrierEvent
}

/** Fills the slot of every finishing event with [slot] (read by the runtime under the commit lock, 4.1). */
internal fun BarrierEvent.withSlot(slot: Int): BarrierEvent = when (this) {
    is BarrierEvent.DrainEnded -> copy(slotAfter = slot)
    is BarrierEvent.ApplyGate -> copy(slotAfter = slot)
    is BarrierEvent.ApplyFinished -> copy(slotAfter = slot)
    is BarrierEvent.ApplyThrew -> copy(slotAfter = slot)
    is BarrierEvent.Abandoned -> copy(slotAfter = slot)
    is BarrierEvent.WindowClosed -> copy(slotAfter = slot)
    is BarrierEvent.Begin, is BarrierEvent.WindowOpened, is BarrierEvent.WindowAccount,
    is BarrierEvent.RecoveryRequired, BarrierEvent.WipeSucceeded -> this
}

internal sealed interface BarrierEffect {
    /** Synchronous Swift revocation (4.6). */
    data class Revoke(val state: IdentityState) : BarrierEffect
    /** Revision 8: keyed by the Begin, not the epoch. */
    data class AwaitDrain(val transitionId: Long) : BarrierEffect

    /**
     * Revision 8: cancels by class per CancelPolicy for [kind] (4.3a); the runtime takes the job
     * snapshot inside the reducing section.
     */
    data class CancelJobs(val kind: TransitionKind, val logNames: Boolean) : BarrierEffect
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
        val drained = s.drained
        return when (event) {
            is BarrierEvent.Begin -> when {
                !event.kind.drains -> unchanged(s, "wrong lane: begin ${event.kind}") // B16
                drained != null || s.window != null -> unchanged(s, "begin refused: held") // B13
                // B20: recovery holds; a profile transition cannot begin.
                s.recovery != null && event.kind.isProfileKind ->
                    s to listOf(BarrierEffect.Log("begin refused: recovery required (${s.recovery})"), BarrierEffect.EndFailed)
                else -> { // B1, or B21 from Recovery (account kinds)
                    val id = s.transitionsBegun + 1
                    val next = s.copy(
                        transitionsBegun = id,
                        drained = DrainedOp(event.kind, DrainedStage.Draining, s.windowsOpened, transitionId = id),
                    )
                    next to listOf(BarrierEffect.Revoke(next.toPublic()), BarrierEffect.AwaitDrain(id))
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
                // B6 (rule C: effects still in flight end it like a counted window)
                s.windowsOpened == drained.windowsAtBegin && !event.effectsBusy ->
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
                    BarrierEffect.CancelJobs(drained.kind, logNames = true),
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
                        add(BarrierEffect.CancelJobs(event.kind, logNames = false))
                        if (preempts) add(BarrierEffect.SignalPreempted)
                    }
                    next to effects
                }
            }

            is BarrierEvent.WindowAccount -> if (s.window != null) {
                // B11; B18: a successful publish clears FailedPublish (never FailedWipe).
                val recovery = if (s.recovery == RecoveryReason.FailedPublish) null else s.recovery
                s.copy(latestAccount = event.account, recovery = recovery) to emptyList()
            } else {
                outOfOrder(s, event)
            }

            is BarrierEvent.RecoveryRequired -> if (s.window != null) {
                // B17; FailedWipe is never downgraded to FailedPublish.
                val recovery = if (s.recovery == RecoveryReason.FailedWipe) s.recovery else event.reason
                s.copy(recovery = recovery) to listOf(BarrierEffect.Log("recovery required: ${event.reason}"))
            } else {
                outOfOrder(s, event)
            }

            BarrierEvent.WipeSucceeded -> if (s.window != null) {
                s.copy(recovery = null) to emptyList() // B19
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
        val k = drained.kind
        val applying = s.copy(drained = drained.copy(stage = DrainedStage.Applying))
        return when (event.how) {
            DrainEnd.Settled -> // B2
                applying to listOf(BarrierEffect.CancelJobs(k, logNames = false), BarrierEffect.RunApply)
            DrainEnd.JobsDeadline -> // B3 (decision F)
                applying to listOf(
                    BarrierEffect.CancelJobs(k, logNames = true),
                    BarrierEffect.Log("drain deadline: jobs still running, cancelled"),
                    BarrierEffect.RunApply,
                )
            DrainEnd.TeardownUnconfirmed -> if (drained.kind.isProfileKind) {
                // B3a (revisions 7-8): released at once, Open with the same epoch and scope
                // (nothing changed: no bump, no cancellation). Draining implies no window is open
                // (B10 turns Draining into Preempted), so there is no window branch.
                s.copy(drained = null) to listOf(
                    BarrierEffect.Log("teardown unconfirmed: ${drained.kind} failed closed"),
                    BarrierEffect.EndFailed,
                )
            } else {
                // B3b: account kinds proceed closed.
                applying to listOf(
                    BarrierEffect.CancelJobs(k, logNames = true),
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

    /** settle(s): if all three holds are now null and the phase before was not Open, bump once. */
    private fun BarrierState.settle(before: BarrierState, slotAfter: Int): BarrierState {
        if (!allReleased || before.phase is IdentityPhase.Open) return this
        val slot = if (slotAfter == SLOT_UNSET) scope.slot else slotAfter
        return copy(epoch = epoch.next(), scope = IdentityScope(latestAccount, slot))
    }

    private fun unchanged(s: BarrierState, line: String) = s to listOf<BarrierEffect>(BarrierEffect.Log(line))

    private fun outOfOrder(s: BarrierState, event: BarrierEvent) =
        // No event payload in the line: WindowAccount carries a user id.
        unchanged(s, "out-of-order: ${event::class.simpleName} in ${s.phase::class.simpleName} drained=${s.drained} window=${s.window}") // B15
}
