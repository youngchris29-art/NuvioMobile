package com.nuvio.app.core.auth

import kotlin.test.AfterTest
import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertNull
import kotlin.test.assertFalse
import kotlin.test.assertTrue

/** Upstream daa966d36: the jvm actual's `signed_out_notice` flag, plus the fork's `account_owner`. */
class AuthStorageFlagJvmTest {
    @AfterTest
    fun cleanUp() {
        AuthStorage.saveFlag("signed_out_notice", false)
        AuthStorage.saveAccountOwner(null)
    }

    @Test
    fun flagRoundTrips() {
        AuthStorage.saveFlag("signed_out_notice", true)
        assertTrue(AuthStorage.loadFlag("signed_out_notice"))
        AuthStorage.saveFlag("signed_out_notice", false)
        assertFalse(AuthStorage.loadFlag("signed_out_notice"))
    }

    @Test
    fun anUnknownKeyReadsFalse() {
        assertFalse(AuthStorage.loadFlag("auth_storage_flag_test_never_written"))
    }

    @Test
    fun accountOwnerRoundTripsAndClears() {
        AuthStorage.saveAccountOwner("user-a")
        assertEquals("user-a", AuthStorage.loadAccountOwner())
        AuthStorage.saveAccountOwner(null)
        assertNull(AuthStorage.loadAccountOwner())
    }
}
