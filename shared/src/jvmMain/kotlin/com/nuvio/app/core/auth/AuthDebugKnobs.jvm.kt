package com.nuvio.app.core.auth

import kotlin.time.Duration

// Ported from androidMain's actual verbatim — the debug stall knob is opt-in only, no-op here.
internal actual fun debugSessionRestoreStall(): Duration? = null

internal actual fun debugAuthNetworkDown(): Boolean = false

internal actual fun debugAuthSessionExpired(): Boolean = false

internal actual fun authSessionTraceEnabled(): Boolean = false

