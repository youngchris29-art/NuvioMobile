package com.nuvio.app.features.player.external

import android.content.Context
import android.content.SharedPreferences

actual object ExternalPlaybackSessionStorage {
    private const val preferencesName = "nuvio_external_playback"
    private const val pendingExternalPlaybackKey = "pending_external_playback"

    private var preferences: SharedPreferences? = null

    fun initialize(context: Context) {
        preferences = context.getSharedPreferences(preferencesName, Context.MODE_PRIVATE)
    }

    actual fun load(): String? =
        preferences?.getString(pendingExternalPlaybackKey, null)

    actual fun save(json: String) {
        preferences?.edit()?.putString(pendingExternalPlaybackKey, json)?.apply()
    }

    actual fun clear() {
        preferences?.edit()?.remove(pendingExternalPlaybackKey)?.apply()
    }
}
