package com.nuvio.app.features.simkl

internal expect object SimklSyncStorage {
    fun loadPayload(): String?
    fun savePayload(payload: String)

    /** Writes [profileId]'s file, not whichever profile is active when the write happens. */
    fun savePayload(profileId: Int, payload: String)
    fun removeProfile(profileId: Int)
}
