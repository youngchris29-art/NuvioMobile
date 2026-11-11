package com.nuvio.app.core.network

/**
 * The identity of a URL for "is this the same resource" comparisons: scheme and host are compared
 * case-insensitively (RFC 3986), while userinfo, port, path, query and fragment keep their case
 * (they are case-sensitive: a gist id, a raw-file path or a `?token=` value that differs only in
 * case names something else). Surrounding whitespace is trimmed.
 *
 * A string without a `://` scheme separator before its first `/`, `?` or `#` has no authority to
 * lower-case and is returned trimmed and otherwise unchanged.
 */
internal fun urlIdentityKey(url: String): String {
    val trimmed = url.trim()
    val firstBreak = trimmed.indexOfFirst { it == '/' || it == '?' || it == '#' }.let { if (it < 0) trimmed.length else it }
    val schemeAt = trimmed.indexOf("://").takeIf { it in 0 until firstBreak } ?: return trimmed
    val afterSep = trimmed.substring(schemeAt + 3)
    val authorityEnd = afterSep.indexOfFirst { it == '/' || it == '?' || it == '#' }.let { if (it < 0) afterSep.length else it }
    val authority = afterSep.substring(0, authorityEnd)
    val at = authority.lastIndexOf('@')
    val host = if (at >= 0) authority.substring(0, at + 1) + authority.substring(at + 1).lowercase() else authority.lowercase()
    return trimmed.substring(0, schemeAt).lowercase() + "://" + host + afterSep.substring(authorityEnd)
}

/** Whether two badge-pack source URLs name the same pack (see [urlIdentityKey]). */
fun isSameBadgeSource(a: String, b: String): Boolean = urlIdentityKey(a) == urlIdentityKey(b)
