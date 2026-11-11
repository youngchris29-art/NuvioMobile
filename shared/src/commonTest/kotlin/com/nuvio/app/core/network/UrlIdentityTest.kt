package com.nuvio.app.core.network

import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertFalse
import kotlin.test.assertNotEquals
import kotlin.test.assertTrue

class UrlIdentityTest {
    @Test
    fun schemeAndHostAreLowerCased() {
        assertEquals("https://example.com/Path", urlIdentityKey("HTTPS://EXAMPLE.com/Path"))
    }

    @Test
    fun userinfoKeepsItsCase() {
        assertEquals("https://User:Pw@example.com/p", urlIdentityKey("https://User:Pw@EXAMPLE.com/p"))
        assertNotEquals(urlIdentityKey("https://User@example.com/p"), urlIdentityKey("https://user@example.com/p"))
    }

    @Test
    fun portIsKept() {
        assertEquals("https://example.com:8443/p", urlIdentityKey("https://EXAMPLE.com:8443/p"))
        assertNotEquals(urlIdentityKey("https://example.com:8443/p"), urlIdentityKey("https://example.com:9443/p"))
    }

    @Test
    fun pathQueryAndFragmentKeepTheirCase() {
        assertNotEquals(urlIdentityKey("https://example.com/Anime.json"), urlIdentityKey("https://example.com/anime.json"))
        assertNotEquals(urlIdentityKey("https://example.com/p?token=AbC"), urlIdentityKey("https://example.com/p?token=abc"))
        assertNotEquals(urlIdentityKey("https://example.com/p#Frag"), urlIdentityKey("https://example.com/p#frag"))
        assertEquals("https://example.com#Frag", urlIdentityKey("https://EXAMPLE.com#Frag"))
    }

    @Test
    fun surroundingWhitespaceIsTrimmed() {
        assertEquals(urlIdentityKey("https://example.com/p.json"), urlIdentityKey("  https://EXAMPLE.com/p.json \n"))
    }

    @Test
    fun aStringWithoutASchemeIsReturnedTrimmedAndUnchanged() {
        assertEquals("Example.com/P", urlIdentityKey(" Example.com/P "))
        assertEquals("p?x=a://B", urlIdentityKey("p?x=a://B"))
    }

    @Test
    fun badgeSourcesMatchOnHostCaseOnly() {
        assertTrue(isSameBadgeSource("https://EXAMPLE.com/p.json", " https://example.com/p.json "))
        assertFalse(isSameBadgeSource("https://example.com/P.json", "https://example.com/p.json"))
    }
}
