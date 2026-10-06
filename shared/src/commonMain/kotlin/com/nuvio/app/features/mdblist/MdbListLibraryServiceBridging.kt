package com.nuvio.app.features.mdblist

/** Shown when a visibility change fails without a message that is safe to show. */
internal const val MDBLIST_LIST_VISIBILITY_FALLBACK = "Couldn't update this list. Try again."

/**
 * User-safe text for a failed [MdbListLibraryService.setListVisible], the same rule as
 * `LibraryRepository.removeFromListAsync`: exactly `require`'s class keeps its own words ("This list
 * is no longer available"); everything else, including subclasses such as Ktor's illegal-header
 * exception whose message holds the bearer token, goes through [localizedMdbListMessage].
 */
internal fun mdbListListVisibilityFailureMessage(error: Throwable): String {
    if (error::class == IllegalArgumentException::class) {
        error.message?.trim()?.takeIf { it.isNotEmpty() }?.let { return it }
    }
    return error.localizedMdbListMessage().ifBlank { MDBLIST_LIST_VISIBILITY_FALLBACK }
}

/**
 * Swift-facing: [onResult] gets nil on success, else a message safe to put on screen. Wraps the
 * upstream [MdbListLibraryService.setListVisibleAsync] (left untouched for the next upstream diff).
 */
fun MdbListLibraryService.setListVisibilityAsync(key: String, visible: Boolean, onResult: (String?) -> Unit) {
    setListVisibleAsync(key, visible) { error ->
        onResult(error?.let(::mdbListListVisibilityFailureMessage))
    }
}
