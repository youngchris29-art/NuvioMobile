package com.nuvio.app.features.trakt

expect object TraktAuthStorage {
    fun loadPayload(): String?
    fun savePayload(payload: String)
}
