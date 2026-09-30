package com.nuvio.app.features.mdblist

import android.content.Context

/**
 * Fork: public Android startup hook for the MDBList persistence actuals, which are `internal` to
 * :shared and so cannot be initialised from composeApp's `MainActivity` directly (upstream calls
 * `PlatformMdbListAuthPersistence.initialize` / `PlatformMdbListSyncStorage.initialize` from its
 * single-module MainActivity). `MdbListTracker.register()` runs on Android through
 * `ensureTrackingProvidersRegistered()`, so both must be initialised before the first write.
 */
object MdbListAndroidStorage {
    fun initialize(context: Context) {
        PlatformMdbListAuthPersistence.initialize(context)
        PlatformMdbListSyncStorage.initialize(context)
    }
}
