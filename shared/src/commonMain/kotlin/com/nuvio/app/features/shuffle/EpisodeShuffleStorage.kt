package com.nuvio.app.features.shuffle

/**
 * Per-profile persistence for [EpisodeShuffleProfile] JSON. Base key `episode_shuffle`
 * (`ProfileScopedKey.of("episode_shuffle", profileId)`); registered in `AccountDataStores`.
 */
expect object EpisodeShuffleStorage {
    fun load(profileId: Int): String?
    fun save(profileId: Int, payload: String)
}
