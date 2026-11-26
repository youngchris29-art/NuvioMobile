package com.nuvio.app.core.identity

import com.nuvio.app.core.auth.AuthState

/*
 * Identity value types (fork-only). One identity = whose data it is: the account (or local guest)
 * plus the profile slot, stamped with the barrier epoch and the live auth serial.
 *
 * Design: docs/batch-scope-identity-spec.md, section 3.1.
 */

/** The account the published auth state names. */
sealed interface AccountKey {
    data class Account(val userId: String) : AccountKey
    data class Guest(val guestId: String) : AccountKey
    data object None : AccountKey

    /** "account:<id>" / "guest:<id>"; None has no storage key. Used by persisted deferred work. */
    fun storageKey(): String? = when (this) {
        is Account -> ACCOUNT_PREFIX + userId
        is Guest -> GUEST_PREFIX + guestId
        None -> null
    }

    companion object {
        private const val ACCOUNT_PREFIX = "account:"
        private const val GUEST_PREFIX = "guest:"

        /** Authenticated(isAnonymous=false) → Account; Authenticated(isAnonymous=true) → Guest; Loading, Unauthenticated → None. */
        fun of(state: AuthState): AccountKey = when (state) {
            is AuthState.Authenticated -> if (state.isAnonymous) Guest(state.userId) else Account(state.userId)
            AuthState.Loading, AuthState.Unauthenticated -> None
        }

        /** Inverse of [storageKey]; null or malformed → null. */
        fun parse(storageKey: String?): AccountKey? {
            if (storageKey == null) return null
            return when {
                storageKey.startsWith(ACCOUNT_PREFIX) ->
                    storageKey.removePrefix(ACCOUNT_PREFIX).takeIf { it.isNotEmpty() }?.let(::Account)
                storageKey.startsWith(GUEST_PREFIX) ->
                    storageKey.removePrefix(GUEST_PREFIX).takeIf { it.isNotEmpty() }?.let(::Guest)
                else -> null
            }
        }
    }
}

data class IdentityScope(val account: AccountKey, val slot: Int)

data class IdentityEpoch(val value: Long) : Comparable<IdentityEpoch> {
    override fun compareTo(other: IdentityEpoch): Int = value.compareTo(other.value)
    fun next(): IdentityEpoch = IdentityEpoch(value + 1)
    companion object { val Initial = IdentityEpoch(0) }
}

/** What a piece of work captured when it started: scope, epoch and the live auth serial. */
data class IdentityToken(val scope: IdentityScope, val epoch: IdentityEpoch, val authSerial: Long)

/** Account-level work (profile lists, account pushes) belongs to the account, not a profile (3.5). */
data class AccountToken(val account: AccountKey, val authSerial: Long)

sealed interface IdentityPhase {
    data object Open : IdentityPhase
    data class Draining(val from: IdentityEpoch) : IdentityPhase
    data class Closed(val from: IdentityEpoch) : IdentityPhase
    data class Applying(val from: IdentityEpoch) : IdentityPhase
}

enum class CommitKind { LocalWrite, RemoteSend, Publish, Start }

enum class RejectReason { StaleEpoch, AccountChanged, BarrierInProgress, WritesClosed, Impossible }

sealed interface Verdict {
    data object Commit : Verdict
    data class Reject(val reason: RejectReason) : Verdict
}

enum class TransitionKind {
    ProfileSelect, ActiveProfileDelete, SlotRemoved, SignOut, DeleteAccount, ServerSwitch, // drained
    AccountPublished, AccountWipe;                                                          // immediate

    val drains: Boolean get() = this != AccountPublished && this != AccountWipe

    /** A drained kind that only moves who is active (3.4: `profile(k)`). */
    internal val isProfileKind: Boolean
        get() = this == ProfileSelect || this == ActiveProfileDelete || this == SlotRemoved

    /** A drained kind that resets the account (3.4: `account(k)`). */
    internal val isAccountKind: Boolean
        get() = this == SignOut || this == DeleteAccount || this == ServerSwitch
}

/** What observers (Swift `IdentityModel`, Kotlin) see. */
data class IdentityState(
    val scope: IdentityScope,
    val epoch: IdentityEpoch,
    val phase: IdentityPhase,
    /** Non-null exactly while phase != Open. */
    val kind: TransitionKind?,
    /** Revision 8: the id of the drained transition in progress (0 when none); Swift echoes it in teardownDone. */
    val transitionId: Long = 0,
) {
    val transitioning: Boolean get() = phase !is IdentityPhase.Open
}
