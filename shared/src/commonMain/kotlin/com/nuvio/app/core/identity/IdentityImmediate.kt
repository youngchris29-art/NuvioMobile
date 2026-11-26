package com.nuvio.app.core.identity

import co.touchlab.kermit.Logger
import com.nuvio.app.core.auth.AuthState
import com.nuvio.app.core.coroutines.uncaughtCoroutineLogger
import com.nuvio.app.core.profile.ActiveProfileProvider
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.launch
import kotlin.concurrent.Volatile

/*
 * Auth windows (fork-only): one closed window per top-level auth step chain, from the first
 * identity effect in it (a serial change, a wipe or an account-changing publish) to the end of the
 * chain. All calls come from the auth lane, which serializes them. Nothing calls this in W1; W2
 * wires AuthRepository's RealAuthEffects and the two AuthSessionDriver hooks to it.
 *
 * Design: docs/batch-scope-identity-spec.md, section 4.5 (revision 7).
 */
internal object IdentityImmediate {
    private val log = Logger.withTag("Identity")

    /** tvOS installs TvOsIdentityHooks.accountPublished (W2): ensureLoaded, add-on reset, fan-out. */
    @Volatile
    var onAccountPublished: (AccountKey) -> Unit = {}

    /** Run after any settle to Open with a changed account (5.7; revision 8: fired from IdentityRuntime). */
    @Volatile
    var afterAccountOpen: () -> Unit = {}

    /**
     * Review r3-3: the recovery run, under the same window and the apply lock, when a publish's hook
     * or auth write threw part-way (it may have loaded [failed]'s profiles). [shown] is the account
     * AuthRepository.state still shows. Default: re-run the publish hook for [shown], which reloads
     * its profiles, resets add-ons and fans out (5.7). W2 may install a stronger recovery.
     */
    @Volatile
    var recoverAfterFailedPublish: (failed: AccountKey, shown: AccountKey) -> Unit = { _, shown -> onAccountPublished(shown) }

    /** Set when a publish in the open window threw; read and cleared by [chainEnded]. Auth lane only. */
    @Volatile
    private var failedPublish: AccountKey? = null

    /** Where [afterAccountOpen] is launched: Default, fire-and-forget, outside every lock. */
    internal var afterOpenScope: CoroutineScope =
        CoroutineScope(SupervisorJob() + Dispatchers.Default + uncaughtCoroutineLogger("IdentityImmediate"))

    /** Wraps AuthRepository.RealAuthEffects.wipeAccountData. */
    fun accountWipe(wipe: () -> Unit) {
        openIfNeeded(TransitionKind.AccountWipe)
        IdentityLocks.withApply { ActiveProfileProvider.changing { wipe() } }
    }

    /** Wraps AuthRepository.RealAuthEffects.publish: [write] is `_state.value = state`. */
    fun publishAuth(state: AuthState, write: () -> Unit) {
        val account = AccountKey.of(state)
        val model = IdentityRuntime.snapshot()
        if (model.window == null && account == model.latestAccount) {
            write()
            return
        }
        openIfNeeded(TransitionKind.AccountPublished)
        try {
            IdentityLocks.withApply { ActiveProfileProvider.changing { onAccountPublished(account) } }
            write()
        } catch (t: Throwable) {
            // The hook may have mutated profile state for [account] before it threw: chainEnded
            // must recover before the gate opens (review r3-3).
            failedPublish = account
            throw t
        }
        failedPublish = null
        // Review r2-1: the window's account is recorded only after the hook and the auth write
        // succeeded. If either throws, the window still holds (no token exists) and chainEnded
        // settles it on the account AuthRepository.state still shows.
        IdentityEffects.run(IdentityRuntime.reduceStep(BarrierEvent.WindowAccount(account)))
    }

    /** Called by the auth driver before it updates its ticket whenever a reduction changes the live serial. */
    fun serialChanging() {
        openIfNeeded(TransitionKind.AccountWipe)
    }

    /** Called by the auth driver when a top-level step chain returns (also when it threw). */
    fun chainEnded() {
        val model = IdentityRuntime.snapshot()
        if (model.window == null) return
        val failed = failedPublish
        if (failed != null) {
            failedPublish = null
            recover(failed, model.latestAccount)
        }
        IdentityEffects.run(IdentityRuntime.reduceStep(BarrierEvent.WindowClosed(SLOT_UNSET)))
    }

    /**
     * The gate never opens on an account whose hook failed part-way (review r3-3). Recovery runs
     * once, inside the still-open window; if it succeeds the window settles on [shown] with its
     * state reloaded; if it also throws, the window settles on AccountKey.None (fail closed: every
     * token for [shown] or [failed] is refused, R4, and the next publish of [shown] opens a window
     * and runs the hook again, since None differs from it). Either way the window closes in this
     * same chainEnded, so P3 holds.
     */
    private fun recover(failed: AccountKey, shown: AccountKey) {
        val recovered = try {
            IdentityLocks.withApply { ActiveProfileProvider.changing { recoverAfterFailedPublish(failed, shown) } }
            true
        } catch (t: Throwable) {
            log.e(t) { "[Identity] recovery after a failed publish threw; the gate opens signed out" }
            false
        }
        if (recovered) {
            log.w { "[Identity] publish failed part-way; recovered the shown account before reopening" }
        } else {
            IdentityEffects.run(IdentityRuntime.reduceStep(BarrierEvent.WindowAccount(AccountKey.None)))
        }
    }

    /**
     * Revision 8: IdentityRuntime detects every settle to Open whose account differs from the last
     * Open period's (B12 here, or B7 when a drained account transition outlives its window) and the
     * effect runner calls this after the lock: [afterAccountOpen] on Default, fire-and-forget.
     */
    internal fun launchAfterAccountOpen() {
        val hook = afterAccountOpen
        afterOpenScope.launch {
            try {
                hook()
            } catch (t: Throwable) {
                log.e(t) { "[Identity] afterAccountOpen threw" }
            }
        }
    }

    /** Opens a window of [kind] unless one is open; runs its revoke synchronously (result ignored: windows proceed closed). */
    private fun openIfNeeded(kind: TransitionKind) {
        if (IdentityRuntime.snapshot().window != null) return
        IdentityEffects.run(IdentityRuntime.reduceStep(BarrierEvent.WindowOpened(kind)))
    }

    /** Tests only. */
    internal fun resetForTest() {
        onAccountPublished = {}
        afterAccountOpen = {}
        recoverAfterFailedPublish = { _, shown -> onAccountPublished(shown) }
        failedPublish = null
        afterOpenScope = CoroutineScope(SupervisorJob() + Dispatchers.Default + uncaughtCoroutineLogger("IdentityImmediate"))
    }
}
