package com.nuvio.app.core.identity

import kotlin.test.Test
import kotlin.test.assertEquals

/** Spec 3.5: drained {null, kind × stage} × window × account relation against an oracle. */
class AccountLevelDecisionTest {

    private enum class AccountRel { Same, Other, OtherSerial }

    private val drainedKinds = TransitionKind.entries.filter { it.drains }
    private val accountKinds = setOf(TransitionKind.SignOut, TransitionKind.DeleteAccount, TransitionKind.ServerSwitch)

    private fun oracle(drained: DrainedOp?, window: TransitionKind?, recovery: RecoveryReason?, rel: AccountRel): Verdict = when {
        window != null || recovery != null -> Verdict.Reject(RejectReason.WritesClosed)
        drained != null && drained.kind in accountKinds && drained.stage != DrainedStage.Draining ->
            Verdict.Reject(RejectReason.WritesClosed)
        rel != AccountRel.Same -> Verdict.Reject(RejectReason.AccountChanged)
        else -> Verdict.Commit
    }

    @Test
    fun everyCombination() {
        val drainedAxis: List<DrainedOp?> = listOf<DrainedOp?>(null) +
            drainedKinds.flatMap { k -> DrainedStage.entries.map { DrainedOp(k, it, windowsAtBegin = 0, transitionId = 1) } }
        val windows = listOf(null, TransitionKind.AccountWipe, TransitionKind.AccountPublished)
        var count = 0
        val recoveries = listOf<RecoveryReason?>(null) + RecoveryReason.entries
        for (drained in drainedAxis) for (window in windows) for (recovery in recoveries) for (rel in AccountRel.entries) {
            val token = AccountToken(
                account = if (rel == AccountRel.Other) accountB else accountA,
                authSerial = if (rel == AccountRel.OtherSerial) 2 else 1,
            )
            val actual = CommitDecision.decideAccountLevel(token, drained, window, recovery, accountA, 1)
            assertEquals(oracle(drained, window, recovery, rel), actual, "$drained $window $recovery $rel")
            count++
        }
        assertEquals(19 * 3 * 3 * 3, count)
    }

    @Test
    fun profileApplyWithWindowRefuses() {
        val drained = DrainedOp(TransitionKind.ActiveProfileDelete, DrainedStage.Applying, 0, transitionId = 1, gated = true)
        assertEquals(
            Verdict.Reject(RejectReason.WritesClosed),
            CommitDecision.decideAccountLevel(AccountToken(accountA, 1), drained, TransitionKind.AccountWipe, null, accountA, 1),
        )
    }

    @Test
    fun profileBarrierDoesNotRefuseAccountWork() {
        DrainedStage.entries.forEach { stage ->
            val drained = DrainedOp(TransitionKind.ProfileSelect, stage, 0, transitionId = 1)
            assertEquals(Verdict.Commit, CommitDecision.decideAccountLevel(AccountToken(accountA, 1), drained, null, null, accountA, 1))
        }
    }
}
