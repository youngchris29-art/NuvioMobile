package com.nuvio.app.features.settings

enum class AppLanguage(
    val code: String,
) {
    DEVICE("device"),
    BULGARIAN("bg"),
    CZECH("cs"),
    ENGLISH("en"),
    FRENCH("fr"),
    GERMAN("de"),
    GREEK("el"),
    HUNGARIAN("hu"),
    INDONESIAN("id"),
    ITALIAN("it"),
    POLISH("pl"),
    PORTUGUESE_BRAZIL("pt-BR"),
    PORTUGUESE("pt"),
    SLOVAK("sk"),
    SPANISH("es"),
    TURKISH("tr"),
    NORWEGIAN("nb"),
    JAPANESE("ja"),
    ;

    companion object {
        fun fromCode(code: String?): AppLanguage =
            entries.firstOrNull { it.code.equals(code, ignoreCase = true) } ?: DEVICE
    }
}
