@file:OptIn(kotlinx.cinterop.ExperimentalForeignApi::class, kotlinx.cinterop.BetaInteropApi::class)

package com.nuvio.app.core.storage

import platform.Foundation.NSApplicationSupportDirectory
import platform.Foundation.NSCachesDirectory
import platform.Foundation.NSFileManager
import platform.Foundation.NSSearchPathForDirectoriesInDomains
import platform.Foundation.NSString
import platform.Foundation.NSUTF8StringEncoding
import platform.Foundation.NSUserDomainMask
import platform.Foundation.create
import platform.Foundation.writeToFile
import kotlin.test.AfterTest
import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertFalse
import kotlin.test.assertTrue

/**
 * tvOS pins the payload root to `Library/Caches/PayloadStores` (the only location Apple's tvOS
 * storage rules allow for files this size, see `PayloadStoreLocation.tvos.kt`) and relocates
 * the files earlier builds wrote under Application Support.
 */
class PayloadStoreLocationTvOsTest {
    private val subdirectory = "PayloadStoreLocationTvOsTest"
    private val key = "payload_store_location_test_key"
    private val fileManager = NSFileManager.defaultManager

    private fun searchPath(directory: ULong): String =
        NSSearchPathForDirectoriesInDomains(directory, NSUserDomainMask, true).first() as String

    @AfterTest
    fun tearDown() {
        PayloadFileStore.deleteAll(subdirectory)
    }

    @Test
    fun theRootIsThePayloadStoresFolderOfTheCachesDirectory() {
        assertEquals("${searchPath(NSCachesDirectory)}/PayloadStores", payloadStoreBaseDirectory())
        assertEquals(listOf(searchPath(NSApplicationSupportDirectory)), payloadStoreLegacyBaseDirectories())
    }

    @Test
    fun saveLandsTheFileUnderCachesNotUnderApplicationSupport() {
        assertTrue(PayloadFileStore.save(subdirectory, key, "{}"))

        val cachesPath = "${searchPath(NSCachesDirectory)}/PayloadStores/$subdirectory/$key.json"
        val supportPath = "${searchPath(NSApplicationSupportDirectory)}/$subdirectory/$key.json"
        assertTrue(fileManager.fileExistsAtPath(cachesPath), "expected $cachesPath")
        assertFalse(fileManager.fileExistsAtPath(supportPath))
    }

    @Test
    fun aFileLeftUnderApplicationSupportMovesToCachesOnFirstRead() {
        val supportDirectory = "${searchPath(NSApplicationSupportDirectory)}/$subdirectory"
        fileManager.createDirectoryAtPath(supportDirectory, withIntermediateDirectories = true, attributes = null, error = null)
        val supportPath = "$supportDirectory/$key.json"
        assertTrue(NSString.create(string = "from-support").writeToFile(supportPath, atomically = true, encoding = NSUTF8StringEncoding, error = null))

        assertEquals("from-support", PayloadFileStore.load(subdirectory, key))
        assertFalse(fileManager.fileExistsAtPath(supportPath), "the Application Support copy goes after the move")
        assertTrue(fileManager.fileExistsAtPath("${payloadStoreBaseDirectory()}/$subdirectory/$key.json"))
        assertEquals("from-support", PayloadFileStore.load(subdirectory, key))
    }
}
