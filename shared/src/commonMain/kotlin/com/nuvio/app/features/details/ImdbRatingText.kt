package com.nuvio.app.features.details

/**
 * Fork deviation (device session 2026-10-04): an add-on's `imdbRating` as shown, or null when it
 * says there is no rating. Some add-ons send "N/A" (the OMDb placeholder), a dash or 0 for a title
 * that has no IMDb rating yet, and the Detail meta line printed that as "★ N/A". Everything else
 * passes through trimmed, unchanged (a "7.4" or a "7.4/10" stays as the add-on wrote it).
 * Upstream-report candidate: the phone app reads the same field.
 */
internal fun knownImdbRating(raw: String?): String? {
    val value = raw?.trim()?.takeIf(String::isNotBlank) ?: return null
    if (value.equals("N/A", ignoreCase = true) || value.equals("NA", ignoreCase = true) || value == "-") {
        return null
    }
    value.toDoubleOrNull()?.let { if (it <= 0.0) return null }
    return value
}
