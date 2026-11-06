package com.nuvio.app.features.streams

/**
 * Whether the stream picker lists a stream at all. Ported 1:1 from the tvOS
 * `StreamsViewModel.isListable`, which now delegates here so the picker and the format-badge probe
 * cannot drift: a direct URL, a debrid candidate when debrid can resolve it, or a YouTube video id
 * that the picker resolves on the device. Torrent-only results without debrid are not listable.
 * [com.nuvio.app.features.debrid.DebridStreamPresentation] uses it too, so the Cached Sources Only
 * hidden count never promises a row the picker would drop.
 */
object StreamListability {
    fun isListable(stream: StreamItem, debridCanResolve: Boolean): Boolean {
        if (!stream.playableDirectUrl.isNullOrEmpty()) return true
        if (debridCanResolve && stream.isAddonDebridCandidate) return true
        return !stream.youTubeIdToResolve.isNullOrEmpty()
    }
}
