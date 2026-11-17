package com.nuvio.app.core.auth

import platform.Foundation.NSUserDefaults

actual object AuthStorage {
    private const val KEY_ANONYMOUS_USER_ID = "anonymous_user_id"
    private const val KEY_ACCOUNT_OWNER = "account_owner"

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
        NSUserDefaults.standardUserDefaults.stringForKey(KEY_ACCOUNT_OWNER)

    actual fun saveAccountOwner(userId: String?) {
        if (userId == null) {
            NSUserDefaults.standardUserDefaults.removeObjectForKey(KEY_ACCOUNT_OWNER)
        } else {
            NSUserDefaults.standardUserDefaults.setObject(userId, forKey = KEY_ACCOUNT_OWNER)
        }
    }
}
