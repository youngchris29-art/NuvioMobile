package com.nuvio.app.core.auth

import platform.Foundation.NSUserDefaults

actual object AuthStorage {
    private const val KEY_ANONYMOUS_USER_ID = "anonymous_user_id"
    private const val KEY_ACCOUNT_OWNER = "account_owner"
    private const val KEY_ACCOUNT_WIPE_PENDING = "account_wipe_pending"

    actual fun loadAnonymousUserId(): String? =
        NSUserDefaults.standardUserDefaults.stringForKey(KEY_ANONYMOUS_USER_ID)

    actual fun saveAnonymousUserId(userId: String) {
        NSUserDefaults.standardUserDefaults.setObject(userId, forKey = KEY_ANONYMOUS_USER_ID)
    }

    actual fun clearAnonymousUserId() {
        NSUserDefaults.standardUserDefaults.removeObjectForKey(KEY_ANONYMOUS_USER_ID)
    }

    actual fun loadFlag(key: String): Boolean =
        NSUserDefaults.standardUserDefaults.boolForKey(key)

    actual fun saveFlag(key: String, value: Boolean) {
        NSUserDefaults.standardUserDefaults.setBool(value, forKey = key)
    }

    actual fun loadAccountOwner(): String? =
        NSUserDefaults.standardUserDefaults.stringForKey(KEY_ACCOUNT_OWNER)?.takeIf { it.isNotEmpty() }

    actual fun saveAccountOwner(userId: String?) {
        NSUserDefaults.standardUserDefaults.setObject(userId.orEmpty(), forKey = KEY_ACCOUNT_OWNER)
    }

    actual fun isAccountOwnerRecorded(): Boolean =
        NSUserDefaults.standardUserDefaults.stringForKey(KEY_ACCOUNT_OWNER) != null

    actual fun loadAccountWipePending(): Boolean =
        NSUserDefaults.standardUserDefaults.boolForKey(KEY_ACCOUNT_WIPE_PENDING)

    actual fun saveAccountWipePending(pending: Boolean) {
        NSUserDefaults.standardUserDefaults.setBool(pending, forKey = KEY_ACCOUNT_WIPE_PENDING)
    }
}
