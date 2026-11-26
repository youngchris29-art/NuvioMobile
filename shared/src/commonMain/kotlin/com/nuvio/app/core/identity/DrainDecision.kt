package com.nuvio.app.core.identity

/*
 * The pure parts of the work registry rule (fork-only): which jobs a drain waits for, when it ends,
 * and which jobs a transition cancels. Jobs carry a class fixed at admission, never an epoch.
 *
 * Design: docs/batch-scope-identity-spec.md, section 4.3a (revision 8).
 */

/** The class a job is admitted under. */
internal sealed interface WorkClass {
    /** Launched with an IdentityToken (IdentityWork.launch). */
    data class Profile(val scope: IdentityScope) : WorkClass

    /** Launched with an AccountToken (IdentityWork.launchAccount). */
    data class Account(val account: AccountKey) : WorkClass
}

/** What the drain sees: jobs not marked awaiting-barrier, by class, and whether its teardown ack arrived. */
internal data class DrainView(val profileJobs: Int, val accountJobs: Int, val ackMatched: Boolean)

internal object DrainDecision {
    /** Null = keep waiting; with [deadline] = true it never returns null. */
    fun decide(kind: TransitionKind, view: DrainView, teardownRequired: Boolean, deadline: Boolean): DrainEnd? {
        val awaited = if (kind.isAccountKind) view.profileJobs + view.accountJobs else view.profileJobs
        val teardownOk = !teardownRequired || view.ackMatched
        return when {
            awaited == 0 && teardownOk -> DrainEnd.Settled
            !deadline -> null
            !teardownOk -> DrainEnd.TeardownUnconfirmed
            else -> DrainEnd.JobsDeadline
        }
    }
}

internal object CancelPolicy {
    /**
     * Whether a transition of [kind] (a drained kind at its drain end, an immediate kind at
     * WindowOpened) cancels a job of [cls]. Profile kinds cancel every Profile job and no Account
     * job; account kinds and both window kinds cancel every job.
     */
    fun cancels(kind: TransitionKind, cls: WorkClass): Boolean =
        if (kind.isProfileKind) cls is WorkClass.Profile else true
}
