package com.nuvio.app.core.auth

import kotlin.time.Duration

/**
 * Debug-build-only stall injection for the session-restore watchdog: when set, the session-status
 * collector is delayed by this long, so the root gate behaves exactly as if the auth library never
 * left its Initializing state (the boot-hang class of 2026-08-05). Returns null in release builds
 * and when the knob is unset.
 *
 * Apple: `defaults write <bundle-id> debug.authRestoreStallSeconds -int 30`
 */
internal expect fun debugSessionRestoreStall(): Duration?

/**
 * Debug-build-only "network down" for the offline cold-launch device rows (spec C6, decision AS):
 * when true, every Supabase request fails with an IOException before it leaves the device, so the
 * auth library sees exactly what it sees offline (RefreshFailure, an unreachable validation) while
 * the rig can still talk to the box. False in release builds and when unset.
 *
 * Apple: launch with `-debug.authNetworkDown 1` (argument domain) or
 * `defaults write <bundle-id> debug.authNetworkDown -bool true`.
 */
internal expect fun debugAuthNetworkDown(): Boolean

/**
 * D1b: debug-build-only "the stored session expired while the app was closed". When true, the
 * first stored session the auth library loads this launch is handed back with its expiry moved
 * into the past, in memory only (DebugExpiredSessionManager), so the library takes its real
 * expired-restore path: no Authenticated(Storage), an immediate refresh, and with
 * `-debug.authNetworkDown 1` RefreshFailure while it retries. False in release builds.
 *
 * Apple: launch with `-debug.authSessionExpired 1`.
 */
internal expect fun debugAuthSessionExpired(): Boolean

/**
 * D1b: debug-build-only auth-session trace on stdout (`[AuthSession] …` lines, which the rig's
 * console stream captures). Never carries a token, email, user id or URL. False in release builds.
 */
internal expect fun authSessionTraceEnabled(): Boolean

