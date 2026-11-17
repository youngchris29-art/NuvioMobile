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
