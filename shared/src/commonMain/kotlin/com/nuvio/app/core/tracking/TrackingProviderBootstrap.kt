package com.nuvio.app.core.tracking

import com.nuvio.app.features.tracking.TrackingProviderRegistry
import com.nuvio.app.features.trakt.TraktAuthRepository
import com.nuvio.app.features.trakt.TraktScrobbleRepository
import com.nuvio.app.features.trakt.TraktTrackingLibraryProvider
import com.nuvio.app.features.trakt.TraktTrackingProgressProvider
import com.nuvio.app.features.watching.sync.TraktWatchedSyncAdapter

/**
 * Registers every tracking provider this build ships into [TrackingProviderRegistry].
 *
 * Idempotent: the registry stores by provider id and the `object` touches below only force the
 * Kotlin object initializers (which self-register auth/scrobble ports) to run once.
 *
 * Phase 1 scope: **Trakt only**. Upstream's version also registers the Simkl auth/sync/library/
 * progress/mutation ports; every one of those lines is intentionally omitted until the Simkl
 * feature package is ported (Phase 2) and registered (Phase 3).
 */
fun ensureTrackingProvidersRegistered() {
    TraktAuthRepository.descriptor
    TraktScrobbleRepository.ensureRegistered()
    TrackingProviderRegistry.registerLibraryProvider(TraktTrackingLibraryProvider)
    TrackingProviderRegistry.registerWatchedProvider(TraktWatchedSyncAdapter)
    TrackingProviderRegistry.registerProgressProvider(TraktTrackingProgressProvider)
}
