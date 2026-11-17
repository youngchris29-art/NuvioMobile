package com.nuvio.app.core.auth

import com.nuvio.app.core.account.AccountDataStores
import kotlin.test.Test
import kotlin.test.assertFalse
import kotlin.test.assertTrue

/**
 * Review r2-1: the session model's recovery state must survive the account wipe it guards. Checked
 * against the registry both cleaners read (tvOS `TvOsAccountDataCleaner`, iOS
 * `PlatformLocalAccountDataCleaner`, Android `PlatformLocalAccountDataCleaner`), using the same four
 * Apple key rules they apply: plain keys verbatim, `<base>_<profile>`, `<prefix><profile>`, and
 * every key starting with a dynamic prefix.
 */
class AuthMarkerKeysTest {
    private val profiles = 0..64

    @Test
    fun noAppleWipeRuleRemovesAMarkerKey() {
        AuthMarkerKeys.all.forEach { key ->
            assertFalse(key in AccountDataStores.applePlainKeys(), "plain key $key")
            assertTrue(AccountDataStores.appleDynamicPrefixes().none { key.startsWith(it) }, "dynamic prefix over $key")
            profiles.forEach { profile ->
                assertTrue(AccountDataStores.appleProfileScopedBases().none { "${it}_$profile" == key }, "scoped base over $key")
                assertTrue(AccountDataStores.appleProfileIndexedPrefixes().none { "$it$profile" == key }, "indexed prefix over $key")
            }
        }
    }

    @Test
    fun theAndroidMarkerFileIsNotWiped() {
        assertFalse(AuthMarkerKeys.ANDROID_PREFS in AccountDataStores.androidPreferenceNames())
        assertTrue("nuvio_auth" in AccountDataStores.androidPreferenceNames())
    }
}
