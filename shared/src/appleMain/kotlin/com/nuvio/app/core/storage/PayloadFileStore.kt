@file:OptIn(kotlinx.cinterop.ExperimentalForeignApi::class, kotlinx.cinterop.BetaInteropApi::class)

package com.nuvio.app.core.storage

import co.touchlab.kermit.Logger
import kotlinx.atomicfu.locks.SynchronizedObject
import kotlinx.atomicfu.locks.synchronized
import kotlinx.cinterop.ObjCObjectVar
import kotlinx.cinterop.alloc
import kotlinx.cinterop.memScoped
import kotlinx.cinterop.ptr
import kotlinx.cinterop.value
import platform.Foundation.NSError
import platform.Foundation.NSFileManager
import platform.Foundation.NSString
import platform.Foundation.NSUTF8StringEncoding
import platform.Foundation.NSUserDefaults
import platform.Foundation.create
import platform.Foundation.stringWithContentsOfFile
import platform.Foundation.writeToFile

/**
 * File backing for payload stores whose defaults writes can grow with user data (the BUG-11 /
 * Trakt-library defect class): CFPreferences aborts the process outright on an oversized
 * defaults write (`__CFPREFERENCES_HAS_DETECTED_THIS_APP_TRYING_TO_STORE_TOO_MUCH_DATA__`), so
 * any payload without a hard size bound must never go through NSUserDefaults.
 *
 * Each store owns one subdirectory under the platform's payload root ([payloadStoreBaseDirectory]:
 * Application Support on iOS, `Library/Caches/PayloadStores` on tvOS — see
 * `PayloadStoreLocation.tvos.kt` for why), and files are named after the exact defaults key they
 * replace: [load] drains a legacy defaults value into the file store on first read, and
 * [save]/[remove] delete the legacy key so the defaults plist shrinks back on devices that wrote
 * through the old path. [load]/[save] only drop the legacy key after the file write succeeds, so
 * a failed write never loses the only copy.
 *
 * Failures are never silent: the first failed directory creation or file write per store and
 * launch is logged with the NSError (2026-10-29: on the Living Room Apple TV every write failed
 * for two months without a line in the console, and local watch progress only survived through
 * the sync push). The logic lives in [PayloadFiles] behind the [PayloadFileSystem] seam so the
 * failure paths have unit tests; this object is the production wiring.
 */
internal object PayloadFileStore {
    private val log = Logger.withTag("PayloadFileStore")
    private val files = PayloadFiles(
        fileSystem = ApplePayloadFileSystem,
        legacy = StandardLegacyDefaults,
        report = { message -> log.w { message } },
    )

    fun load(subdirectory: String, key: String): String? = files.load(subdirectory, key)

    /** Returns false when the write did not durably land (no resolvable root, or the directory / file write failed). */
    fun save(subdirectory: String, key: String, payload: String): Boolean = files.save(subdirectory, key, payload)

    fun remove(subdirectory: String, key: String) = files.remove(subdirectory, key)

    /** Sign-out cleanup — drops the store's whole directory (called by TvOsAccountDataCleaner). */
    fun deleteAll(subdirectory: String) = files.deleteAll(subdirectory)
}

/** The file-system operations [PayloadFiles] needs; [ApplePayloadFileSystem] is the real one, tests pass a fake. */
internal interface PayloadFileSystem {
    /** Root every store subdirectory lives under, or null when the platform cannot resolve one. */
    val baseDirectory: String?

    /** Roots earlier builds used; a file found under one is moved under [baseDirectory] on first read. */
    val legacyBaseDirectories: List<String>

    /** Creates [path] with intermediate directories. Null on success, else a description of the failure. */
    fun createDirectory(path: String): String?

    fun read(path: String): String?

    /** Atomic UTF-8 write of [payload] to [path]. Null on success, else a description of the failure. */
    fun write(path: String, payload: String): String?

    fun remove(path: String)
}

/** The NSUserDefaults values pre-migration builds wrote; a seam so tests never touch the real defaults. */
internal interface LegacyDefaults {
    fun get(key: String): String?
    fun remove(key: String)
}

