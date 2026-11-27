package com.nuvio.app.core.identity

import co.touchlab.kermit.Logger
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Job
import kotlinx.coroutines.flow.StateFlow
import kotlin.concurrent.Volatile

/*
 * The public identity gate (fork-only): tokens, checks and commits. Every decision reads the
 * barrier state and the live auth serial inside the commit lock.
 *
 * Design: docs/batch-scope-identity-spec.md, section 4.2.
 */

sealed interface CommitResult<out T> {
    data class Committed<T>(val value: T) : CommitResult<T>
    data class Rejected(val reason: RejectReason) : CommitResult<Nothing>
}

sealed interface PersistedResult<out T> {
    data class Recorded<T>(val value: T) : PersistedResult<T>
    data object Parked : PersistedResult<Nothing>
    data class Dropped(val reason: DropReason) : PersistedResult<Nothing>
}

/** Rule D: the remote follow-up of a committed local write, admitted in the commit's own section. */
class FollowUp(val name: String, val scope: CoroutineScope, val block: suspend CoroutineScope.() -> Unit)

object IdentityGate {
    private val log = Logger.withTag("Identity")
    private const val UNNAMED_SITE = "unnamed"

    val state: StateFlow<IdentityState> get() = IdentityRuntime.state

    /** W4: true on tvOS; an upsert without a captured token is refused (10, item 2). */
    @Volatile
    var requireTokenedSessions: Boolean = false

    /** Rejections already logged for the current epoch: "<site>|<reason>". Under the commit lock. */
    private val loggedRejects = mutableSetOf<String>()
    private var loggedEpoch: IdentityEpoch = IdentityEpoch.Initial

    /** Null unless phase is Open (decision H: no new work starts during a barrier). */
    fun currentToken(): IdentityToken? = IdentityLocks.withCommit {
        val model = IdentityRuntime.snapshot()
        if (model.phase is IdentityPhase.Open) {
            IdentityToken(model.scope, model.epoch, IdentityRuntime.authSerial())
        } else {
            null
        }
    }

    /** Null while an account hold is closed (a window, Recovery, or an account kind past its drain; 3.5). */
    fun currentAccountToken(): AccountToken? = IdentityLocks.withCommit {
        val model = IdentityRuntime.snapshot()
        val closed = model.window != null || model.recovery != null || model.drained?.let {
            it.kind.isAccountKind && it.stage != DrainedStage.Draining
        } == true
        if (closed) null else AccountToken(model.latestAccount, IdentityRuntime.authSerial())
    }

    /**
     * Rule G (31.1): the token a picker row is displayed and PIN-checked under, passed in a
     * SelectRequest. Minted while Open and in Recovery(FailedApply) (the picker is on screen and a
     * select is the retry, B20a); null while a window or drained transition holds or in the other
     * recovery reasons. Departure: the spec names currentAccountToken(), which is null in Recovery.
     */
    fun selectionToken(): AccountToken? = IdentityLocks.withCommit {
        val model = IdentityRuntime.snapshot()
        val usable = model.window == null && model.drained == null &&
            (model.recovery == null || model.recovery == RecoveryReason.FailedApply)
        if (usable) AccountToken(model.latestAccount, IdentityRuntime.authSerial()) else null
    }

    fun currentEpoch(): IdentityEpoch = IdentityRuntime.snapshot().epoch

    /** Null token → Reject(WritesClosed). */
    fun check(token: IdentityToken?, kind: CommitKind): Verdict = check(token, kind, UNNAMED_SITE)

    /** [check] with the call-site name used for the once-per-epoch rejection log (4.2). */
    fun check(token: IdentityToken?, kind: CommitKind, site: String): Verdict =
        IdentityLocks.withCommit { decideLocked(token, kind) }.also { logVerdict(it, site) }

    fun checkAccount(token: AccountToken?): Verdict = checkAccount(token, UNNAMED_SITE)

    fun checkAccount(token: AccountToken?, site: String): Verdict =
        IdentityLocks.withCommit { decideAccountLocked(token) }.also { logVerdict(it, site) }

    /** NOT inline: [block] cannot suspend. Runs [block] under the commit lock iff the verdict is Commit. */
    fun <T> commit(token: IdentityToken?, kind: CommitKind, site: String = UNNAMED_SITE, block: () -> T): CommitResult<T> {
        var verdict: Verdict = Verdict.Commit
        val result = IdentityLocks.withCommit {
            verdict = decideLocked(token, kind)
            when (val v = verdict) {
                Verdict.Commit -> CommitResult.Committed(block())
                is Verdict.Reject -> CommitResult.Rejected(v.reason)
            }
        }
        logVerdict(verdict, site)
        return result
    }

    fun <T> commitAccount(token: AccountToken?, site: String = UNNAMED_SITE, block: () -> T): CommitResult<T> {
        var verdict: Verdict = Verdict.Commit
        val result = IdentityLocks.withCommit {
            verdict = decideAccountLocked(token)
            when (val v = verdict) {
                Verdict.Commit -> CommitResult.Committed(block())
                is Verdict.Reject -> CommitResult.Rejected(v.reason)
            }
        }
        logVerdict(verdict, site)
        return result
    }

