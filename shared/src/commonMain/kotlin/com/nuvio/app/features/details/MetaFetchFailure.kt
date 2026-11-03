package com.nuvio.app.features.details

import kotlinx.serialization.SerializationException

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
    fun isAddonAnswer(error: Throwable): Boolean = error is MissingMetaObjectException

    fun message(addonName: String, type: String, id: String, error: Throwable): String =
        if (isAddonAnswer(error)) {
            "Add-on \"$addonName\" returned no meta object for type=$type id=$id; trying the next source"
        } else {
            "Failed to fetch/parse meta from add-on \"$addonName\" for type=$type id=$id: " + detail(error)
        }

    /**
     * Only parser-class messages are ours; any other message (a Ktor timeout or connection
     * error) can hold the request URL with the add-on's token, so those print the class name.
     */
    private fun detail(error: Throwable): String {
        val name = error::class.simpleName ?: "unknown error"
        val ours = error is IllegalStateException || error is SerializationException
        return if (ours) error.message ?: name else name
    }
}
