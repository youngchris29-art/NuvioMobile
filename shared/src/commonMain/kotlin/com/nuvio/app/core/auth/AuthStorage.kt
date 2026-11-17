package com.nuvio.app.core.auth

expect object AuthStorage {
    fun loadAnonymousUserId(): String?
    fun saveAnonymousUserId(userId: String)
    fun clearAnonymousUserId()
    fun loadFlag(key: String): Boolean
    fun saveFlag(key: String, value: Boolean)
    /** User id of the account whose data is on this device; null when none or never recorded. */
    fun loadAccountOwner(): String?
    /** null records "no owner" (kept as an empty value, so it stays distinct from never recorded). */
    fun saveAccountOwner(userId: String?)
    /** False on an install that never recorded an owner: its local data may belong to any account. */
    fun isAccountOwnerRecorded(): Boolean
    /** A wipe started and has not confirmed success (see AuthSessionModel). */
    fun loadAccountWipePending(): Boolean
    fun saveAccountWipePending(pending: Boolean)
}

/**
 * Where the session model's recovery state lives (review r2-1): the account owner, the wipe-pending
 * marker and the signed-out notice must survive the very wipe they guard, so they are kept OUTSIDE
 * everything `AccountDataStores` erases. Apple: plain keys in `NSUserDefaults.standardUserDefaults`
 * that match no registry key, prefix or profile pattern. Android and JVM: their own preferences
 * file [ANDROID_PREFS], which is not in the registry (the wipe clears `nuvio_auth` whole).
 * `AuthMarkerKeysTest` pins both against the registry.
 */
internal object AuthMarkerKeys {
    const val OWNER = "account_owner"
    const val WIPE_PENDING = "account_wipe_pending"
    const val SIGNED_OUT_NOTICE = "signed_out_notice"
    const val ANDROID_PREFS = "nuvio_auth_markers"
    val all = listOf(OWNER, WIPE_PENDING, SIGNED_OUT_NOTICE)
}

