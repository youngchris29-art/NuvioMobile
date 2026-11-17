package com.nuvio.app.core.auth

expect object AuthStorage {
    fun loadAnonymousUserId(): String?
    fun saveAnonymousUserId(userId: String)
    fun clearAnonymousUserId()
    fun loadFlag(key: String): Boolean
    fun saveFlag(key: String, value: Boolean)
    /** User id of the account whose data is on this device; null when none (see AuthSessionModel). */
    fun loadAccountOwner(): String?
    fun saveAccountOwner(userId: String?)
}
