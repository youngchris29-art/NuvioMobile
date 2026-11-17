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
