package com.nuvio.app.core.bootstrap

import com.nuvio.app.core.account.AccountDataCleanerProvider
import com.nuvio.app.core.profile.ActiveProfileIdProvider
import com.nuvio.app.core.profile.ActiveProfileProvider
import com.nuvio.app.core.sync.ProfileSettingsSync
import com.nuvio.app.core.sync.SyncPlatformProvider
import com.nuvio.app.core.sync.TV_SYNC_PLATFORM
import com.nuvio.app.core.ui.CardDepthStyleRepository
import com.nuvio.app.core.ui.PosterCardStyleRepository
import com.nuvio.app.features.addons.AddonProfileContext
import com.nuvio.app.features.addons.AddonProfileProvider
import com.nuvio.app.features.addons.AddonRepository
import com.nuvio.app.features.catalog.CatalogRepository
import com.nuvio.app.features.collection.CollectionMobileSettingsRepository
import com.nuvio.app.features.collection.CollectionRepository
import com.nuvio.app.features.debrid.DebridSettingsRepository
import com.nuvio.app.features.details.MetaDetailsRepository
import com.nuvio.app.features.details.MetaScreenSettingsRepository
import com.nuvio.app.features.home.HomeCatalogSettingsRepository
import com.nuvio.app.features.home.HomeRepository
import com.nuvio.app.features.library.LibraryDisplaySettingsRepository
import com.nuvio.app.features.library.LibraryRepository
import com.nuvio.app.features.notifications.EpisodeReleaseNotificationsRepository
import com.nuvio.app.features.player.PlayerLaunchStore
import com.nuvio.app.features.player.PlayerSettingsRepository
import com.nuvio.app.features.player.SubtitleRepository
import com.nuvio.app.features.profiles.MAX_PROFILES
import com.nuvio.app.features.profiles.ProfileLifecycleCoordinator
import com.nuvio.app.features.profiles.ProfileLifecycleProvider
import com.nuvio.app.features.profiles.ProfileRepository
import com.nuvio.app.features.search.SearchHistoryRepository
import com.nuvio.app.features.search.SearchRepository
import com.nuvio.app.features.settings.ThemeSettingsRepository
import com.nuvio.app.features.settings.ThemeSettingsStoreProvider
import com.nuvio.app.features.settings.TvOsThemeSettingsStore
import com.nuvio.app.features.streams.StreamBadgeSettingsRepository
import com.nuvio.app.features.streams.StreamContextStore
import com.nuvio.app.features.streams.StreamLaunchStore
import com.nuvio.app.features.streams.StreamsRepository
import com.nuvio.app.features.trakt.TraktAuthRepository
import com.nuvio.app.features.trakt.TraktSettingsRepository
import com.nuvio.app.features.watched.WatchedRepository
import com.nuvio.app.features.watchprogress.ContinueWatchingEnrichmentCache
import com.nuvio.app.features.watchprogress.ContinueWatchingPreferencesRepository
import com.nuvio.app.features.watchprogress.WatchProgressRepository
import com.nuvio.app.core.auth.AuthRepository
import com.nuvio.app.core.auth.AuthState
import com.nuvio.app.core.sync.RealtimeSyncConfig
import com.nuvio.app.core.sync.RealtimeSyncInvalidationService
import com.nuvio.app.core.coroutines.uncaughtCoroutineLogger
import co.touchlab.kermit.Logger
import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.flow.combine
import kotlinx.coroutines.flow.distinctUntilChanged
import kotlinx.coroutines.launch
import platform.Foundation.NSUserDefaults

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

    // Platform-scoped settings sync: the Nuvio Cloud API keeps a separate settings blob per
    // platform (p_platform), so tvOS must identify as "tv" — otherwise it would read/overwrite the
    // phone's blob (the shared default is "mobile").
    SyncPlatformProvider.platform = TV_SYNC_PLATFORM

    // Theme persistence: the shared default ThemeSettingsStore is a no-op (theme would reset every
    // launch). The tvOS adapter persists to NSUserDefaults (profile-scoped keys) and defaults to
    // CRIMSON — the app's launch look. Installed before any ThemeSettingsRepository.ensureLoaded().
    ThemeSettingsStoreProvider.store = TvOsThemeSettingsStore

    // Account-data cleaner: AuthRepository.signOut()/session-invalidation call this seam to wipe
    // local state. The default is a no-op, which on tvOS would let guest-mode data (keyed by
    // profile id, NOT user id) bleed into a signed-in account — and then sync UP to the cloud.
    // Mirrors composeApp's LocalAccountDataCleaner minus the flavor-bound/composeApp-only repos
    // (PluginRepository, P2pSettingsRepository) that tvOS doesn't ship.
    AccountDataCleanerProvider.cleaner = TvOsAccountDataCleaner

    // Load the sync-backend selection (defaults to the hosted backend from SupabaseConfig).
    // AuthRepository.initialize()'s collector waits for this `isLoaded` flag — without it the auth
    // state never leaves Loading. composeApp does this at App() startup; tvOS must too.

    // Push settings changes to the per-platform ("tv") cloud blob — debrid/TMDB/MDBList keys,
    // subtitle style, poster style, theme, etc. composeApp starts this in App(); without it every
    // tvOS-set key stays local-only, so the sign-out wipe loses them and the next sign-in's pull
    // REPLACES local settings with the (empty) server blob. With it, sign-in restores everything.
    ProfileSettingsSync.startObserving()

    // Restore any previously-persisted profiles + active selection from NSUserDefaults before the
    // repositories read the active profile id. No-op on a fresh install (no stored payload yet);
    // wrapped defensively so a malformed cache can never crash startup.
    runCatching { ProfileRepository.loadCachedProfiles() }

    // Live sync invalidation: subscribe to the account's Supabase realtime channel so changes made
    // on other devices (library, watched, addons, profile settings…) pull within seconds instead
    // of waiting for the next launch/foreground sync. Mirrors composeApp App()'s
    // LaunchedEffect(authState, activeProfile) start/stop logic.
    startRealtimeInvalidationObserver()
}

