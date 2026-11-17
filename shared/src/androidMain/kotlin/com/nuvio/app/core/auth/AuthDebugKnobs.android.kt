package com.nuvio.app.core.auth

import kotlin.time.Duration

internal actual fun debugSessionRestoreStall(): Duration? = null

internal actual fun debugAuthNetworkDown(): Boolean = false

internal actual fun debugAuthSessionExpired(): Boolean = false

internal actual fun authSessionTraceEnabled(): Boolean = false

