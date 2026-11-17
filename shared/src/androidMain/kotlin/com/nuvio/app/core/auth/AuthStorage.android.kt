package com.nuvio.app.core.auth

import android.content.Context
import android.content.SharedPreferences

actual object AuthStorage {
    private const val PREFS_NAME = "nuvio_auth"
    private const val KEY_ANONYMOUS_USER_ID = "anonymous_user_id"
    private const val KEY_ACCOUNT_OWNER = AuthMarkerKeys.OWNER
    private const val KEY_ACCOUNT_WIPE_PENDING = AuthMarkerKeys.WIPE_PENDING

    private var preferences: SharedPreferences? = null

    // r2-1: owner, wipe marker and notice live outside every file the account wipe clears.
    private var markers: SharedPreferences? = null

    fun initialize(context: Context) {
        preferences = context.getSharedPreferences(PREFS_NAME, Context.MODE_PRIVATE)
        markers = context.getSharedPreferences(AuthMarkerKeys.ANDROID_PREFS, Context.MODE_PRIVATE)
    }

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

    actual fun saveAccountOwner(userId: String?) {
        markers?.edit()?.putString(KEY_ACCOUNT_OWNER, userId.orEmpty())?.commit()
    }

    actual fun isAccountOwnerRecorded(): Boolean =
        markers?.getString(KEY_ACCOUNT_OWNER, null) != null

    actual fun loadAccountWipePending(): Boolean =
        markers?.getBoolean(KEY_ACCOUNT_WIPE_PENDING, false) == true

    actual fun saveAccountWipePending(pending: Boolean) {
        markers?.edit()?.putBoolean(KEY_ACCOUNT_WIPE_PENDING, pending)?.commit()
    }
}
