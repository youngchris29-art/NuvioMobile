package com.nuvio.app.features.trailer

data class TrailerPlaybackSource(
    val videoUrl: String,
    val audioUrl: String? = null,
    /**
     * A progressive H.264/MP4 (or HLS) URL suitable for native `AVPlayer` playback. tvOS plays this
     * (AVPlayer coexists with SwiftUI; libmpv/Vulkan does not). Null when only adaptive VP9/AV1 is
     * available. Mobile ignores it and uses [videoUrl] for its libmpv player.
     */
    val progressiveUrl: String? = null,
)