    /**
     * Decision, token minting and the caller's block are ONE step under the commit lock. [block]
     * receives the token valid at that instant; it consumes the session and does the local write
     * synchronously; remote follow-ups are launched with that token afterwards.
     */
    fun <T> commitPersisted(
        sessionAccountKey: String?,
        sessionSlot: Int,
        block: (IdentityToken) -> T,
    ): PersistedResult<T> = IdentityLocks.withCommit {
        val model = IdentityRuntime.snapshot()
        when (val verdict = PersistedClaimDecision.decide(sessionAccountKey, sessionSlot, model.phase, model.scope)) {
            ClaimVerdict.Record ->
                PersistedResult.Recorded(block(IdentityToken(model.scope, model.epoch, IdentityRuntime.authSerial())))
            ClaimVerdict.Park -> PersistedResult.Parked
            is ClaimVerdict.Drop -> PersistedResult.Dropped(verdict.reason)
        }
    }

    /** Tests only: runs between a follow-up's admission section and its start (rule D interleavings). */
    internal var afterFollowUpAdmitted: () -> Unit = {}

    /**
     * Rule D: one commit section decides, runs [block], then creates (LAZY) and registers the
     * follow-up as RemoteSend work of the token's class; the job starts after the section, so a
     * drain that begins afterwards counts it and no drain can end between the local commit and the
     * admission. Refused: neither runs. [block] throws: the exception propagates, nothing is
     * admitted. [followUp] returns null: nothing is admitted.
     */
    fun <T> commitWithFollowUp(
        token: IdentityToken?,
        kind: CommitKind,
        site: String,
        block: () -> T,
        followUp: (T) -> FollowUp?,
    ): CommitResult<T> {
        var verdict: Verdict = Verdict.Commit
        var admitted: Job? = null
        val result = IdentityLocks.withCommit {
            verdict = decideLocked(token, kind)
            when (val v = verdict) {
                Verdict.Commit -> {
                    val value = block()
                    followUp(value)?.let { admitted = admitFollowUpLocked(token!!, it) }
                    CommitResult.Committed(value)
                }
                is Verdict.Reject -> CommitResult.Rejected(v.reason)
            }
        }
        admitted?.let { startFollowUp(it) } // first: nothing after the section may leave it unstarted
        logVerdict(verdict, site)
        return result
    }

    /** Rule D for the persisted claim (3.3): decision, token, local write and follow-up admission in one section. */
    fun <T> commitPersistedWithFollowUp(
        sessionAccountKey: String?,
        sessionSlot: Int,
        site: String,
        block: (IdentityToken) -> T,
        followUp: (T, IdentityToken) -> FollowUp?,
    ): PersistedResult<T> {
        var admitted: Job? = null
        val result = IdentityLocks.withCommit {
            val model = IdentityRuntime.snapshot()
            when (val verdict = PersistedClaimDecision.decide(sessionAccountKey, sessionSlot, model.phase, model.scope)) {
                ClaimVerdict.Record -> {
                    val token = IdentityToken(model.scope, model.epoch, IdentityRuntime.authSerial())
                    val value = block(token)
                    followUp(value, token)?.let { admitted = admitFollowUpLocked(token, it) }
                    PersistedResult.Recorded(value)
                }
                ClaimVerdict.Park -> PersistedResult.Parked
                is ClaimVerdict.Drop -> PersistedResult.Dropped(verdict.reason)
            }
        }
        admitted?.let { startFollowUp(it) } // first: nothing after the section may leave it unstarted
        if (result !is PersistedResult.Recorded) log.i { "[Identity] persisted claim $site: ${result::class.simpleName}" }
        return result
    }

    private fun admitFollowUpLocked(token: IdentityToken, followUp: FollowUp): Job =
        IdentityWork.registerLocked(
            followUp.name, followUp.scope, IdentityJobElement(token, followUp.name), WorkClass.Profile(token.scope), followUp.block,
        )

    private fun startFollowUp(job: Job) {
        try {
            afterFollowUpAdmitted()
        } finally {
            IdentityWork.startAdmitted(job) // always started: a LAZY job is never left unstarted
        }
    }

    /** Under the commit lock. */
    internal fun decideLocked(token: IdentityToken?, kind: CommitKind): Verdict {
        if (token == null) return Verdict.Reject(RejectReason.WritesClosed)
        val model = IdentityRuntime.snapshot()
        return CommitDecision.decide(token, model.phase, model.scope, model.epoch, IdentityRuntime.authSerial(), kind)
    }

    /** Under the commit lock. */
    internal fun decideAccountLocked(token: AccountToken?): Verdict {
        if (token == null) return Verdict.Reject(RejectReason.WritesClosed)
        val model = IdentityRuntime.snapshot()
        return CommitDecision.decideAccountLevel(
            token, model.drained, model.window, model.recovery, model.latestAccount, IdentityRuntime.authSerial(),
        )
    }

    /** Info once per (site, reason) per epoch; Impossible at error level always. */
    internal fun logVerdict(verdict: Verdict, site: String) {
        if (verdict !is Verdict.Reject) return
        if (verdict.reason == RejectReason.Impossible) {
            log.e { "[Identity] reject ${verdict.reason} $site" }
            return
        }
        val first = IdentityLocks.withCommit {
            val epoch = IdentityRuntime.snapshot().epoch
            if (epoch != loggedEpoch) {
                loggedEpoch = epoch
                loggedRejects.clear()
            }
            loggedRejects.add("$site|${verdict.reason}")
        }
        if (first) log.i { "[Identity] reject ${verdict.reason} $site" }
    }

    /** Tests only. */
    internal fun resetForTest() {
        IdentityLocks.withCommit {
            loggedRejects.clear()
            loggedEpoch = IdentityEpoch.Initial
        }
        requireTokenedSessions = false
    }
}
