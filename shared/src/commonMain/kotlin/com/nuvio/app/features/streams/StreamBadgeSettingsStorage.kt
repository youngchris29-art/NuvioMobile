package com.nuvio.app.features.streams

import kotlinx.serialization.json.JsonObject

expect object StreamBadgeSettingsStorage {
    fun loadStreamBadgeRules(): String?
    fun saveStreamBadgeRules(rules: String)
    fun loadShowFileSizeBadges(): Boolean?
    fun saveShowFileSizeBadges(enabled: Boolean)
    fun loadShowAddonLogo(): Boolean?
    fun saveShowAddonLogo(enabled: Boolean)
    fun loadShowInPlayer(): Boolean?
    fun saveShowInPlayer(enabled: Boolean)
    fun loadPlayerBadgeSource(): String?
    fun savePlayerBadgeSource(source: String)
    fun loadStreamBackgroundMode(): String?
    fun saveStreamBackgroundMode(mode: String)
    fun loadStreamGroupingMode(): String?
    fun saveStreamGroupingMode(mode: String)
    /** Test reset: the key is profile-local, so `replaceFromSyncPayload` does not clear it. */
    fun clearStreamGroupingMode()
    fun loadStreamListOpensWith(): String?
    fun saveStreamListOpensWith(mode: String)
    /** Test reset: the key is profile-local, so `replaceFromSyncPayload` does not clear it. */
    fun clearStreamListOpensWith()
    fun loadStreamBadgePlacement(): String?
    fun saveStreamBadgePlacement(placement: String)
    fun loadLegacyDebridStreamBadgeRules(): String?
    fun clearLegacyDebridStreamBadgeRules()
    fun exportToSyncPayload(): JsonObject
    fun replaceFromSyncPayload(payload: JsonObject)
}
