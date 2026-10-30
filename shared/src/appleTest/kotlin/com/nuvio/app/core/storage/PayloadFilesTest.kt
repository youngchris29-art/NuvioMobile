package com.nuvio.app.core.storage

import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertFalse
import kotlin.test.assertNull
import kotlin.test.assertTrue

/**
 * The failure paths of the payload store, on a fake file system: a root that cannot be created,
 * a write that fails, a platform without a root. These are the paths the tvOS device hit for two
 * months without a log line (2026-10-29); the happy path on the real file system is
 * [PayloadFileStoreTest].
 */
class PayloadFilesTest {
    private class FakeFileSystem(
        override val baseDirectory: String? = "/root",
        override val legacyBaseDirectories: List<String> = emptyList(),
        var createDirectoryError: String? = null,
        var writeError: String? = null,
    ) : PayloadFileSystem {
        val directories = mutableSetOf<String>()
        val files = mutableMapOf<String, String>()
        var createDirectoryCalls = 0

        override fun createDirectory(path: String): String? {
            createDirectoryCalls++
            createDirectoryError?.let { return it }
            directories += path
            return null
        }

        override fun read(path: String): String? = files[path]

        override fun write(path: String, payload: String): String? {
            writeError?.let { return it }
            files[path] = payload
            return null
        }

        override fun remove(path: String) {
            files.remove(path)
            directories.remove(path)
            files.keys.filter { it.startsWith("$path/") }.forEach(files::remove)
        }
    }

    private class FakeLegacyDefaults : LegacyDefaults {
        val values = mutableMapOf<String, String>()
        override fun get(key: String): String? = values[key]
        override fun remove(key: String) {
            values.remove(key)
        }
    }

    private val reports = mutableListOf<String>()

    private fun files(fileSystem: FakeFileSystem, legacy: FakeLegacyDefaults = FakeLegacyDefaults()) =
        PayloadFiles(fileSystem, legacy, reports::add)

    @Test
    fun saveCreatesTheStoreDirectoryUnderTheRootAndWritesTheKeyFile() {
        val fs = FakeFileSystem()
        val store = files(fs)

        assertTrue(store.save("WatchProgress", "watch_progress_payload_3", "{}"))
        assertTrue("/root/WatchProgress" in fs.directories)
        assertEquals("{}", fs.files["/root/WatchProgress/watch_progress_payload_3.json"])
        assertEquals("{}", store.load("WatchProgress", "watch_progress_payload_3"))
        assertTrue(reports.isEmpty(), "a successful save logs nothing")
    }

    @Test
    fun saveReturnsFalseAndReportsOncePerStoreWhenTheDirectoryCannotBeCreated() {
        val fs = FakeFileSystem(createDirectoryError = "NSCocoaErrorDomain 513 You don’t have permission")
        val store = files(fs)

        assertFalse(store.save("WatchProgress", "watch_progress_payload_3", "{}"))
        assertFalse(store.save("WatchProgress", "watch_progress_payload_3", "{}"))
        assertFalse(store.save("Collections", "collections_payload_3", "{}"))

        assertTrue(fs.files.isEmpty())
        assertEquals(2, reports.size, "one line per store, not per save: $reports")
        assertTrue(reports[0].startsWith("WatchProgress payload store: cannot create /root/WatchProgress: NSCocoaErrorDomain 513"), reports[0])
        assertTrue("root=/root" in reports[0], reports[0])
        assertTrue(reports[1].startsWith("Collections payload store:"), reports[1])
    }

    @Test
    fun saveReturnsFalseAndReportsWhenTheFileWriteFails() {
        val fs = FakeFileSystem(writeError = "NSCocoaErrorDomain 640 No space left")
        val store = files(fs)

        assertFalse(store.save("Library", "library_payload_1", "{}"))
        assertEquals(1, reports.size)
        assertTrue("cannot write /root/Library/library_payload_1.json: NSCocoaErrorDomain 640" in reports[0], reports[0])
    }

