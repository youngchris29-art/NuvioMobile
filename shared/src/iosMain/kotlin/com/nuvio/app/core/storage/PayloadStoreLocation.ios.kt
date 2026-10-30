@file:OptIn(kotlinx.cinterop.ExperimentalForeignApi::class)

package com.nuvio.app.core.storage

import platform.Foundation.NSApplicationSupportDirectory
import platform.Foundation.NSSearchPathForDirectoriesInDomains
import platform.Foundation.NSUserDomainMask

/**
 * iOS: `Library/Application Support`, the directory Apple names for support files the user never
 * sees. It is persistent, backed up, and never purged, which is what the composeApp iOS build
 * has used since the stores moved out of NSUserDefaults.
 */
internal actual fun payloadStoreBaseDirectory(): String? =
    NSSearchPathForDirectoriesInDomains(NSApplicationSupportDirectory, NSUserDomainMask, true)
        .firstOrNull() as? String

internal actual fun payloadStoreLegacyBaseDirectories(): List<String> = emptyList()
