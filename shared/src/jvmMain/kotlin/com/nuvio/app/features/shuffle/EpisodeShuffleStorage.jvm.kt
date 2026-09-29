package com.nuvio.app.features.shuffle

import com.nuvio.app.core.storage.ProfileScopedKey

// JVM actual (test target): in-memory, same `episode_shuffle` profile-scoped key layout as the
// Apple/Android actuals.
internal actual object EpisodeShuffleStorage {
    private val payloads = mutableMapOf<String, String>()

    actual fun load(profileId: Int): String? = synchronized(payloads) {
        payloads[ProfileScopedKey.of("episode_shuffle", profileId)]
    }

    actual fun save(profileId: Int, payload: String) {
        synchronized(payloads) { payloads[ProfileScopedKey.of("episode_shuffle", profileId)] = payload }
    }
}
