package com.nuvio.app.core.auth

import io.github.jan.supabase.annotations.SupabaseInternal
import io.github.jan.supabase.auth.SessionManager
import io.github.jan.supabase.auth.createDefaultSettingsKey
import io.github.jan.supabase.auth.user.UserSession
import kotlin.time.Clock
import kotlin.time.Duration.Companion.minutes
import kotlin.time.Instant

/**
 * D1b, debug builds only (installed by SupabaseProvider behind [debugAuthSessionExpired]): makes
 * the auth library restore the stored session as if its access token had expired while the app was
 * closed.
 *
 * supabase-kt 3.4.1 decides at restore (AuthImpl.importSession, autoRefresh path) from the stored
 * `expiresAt`: if `expiresAt - 0.2 * expiresIn <= now` it does not publish Authenticated(Storage)
 * and does not save; it starts the session job, which refreshes at once (and joins init). So
 * handing back the stored session with only `expiresAt` moved into the past puts the library on its
 * genuine expired-restore path, with the real tokens.
 *
 * Safety, all by construction here:
 *  - In memory only: [loadSession] alters a copy; the stored value is never rewritten. A save of
 *    exactly that altered copy is dropped (the library does not issue one on this path; the guard
 *    is belt and braces). Every other save (a real refresh's new session) passes through.
 *  - One launch only: only the first load of this process is altered; nothing is persisted, so the
 *    next launch without the flag restores the stored session unchanged.
 *  - The refresh token is untouched. With the network down the refresh never leaves the device;
 *    without it the library performs an ordinary refresh (the server rotates the tokens and the new
 *    session is saved, exactly as at any expiry).
 */
internal class DebugExpiredSessionManager(
    private val delegate: SessionManager,
    private val now: () -> Instant = { Clock.System.now() },
) : SessionManager {
    private var altered: UserSession? = null
    private var loadedOnce = false

    override suspend fun loadSession(): UserSession? {
        val stored = delegate.loadSession() ?: return null
        if (loadedOnce) return stored
        loadedOnce = true
        val expired = stored.copy(expiresAt = now() - 1.minutes)
        altered = expired
        return expired
    }

    override suspend fun saveSession(session: UserSession) {
        if (session == altered) return
        delegate.saveSession(session)
    }

    override suspend fun deleteSession() = delegate.deleteSession()
}

/**
 * The settings key supabase-kt's default session manager uses for this backend
 * (`createDefaultSessionManager`: `createDefaultSettingsKey(client.supabaseUrl) + "-session"`, where
 * the client keeps `supabaseUrl.split("//").last()`). The wrapper must read the very same stored
 * session; DebugExpiredSessionManagerKeyJvmTest pins this against a real client.
 */
@OptIn(SupabaseInternal::class)
internal fun defaultSessionSettingsKey(backendUrl: String): String =
    createDefaultSettingsKey(backendUrl.split("//").last()) + "-session"
