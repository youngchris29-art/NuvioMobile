package com.nuvio.app.features.player.external

/**
 * Persists the single pending [ExternalPlaybackSession] as JSON, so a callback that relaunches
 * the app after it was killed still finds the session. Plain (not profile-scoped) key: the
 * session records its own profile. Apple: `NSUserDefaults.standardUserDefaults` key
 * `pending_external_playback`; Android: SharedPreferences file `nuvio_external_playback`
 * (same key); JVM (test target): in memory. Registered in `AccountDataStores`, so sign-out
 * wipes a session left pending.
 */
expect object ExternalPlaybackSessionStorage {
    fun load(): String?
    fun save(json: String)
    fun clear()
}
