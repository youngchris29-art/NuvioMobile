package com.nuvio.app.core.storage

/**
 * Sign-out deletion entry point for every file-backed payload store ([PayloadFileStore]
 * subdirectories). Both account cleaners — tvOS (TvOsAccountDataCleaner in
 * TvOsProviderInstaller.kt) and iOS (composeApp's PlatformLocalAccountDataCleaner.ios) — must
 * go through this list so neither platform's wipe can drift when a store is added.
 */
object AppleFilePayloadStores {
    fun deleteAll() {
        com.nuvio.app.features.plugins.PluginStateFiles.deleteAll()
        com.nuvio.app.features.trakt.TraktLibraryStorage.deleteAll()
        com.nuvio.app.features.collection.CollectionStorage.deleteAll()
        com.nuvio.app.features.watchprogress.WatchProgressStorage.deleteAll()
        com.nuvio.app.features.watchprogress.ContinueWatchingEnrichmentStorage.deleteAll()
        com.nuvio.app.features.library.LibraryStorage.deleteAll()
        com.nuvio.app.features.watched.WatchedStorage.deleteAll()
        com.nuvio.app.features.streams.StreamLinkCacheStorage.deleteAll()
        com.nuvio.app.features.simkl.SimklSyncStorage.deleteAll()
    }
}
