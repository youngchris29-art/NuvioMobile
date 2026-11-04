package com.nuvio.app.features.player

import com.nuvio.app.features.player.external.ExternalPlaybackReturn
import platform.Foundation.NSLog
import platform.Foundation.NSURL
import platform.Foundation.NSUserDefaults
import platform.UIKit.UIApplication

private data class IosExternalPlayerSpec(
    val id: String,
    val name: String,
    val scheme: String,
    val buildUrl: (ExternalPlayerPlaybackRequest) -> String,
    /** False when the player can't take this source; `open` then reports `Failed` (and the
     *  default-player route falls back to the built-in player). */
    val supportsSource: (ExternalPlayerPlaybackRequest) -> Boolean = { true },
)

private val iosExternalPlayerSpecs = listOf(
    IosExternalPlayerSpec(
        id = "infuse",
        name = "Infuse",
        scheme = "infuse",
        buildUrl = ::buildInfuseUrl,
    ),
    IosExternalPlayerSpec(
        id = "vlc",
        name = "VLC",
        scheme = "vlc-x-callback",
        buildUrl = { request ->
            buildString {
                append("vlc-x-callback://x-callback-url/stream?url=")
                append(request.sourceUrl.urlQueryEncode())
                request.subtitles?.firstOrNull()?.let { subtitle ->
                    append("&sub=")
                    append(subtitle.url.urlQueryEncode())
                }
            }
        },
    ),
    IosExternalPlayerSpec(
        id = "outplayer",
        name = "Outplayer",
        scheme = "outplayer",
        buildUrl = { request ->
            buildString {
                append("outplayer://x-callback-url/play?url=")
                append(request.sourceUrl.urlQueryEncode())
                append("&filename=")
                append(request.buildPlayerTitle(includeEpisodeTitle = true).urlQueryEncode())
            }
        },
    ),
    IosExternalPlayerSpec(
        id = "vidhub",
        name = "VidHub",
        scheme = "open-vidhub",
        // FEAT-21 (beta.12): modernized from the legacy `/open` method to `/play` — the only
        // method VidHub's integration docs list as supporting Apple TV (they also cover Mac,
        // iPhone/iPad, Android; /open is Apple-legacy-only). /play adds `filename`, `position`
        // (seconds), and `sub`, which /open lacked for the title, so the handoff now carries
        // the same metadata Infuse gets.
        //
        // 2026-08-12 device pass: on the tvOS VidHub build, /play opened the app but never
        // started playback (post-onboarding retest included), despite the docs' Apple TV
        // support table. `debug.vidhubMethod` bisects the handoff live from launch args
        // without a rebuild: "open" = legacy method, "minimal" = /play with url only,
        // "bare" = undocumented vidhub://play (seen in bobsupra/NuvioTVOS, unverified there),
        // anything else/unset = the full documented /play.
        buildUrl = { request ->
            when (NSUserDefaults.standardUserDefaults.stringForKey("debug.vidhubMethod")) {
                // url-only, replicating the pre-beta.12 shipped builder byte-for-byte so the
                // bisect tests the legacy method exactly as it used to go out. (VidHub's docs
                // do list `sub` on /open, but a diagnostic branch adds nothing new.)
                "open" -> "open-vidhub://x-callback-url/open?url=" + request.sourceUrl.urlQueryEncode()
                "minimal" -> buildString {
                    append("open-vidhub://x-callback-url/play?url=")
                    append(request.sourceUrl.urlQueryEncode())
                }
                // Bare scheme, no x-callback-url host. Launch still gates on the open-vidhub
                // probe (spec.scheme), so this fires even if vidhub:// isn't registered —
                // the ContentView probe logs canOpenURL(vidhub://) to interpret a no-op.
                "bare" -> "vidhub://play?url=" + request.sourceUrl.urlQueryEncode()
                else -> buildString {
                    append("open-vidhub://x-callback-url/play?url=")
                    append(request.sourceUrl.urlQueryEncode())
                    append("&filename=")
                    append(request.buildPlayerTitle(includeEpisodeTitle = true).urlQueryEncode())
                    if (request.resumePositionMs > 0) {
                        append("&position=")
                        append(request.resumePositionMs / 1000)
                    }
                    request.subtitles?.firstOrNull()?.let { subtitle ->
                        append("&sub=")
                        append(subtitle.url.urlQueryEncode())
                    }
                }
            }
        },
    ),
    IosExternalPlayerSpec(
        id = "senplayer",
        name = "SenPlayer",
        scheme = "senplayer",
        // FEAT-56 (GitHub youngchris29-art/NuvioTV#5): SenPlayer's URL-scheme parameters are NOT
        // published, so this is the device-test shape, built on the Outplayer/VidHub/Infuse
        // `x-callback-url/play` grammar. Every parameter name below is UNVERIFIED against the
        // app: `position` (seconds), `filename` and `name` (SenPlayer 5.9.1 notes mention
        // "setting UA and name"), `sub`, and the `x-success`/`x-error` return (SenPlayer 6.1.1
        // notes "returning current playback time when exiting playback"). `debug.senplayerMethod`
        // bisects the handoff live from launch args without a rebuild, like VidHub's knob:
        // "minimal" = url only, "noname" = everything except filename/name, unset = full.
        // The minimal leg carries no `x-success`/`x-error` either: url-only is the point of that
        // bisect step, so no playback position comes back on it (the session Swift prepares just
        // expires). "noname" and the full URL keep the callbacks.
        buildUrl = { request ->
            when (NSUserDefaults.standardUserDefaults.stringForKey("debug.senplayerMethod")) {
                "minimal" -> buildString {
                    // url only, no callbacks: see the note above.
                    append("senplayer://x-callback-url/play?url=")
                    append(request.sourceUrl.urlQueryEncode())
                }
                "noname" -> buildSenPlayerUrl(request, includeName = false)
                else -> buildSenPlayerUrl(request, includeName = true)
            }
        },
    ),
    IosExternalPlayerSpec(
        id = "nativeplayer",
        name = "Native Player",
        scheme = "nativeplayer",
        buildUrl = ::buildNativePlayerUrl,
        supportsSource = { request -> nativePlayerSupportsSource(request.sourceUrl) },
    ),
)

