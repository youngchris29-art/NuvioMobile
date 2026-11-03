package com.nuvio.app.features.details

/**
 * BUG-239: an add-on answered its `meta` resource with a JSON object that holds no meta (an
 * error body, `{"meta":null}`, an empty object). Still an [IllegalStateException], so callers
 * that caught the parser's old `error(...)` behave the same.
 */
class MissingMetaObjectException : IllegalStateException("Response did not contain a valid meta object")

/**
 * BUG-239: the log lines for a failed add-on meta fetch. They name the add-on and the title,
 * never the request or manifest URL (add-on URLs carry tokens). A missing meta object is an
 * add-on answer, not an app fault: one warning, no stack trace.
 */
internal object MetaFetchFailureLog {
    // A backslash ends a match too, so a JSON `\"` after a URL is never swallowed.
    private val urlPattern = Regex("""https?://[^\s"'<>)\]\\]+""")
    private val inputExcerptMarker = Regex("""\s*JSON input:""", RegexOption.IGNORE_CASE)
    private val unicodeEscape = Regex("""\\u([0-9a-fA-F]{4})""")
    private val secretParamPattern =
        Regex("""(?i)\b(token|access_token|apikey|api_key|key|auth|password)=[^&\s"'<>)\]\\]+""")

    fun isAddonAnswer(error: Throwable): Boolean = error is MissingMetaObjectException

    /**
     * Review r1 F1: any text that can quote an add-on URL or response (exception messages,
     * payload excerpts, stack frames) passes through here: each URL becomes `<url>` and bare
     * secret-style query values become `<redacted>`. Reviews r2/r3: a quoted body can spell a
     * URL with JSON escapes (`https:\/\/h`, `\u002F`, `\u0026token=`), so every JSON escape is
     * decoded first and the patterns run on the plain text.
     */
    fun scrub(text: String): String {
        val decoded = decodeJsonEscapes(text)
        return secretParamPattern.replace(urlPattern.replace(decoded, "<url>")) { "${it.groupValues[1]}=<redacted>" }
    }

    /** `\uXXXX` first, then `\/`, `\\` and `\"`. Over-decoding is harmless here: it only feeds the scrub. */
    private fun decodeJsonEscapes(text: String): String =
        unicodeEscape.replace(text) { it.groupValues[1].toInt(16).toChar().toString() }
            .replace("\\/", "/")
            .replace("\\\\", "\\")
            .replace("\\\"", "\"")

    /** Review r3: the debug line describes the add-on body without quoting any of it. */
    fun payloadSummary(payload: String): String =
        "Raw payload length=${payload.length}, hasMetaKey=${payload.contains("\"meta\"")}"

    fun message(addonName: String, type: String, id: String, error: Throwable): String =
        if (isAddonAnswer(error)) {
            "Add-on \"$addonName\" returned no meta object for type=$type id=$id; trying the next source"
        } else {
            "Failed to fetch/parse meta from add-on \"$addonName\" for type=$type id=$id: " +
                detail(error) + " at " + location(error)
        }

    /**
     * The class name plus the message, for every class (a timeout keeps its reason): any input
     * excerpt is cut off first, then the rest is scrubbed.
     */
    private fun detail(error: Throwable): String {
        val name = error::class.simpleName ?: "unknown error"
        val text = error.message?.takeIf(String::isNotBlank)?.let(::stripInputExcerpt)?.let(::scrub)
        return if (text == null) name else "$name: $text"
    }

    /**
     * Review r4: kotlinx.serialization appends `\nJSON input: <window>` to its errors, and the
     * window can start inside a tokenized URL where no pattern can see it. Everything from the
     * first `JSON input:` (any case, any preceding whitespace) is dropped, whatever the class;
     * the reason before it (`Unexpected JSON token at offset N …`, `at path: $.poster`) stays.
     */
    internal fun stripInputExcerpt(text: String): String {
        val marker = inputExcerptMarker.find(text) ?: return text
        return text.substring(0, marker.range.first) + " [input excerpt removed]"
    }

    /**
     * Review r1 F2: no stack trace reaches the logger, so name where it was thrown: the first
     * app frame (`com.nuvio`), trimmed and scrubbed.
     */
    private fun location(error: Throwable): String =
        error.stackTraceToString().lineSequence()
            .map(String::trim)
            .firstOrNull { it.startsWith("at ") && it.contains("com.nuvio") }
            ?.let(::scrub)
            ?: "location unknown"
}
