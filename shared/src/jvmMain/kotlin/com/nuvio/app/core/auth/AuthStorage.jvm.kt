package com.nuvio.app.core.auth

// JVM actual for shared/src/jvmMain (beta.14 Wave 4 / :shared jvm test target, see
// docs/issue-triage-plan-2026-08-21.md §6.1). Ported from the androidMain actual in this
// same relative path: same key layout, JvmSharedPreferences swapped in for
// android.content.SharedPreferences (no Context needed on the JVM).

import com.nuvio.app.core.storage.JvmSharedPreferences
import com.nuvio.app.core.storage.jvmSharedPreferences

actual object AuthStorage {
    private const val PREFS_NAME = "nuvio_auth"
    private const val KEY_ANONYMOUS_USER_ID = "anonymous_user_id"
    private const val KEY_ACCOUNT_OWNER = AuthMarkerKeys.OWNER
    private const val KEY_ACCOUNT_WIPE_PENDING = AuthMarkerKeys.WIPE_PENDING

    private val preferences: JvmSharedPreferences? = jvmSharedPreferences(PREFS_NAME)

    // r2-1: owner, wipe marker and notice live outside every file the account wipe clears.
    private val markers: JvmSharedPreferences? = jvmSharedPreferences(AuthMarkerKeys.ANDROID_PREFS)

    actual fun loadAnonymousUserId(): String? =
        preferences?.getString(KEY_ANONYMOUS_USER_ID, null)

    actual fun saveAnonymousUserId(userId: String) {
        preferences?.edit()?.putString(KEY_ANONYMOUS_USER_ID, userId)?.apply()
    }

    actual fun clearAnonymousUserId() {
        preferences?.edit()?.remove(KEY_ANONYMOUS_USER_ID)?.apply()
    }

    // Written synchronously: the model relies on them surviving a crash right after (r2-1).
    actual fun loadFlag(key: String): Boolean =
        markers?.getBoolean(key, false) == true

    actual fun saveFlag(key: String, value: Boolean) {
        markers?.edit()?.putBoolean(key, value)?.commit()
    }

    actual fun loadAccountOwner(): String? =
        markers?.getString(KEY_ACCOUNT_OWNER, null)?.takeIf { it.isNotEmpty() }

    actual fun saveAccountOwner(userId: String?): Boolean =
        markers?.edit()?.putString(KEY_ACCOUNT_OWNER, userId.orEmpty())?.commit() == true

    actual fun isAccountOwnerRecorded(): Boolean =
        markers?.getString(KEY_ACCOUNT_OWNER, null) != null

    actual fun loadAccountWipePending(): Boolean =
        markers?.getBoolean(KEY_ACCOUNT_WIPE_PENDING, false) == true

    actual fun saveAccountWipePending(pending: Boolean): Boolean =
        markers?.edit()?.putBoolean(KEY_ACCOUNT_WIPE_PENDING, pending)?.commit() == true
}
