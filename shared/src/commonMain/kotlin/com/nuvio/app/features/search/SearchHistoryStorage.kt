package com.nuvio.app.features.search

expect object SearchHistoryStorage {
    fun loadPayload(): String?
    fun savePayload(payload: String)
    fun loadEnabled(): Boolean?
    fun saveEnabled(enabled: Boolean)
}