internal class PayloadFiles(
    private val fileSystem: PayloadFileSystem,
    private val legacy: LegacyDefaults,
    private val report: (String) -> Unit,
) {
    private val reportLock = SynchronizedObject()
    private val reportedSubdirectories = mutableSetOf<String>()

    fun load(subdirectory: String, key: String): String? {
        val path = path(subdirectory, key) ?: return legacy.get(key)
        fileSystem.read(path)?.let { return it }
        relocateLegacyFile(subdirectory, key, path)?.let { return it }
        // Migration: drain the legacy defaults value into the file store, then drop the key.
        val legacyValue = legacy.get(key) ?: return null
        if (write(subdirectory, path, legacyValue)) {
            legacy.remove(key)
        }
        return legacyValue
    }

    fun save(subdirectory: String, key: String, payload: String): Boolean {
        val path = path(subdirectory, key) ?: return false
        if (!write(subdirectory, path, payload)) return false
        // Keep shrinking the defaults plist even for keys that are never read back.
        legacy.remove(key)
        return true
    }

    fun remove(subdirectory: String, key: String) {
        allRoots().forEach { root -> fileSystem.remove(filePath(root, subdirectory, key)) }
        legacy.remove(key)
    }

    fun deleteAll(subdirectory: String) {
        allRoots().forEach { root -> fileSystem.remove("$root/$subdirectory") }
    }

    /** The store directory, created on demand; null (reported once per launch) when it cannot exist. */
    private fun directory(subdirectory: String): String? {
        val base = fileSystem.baseDirectory
        if (base == null) {
            reportOnce(subdirectory, "no payload root directory on this platform")
            return null
        }
        val dir = "$base/$subdirectory"
        fileSystem.createDirectory(dir)?.let { error ->
            reportOnce(subdirectory, "cannot create $dir: $error")
            return null
        }
        return dir
    }

    private fun path(subdirectory: String, key: String): String? =
        directory(subdirectory)?.let { "$it/$key.json" }

    private fun filePath(root: String, subdirectory: String, key: String) = "$root/$subdirectory/$key.json"

    private fun allRoots(): List<String> =
        listOfNotNull(fileSystem.baseDirectory) + fileSystem.legacyBaseDirectories

    /** A file an earlier build left under a legacy root moves to [path]; the old copy goes only once the new one landed. */
    private fun relocateLegacyFile(subdirectory: String, key: String, path: String): String? {
        for (root in fileSystem.legacyBaseDirectories) {
            val oldPath = filePath(root, subdirectory, key)
            val payload = fileSystem.read(oldPath) ?: continue
            if (write(subdirectory, path, payload)) {
                fileSystem.remove(oldPath)
            }
            return payload
        }
        return null
    }

    private fun write(subdirectory: String, path: String, payload: String): Boolean {
        val error = fileSystem.write(path, payload) ?: return true
        reportOnce(subdirectory, "cannot write $path: $error")
        return false
    }

    /** One line per store and launch: the first failure carries the diagnosis, repeats would only flood the console. */
    private fun reportOnce(subdirectory: String, message: String) {
        val first = synchronized(reportLock) { reportedSubdirectories.add(subdirectory) }
        if (!first) return
        report(
            "$subdirectory payload store: $message (root=${fileSystem.baseDirectory}); " +
                "this store's data is NOT persisted this launch, further failures are not logged",
        )
    }
}

internal object ApplePayloadFileSystem : PayloadFileSystem {
    override val baseDirectory: String?
        get() = payloadStoreBaseDirectory()

    override val legacyBaseDirectories: List<String>
        get() = payloadStoreLegacyBaseDirectories()

    override fun createDirectory(path: String): String? = memScoped {
        val error = alloc<ObjCObjectVar<NSError?>>()
        val created = NSFileManager.defaultManager.createDirectoryAtPath(
            path,
            withIntermediateDirectories = true,
            attributes = null,
            error = error.ptr,
        )
        if (created) null else describe(error.value)
    }

    override fun read(path: String): String? =
        NSString.stringWithContentsOfFile(path, encoding = NSUTF8StringEncoding, error = null)

    override fun write(path: String, payload: String): String? = memScoped {
        val error = alloc<ObjCObjectVar<NSError?>>()
        val written = NSString.create(string = payload).writeToFile(
            path,
            atomically = true,
            encoding = NSUTF8StringEncoding,
            error = error.ptr,
        )
        if (written) null else describe(error.value)
    }

    override fun remove(path: String) {
        NSFileManager.defaultManager.removeItemAtPath(path, error = null)
    }

    private fun describe(error: NSError?): String =
        error?.let { "${it.domain} ${it.code} ${it.localizedDescription}" } ?: "unknown error"
}

internal object StandardLegacyDefaults : LegacyDefaults {
    override fun get(key: String): String? = NSUserDefaults.standardUserDefaults.stringForKey(key)
    override fun remove(key: String) = NSUserDefaults.standardUserDefaults.removeObjectForKey(key)
}
