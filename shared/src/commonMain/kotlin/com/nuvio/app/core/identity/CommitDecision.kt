package com.nuvio.app.core.identity

/*
 * The pure commit decisions (fork-only): may work stamped with a token commit now?
 *
 * Design: docs/batch-scope-identity-spec.md, sections 3.2 (decide), 3.3 (PersistedClaimDecision)
 * and 3.5 (decideAccountLevel). Every rule is enumerated against an oracle in the tests.
 */
object CommitDecision {

    /** Rules R1–R8 of spec 3.2, applied in order; the first that matches decides. */
    fun decide(
        token: IdentityToken,
        phase: IdentityPhase,
        currentScope: IdentityScope,
        currentEpoch: IdentityEpoch,
        currentAuthSerial: Long,
        kind: CommitKind,
    ): Verdict {
        // R1: a token from the future cannot exist.
        if (token.epoch > currentEpoch) return reject(RejectReason.Impossible)
        // R2: a held phase always names the current epoch.
        val from = phase.from()
        if (from != null && from != currentEpoch) return reject(RejectReason.Impossible)
        // R3
        if (phase is IdentityPhase.Closed || phase is IdentityPhase.Applying || phase is IdentityPhase.Recovery) {
            return reject(RejectReason.WritesClosed)
        }
        // R4: reported before a stale epoch.
        if (token.scope.account != currentScope.account || token.authSerial != currentAuthSerial) {
            return reject(RejectReason.AccountChanged)
        }
        // R5
        if (token.epoch < currentEpoch) return reject(RejectReason.StaleEpoch)
        // R6: the slot only changes with the epoch.
        if (token.scope.slot != currentScope.slot) return reject(RejectReason.Impossible)
        // R7: decision H, no new work starts during a drain.
        if (phase is IdentityPhase.Draining && kind == CommitKind.Start) return reject(RejectReason.BarrierInProgress)
        // R8
        return Verdict.Commit
    }

    /**
     * Account-level work (3.5): reads both holds, never the public kind. Profile-kind barriers do
     * not refuse it.
     */
    internal fun decideAccountLevel(
        token: AccountToken,
        drained: DrainedOp?,
        window: TransitionKind?,
        recovery: RecoveryReason?,
        currentAccount: AccountKey,
        currentAuthSerial: Long,
    ): Verdict {
        if (window != null || recovery != null) return reject(RejectReason.WritesClosed)
        if (drained != null && drained.kind.isAccountKind &&
            (drained.stage == DrainedStage.Preempted || drained.stage == DrainedStage.Applying)
        ) {
            return reject(RejectReason.WritesClosed)
        }
        if (token.account != currentAccount || token.authSerial != currentAuthSerial) {
            return reject(RejectReason.AccountChanged)
        }
        return Verdict.Commit
    }

    private fun reject(reason: RejectReason) = Verdict.Reject(reason)
}

internal fun IdentityPhase.from(): IdentityEpoch? = when (this) {
    IdentityPhase.Open -> null
    is IdentityPhase.Draining -> from
    is IdentityPhase.Closed -> from
    is IdentityPhase.Applying -> from
    is IdentityPhase.Recovery -> from
}

sealed interface ClaimVerdict {
    /** Record now, with a fresh token. */
    data object Record : ClaimVerdict
    /** A barrier is running: keep the callback, replay at the next entry. */
    data object Park : ClaimVerdict
    data class Drop(val reason: DropReason) : ClaimVerdict
}

enum class DropReason { LegacySession, OtherAccount, OtherProfile, SignedOut }

/** Persisted deferred work (the pending external-player session) stores an account key and a slot, never an epoch (3.3). */
object PersistedClaimDecision {
    fun decide(
        sessionAccountKey: String?,
        sessionSlot: Int,
        phase: IdentityPhase,
        currentScope: IdentityScope,
    ): ClaimVerdict {
        val sessionAccount = AccountKey.parse(sessionAccountKey) ?: return ClaimVerdict.Drop(DropReason.LegacySession)
        if (phase !is IdentityPhase.Open) return ClaimVerdict.Park
        if (currentScope.account == AccountKey.None) return ClaimVerdict.Drop(DropReason.SignedOut)
        if (sessionAccount != currentScope.account) return ClaimVerdict.Drop(DropReason.OtherAccount)
        if (sessionSlot != currentScope.slot) return ClaimVerdict.Drop(DropReason.OtherProfile)
        return ClaimVerdict.Record
    }
}