/** Infuse's x-callback play URL. `position` is whole seconds (issue #19: the picker resolves it,
 *  including a Trakt percentage scaled by the runtime). Unit tested (`InfuseUrlTest`). */
internal fun buildInfuseUrl(request: ExternalPlayerPlaybackRequest): String =
    buildString {
        append("infuse://x-callback-url/play?url=")
        append(request.sourceUrl.urlQueryEncode())
        append("&position=")
        append(request.resumePositionMs.coerceAtLeast(0L) / 1000L)
        append("&filename=")
        append(request.buildPlayerTitle(includeEpisodeTitle = true).urlQueryEncode())
        request.subtitles?.forEach { subtitle ->
            append("&sub=")
            append(subtitle.url.urlQueryEncode())
        }
        // Upstream 99ced26a: Infuse opens these when playback ends, reporting the
        // position back (`ExternalPlaybackReturn.handleUrl`).
        request.callbackSuccessUrl?.let { callbackUrl ->
            append("&x-success=")
            append(callbackUrl.urlQueryEncode())
        }
        request.callbackErrorUrl?.let { callbackUrl ->
            append("&x-error=")
            append(callbackUrl.urlQueryEncode())
        }
    }

/**
 * FEAT-78 (Steven, 2026-10-17): Native Player by Native IT (tvOS 26+). Its deep link (v1.1.3+)
 * is documented by the developer as Infuse-compatible:
 * `nativeplayer://x-callback-url/play?url=&filename=&position=&sub=…&x-success=&x-error=`.
 * Limits from that reference, enforced here: `url` must be http(s) and not DASH (`.mpd`); `sub`
 * is SRT only, http(s) only, up to 8 (a VTT/ASS/SSA/TTML link is dropped, an extension-less
 * add-on link is kept: OpenSubtitles v3 serves SRT that way); `position` 0 means "from the
 * start", so it is only sent when positive. Known gaps, not detectable without fetching: a VTT
 * link whose format sits only in the query or has no extension, and a DASH manifest with no
 * `.mpd` in its path, still go through. Request headers are not passed (no parameter for them,
 * same as Infuse).
 * `x-success` returns `lastPlayedUrl`, `position` (seconds) and `progress`, parsed by
 * `ExternalPlaybackReturn` exactly like Infuse's.
 */
