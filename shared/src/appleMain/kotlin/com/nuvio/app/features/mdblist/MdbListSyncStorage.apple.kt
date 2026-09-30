package com.nuvio.app.features.mdblist

import com.nuvio.app.core.storage.PayloadFileStore
import com.nuvio.app.core.storage.ProfileScopedKey

/**
 * Fork deviation from upstream 53c441c0 (iosMain `MdbListSyncStorage.ios.kt`, a separate
 * `nuvio_mdblist_sync` NSUserDefaults suite keyed `profile.<id>`).
 *
 * The MDBList sync snapshot holds the account's whole watched history, playback list and dropped
 * set in one string — the same unbounded-payload class as the Simkl snapshot, so it goes to a
 * file ([PayloadFileStore], see `SimklSyncStorage.apple.kt`), never to a defaults plist where a
 * large history can cross the CFPreferences oversized-write cap. Filenames are
 * `mdblist_sync_snapshot_<profileId>.json` under Application Support/`MdbListSync`, which the
 * sign-out wipe erases via the `AppleKeySpec.FileStore("MdbListSync")` entry in
 * `core.account.AccountDataStores` (`AppleFilePayloadStores.deleteAll`).
 *
 * The repository passes an explicit profile id, so keys use `ProfileScopedKey.of(base, profileId)`
 * rather than the active-profile overload.
 */
internal actual object PlatformMdbListSyncStorage : MdbListSyncStorage {
    private const val subdirectory = "MdbListSync"
    private const val payloadKey = "mdblist_sync_snapshot"

    private fun key(profileId: Int) = ProfileScopedKey.of(payloadKey, profileId)

    actual override suspend fun load(profileId: Int): String? =
        PayloadFileStore.load(subdirectory, key(profileId))

    actual override suspend fun save(profileId: Int, payload: String, checkScope: () -> Unit) {
        checkScope()
        check(PayloadFileStore.save(subdirectory, key(profileId), payload)) { "Unable to save MDBList cache" }
    }

    actual override suspend fun remove(profileId: Int, checkScope: () -> Unit) {
        checkScope()
        PayloadFileStore.remove(subdirectory, key(profileId))
    }

    actual fun clearAll() = PayloadFileStore.deleteAll(subdirectory)
}
