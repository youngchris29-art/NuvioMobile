package com.nuvio.app.core.auth

import kotlin.test.Test
import kotlin.test.assertFalse
import kotlin.test.assertTrue

/**
 * Upstream daa966d36 error classification, message-only cases. The `RestException` status-code
 * branches need a ktor `HttpResponse` (no mock engine in `:shared`), so they are covered by review.
 */
class AuthSessionErrorsTest {
    @Test
    fun jwtExpiredIsDetectedThroughTheCauseChain() {
        assertTrue(IllegalStateException("wrapper", RuntimeException("JWT expired")).isJwtExpiredError())
        assertFalse(RuntimeException("timeout").isJwtExpiredError())
    }

    @Test
    fun invalidSessionMarkersAndDeletedAccountsAreInvalidSessions() {
        assertTrue(RuntimeException("Session not found").isInvalidSessionError())
        assertTrue(RuntimeException("invalid JWT").isInvalidSessionError())
        assertTrue(RuntimeException("User does not exist").isInvalidSessionError())
        assertFalse(RuntimeException("Unable to resolve host").isInvalidSessionError())
    }

    @Test
    fun aRefreshFailureWithoutAServerResponseIsNeverARejection() {
        assertFalse(RuntimeException("invalid_grant").isInvalidRefreshError())
    }

    @Test
    fun deletedAccountMarkers() {
        assertTrue(RuntimeException("insert violates foreign key constraint on auth.users").isDeletedAccountError())
        assertFalse(RuntimeException("JWT expired").isDeletedAccountError())
    }
}
