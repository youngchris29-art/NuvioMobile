package com.nuvio.app.core.network

// Public (was internal): the android actual's `initialize(context)` is called from
// composeApp's MainActivity, which can't see `internal` across the :shared module boundary.
expect object SyncBackendStorage {
    fun loadSelectionPayload(): String?
    fun saveSelectionPayload(payload: String)
}

internal expect suspend fun fetchSyncBackendManifestText(url: String): String
