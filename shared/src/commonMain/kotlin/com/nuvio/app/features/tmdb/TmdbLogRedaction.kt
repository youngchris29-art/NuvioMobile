package com.nuvio.app.features.tmdb

/**
 * Scrubs the TMDB `api_key` query value out of text headed for the log. Ktor timeout and
 * connection exceptions put the full request URL in `message`, and that URL carries the key.
 */
internal object TmdbLogRedaction {
    private val apiKeyParam = Regex("""(api_key=)[^&\s\])]*""", RegexOption.IGNORE_CASE)

    fun redact(message: String?): String =
        (message ?: "null").replace(apiKeyParam) { "api_key=<redacted>" }

    /** Class name plus redacted message; never the Throwable itself, whose stack trace can carry the URL. */
    fun describe(error: Throwable): String =
        "${error::class.simpleName ?: "Throwable"}: ${redact(error.message)}"
}
