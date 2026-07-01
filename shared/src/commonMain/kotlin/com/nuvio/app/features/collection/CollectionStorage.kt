package com.nuvio.app.features.collection

expect object CollectionStorage {
    fun loadPayload(): String?
    fun savePayload(payload: String)
}