private val realtimeObserverScope =
    CoroutineScope(SupervisorJob() + Dispatchers.Default + uncaughtCoroutineLogger("TvOsRealtimeObserver"))
private var realtimeObserverStarted = false

private fun startRealtimeInvalidationObserver() {
    if (realtimeObserverStarted) return
    realtimeObserverStarted = true
    realtimeObserverScope.launch {
        combine(AuthRepository.state, ProfileRepository.state) { auth, profiles ->
            (auth as? AuthState.Authenticated) to profiles.activeProfile?.profileIndex
        }
            .distinctUntilChanged()
            .collect { (authenticated, profileIndex) ->
                if (
                    !RealtimeSyncConfig.ENABLED ||
                    authenticated == null ||
                    authenticated.isAnonymous ||
                    profileIndex == null
                ) {
                    RealtimeSyncInvalidationService.stop()
                } else {
                    RealtimeSyncInvalidationService.start(
                        userId = authenticated.userId,
                        profileId = profileIndex,
                    )
                }
            }
    }
}

/**
 * tvOS account-data wipe (guest→account transitions and sign-out). Two layers, mirroring
 * composeApp's `LocalAccountDataCleaner`:
 *  1. In-memory/repo state via each shared repository's `clearLocalState()`/`clear()`/`reset()`.
 *  2. NSUserDefaults keys for ALL profile slots (repo-level clears only touch the active profile's
 *     `ProfileScopedKey`s) — same key list as composeApp's `PlatformLocalAccountDataCleaner.ios`,
 *     but iterating 1..MAX_PROFILES (6) instead of its legacy 1..4.
 */
