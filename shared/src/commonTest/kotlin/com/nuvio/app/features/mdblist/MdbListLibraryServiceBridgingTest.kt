package com.nuvio.app.features.mdblist

import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertFalse

class MdbListLibraryServiceBridgingTest {
    private class HeaderLikeException(message: String) : IllegalArgumentException(message)

    @Test
    fun `plain require text is kept`() {
        assertEquals(
            "This list is no longer available",
            mdbListListVisibilityFailureMessage(IllegalArgumentException("This list is no longer available")),
        )
    }

    @Test
    fun `io and header exceptions never surface their text`() {
        val secret = "Bearer sk-secret-token"
        for (error in listOf<Throwable>(RuntimeException("Header value '$secret' contains illegal"), HeaderLikeException(secret))) {
            val message = mdbListListVisibilityFailureMessage(error)
            assertFalse(message.contains(secret), message)
            assertFalse(message.isBlank())
        }
    }
}
