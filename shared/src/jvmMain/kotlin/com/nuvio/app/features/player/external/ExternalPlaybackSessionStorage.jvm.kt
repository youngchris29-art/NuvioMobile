package com.nuvio.app.features.player.external

// JVM actual (test target): in memory, same single plain `pending_external_playback` slot as the
// Apple/Android actuals.
actual object ExternalPlaybackSessionStorage {
    private val lock = Any()
    private var payload: String? = null

    actual fun load(): String? = synchronized(lock) { payload }

    actual fun save(json: String) {
        synchronized(lock) { payload = json }
    }

    actual fun clear() {
        synchronized(lock) { payload = null }
    }
}