private object TvOsAccountDataCleaner : com.nuvio.app.core.account.AccountDataCleaner {
    private val plainKeys = listOf(
        "profile_payload",
        "avatar_catalog_payload",
    )
    private val profileIndexedPrefixes = listOf(
        "installed_manifest_urls_",
        "plugins_state_",
        "library_payload_",
        "watched_payload_",
        "watch_progress_payload_",
        "profile_pin_cache_",
    )
    private val profileScopedBaseKeys = listOf(
        "catalog_settings_payload",
        "library_display_settings_payload",
        "continue_watching_preferences_payload",
        "poster_card_style_payload",
        "episode_release_notifications_payload",
        "episode_release_notification_scheduled_ids",
        "selected_theme",
        "amoled_enabled",
        "show_loading_overlay",
        "preferred_audio_language",
        "secondary_preferred_audio_language",
        "preferred_subtitle_language",
        "secondary_preferred_subtitle_language",
        "subtitle_text_color",
        "subtitle_outline_enabled",
        "subtitle_font_size_sp",
        "subtitle_bottom_offset",
        "stream_reuse_last_link_enabled",
        "stream_reuse_last_link_cache_hours",
        "stream_badge_rules",
        "show_file_size_badges",
        "stream_badge_placement",
        "debrid_stream_badge_rules",
        "p2p_enabled",
        "enable_upload",
        "hide_torrent_stats",
        "mdblist_enabled",
        "mdblist_api_key",
        "mdblist_use_imdb",
        "mdblist_use_tmdb",
        "mdblist_use_tomatoes",
        "mdblist_use_metacritic",
        "mdblist_use_trakt",
        "mdblist_use_letterboxd",
        "mdblist_use_audience",
        "trakt_auth_payload",
        "trakt_library_payload",
        "trakt_settings_payload",
        "collection_mobile_settings_payload",
        "collections_payload",
    )

    override fun wipe() {
        // 0) tvOS-only extras installed from tvosMain (plugins today).
        TvOsExtraLifecycleHooks.onClearLocalState()

        // 1) Repo/in-memory state (active profile scope).
        ProfileRepository.clearInMemory()
        AddonRepository.clearLocalState()
        HomeRepository.clear()
        HomeCatalogSettingsRepository.clearLocalState()
        MetaScreenSettingsRepository.clearLocalState()
        LibraryRepository.clearLocalState()
        LibraryDisplaySettingsRepository.clearLocalState()
        WatchProgressRepository.clearLocalState()
        WatchedRepository.clearLocalState()
        ContinueWatchingPreferencesRepository.clearLocalState()
        EpisodeReleaseNotificationsRepository.clearLocalState()
        CollectionMobileSettingsRepository.clearLocalState()
        CollectionRepository.clearLocalState()
        ThemeSettingsRepository.clearLocalState()
        PosterCardStyleRepository.clearLocalState()
        CardDepthStyleRepository.clearLocalState()
        TraktAuthRepository.clearLocalState()
        TraktSettingsRepository.clearLocalState()
        PlayerSettingsRepository.clearLocalState()
        StreamBadgeSettingsRepository.clearLocalState()
        CatalogRepository.clear()
        StreamsRepository.clear()
        MetaDetailsRepository.clear()
        SearchRepository.reset()
        SubtitleRepository.clear()
        PlayerLaunchStore.clear()
        StreamLaunchStore.clear()
        StreamContextStore.clear()

        // 2) Persisted keys for every profile slot.
        val defaults = NSUserDefaults.standardUserDefaults

        plainKeys.forEach(defaults::removeObjectForKey)

        (1..MAX_PROFILES).forEach { profileId ->
            profileIndexedPrefixes.forEach { prefix ->
                defaults.removeObjectForKey("$prefix$profileId")
            }
            profileScopedBaseKeys.forEach { baseKey ->
                defaults.removeObjectForKey("${baseKey}_$profileId")
            }
        }

        for (key in defaults.dictionaryRepresentation().keys) {
            val keyString = key as? String ?: continue
            if (keyString.startsWith("stream_link_")) {
                defaults.removeObjectForKey(keyString)
            }
            // Plugin state + per-scraper settings (scraper ids embed the manifest URL, so the
            // settings keys look like "settings_https://…" — safe to match on that prefix).
            if (keyString.startsWith("plugins_state_") || keyString.startsWith("settings_http")) {
                defaults.removeObjectForKey(keyString)
            }
        }
    }
}

