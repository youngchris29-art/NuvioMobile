package com.nuvio.app.features.addons

import kotlinx.serialization.SerializationException
import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertFalse
import kotlin.test.assertTrue

class AddonFailureMessagesTest {
    @Test
    fun ownHttpStatusTextIsKept() {
        val message = manifestFailureMessage(IllegalStateException("Request failed with HTTP 503"))
        assertEquals("Request failed with HTTP 503", message)
    }

    @Test
    fun parserTextIsKept() {
        assertEquals("Manifest has no id", manifestFailureMessage(IllegalArgumentException("Manifest has no id")))
        assertEquals("Unexpected JSON token", manifestFailureMessage(SerializationException("Unexpected JSON token")))
    }

    @Test
    fun transportErrorsNeverShowTheUrl() {
        val keyed = "Request timeout has expired [url=https://addon.example/abc123SECRET/manifest.json]"
        val message = manifestFailureMessage(RuntimeException(keyed))
        assertFalse(message.contains("SECRET"))
        assertFalse(message.contains("://"))
        assertTrue(message.isNotBlank())
    }

    @Test
    fun ownExceptionWithAUrlStillFallsBack() {
        val message = manifestFailureMessage(IllegalStateException("Bad response from https://addon.example/key/manifest.json"))
        assertFalse(message.contains("://"))
    }

    @Test
    fun blankMessageFallsBack() {
        assertTrue(manifestFailureMessage(IllegalStateException("  ")).isNotBlank())
        assertTrue(manifestFailureMessage(RuntimeException()).isNotBlank())
    }
}
