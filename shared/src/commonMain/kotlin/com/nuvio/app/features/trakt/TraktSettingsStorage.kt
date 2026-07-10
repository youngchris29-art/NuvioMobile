package com.nuvio.app.features.trakt

expect object TraktSettingsStorage {
    fun loadPayload(): String?
    fun savePayload(payload: String)
    fun loadPendingWatchProgressSourcePayload(profileId: Int): String?
    fun savePendingWatchProgressSourcePayload(profileId: Int, payload: String)
    fun clearPendingWatchProgressSourcePayload(profileId: Int)
}
