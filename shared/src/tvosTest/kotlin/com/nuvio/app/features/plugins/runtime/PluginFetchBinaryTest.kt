package com.nuvio.app.features.plugins.runtime

import com.dokar.quickjs.binding.asyncFunction
import com.dokar.quickjs.binding.function
import com.dokar.quickjs.quickJs
import com.nuvio.app.features.plugins.runtime.js.JsRuntime
import com.nuvio.app.features.plugins.runtime.network.decodeFetchRequestBody
import com.nuvio.app.features.plugins.runtime.network.encodeFetchBodyBase64
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.runBlocking
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.JsonPrimitive
import kotlin.test.Test
import kotlin.test.assertContentEquals
import kotlin.test.assertEquals
import kotlin.test.assertFailsWith
import kotlin.test.assertNotNull
import kotlin.test.assertNull
import kotlin.test.assertTrue

/**
 * Upstream 12621c65 (binary-safe plugin fetch) + 2e244028 (static polyfill replayed from cached
 * bytecode). Upstream's BinaryFetchTest is an Android Robolectric/MockWebServer test of the OkHttp
 * actual; this is the tvOS-native equivalent of the bridge half: the JS polyfill must hand a typed
 * array view across as exact bytes (offset + length respected), expose response bytes through
 * Response.arrayBuffer(), keep string bodies as text, and do all of that when the polyfill runs
 * from bytecode compiled by a different QuickJS runtime.
 */
class PluginFetchBinaryTest {

    private val sample = byteArrayOf(0x00, 0x01, 0x7f, 0x80.toByte(), 0xff.toByte())

    @Test
    fun base64RequestBodyDecodesToExactBytes() {
        assertContentEquals(sample, decodeFetchRequestBody("base64", encodeFetchBodyBase64(sample)))
    }

    @Test
    fun textAndEmptyBodiesKeepTheStringPath() {
        assertNull(decodeFetchRequestBody("text", "plain"))
        assertNull(decodeFetchRequestBody("none", ""))
    }

    @Test
    fun unknownBodyKindIsRejected() {
        assertFailsWith<IllegalStateException> { decodeFetchRequestBody("blob", "") }
    }

    @Test
    fun polyfillRoundTripsBinaryBodiesFromCachedBytecode() {
        runBlocking {
            // The first pass compiles and caches the polyfill; the second runtime replays it.
            repeat(2) { runPolyfillRoundTrip() }
        }
    }

    private suspend fun runPolyfillRoundTrip() {
        val sentKinds = mutableListOf<String?>()
        val sentValues = mutableListOf<String?>()
        var captured: String? = null

        quickJs(Dispatchers.Default) {
            function("__get_scraper_id") { _ -> "test-scraper" }
            function("__get_scraper_settings") { _ -> "{\"quality\":\"1080p\"}" }
            function("__get_tmdb_api_key") { _ -> "test-key" }
            function("__capture_result") { args ->
                captured = args.getOrNull(0)?.toString()
                null
            }
            asyncFunction("__native_fetch") { args ->
                sentKinds += args.getOrNull(3)?.toString()
                sentValues += args.getOrNull(4)?.toString()
                JsonObject(
                    mapOf(
                        "ok" to JsonPrimitive(true),
                        "status" to JsonPrimitive(200),
                        "statusText" to JsonPrimitive("OK"),
                        "url" to JsonPrimitive(args.getOrNull(0)?.toString() ?: ""),
                        "body" to JsonPrimitive("text-body"),
                        "bodyBase64" to JsonPrimitive(encodeFetchBodyBase64(sample)),
                        "headers" to JsonObject(emptyMap()),
                    ),
                ).toString()
            }

            evaluate<Any?>(JsRuntime.polyfillBytecode(this))
            evaluate<Any?>(
                """
                (async function() {
                    var view = new Uint8Array([9, 1, 127, 128, 255, 9]).subarray(1, 5);
                    var res = await fetch('https://example.invalid/bin', { method: 'POST', body: view });
                    var bytes = new Uint8Array(await res.arrayBuffer());
                    var text = await res.text();
                    await fetch('https://example.invalid/text', { method: 'POST', body: 'plain' });
                    __capture_result(JSON.stringify({
                        bytes: Array.prototype.slice.call(bytes),
                        text: text,
                        id: SCRAPER_ID,
                        quality: SCRAPER_SETTINGS.quality
                    }));
                })();
                """.trimIndent(),
            )
        }

        assertEquals(listOf<String?>("base64", "text"), sentKinds)
        assertContentEquals(
            byteArrayOf(0x01, 0x7f, 0x80.toByte(), 0xff.toByte()),
            decodeFetchRequestBody("base64", sentValues[0] ?: ""),
        )
        assertEquals("plain", sentValues[1])

        val result = assertNotNull(captured)
        assertTrue(result.contains("\"bytes\":[0,1,127,128,255]"), result)
        assertTrue(result.contains("\"text\":\"text-body\""), result)
        assertTrue(result.contains("\"id\":\"test-scraper\""), result)
        assertTrue(result.contains("\"quality\":\"1080p\""), result)
    }
}
