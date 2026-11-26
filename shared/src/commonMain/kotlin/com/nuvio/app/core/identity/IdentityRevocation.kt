package com.nuvio.app.core.identity

import co.touchlab.kermit.Logger
import kotlin.concurrent.Volatile

/*
 * Synchronous revocation (fork-only) and the runner for reducer effects. The driver and the auth
 * windows run every Revoke effect synchronously before the drain, the apply body, the wipe or the
 * account publish, so ordering never depends on StateFlow delivery.
 *
 * Design: docs/batch-scope-identity-spec.md, section 4.6 (revision 7).
 */

/** Implemented in Swift (`IdentityRevokerImpl`, W2). */
interface IdentityRevoker {
    /** True = the cover window (when the kind has one) is visible and the shell state was revoked. */
    fun revoke(state: IdentityState): Boolean
}

object IdentityRevocation {
    @Volatile
    var revoker: IdentityRevoker? = null

    /** tvOS sets true (TvOsProviderInstaller); a missing revoker then counts as `revoke` returning false. */
    @Volatile
    var required: Boolean = false
}

/** Runs a step's side effects after the commit lock was released. */
internal object IdentityEffects {
    private val log = Logger.withTag("Identity")

    /**
     * Runs a reducing section's side effects after the commit lock was released: Revoke
     * (synchronously), the cancellation snapshot, SignalPreempted and Log, in order, then the
     * afterAccountOpen launch. The control effects (RunApply, Proceed, EndPreempted, EndFailed,
     * AwaitDrain) are left to the caller. Returns the revoke result: false when the revoker
     * returned false, threw, or is missing while required; true when the step had no Revoke.
     */
    fun run(reduced: Reduced): Boolean {
        var ok = true
        try {
            for (effect in reduced.effects) {
                when (effect) {
                    is BarrierEffect.Revoke -> ok = revoke(effect.state) && ok
                    is BarrierEffect.CancelJobs -> Unit // the snapshot below, taken in the reducing section
                    BarrierEffect.SignalPreempted -> Unit // the wake comes from cancelTargets below
                    is BarrierEffect.Log -> log.i { "[Identity] ${effect.line}" }
                    is BarrierEffect.AwaitDrain, BarrierEffect.RunApply, BarrierEffect.Proceed,
                    BarrierEffect.EndPreempted, BarrierEffect.EndFailed -> Unit
                }
            }
        } finally {
            // Rules C (revision 10): issue the cancels, then clear effects-in-flight (after the
            // revoke above has returned), and only then wake the drain loop and signal pre-emption.
            try {
                IdentityWork.cancelTargets(reduced.toCancel)
            } finally {
                if (reduced.inFlight) IdentityWork.clearEffectsInFlight()
                if (reduced.effects.any { it == BarrierEffect.SignalPreempted }) IdentityWork.signalPreempted()
            }
        }
        if (reduced.accountOpened) IdentityImmediate.launchAfterAccountOpen()
        return ok
    }

    private fun revoke(state: IdentityState): Boolean {
        val revoker = IdentityRevocation.revoker
        if (revoker == null) {
            if (IdentityRevocation.required) log.e { "[Identity] revoke: no revoker installed (required)" }
            return !IdentityRevocation.required
        }
        val ok = try {
            revoker.revoke(state)
        } catch (t: Throwable) {
            log.e(t) { "[Identity] revoke threw" }
            false
        }
        if (!ok) log.e { "[Identity] revoke returned false for ${state.kind}" }
        return ok
    }
}
