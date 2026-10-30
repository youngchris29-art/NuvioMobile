@file:OptIn(kotlinx.cinterop.ExperimentalForeignApi::class)

package com.nuvio.app.core.storage

import platform.Foundation.NSApplicationSupportDirectory
import platform.Foundation.NSCachesDirectory
import platform.Foundation.NSSearchPathForDirectoriesInDomains
import platform.Foundation.NSUserDomainMask

/**
 * tvOS: `Library/Caches/PayloadStores`.
 *
 * Apple's tvOS rule (App Programming Guide for tvOS, "Local Storage for Your App Is Limited"):
 * an app gets 500 KB of persistent local storage, through NSUserDefaults only; every other
 * local file must be purgeable, and the Caches directory is the location the guide names for it.
 * The payloads here are far past 500 KB in total (the watch-progress and collections payloads
 * alone were ~190 KB each per profile on the Living Room device, 2026-08-01) and a defaults
 * write of that size aborts the process (BUG-11), so Caches is the only location the rules
 * allow. The master copy of every store is the Nuvio sync backend or the tracker that produced
 * it; a purge costs a re-pull, never the data.
 *
 * Until 2026-10-30 the tvOS stores targeted Application Support, like iOS. On a real Apple TV
 * (Living Room, tvOS 27.2) that directory does not exist in the container and
 * `createDirectoryAtPath` under it fails with NSCocoaErrorDomain 513 ("You don’t have permission
 * to save the file … in the folder “Application Support”"); creating anything under Documents
 * fails the same way, while Caches accepts the write. Every save failed, silently, so nothing
 * was ever persisted locally on the box and a cold relaunch lost every position the sync push
 * had not carried yet. The tvOS simulator allows the directory, which is why the simulator
 * never showed it. Application Support stays listed as a legacy root so a simulator's existing
 * files move over on first read.
 */
internal actual fun payloadStoreBaseDirectory(): String? =
    (NSSearchPathForDirectoriesInDomains(NSCachesDirectory, NSUserDomainMask, true).firstOrNull() as? String)
        ?.let { "$it/PayloadStores" }

internal actual fun payloadStoreLegacyBaseDirectories(): List<String> =
    listOfNotNull(
        NSSearchPathForDirectoriesInDomains(NSApplicationSupportDirectory, NSUserDomainMask, true)
            .firstOrNull() as? String,
    )
