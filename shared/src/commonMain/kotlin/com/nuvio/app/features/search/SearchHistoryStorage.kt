package com.nuvio.app.features.search

expect object SearchHistoryStorage {
    fun loadPayload(): String?
    fun savePayload(payload: String)
}