    @Test
    fun aFailedWriteKeepsTheLegacyDefaultsValueAndLoadStillReturnsIt() {
        val fs = FakeFileSystem(createDirectoryError = "denied")
        val legacy = FakeLegacyDefaults().apply { values["watched_payload_1"] = "legacy" }
        val store = files(fs, legacy)

        assertFalse(store.save("Watched", "watched_payload_1", "new"))
        assertEquals("legacy", legacy.values["watched_payload_1"], "the only copy must survive a failed write")
        assertEquals("legacy", store.load("Watched", "watched_payload_1"))
        assertEquals("legacy", legacy.values["watched_payload_1"], "a failed drain must not drop the defaults key")
    }

    @Test
    fun noRootDirectoryReportsOnceAndFallsBackToTheLegacyValue() {
        val fs = FakeFileSystem(baseDirectory = null)
        val legacy = FakeLegacyDefaults().apply { values["k"] = "legacy" }
        val store = files(fs, legacy)

        assertFalse(store.save("Store", "k", "v"))
        assertEquals("legacy", store.load("Store", "k"))
        assertEquals(0, fs.createDirectoryCalls)
        assertEquals(1, reports.size)
        assertTrue("no payload root directory" in reports[0], reports[0])
    }

    @Test
    fun loadDrainsTheLegacyDefaultsValueOnlyAfterTheFileWriteLanded() {
        val fs = FakeFileSystem()
        val legacy = FakeLegacyDefaults().apply { values["k"] = "legacy" }
        val store = files(fs, legacy)

        assertEquals("legacy", store.load("Store", "k"))
        assertEquals("legacy", fs.files["/root/Store/k.json"])
        assertNull(legacy.values["k"])
    }

    @Test
    fun loadMovesAFileFromALegacyRootUnderTheCurrentRoot() {
        val fs = FakeFileSystem(legacyBaseDirectories = listOf("/old"))
        fs.files["/old/WatchProgress/watch_progress_payload_1.json"] = "moved"
        val store = files(fs)

        assertEquals("moved", store.load("WatchProgress", "watch_progress_payload_1"))
        assertEquals("moved", fs.files["/root/WatchProgress/watch_progress_payload_1.json"])
        assertNull(fs.files["/old/WatchProgress/watch_progress_payload_1.json"], "the old copy goes once the new one landed")
        assertTrue(reports.isEmpty())
    }

    @Test
    fun aFileThatCannotMoveStaysUnderTheLegacyRootAndIsStillReturned() {
        val fs = FakeFileSystem(legacyBaseDirectories = listOf("/old"), writeError = "denied")
        fs.files["/old/Store/k.json"] = "kept"
        val store = files(fs)

        assertEquals("kept", store.load("Store", "k"))
        assertEquals("kept", fs.files["/old/Store/k.json"])
        assertEquals(1, reports.size)
    }

    @Test
    fun theCurrentRootWinsOverALegacyRoot() {
        val fs = FakeFileSystem(legacyBaseDirectories = listOf("/old"))
        fs.files["/old/Store/k.json"] = "old"
        fs.files["/root/Store/k.json"] = "new"

        assertEquals("new", files(fs).load("Store", "k"))
        assertEquals("old", fs.files["/old/Store/k.json"], "nothing is touched when the current root has the file")
    }

    @Test
    fun removeAndDeleteAllClearEveryRoot() {
        val fs = FakeFileSystem(legacyBaseDirectories = listOf("/old"))
        val legacy = FakeLegacyDefaults().apply { values["a"] = "x" }
        val store = files(fs, legacy)
        fs.files["/old/Store/a.json"] = "old"
        fs.files["/old/Store/b.json"] = "old"
        store.save("Store", "a", "new")
        store.save("Store", "b", "new")

        store.remove("Store", "a")
        assertNull(fs.files["/root/Store/a.json"])
        assertNull(fs.files["/old/Store/a.json"])
        assertNull(legacy.values["a"])
        assertEquals("new", fs.files["/root/Store/b.json"])

        store.deleteAll("Store")
        assertTrue(fs.files.isEmpty(), "deleteAll leaves nothing under any root: ${fs.files.keys}")
    }
}
