package com.nuvio.app.core.identity

import com.nuvio.app.core.coroutines.uncaughtCoroutineLogger
import com.nuvio.app.features.profiles.ProfileRepository
import kotlinx.atomicfu.locks.SynchronizedObject
import kotlinx.atomicfu.locks.synchronized
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.Job
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.launch

/*
 * W2 review r1 #3: a profile pull requested while an identity window holds (no account token yet,
 * e.g. the first pull right after a sign-in publishes) is owed, not dropped. One owner records it
 * for the account it was asked for and re-issues it exactly once when the identity opens on that
 * account; an Open on another account drops it (that account's own publish asks again).
 */
internal enum class OwedPullAction { Keep, Drop, Pull }

internal object OwedPullRule {
    fun decide(owed: AccountKey?, phaseOpen: Boolean, openAccount: AccountKey): OwedPullAction = when {
        owed == null || !phaseOpen -> OwedPullAction.Keep
        openAccount == owed -> OwedPullAction.Pull
        else -> OwedPullAction.Drop
    }
}

internal object OwedProfilePull {
    private val lock = SynchronizedObject()
    private var owed: AccountKey? = null
    private var watcher: Job? = null
    private var scope = CoroutineScope(SupervisorJob() + Dispatchers.Default + uncaughtCoroutineLogger("OwedProfilePull"))

    /** Re-issues the pull (tests replace it). */
    var pull: () -> Unit = { scope.launch { ProfileRepository.pullProfiles() } }

    /** Tests only: runs in [wake] before the lock is taken (an interleaving seam). */
    internal var beforeLockForTest: () -> Unit = {}

    /**
     * A pull for [account] was asked for while no account token could be minted. The debt is
     * recorded and decided in one section, against the identity state current in that section.
     */
    fun owe(account: AccountKey) {
        if (account == AccountKey.None) return
        val action = synchronized(lock) {
            owed = account
            if (watcher == null) watcher = scope.launch { IdentityGate.state.collect { wake() } }
            decideLocked()
        }
        if (action == OwedPullAction.Pull) pull()
    }

    /**
     * Review r2 #2: an emission only wakes this; the decision always reads the CURRENT identity
     * state inside the lock that records the debt, so a stale emission (A open) can never consume
     * a debt recorded after it (B, inside B's window).
     */
    internal fun wake() {
        beforeLockForTest()
        val action = synchronized(lock) { decideLocked() }
        if (action == OwedPullAction.Pull) pull()
    }

    private fun decideLocked(): OwedPullAction {
        val state = IdentityGate.state.value
        return OwedPullRule.decide(owed, state.phase is IdentityPhase.Open, state.scope.account).also {
            if (it != OwedPullAction.Keep) owed = null // taken once, under the lock: never twice
        }
    }

    /** Tests only. */
    internal fun resetForTest() {
        synchronized(lock) {
            watcher?.cancel()
            watcher = null
            owed = null
        }
        pull = { scope.launch { ProfileRepository.pullProfiles() } }
        beforeLockForTest = {}
    }
}
