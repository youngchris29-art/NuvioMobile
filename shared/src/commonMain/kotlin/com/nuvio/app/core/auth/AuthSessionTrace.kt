package com.nuvio.app.core.auth

/**
 * D1b: one short line per reducer input and per significant output, for the debug-build console
 * (`[AuthSession] …`, printed by RealAuthEffects.trace only when [authSessionTraceEnabled]).
 *
 * Every line is built from fixed words and enum names only: never a token, email, user id, guest
 * id, serial-free identity or URL. Who is involved is said as "account", "guest" or "none".
 * AuthSessionTraceTest feeds secret-looking values through every case and checks none comes out.
 */
internal fun describeEvent(event: AuthEvent): String = when (event) {
    is AuthEvent.Boot -> {
        val resolution = resolveBoot(event.guestId, event.owner)
        val owner = when {
            event.ownerUnknown -> "unknown"
            event.owner != null -> "account"
            else -> "none"
        }
        val guest = when {
            resolution.trustedGuestId != null -> "trusted"
            resolution.clearStaleGuestId -> "stale, cleared"
            else -> "none"
        }
        "boot owner=$owner guest=$guest wipePending=${event.wipePending} notice=${event.notice}"
    }
    AuthEvent.WatchdogFired -> "watchdog fired"
    is AuthEvent.ValidationFinished ->
        "validation ${event.verdict}" + if (event.verifiedUserId != null) " (user returned)" else ""
    is AuthEvent.SessionErrorReported -> "sync error ${event.kind}"
    is AuthEvent.ResetStarted -> "reset started ${event.kind}"
    is AuthEvent.ResetFinished -> "reset finished ${event.kind}"
    is AuthEvent.SessionStartStarted -> "session start ${event.kind}"
    is AuthEvent.SessionStartFinished -> "session start finished ${event.kind} ok=${event.ok}"
    is AuthEvent.GuestChosen -> "guest chosen"
    is AuthEvent.WipeFinished -> "wipe finished ok=${event.ok}"
    is AuthEvent.GatePassed -> "gate passed ${describeGate(event.output)}"
    is AuthEvent.GateFailed -> "gate failed ${describeGate(event.output)}"
    Snap.Initializing -> "status Initializing"
    Snap.RefreshFailure -> "status RefreshFailure"
    is Snap.NotAuthenticated -> "status NotAuthenticated cleared=${event.cleared}"
    Snap.Scaffold -> "status Authenticated(scaffold)"
    is Snap.Account -> {
        val source = when {
            event.refreshedFrom != null -> "refresh"
            event.restored -> "storage"
            else -> "new"
        }
        val who = if (event.userId == null) "account unresolved" else "account"
        "status Authenticated($who source=$source)"
    }
}

/** The significant outputs; null for the ones not worth a line. */
internal fun describeOutput(output: AuthOutput): String? = when (output) {
    is AuthOutput.Publish -> "publish " + when (val s = output.state) {
        AuthState.Loading -> "loading"
        AuthState.Unauthenticated -> "signed-out"
        is AuthState.Authenticated -> if (s.isAnonymous) "guest" else "account"
    }
    is AuthOutput.PersistOwner -> null // its outcome is the gate line
    is AuthOutput.PersistWipePending -> null // ditto
    is AuthOutput.SaveGuestId -> null // ditto
    is AuthOutput.PersistNotice -> if (output.pending) "notice set" else "notice cleared"
    AuthOutput.ShowNotice -> "notice shown"
    AuthOutput.HideNotice -> null
    AuthOutput.ClearGuestId -> "guest id cleared"
    AuthOutput.WipeAccountData -> "wipe started"
    AuthOutput.ClearSupabaseSession -> "library session cleared"
    AuthOutput.KickSessionRefresh -> "refresh kicked"
    is AuthOutput.StartValidation -> "validation started"
    is AuthOutput.Drop -> describeDrop(output.reason)
}

private fun describeGate(output: AuthOutput): String = when (output) {
    is AuthOutput.PersistWipePending -> if (output.pending) "marker set" else "marker clear"
    is AuthOutput.PersistOwner -> if (output.userId == null) "owner nobody" else "owner account"
    is AuthOutput.SaveGuestId -> "guest id"
    else -> "other"
}

/**
 * Drop reasons are free text and some carry ids, so only a fixed category is printed. The
 * lost-session reasons are fixed sentences (AuthSessionModel.lostReset callers) and are kept.
 */
private fun describeDrop(reason: String): String? = when {
    reason.startsWith("lost session: ") -> {
        val why = reason.removePrefix("lost session: ")
        if (why in LOST_REASONS) "lost reset: $why" else "lost reset"
    }
    reason.startsWith("wipe failed") -> "wipe failed, marker stays set"
    reason.startsWith("wipe: ") -> null // "wipe started" follows
    reason.startsWith("durable write failed") -> null // the gate line says which
    reason.startsWith("accept attempt") -> "accept attempt failed"
    reason.startsWith("boot: guest id") -> null // the boot line says it
    reason.startsWith("stale validation verdict") -> "stale verdict ignored"
    reason.startsWith("identity still unresolved") -> "identity unresolved, validating again"
    reason.startsWith("stale session error") -> "stale sync error ignored"
    reason.startsWith("foreign refresh") -> "foreign refresh ignored"
    reason.startsWith("gate outcome") -> "gate outcome mismatch"
    else -> "dropped"
}

private val LOST_REASONS = setOf(
    "the library reported no session",
    "the stored session of an unknown owner was rejected",
    "no usable stored session and no recorded owner",
    "validation rejected the session",
    "a sync call reported the account deleted",
)
