package com.nuvio.app.features.player

import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertTrue

/**
 * OpenSubtitles Spanish-EU aliases (upstream NuvioTV 2a54e8cbe) and Serbo-Croatian
 * "hbs-" labels (upstream NuvioTV d34a5025d), and Montenegrin codes (upstream NuvioTV 7eb388a83).
 */
class PlayerSubtitleMatchingAliasTest {

    @Test
    fun spanishEuCodesNormalizeToSpanish() {
        assertEquals("es", SubtitleLanguageMatching.normalizeLanguageCode("spn"))
        assertEquals("es", SubtitleLanguageMatching.normalizeLanguageCode("sp"))
        assertEquals("es", SubtitleLanguageMatching.normalizeLanguageCode("ESP"))
        assertTrue(SubtitleLanguageMatching.matchesLanguageCode("spn", "es"))
    }

    @Test
    fun latinAmericanCodeStaysLatinAmerican() {
        assertEquals("es-419", SubtitleLanguageMatching.normalizeLanguageCode("spl"))
    }

    @Test
    fun hbsLabelsResolveToTheirOwnLanguage() {
        assertEquals("sr", SubtitleLanguageMatching.normalizeLanguageCode("hbs-srp"))
        assertEquals("hr", SubtitleLanguageMatching.normalizeLanguageCode("hbs-hrv"))
        assertEquals("bs", SubtitleLanguageMatching.normalizeLanguageCode("hbs_bos"))
    }

    @Test
    fun bareHbsIsLeftAlone() {
        assertEquals("hbs", SubtitleLanguageMatching.normalizeLanguageCode("hbs"))
    }

    @Test
    fun montenegrinCodesNormalizeToSerbianMontenegro() {
        assertEquals("sr-me", SubtitleLanguageMatching.normalizeLanguageCode("mne"))
        assertEquals("sr-me", SubtitleLanguageMatching.normalizeLanguageCode("ME"))
        assertEquals("sr-me", SubtitleLanguageMatching.normalizeLanguageCode("cnr"))
        assertTrue(SubtitleLanguageMatching.matchesLanguageCode("mne", "sr-me"))
        assertTrue(SubtitleLanguageMatching.matchesLanguageCode("me", "sr-me"))
        assertTrue(SubtitleLanguageMatching.matchesLanguageCode("cnr", "sr-me"))
        // A plain Serbian preference still accepts Montenegrin tracks.
        assertTrue(SubtitleLanguageMatching.matchesLanguageCode("mne", "sr"))
        // A Montenegrin preference does not pull in plain Serbian.
        assertTrue(!SubtitleLanguageMatching.matchesLanguageCode("srp", "sr-me"))
    }

    @Test
    fun audioPreferenceAliasesCoverMontenegrinCodes() {
        assertEquals("sr-me", normalizeLanguageCode("mne"))
        assertEquals("sr-me", normalizeLanguageCode("me"))
        assertEquals("sr-me", normalizeLanguageCode("cnr"))
        assertEquals("sr-me", normalizeLanguageCode("Montenegrin"))
        assertEquals("sr", normalizeLanguageCode("srp"))
    }

    @Test
    fun audioPreferenceAliasesCoverSpanishEuCodes() {
        assertEquals("es", normalizeLanguageCode("spn"))
        assertEquals("es", normalizeLanguageCode("esp"))
    }
}
