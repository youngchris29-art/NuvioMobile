package com.nuvio.app.features.player

/**
 * Seam producing a human-readable label for a language code (e.g. "en" -> "English").
 * The phone app installs an adapter backed by getLanguageLabelForCode (which maps 81
 * lang_* Compose-resource strings); tvOS leaves the default (uppercased raw code, e.g. "EN").
 * Keeps the 81-string PlayerLanguageLabels.kt out of :shared.
 */
fun interface SubtitleLanguageLabeler {
    suspend fun label(code: String?): String
}

object SubtitleLanguageLabelProvider {
    var labeler: SubtitleLanguageLabeler = SubtitleLanguageLabeler { code ->
        code?.trim()?.takeIf { it.isNotBlank() }?.uppercase() ?: ""
    }
}