internal fun buildNativePlayerUrl(request: ExternalPlayerPlaybackRequest): String =
    buildString {
        append("nativeplayer://x-callback-url/play?url=")
        append(request.sourceUrl.urlQueryEncode())
        append("&filename=")
        append(request.buildPlayerTitle(includeEpisodeTitle = true).urlQueryEncode())
        if (request.resumePositionMs > 0) {
            append("&position=")
            append(request.resumePositionMs / 1000)
        }
        request.subtitles.orEmpty()
            .filter { it.url.isHttpUrl() && !it.url.hasNonSrtSubtitleExtension() }
            .take(8)
            .forEach { subtitle ->
                append("&sub=")
                append(subtitle.url.urlQueryEncode())
            }
        request.callbackSuccessUrl?.let { callbackUrl ->
            append("&x-success=")
            append(callbackUrl.urlQueryEncode())
        }
        request.callbackErrorUrl?.let { callbackUrl ->
            append("&x-error=")
            append(callbackUrl.urlQueryEncode())
        }
    }

internal fun nativePlayerSupportsSource(sourceUrl: String): Boolean =
    sourceUrl.isHttpUrl() && !sourceUrl.urlPath().lowercase().endsWith(".mpd")

private fun String.isHttpUrl(): Boolean {
    val lower = trim().lowercase()
    return lower.startsWith("http://") || lower.startsWith("https://")
}

/** The URL without its query or fragment. */
private fun String.urlPath(): String = substringBefore('#').substringBefore('?')

private fun String.hasNonSrtSubtitleExtension(): Boolean {
    val path = urlPath().lowercase()
    return listOf(".vtt", ".webvtt", ".ass", ".ssa", ".ttml", ".dfxp", ".xml", ".sub").any { path.endsWith(it) }
}

private fun buildSenPlayerUrl(request: ExternalPlayerPlaybackRequest, includeName: Boolean): String =
    buildString {
        append("senplayer://x-callback-url/play?url=")
        append(request.sourceUrl.urlQueryEncode())
        if (request.resumePositionMs > 0) {
            append("&position=")
            append(request.resumePositionMs / 1000)
        }
        if (includeName) {
            val title = request.buildPlayerTitle(includeEpisodeTitle = true).urlQueryEncode()
            append("&filename=")
            append(title)
            append("&name=")
            append(title)
        }
        request.subtitles?.forEach { subtitle ->
            append("&sub=")
            append(subtitle.url.urlQueryEncode())
        }
        // Return contract, modelled on Infuse's but unverified for SenPlayer: a returned
        // `position` (the parameter name is assumed; the device probe decides) lands in
        // `ExternalPlaybackReturn.handleUrl` once Swift prepares a session for "senplayer".
        // `lastPlayedUrl` is Infuse's own echo and is optional here: the handler accepts a
        // positioned success without it for any player but Infuse (review r1 F9).
        request.callbackSuccessUrl?.let { callbackUrl ->
            append("&x-success=")
            append(callbackUrl.urlQueryEncode())
        }
        request.callbackErrorUrl?.let { callbackUrl ->
            append("&x-error=")
            append(callbackUrl.urlQueryEncode())
        }
    }

