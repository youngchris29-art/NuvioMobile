package com.nuvio.app.features.trakt

expect object TraktLibraryStorage {
    fun loadPayload(): String?
    fun savePayload(payload: String)

    /** Writes [profileId]'s payload, not whichever profile is active when the write happens. */
    internal fun savePayload(profileId: Int, payload: String)

    /** Reads [profileId]'s payload, not whichever profile is active when the read happens. */
    internal fun loadPayload(profileId: Int): String?
}