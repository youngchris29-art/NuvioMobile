package com.nuvio.app.features.trakt

// JVM actual for shared/src/jvmMain (beta.14 Wave 4 / :shared jvm test target, see
// docs/issue-triage-plan-2026-08-21.md §6.1). Ported from the androidMain actual in this
// same relative path: same key layout, JvmSharedPreferences swapped in for
// android.content.SharedPreferences (no Context needed on the JVM).

import com.nuvio.app.core.storage.JvmSharedPreferences
import com.nuvio.app.core.storage.jvmSharedPreferences
import com.nuvio.app.core.storage.ProfileScopedKey

actual object TraktSettingsStorage {
    private const val preferencesName = "nuvio_trakt_settings"
    private const val payloadKey = "trakt_settings_payload"
    private const val pendingWatchProgressSourceKey = "pending_watch_progress_source"

    private val preferences: JvmSharedPreferences? = jvmSharedPreferences(preferencesName)

    actual fun loadPayload(): String? =
        preferences?.getString(ProfileScopedKey.of(payloadKey), null)

    actual fun savePayload(payload: String) {
        preferences
            ?.edit()
            ?.putString(ProfileScopedKey.of(payloadKey), payload)
            ?.apply()
    }

    actual fun loadPendingWatchProgressSourcePayload(profileId: Int): String? =
        preferences?.getString(ProfileScopedKey.of(pendingWatchProgressSourceKey, profileId), null)

    actual fun savePendingWatchProgressSourcePayload(profileId: Int, payload: String) {
        preferences
            ?.edit()
            ?.putString(ProfileScopedKey.of(pendingWatchProgressSourceKey, profileId), payload)
            ?.commit()
    }

    actual fun clearPendingWatchProgressSourcePayload(profileId: Int) {
        preferences
            ?.edit()
            ?.remove(ProfileScopedKey.of(pendingWatchProgressSourceKey, profileId))
            ?.apply()
    }
}