/**
 * tvOS fan-out for profile-lifecycle events. `ProfileRepository.selectProfile()` calls
 * [onProfileSelected]; each target repository reloads its data for the new profile (mirrors the
 * subset of composeApp's adapter that applies to the screens tvOS ships today).
 */
/**
 * Extension points for tvOS-only source sets. appleMain compiles for iOS too (where these hooks
 * stay as no-ops), so appleMain code can't reference tvosMain classes directly — tvosMain
 * installers (e.g. `installTvOsPlugins()`) assign these instead, and the cleaner/coordinator
 * below invoke them alongside the statically-known repos.
 */
object TvOsExtraLifecycleHooks {
    @kotlin.concurrent.Volatile
    var onProfileChanged: (Int) -> Unit = {}

    @kotlin.concurrent.Volatile
    var onClearLocalState: () -> Unit = {}
}

private object TvOsProfileLifecycleCoordinator : ProfileLifecycleCoordinator {
    private val log = Logger.withTag("TvOsProfileLifecycle")

    /**
     * Runs one fan-out step so a throw degrades that repository instead of killing the app.
     *
     * This whole fan-out runs on the CALLER'S thread, which for a profile tap is the Swift main
     * thread (`ProfilesViewModel.select` → `ProfileRepository.selectProfile`). A Kotlin exception
     * escaping into Swift there is not catchable on the Swift side — it reaches the Kotlin/Native
     * unhandled-exception hook and aborts the process. Because the fan-out is the same every time,
     * any one throwing repository turns into "the app force-closes every time I pick my profile"
     * (beta.1 tester report, and again after beta.3's QR sign-in put far more testers on the
     * signed-in path where the profile-scoped stores actually have content to load).
     *
     * The step name is logged before the call so a crash report or console log names the culprit
     * even if a step fails in a way this cannot contain.
     */
    private inline fun step(name: String, block: () -> Unit) {
        try {
            block()
        } catch (error: CancellationException) {
            throw error
        } catch (error: Throwable) {
            log.e(error) { "Profile-select step '$name' failed; continuing with the remaining steps" }
        }
    }

    override fun onProfileSelected(profileIndex: Int) {
        log.i { "Profile selected: $profileIndex — running fan-out" }
        step("tvOsExtras") { TvOsExtraLifecycleHooks.onProfileChanged(profileIndex) }
        step("watched") { WatchedRepository.onProfileChanged(profileIndex) }
        step("library") { LibraryRepository.onProfileChanged(profileIndex) }
        step("libraryDisplaySettings") { LibraryDisplaySettingsRepository.onProfileChanged() }
        step("watchProgress") { WatchProgressRepository.onProfileChanged(profileIndex) }
        step("continueWatchingEnrichment") { ContinueWatchingEnrichmentCache.onProfileChanged() }
        step("addons") { AddonRepository.onProfileChanged(profileIndex) }
        step("searchHistory") { SearchHistoryRepository.onProfileChanged() }
        // Theme is profile-scoped (ProfileScopedKey) — reload it for the new profile.
        step("theme") { ThemeSettingsRepository.onProfileChanged() }
        // Card-depth poster styling is profile-scoped too; reload so a local (guest) profile switch
        // doesn't leave the previous profile's setting live on the tvOS card surfaces.
        step("cardDepthStyle") { CardDepthStyleRepository.onProfileChanged() }
        // Debrid keys/settings are profile-scoped too; without this a guest profile switch
        // (no cloud pull) would keep the previous profile's keys in memory.
        step("debridSettings") { DebridSettingsRepository.onProfileChanged() }
        step("home") { HomeRepository.clear() }
        log.i { "Profile-select fan-out complete for profile $profileIndex" }
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
