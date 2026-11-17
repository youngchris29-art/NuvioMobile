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
        AuthStorage.saveAccountWipePending(false)
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
        assertTrue(AuthStorage.isAccountOwnerRecorded())
        AuthStorage.saveAccountOwner(null)
        assertNull(AuthStorage.loadAccountOwner())
        // "No owner" stays recorded: it is not the unknown owner of an install that never wrote one.
        assertTrue(AuthStorage.isAccountOwnerRecorded())
    }

    @Test
    fun wipePendingRoundTrips() {
        AuthStorage.saveAccountWipePending(true)
        assertTrue(AuthStorage.loadAccountWipePending())
        AuthStorage.saveAccountWipePending(false)
        assertFalse(AuthStorage.loadAccountWipePending())
    }

    @Test
    fun theRecoveryStateSurvivesTheAccountWipeOfNuvioAuth() {
        AuthStorage.saveAccountOwner("user-a")
        AuthStorage.saveAccountWipePending(true)
        AuthStorage.saveFlag(AuthMarkerKeys.SIGNED_OUT_NOTICE, true)
        AuthStorage.saveAnonymousUserId("guest-1")
        // What the Android/JVM account cleaner does to every registry file, nuvio_auth included.
        com.nuvio.app.core.account.AccountDataStores.androidPreferenceNames().forEach { name ->
            com.nuvio.app.core.storage.jvmSharedPreferences(name).edit().clear().commit()
        }
        assertNull(AuthStorage.loadAnonymousUserId())
        assertEquals("user-a", AuthStorage.loadAccountOwner())
        assertTrue(AuthStorage.loadAccountWipePending())
        assertTrue(AuthStorage.loadFlag(AuthMarkerKeys.SIGNED_OUT_NOTICE))
    }
}
