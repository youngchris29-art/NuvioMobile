package com.nuvio.app.features.player.external

import platform.Foundation.NSUserDefaults

actual object ExternalPlaybackSessionStorage {
    private const val pendingExternalPlaybackKey = "pending_external_playback"

    actual fun load(): String? =
        NSUserDefaults.standardUserDefaults.stringForKey(pendingExternalPlaybackKey)

    actual fun save(json: String) {
        NSUserDefaults.standardUserDefaults.setObject(json, forKey = pendingExternalPlaybackKey)
    }

    actual fun clear() {
        NSUserDefaults.standardUserDefaults.removeObjectForKey(pendingExternalPlaybackKey)
    }
}
