package com.nuvio.app.core.identity

/*
 * Launch restore (fork-only, W2): whether the profile cache on disk may be applied before the auth
 * model has said who is signed in. Pure.
 *
 * Design: docs/batch-scope-identity-spec.md, sections 5.9 and 8.1.
 */

enum class BootCacheAction { Apply, Defer }

object BootProfileCache {
    /**
     * Apply iff the cached payload names an owner AND that owner is the trusted guest or the
     * recorded account owner; otherwise Defer (the account's own publish loads it, P6).
     * [recordedAccountOwner] is null both when no owner was ever recorded and when "nobody" was.
     */
    fun decide(payloadUserId: String?, trustedGuestId: String?, recordedAccountOwner: String?): BootCacheAction =
        if (payloadUserId != null && (payloadUserId == trustedGuestId || payloadUserId == recordedAccountOwner)) {
            BootCacheAction.Apply
        } else {
            BootCacheAction.Defer
        }
}
