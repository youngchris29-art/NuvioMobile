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
    private val urlPattern = Regex("""https?://[^\s"'<>)\]]+""")
    private val secretParamPattern =
        Regex("""(?i)\b(token|access_token|apikey|api_key|key|auth|password)=[^&\s"'<>)\]]+""")

    fun isAddonAnswer(error: Throwable): Boolean = error is MissingMetaObjectException

    /**
     * Review r1 F1: any text that can quote an add-on URL or response (exception messages,
     * payload excerpts, stack frames) passes through here: each URL becomes `<url>` and bare
     * secret-style query values become `<redacted>`.
     */
    fun scrub(text: String): String =
        secretParamPattern.replace(urlPattern.replace(text, "<url>")) { "${it.groupValues[1]}=<redacted>" }

    fun message(addonName: String, type: String, id: String, error: Throwable): String =
        if (isAddonAnswer(error)) {
            "Add-on \"$addonName\" returned no meta object for type=$type id=$id; trying the next source"
        } else {
            "Failed to fetch/parse meta from add-on \"$addonName\" for type=$type id=$id: " +
                detail(error) + " at " + location(error)
        }

    /** The class name plus the scrubbed message, for every class (a timeout keeps its reason). */
    private fun detail(error: Throwable): String {
        val name = error::class.simpleName ?: "unknown error"
        val text = error.message?.takeIf(String::isNotBlank)?.let(::scrub)
        return if (text == null) name else "$name: $text"
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