actual object ExternalPlayerPlatform {
    actual fun defaultPlayerId(): String? = null

    actual fun availablePlayers(): List<ExternalPlayerApp> =
        iosExternalPlayerSpecs
            .filter { spec -> UIApplication.sharedApplication.canOpenURL(spec.schemeProbeUrl()) }
            .map { spec -> ExternalPlayerApp(spec.id, spec.name) }

    actual fun open(
        request: ExternalPlayerPlaybackRequest,
        playerId: String?,
    ): ExternalPlayerOpenResult {
        if (playerId.isNullOrBlank()) return ExternalPlayerOpenResult.NotConfigured
        val spec = iosExternalPlayerSpecs.firstOrNull { it.id == playerId }
            ?: return ExternalPlayerOpenResult.NotConfigured
        if (!UIApplication.sharedApplication.canOpenURL(spec.schemeProbeUrl())) {
            return ExternalPlayerOpenResult.NoPlayerAvailable
        }
        if (!spec.supportsSource(request)) return ExternalPlayerOpenResult.Failed
        val urlString = spec.buildUrl(request)
        // Knob-gated, console-only: the string embeds tokenized debrid URLs, so it must never
        // log unconditionally (the Sentry breadcrumb scrub in d5b29180 exists for this reason).
        if (NSUserDefaults.standardUserDefaults.boolForKey("debug.extPlayerProbe")) {
            // Single-arg NSLog with % escaped: K/N strings do not bridge through NSLog's C
            // varargs — NSLog("%@", kotlinString) SIGSEGVs (field-proven 2026-08-01).
            val line = "[ExtPlayerProbe] open player=" + spec.id + " url=" + urlString
            NSLog(line.replace("%", "%%"))
        }
        val url = NSURL.URLWithString(urlString)
            ?: return ExternalPlayerOpenResult.Failed
        // Upstream 99ced26a: a launch that carried a return callback but never opened drops its
        // own pending session (the open result arrives asynchronously, after `Opened`).
        val callbackSuccessUrl = request.callbackSuccessUrl
        UIApplication.sharedApplication.openURL(
            url = url,
            options = emptyMap<Any?, Any>(),
            completionHandler = if (callbackSuccessUrl == null) {
                null
            } else {
                { opened: Boolean ->
                    if (!opened) ExternalPlaybackReturn.cancelLaunchForCallbackUrl(callbackSuccessUrl)
                }
            },
        )
        return ExternalPlayerOpenResult.Opened
    }

    actual fun buildIntent(
        request: ExternalPlayerPlaybackRequest,
        playerId: String?,
    ): ExternalPlayerIntentResult {
        // iOS doesn't use Android intents; this returns the URL as the "intent" payload
        if (playerId.isNullOrBlank()) return ExternalPlayerIntentResult.NotConfigured
        val spec = iosExternalPlayerSpecs.firstOrNull { it.id == playerId }
            ?: return ExternalPlayerIntentResult.NotConfigured
        if (!UIApplication.sharedApplication.canOpenURL(spec.schemeProbeUrl())) {
            return ExternalPlayerIntentResult.Failed
        }
        if (!spec.supportsSource(request)) return ExternalPlayerIntentResult.Failed
        val url = NSURL.URLWithString(spec.buildUrl(request))
            ?: return ExternalPlayerIntentResult.Failed
        return ExternalPlayerIntentResult.Success(url)
    }
}

private fun IosExternalPlayerSpec.schemeProbeUrl(): NSURL =
    NSURL.URLWithString("$scheme://") ?: NSURL.URLWithString("nuvio://")!!

private fun String.urlQueryEncode(): String {
    val hex = "0123456789ABCDEF"
    return buildString {
        encodeToByteArray().forEach { byte ->
            val value = byte.toInt() and 0xFF
            val char = value.toChar()
            val safe = char in 'A'..'Z' ||
                char in 'a'..'z' ||
                char in '0'..'9' ||
                char == '-' ||
                char == '_' ||
                char == '.' ||
                char == '~'
            if (safe) {
                append(char)
            } else {
                append('%')
                append(hex[value ushr 4])
                append(hex[value and 0x0F])
            }
        }
    }
}
