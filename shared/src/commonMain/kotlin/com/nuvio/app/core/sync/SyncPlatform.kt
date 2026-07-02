package com.nuvio.app.core.sync

import kotlin.concurrent.Volatile

const val MOBILE_SYNC_PLATFORM = "mobile"
const val TV_SYNC_PLATFORM = "tv"
internal const val HOME_CATALOG_SHARED_SYNC_PLATFORM = "home_catalog_shared"
internal val HOME_CATALOG_LEGACY_SYNC_PLATFORMS = listOf(MOBILE_SYNC_PLATFORM, TV_SYNC_PLATFORM)

/**
 * Which `p_platform` value this client sends on the platform-scoped settings-blob RPCs
 * (`sync_pull_profile_settings_blob` / `sync_push_profile_settings_blob`). The Nuvio Cloud API
 * (docs/nuvio-cloud-api-reference.md §Profile Settings) scopes those blobs per platform, so the
 * phone and the TV keep separate settings server-side.
 *
 * Default is [MOBILE_SYNC_PLATFORM] (composeApp needs no install). The tvOS target sets
 * [TV_SYNC_PLATFORM] in `installTvOsSharedProviders()`. Mirrors the StringProvider /
 * FeaturePolicyProvider injection pattern.
 */
object SyncPlatformProvider {
    @Volatile
    var platform: String = MOBILE_SYNC_PLATFORM
}
