package com.nuvio.app.core.auth

import platform.Foundation.NSUserDefaults

actual object AuthStorage {
    private const val KEY_ANONYMOUS_USER_ID = "anonymous_user_id"
    private const val KEY_ACCOUNT_OWNER = AuthMarkerKeys.OWNER
    private const val KEY_ACCOUNT_WIPE_PENDING = AuthMarkerKeys.WIPE_PENDING

    actual fun loadAnonymousUserId(): String? =
        NSUserDefaults.standardUserDefaults.stringForKey(KEY_ANONYMOUS_USER_ID)

    actual fun saveAnonymousUserId(userId: String) {
        NSUserDefaults.standardUserDefaults.setObject(userId, forKey = KEY_ANONYMOUS_USER_ID)
    }

    internal actual fun saveAnonymousUserIdDurably(userId: String): Boolean {
        NSUserDefaults.standardUserDefaults.setObject(userId, forKey = KEY_ANONYMOUS_USER_ID)
        return NSUserDefaults.standardUserDefaults.synchronize()
    }

    internal actual fun clearAnonymousUserIdDurably(): Boolean {
        NSUserDefaults.standardUserDefaults.removeObjectForKey(KEY_ANONYMOUS_USER_ID)
        return NSUserDefaults.standardUserDefaults.synchronize()
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

    actual fun saveAccountOwner(userId: String?): Boolean {
        NSUserDefaults.standardUserDefaults.setObject(userId.orEmpty(), forKey = KEY_ACCOUNT_OWNER)
        return flushed()
    }

    actual fun isAccountOwnerRecorded(): Boolean =
        NSUserDefaults.standardUserDefaults.stringForKey(KEY_ACCOUNT_OWNER) != null

    actual fun loadAccountWipePending(): Boolean =
        NSUserDefaults.standardUserDefaults.boolForKey(KEY_ACCOUNT_WIPE_PENDING)

    actual fun saveAccountWipePending(pending: Boolean): Boolean {
        NSUserDefaults.standardUserDefaults.setBool(pending, forKey = KEY_ACCOUNT_WIPE_PENDING)
        return flushed()
    }

    /**
     * r3-4: `NSUserDefaults` setters report nothing; the value is in the process's cache at once and
     * cfprefsd persists it asynchronously. `synchronize()` asks for that write now and returns false
     * when it could not be saved (for example the preferences daemon refusing it). It cannot catch
     * every later disk failure, so on Apple "durable" means "accepted and flushed by cfprefsd".
     */
    private fun flushed(): Boolean = NSUserDefaults.standardUserDefaults.synchronize()
}
