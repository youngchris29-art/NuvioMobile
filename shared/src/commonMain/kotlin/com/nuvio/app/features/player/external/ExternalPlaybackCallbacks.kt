package com.nuvio.app.features.player.external

/**
 * Builds the x-callback URLs an external player opens when playback ends: upstream `99ced26a`'s
 * hard-coded `nuvio://external-player/infuse/<id>/success|error`, generalised so the caller
 * supplies the app's own URL scheme (tvOS registers its own) and the player id.
 */
object ExternalPlaybackCallbacks {
    internal const val HOST = "external-player"
    internal const val SUCCESS = "success"
    internal const val ERROR = "error"

    /**
     * Returns `(success, error)`:
     * `<scheme>://external-player/<playerId>/<sessionId>/success` and `.../error`.
     */
    fun build(scheme: String, playerId: String, sessionId: String): Pair<String, String> {
        val base = "${scheme.trim()}://$HOST/${playerId.trim()}/$sessionId"
        return "$base/$SUCCESS" to "$base/$ERROR"
    }
}
