package com.nuvio.app.features.addons

import com.nuvio.app.core.i18n.StringKey
import com.nuvio.app.core.i18n.resourceString
import kotlinx.serialization.SerializationException

/*
 * Search & Discover batch 2026-10-06 (review r2 follow-up): the add-on manifest error reaches the
 * screen on Home ("Setting up your catalogs…" → Retry), Search and Discover (their manifest-failure
 * empty states), and composeApp's add-on screens. The fork's own failures carry localized text
 * (`error(resourceString("Request failed with HTTP …"))`, `IllegalStateException("Empty response
 * body")`, the manifest parser's `require`/`SerializationException`s), but a transport failure
 * from Ktor or the Darwin engine carries the request URL in its message ("Request timeout has
 * expired [url=…]", `NSErrorFailingURLStringKey=…`) — and a keyed add-on keeps its API or debrid
 * key in that URL. So only the fork's own exception types keep their text; everything else shows
 * the localized "Unable to load manifest".
 */

/** The user-facing text for a failed manifest load; never a raw transport message. */
internal fun manifestFailureMessage(error: Throwable): String {
    val fallback = resourceString("Unable to load manifest", StringKey.addon_load_manifest_failed)
    val keepsOwnText = error is IllegalStateException ||
        error is IllegalArgumentException ||
        error is SerializationException
    val message = error.message?.trim().orEmpty()
    return if (keepsOwnText && message.isNotEmpty() && !message.looksLikeUrlBearing()) message else fallback
}

/** A belt-and-braces check: even one of our own exceptions never shows a URL. */
private fun String.looksLikeUrlBearing(): Boolean =
    contains("://") || contains("url=", ignoreCase = true)
