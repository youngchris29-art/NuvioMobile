package com.nuvio.app.core.identity

import kotlin.test.Test
import kotlin.test.assertEquals

/** Spec 3.2: every combination of the decision's inputs against an oracle written over the rows. */
class CommitDecisionTest {

    private enum class PhaseKind { Open, Draining, Closed, Applying }
    private enum class EpochRel { Older, Equal, Newer }
    private enum class AccountRel { Same, OtherAccount, OtherSerial }

    private data class Case(
        val phase: PhaseKind,
        val fromEqual: Boolean,
        val epoch: EpochRel,
        val account: AccountRel,
        val sameSlot: Boolean,
        val kind: CommitKind,
    )

    private val current = IdentityEpoch(5)
    private val currentScope = IdentityScope(accountA, 2)
    private val currentSerial = 7L

    /** The independent oracle: rows R1–R8 as a `when` over the relations. */
    private fun oracle(c: Case): Verdict = when {
        c.epoch == EpochRel.Newer -> Verdict.Reject(RejectReason.Impossible)
        c.phase != PhaseKind.Open && !c.fromEqual -> Verdict.Reject(RejectReason.Impossible)
        c.phase == PhaseKind.Closed || c.phase == PhaseKind.Applying -> Verdict.Reject(RejectReason.WritesClosed)
        c.account != AccountRel.Same -> Verdict.Reject(RejectReason.AccountChanged)
        c.epoch == EpochRel.Older -> Verdict.Reject(RejectReason.StaleEpoch)
        !c.sameSlot -> Verdict.Reject(RejectReason.Impossible)
        c.phase == PhaseKind.Draining && c.kind == CommitKind.Start -> Verdict.Reject(RejectReason.BarrierInProgress)
        else -> Verdict.Commit
    }

    private fun decide(c: Case): Verdict {
        val from = if (c.fromEqual) current else IdentityEpoch(current.value - 1)
        val phase = when (c.phase) {
            PhaseKind.Open -> IdentityPhase.Open
            PhaseKind.Draining -> IdentityPhase.Draining(from)
            PhaseKind.Closed -> IdentityPhase.Closed(from)
            PhaseKind.Applying -> IdentityPhase.Applying(from)
        }
        val epoch = when (c.epoch) {
            EpochRel.Older -> IdentityEpoch(current.value - 1)
            EpochRel.Equal -> current
            EpochRel.Newer -> current.next()
        }
        val account = if (c.account == AccountRel.OtherAccount) accountB else accountA
        val serial = if (c.account == AccountRel.OtherSerial) currentSerial + 1 else currentSerial
        val slot = if (c.sameSlot) currentScope.slot else currentScope.slot + 1
        val token = IdentityToken(IdentityScope(account, slot), epoch, serial)
        return CommitDecision.decide(token, phase, currentScope, current, currentSerial, c.kind)
    }

    private fun allCases(): List<Case> = buildList {
        for (phase in PhaseKind.entries) {
            val fromAxis = if (phase == PhaseKind.Open) listOf(true) else listOf(true, false)
            for (fromEqual in fromAxis) for (epoch in EpochRel.entries) for (account in AccountRel.entries)
                for (sameSlot in listOf(true, false)) for (kind in CommitKind.entries) {
                    add(Case(phase, fromEqual, epoch, account, sameSlot, kind))
                }
        }
    }

    @Test
    fun everyCombination() {
        val cases = allCases()
        // (1 Open + 3 held × 2 from) × 3 epoch × 3 account × 2 slot × 4 kind.
        assertEquals(504, cases.size)
        cases.forEach { assertEquals(oracle(it), decide(it), "case $it") }
    }

    @Test
    fun openAllEqualCommits() {
        CommitKind.entries.forEach {
            assertEquals(Verdict.Commit, decide(Case(PhaseKind.Open, true, EpochRel.Equal, AccountRel.Same, true, it)))
        }
    }

    @Test
    fun drainingLetsOldWorkCommit() {
        listOf(CommitKind.LocalWrite, CommitKind.RemoteSend, CommitKind.Publish).forEach {
            assertEquals(Verdict.Commit, decide(Case(PhaseKind.Draining, true, EpochRel.Equal, AccountRel.Same, true, it)))
        }
    }

    @Test
    fun drainingRefusesNewWork() {
        assertEquals(
            Verdict.Reject(RejectReason.BarrierInProgress),
            decide(Case(PhaseKind.Draining, true, EpochRel.Equal, AccountRel.Same, true, CommitKind.Start)),
        )
    }

    @Test
    fun closedAndApplyingRefuseWrites() {
        listOf(PhaseKind.Closed, PhaseKind.Applying).forEach {
            assertEquals(
                Verdict.Reject(RejectReason.WritesClosed),
                decide(Case(it, true, EpochRel.Equal, AccountRel.Same, true, CommitKind.LocalWrite)),
            )
        }
    }

    @Test
    fun accountChangeReportedBeforeStaleEpoch() {
        listOf(AccountRel.OtherAccount, AccountRel.OtherSerial).forEach {
            assertEquals(
                Verdict.Reject(RejectReason.AccountChanged),
                decide(Case(PhaseKind.Open, true, EpochRel.Older, it, true, CommitKind.LocalWrite)),
            )
        }
        assertEquals(
            Verdict.Reject(RejectReason.StaleEpoch),
            decide(Case(PhaseKind.Open, true, EpochRel.Older, AccountRel.Same, false, CommitKind.LocalWrite)),
        )
    }

    @Test
    fun newerTokenIsImpossible() {
        assertEquals(
            Verdict.Reject(RejectReason.Impossible),
            decide(Case(PhaseKind.Open, true, EpochRel.Newer, AccountRel.Same, true, CommitKind.LocalWrite)),
        )
    }

    @Test
    fun sameEpochOtherSlotIsImpossible() {
        assertEquals(
            Verdict.Reject(RejectReason.Impossible),
            decide(Case(PhaseKind.Open, true, EpochRel.Equal, AccountRel.Same, false, CommitKind.LocalWrite)),
        )
    }
}
