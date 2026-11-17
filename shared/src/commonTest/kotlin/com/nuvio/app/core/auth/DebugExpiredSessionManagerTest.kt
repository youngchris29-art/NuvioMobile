package com.nuvio.app.core.auth

import io.github.jan.supabase.auth.SessionManager
import io.github.jan.supabase.auth.user.UserSession
import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertNull
import kotlin.test.assertSame
import kotlin.test.assertTrue
import kotlin.time.Duration.Companion.days
import kotlin.time.Duration.Companion.seconds
import kotlin.time.Instant
import kotlinx.coroutines.test.runTest

/** D1b: the debug expired-session wrapper alters only what the library reads, once, in memory. */
class DebugExpiredSessionManagerTest {

    private class StoreSpy(var stored: UserSession?) : SessionManager {
        val saved = mutableListOf<UserSession>()
        var deleted = 0
        override suspend fun saveSession(session: UserSession) {
            saved += session
            stored = session
        }
        override suspend fun loadSession(): UserSession? = stored
        override suspend fun deleteSession() {
            deleted++
            stored = null
        }
    }

    private val now = Instant.fromEpochSeconds(1_800_000_000)

    /** A session as the box holds it: 7-day lifetime, issued an hour ago, far from expiry. */
    private val fresh = UserSession(
        accessToken = "access-token-value",
        refreshToken = "refresh-token-value",
        expiresIn = 7.days.inWholeSeconds,
        tokenType = "bearer",
        user = null,
        expiresAt = now + 7.days - 3600.seconds,
    )

    /** supabase-kt 3.4.1 AuthImpl.importSession: refresh at once when this is not in the future. */
    private fun UserSession.libraryRefreshesAtOnce(): Boolean =
        expiresAt - (expiresIn * 0.2).seconds <= now

    @Test
    fun theFirstLoadIsSeenAsExpiredByTheLibraryRule() = runTest {
        assertTrue(!fresh.libraryRefreshesAtOnce(), "precondition: the stored session is fresh")
        val manager = DebugExpiredSessionManager(StoreSpy(fresh)) { now }
        val loaded = manager.loadSession()!!
        assertTrue(loaded.libraryRefreshesAtOnce())
        assertTrue(loaded.expiresAt < now)
    }

    @Test
    fun onlyTheExpiryChangesTheTokensAreTheStoredOnes() = runTest {
        val loaded = DebugExpiredSessionManager(StoreSpy(fresh)) { now }.loadSession()!!
        assertEquals(fresh.copy(expiresAt = loaded.expiresAt), loaded)
        assertEquals(fresh.refreshToken, loaded.refreshToken)
        assertEquals(fresh.accessToken, loaded.accessToken)
    }

    @Test
    fun theAlteredSessionIsNeverWrittenBack() = runTest {
        val store = StoreSpy(fresh)
        val manager = DebugExpiredSessionManager(store) { now }
        val loaded = manager.loadSession()!!
        manager.saveSession(loaded)
        assertEquals(emptyList(), store.saved)
        assertSame(fresh, store.stored)
    }

    @Test
    fun aRealRefreshIsSavedAsUsual() = runTest {
        val store = StoreSpy(fresh)
        val manager = DebugExpiredSessionManager(store) { now }
        manager.loadSession()
        val refreshed = fresh.copy(accessToken = "new-access", refreshToken = "new-refresh", expiresAt = now + 7.days)
        manager.saveSession(refreshed)
        assertEquals(listOf(refreshed), store.saved)
    }

    @Test
    fun onlyTheFirstLoadOfTheLaunchIsAltered() = runTest {
        val manager = DebugExpiredSessionManager(StoreSpy(fresh)) { now }
        manager.loadSession()
        assertSame(fresh, manager.loadSession())
    }

    @Test
    fun aDeleteStillReachesTheStore() = runTest {
        val store = StoreSpy(fresh)
        DebugExpiredSessionManager(store) { now }.deleteSession()
        assertEquals(1, store.deleted)
        assertNull(store.stored)
    }

    @Test
    fun noStoredSessionStaysNone() = runTest {
        val manager = DebugExpiredSessionManager(StoreSpy(null)) { now }
        assertNull(manager.loadSession())
    }
}
