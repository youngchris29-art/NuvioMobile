package com.nuvio.app.core.bootstrap

import com.nuvio.app.core.profile.ActiveProfileIdProvider
import com.nuvio.app.core.profile.ActiveProfileProvider
import com.nuvio.app.features.addons.AddonProfileContext
import com.nuvio.app.features.addons.AddonProfileProvider
import com.nuvio.app.features.addons.AddonRepository
import com.nuvio.app.features.home.HomeRepository
import com.nuvio.app.features.library.LibraryRepository
import com.nuvio.app.features.profiles.ProfileLifecycleCoordinator
import com.nuvio.app.features.profiles.ProfileLifecycleProvider
import com.nuvio.app.features.profiles.ProfileRepository
import com.nuvio.app.features.search.SearchHistoryRepository
import com.nuvio.app.features.watched.WatchedRepository
import com.nuvio.app.features.watchprogress.ContinueWatchingEnrichmentCache
import com.nuvio.app.features.watchprogress.WatchProgressRepository

/**
 * tvOS-side install block for the shared provider seams.
 *
 * The phone app wires these seams in `composeApp`'s `App()` (see the `.install()` / `.provider =`
 * block there), which the tvOS target never runs — so without this call every seam falls back to
 * its default (single primary profile, id 1) and nothing the user does is profile-scoped or
 * persisted per profile. Calling [installTvOsSharedProviders] once at NuvioTV startup backs the
 * profile seams with the real (already-migrated) [ProfileRepository], so any storage keyed through
 * `core.storage.ProfileScopedKey` follows the active profile. This is the foundation the later
 * tvOS feature areas build on: Profiles, Library/Collections, Settings persistence, and Trakt.
 *
 * Scope note — only seams whose backing lives in `:shared` are wired here:
 *  - [ActiveProfileProvider] and [AddonProfileProvider] → real [ProfileRepository]  ✅ wired below.
 *  - `core.i18n` StringProvider → left null; the shared helpers already return English fallbacks,
 *    which is correct for tvOS until localization is ported.
 *  - `core.build.FeaturePolicyProvider` → already defaults to `DefaultFeaturePolicy` (the tvOS
 *    baseline), so no install is needed.
 *  - `core.account.AccountDataCleanerProvider` → left no-op: its real backing
 *    (`LocalAccountDataCleaner`) is a composeApp god-object not reachable from `:shared`. It only
 *    matters for full account sign-out wipes, which tvOS doesn't offer yet.
 *  - The remaining Compose-coupled seams (Toast, Theme/NativeTab, Downloads, Notifications,
 *    PluginSync, external-subtitle cache, cloud-poster, etc.) stay on their defaults until their
 *    features land on tvOS.
 *
 * Idempotent; safe to call more than once.
 */
fun installTvOsSharedProviders() {
    // Active profile id → real ProfileRepository. `core.storage.ProfileScopedKey` reads this, so
    // persisted per-profile data (watch progress, library, collections, settings) is keyed to the
    // active profile instead of the hard-coded default id 1.
    ActiveProfileProvider.provider = ActiveProfileIdProvider { ProfileRepository.activeProfileId }

    // Addon profile context → real ProfileRepository, so installed add-on sets can be
    // profile-scoped (mirrors composeApp's ProfileRepositoryAddonProfileContext).
    AddonProfileProvider.context = TvOsAddonProfileContext

    // Fan out profile switches to the per-profile repositories tvOS uses. The phone app does this
    // via composeApp's ProfileLifecycleCoordinatorAdapter (~24 repos); tvOS only needs the ones it
    // actually reads. Without this, switching profiles leaves stale data (continue watching,
    // library, addons) from the previous profile on screen.
    ProfileLifecycleProvider.coordinator = TvOsProfileLifecycleCoordinator

    // Restore any previously-persisted profiles + active selection from NSUserDefaults before the
    // repositories read the active profile id. No-op on a fresh install (no stored payload yet);
    // wrapped defensively so a malformed cache can never crash startup.
    runCatching { ProfileRepository.loadCachedProfiles() }
}

/**
 * tvOS fan-out for profile-lifecycle events. `ProfileRepository.selectProfile()` calls
 * [onProfileSelected]; each target repository reloads its data for the new profile (mirrors the
 * subset of composeApp's adapter that applies to the screens tvOS ships today).
 */
private object TvOsProfileLifecycleCoordinator : ProfileLifecycleCoordinator {
    override fun onProfileSelected(profileIndex: Int) {
        WatchedRepository.onProfileChanged(profileIndex)
        LibraryRepository.onProfileChanged(profileIndex)
        WatchProgressRepository.onProfileChanged(profileIndex)
        ContinueWatchingEnrichmentCache.onProfileChanged()
        AddonRepository.onProfileChanged(profileIndex)
        SearchHistoryRepository.onProfileChanged()
        HomeRepository.clear()
    }

    override fun onProfilesCached() {}
}

/**
 * [AddonProfileContext] backed by the shared [ProfileRepository]. Kept private to this file and
 * given a tvOS-specific name so it does not collide with composeApp's
 * `ProfileRepositoryAddonProfileContext` (same seam, different module) when both are present in the
 * iOS framework build.
 */
private object TvOsAddonProfileContext : AddonProfileContext {
    override val activeProfileId: Int
        get() = ProfileRepository.activeProfileId

    override val activeProfileIndex: Int?
        get() = ProfileRepository.state.value.activeProfile?.profileIndex

    override val usesPrimaryAddons: Boolean
        get() = ProfileRepository.state.value.activeProfile?.usesPrimaryAddons == true
}
