package com.nuvio.app.core.identity

/*
 * W2 fix round: whether an auth window is a publish window or a wipe window, decided here and read
 * by Swift as IdentityState.kind (accountpublished: no cover, spec 4.6; accountwipe: "Signing
 * out…"). Pure.
 *
 * Both window kinds hold, cancel and revoke alike (CancelPolicy treats them the same); only what the
 * user sees differs. A serial change or a publish opens a publish window. A wipe is a wipe window
 * only while an account is still shown (a sign-out or a lost session erasing that account's data);
 * a wipe while nobody is shown belongs to an accept (sign-in, launch restore, A → B after its
 * Unauthenticated snap, 5.7), which stays a publish window.
 */
internal enum class WindowCause { SerialChange, Wipe, Publish }

internal object WindowKindRule {
    /** The kind a window opens with when [cause] opens it. */
    fun opening(cause: WindowCause, latestAccount: AccountKey): TransitionKind = when (cause) {
        WindowCause.Wipe -> if (latestAccount == AccountKey.None) TransitionKind.AccountPublished else TransitionKind.AccountWipe
        WindowCause.SerialChange, WindowCause.Publish -> TransitionKind.AccountPublished
    }

    /** The kind an open window of kind [current] takes when [cause] happens inside it: only publish → wipe, never back. */
    fun within(current: TransitionKind, cause: WindowCause, latestAccount: AccountKey): TransitionKind =
        if (current == TransitionKind.AccountPublished && opening(cause, latestAccount) == TransitionKind.AccountWipe) {
            TransitionKind.AccountWipe
        } else {
            current
        }
}
