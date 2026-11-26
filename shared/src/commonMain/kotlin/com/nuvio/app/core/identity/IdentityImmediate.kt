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
        IdentityEffects.run(IdentityRuntime.reduceStep(BarrierEvent.WindowAccount(account)))
        IdentityLocks.withApply { ActiveProfileProvider.changing { onAccountPublished(account) } }
        write()
    }

    /** Called by the auth driver before it updates its ticket whenever a reduction changes the live serial. */
    fun serialChanging() {
        openIfNeeded(TransitionKind.AccountWipe)
    }

    /** Called by the auth driver when a top-level step chain returns (also when it threw). */
    fun chainEnded() {
        if (IdentityRuntime.snapshot().window == null) return
        IdentityEffects.run(IdentityRuntime.reduceStep(BarrierEvent.WindowClosed(SLOT_UNSET)))
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
        afterOpenScope = CoroutineScope(SupervisorJob() + Dispatchers.Default + uncaughtCoroutineLogger("IdentityImmediate"))
    }
}
