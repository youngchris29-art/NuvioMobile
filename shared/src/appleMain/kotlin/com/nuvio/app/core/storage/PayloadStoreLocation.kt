package com.nuvio.app.core.storage

/**
 * Root directory the [PayloadFileStore] subdirectories live under, or null when the platform
 * cannot resolve one. Per platform because Apple's storage rules differ: see
 * `PayloadStoreLocation.ios.kt` and `PayloadStoreLocation.tvos.kt`.
 */
internal expect fun payloadStoreBaseDirectory(): String?

/**
 * Roots earlier builds wrote under. [PayloadFiles.load] moves a file found there to
 * [payloadStoreBaseDirectory] on first read, and the wipe/remove paths clear them as well.
 */
internal expect fun payloadStoreLegacyBaseDirectories(): List<String>
