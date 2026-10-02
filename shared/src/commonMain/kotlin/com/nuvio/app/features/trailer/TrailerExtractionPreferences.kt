package com.nuvio.app.features.trailer

object TrailerExtractionPreferences {
    /**
     * 0 = no preference. When > 0, formats above this fps rank below same-height formats at or
     * under it (a preference, not a cap: 1080p60 still beats 720p30). Set by the tvOS app at
     * launch from `debug.trailerMaxFps`.
     */
    var maxVideoFps: Int = 0
}
