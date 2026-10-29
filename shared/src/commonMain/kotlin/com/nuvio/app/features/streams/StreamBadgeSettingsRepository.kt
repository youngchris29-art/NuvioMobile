package com.nuvio.app.features.streams

import com.nuvio.app.core.i18n.localizedBadgeEnterUrl
import com.nuvio.app.core.i18n.localizedBadgeImportFailed
import com.nuvio.app.core.i18n.localizedBadgeImportLimit
import com.nuvio.app.core.i18n.localizedBadgeUrlSchemeInvalid
import com.nuvio.app.features.addons.httpGetText
import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asStateFlow
import kotlinx.serialization.ExperimentalSerializationApi
import kotlinx.serialization.Serializable
import kotlinx.serialization.SerializationException
import kotlinx.serialization.decodeFromString
import kotlinx.serialization.encodeToString
import kotlinx.serialization.json.Json

data class StreamBadgeSettingsUiState(
    val rules: StreamBadgeRules = StreamBadgeRules(),
    val showFileSizeBadges: Boolean = true,
    val showAddonLogo: Boolean = false,
    /** Show badge chips for what is playing in the player (upstream 344117e73). */
    val showInPlayer: Boolean = false,
    /** Badge pack source URL used in the player; blank = same pack as the stream list (upstream 83e528f00). */
    val playerBadgeSource: String = "",
    val badgePlacement: StreamBadgePlacement = StreamBadgePlacement.BOTTOM,
    val backgroundMode: StreamBackgroundMode = StreamBackgroundDefaults.platformDefault,
    val groupingMode: StreamGroupingMode = StreamGroupingMode.QUALITY,
    val listOpensWith: StreamListOpensWith = StreamListOpensWith.BEST_PICK,
)

enum class StreamBackgroundMode {
    Normal,
    Cinematic,
}

/** Stream picker "Group Sources By" (polish D5). Profile-local: never synced. */
enum class StreamGroupingMode {
    QUALITY,
    ADDON,
}

/** Stream picker "Source List Opens With" (Direction C D9). Profile-local: never synced. */
enum class StreamListOpensWith {
    BEST_PICK,
    FULL_LIST,
}

enum class StreamBadgePlacement {
    TOP,
    BOTTOM,
}

object StreamBadgeSettingsRepository {
    private val _uiState = MutableStateFlow(StreamBadgeSettingsUiState())
    val uiState: StateFlow<StreamBadgeSettingsUiState> = _uiState.asStateFlow()

    @OptIn(ExperimentalSerializationApi::class)
    private val json = Json {
        ignoreUnknownKeys = true
        explicitNulls = false
    }

    private var hasLoaded = false
    private var streamBadgeRules = StreamBadgeRules()
    private var showFileSizeBadges = true
    private var showAddonLogo = false
    private var showInPlayer = false
    private var playerBadgeSource = ""
    private var badgePlacement = StreamBadgePlacement.BOTTOM
    private var backgroundMode = StreamBackgroundDefaults.platformDefault
    private var groupingMode = StreamGroupingMode.QUALITY
    private var listOpensWith = StreamListOpensWith.BEST_PICK

    fun ensureLoaded() {
        if (hasLoaded) return
        loadFromDisk()
    }

    fun onProfileChanged() {
        loadFromDisk()
    }

    fun clearLocalState() {
        hasLoaded = false
        streamBadgeRules = StreamBadgeRules()
        showFileSizeBadges = true
        showAddonLogo = false
        showInPlayer = false
        playerBadgeSource = ""
        badgePlacement = StreamBadgePlacement.BOTTOM
        backgroundMode = StreamBackgroundDefaults.platformDefault
        groupingMode = StreamGroupingMode.QUALITY
        listOpensWith = StreamListOpensWith.BEST_PICK
        _uiState.value = StreamBadgeSettingsUiState()
    }

    fun snapshot(): StreamBadgeRules {
        ensureLoaded()
        return _uiState.value.rules
    }

    fun showFileSizeBadgesSnapshot(): Boolean {
        ensureLoaded()
        return _uiState.value.showFileSizeBadges
    }

    fun badgePlacementSnapshot(): StreamBadgePlacement {
        ensureLoaded()
        return _uiState.value.badgePlacement
    }

    suspend fun importStreamBadgeRulesFromUrl(url: String): StreamBadgeImportResult {
        ensureLoaded()
        val normalizedUrl = url.trim()
        if (normalizedUrl.isBlank()) {
            return StreamBadgeImportResult.Error(localizedBadgeEnterUrl())
        }
        if (!normalizedUrl.startsWith("https://", ignoreCase = true) &&
            !normalizedUrl.startsWith("http://", ignoreCase = true)
        ) {
            return StreamBadgeImportResult.Error(localizedBadgeUrlSchemeInvalid())
        }

        return try {
            val currentRules = streamBadgeRules.normalized()
            val isExistingImport = currentRules.imports.any { import ->
                import.sourceUrl.equals(normalizedUrl, ignoreCase = true)
            }
            if (!isExistingImport && currentRules.imports.size >= STREAM_BADGE_IMPORT_LIMIT) {
                return StreamBadgeImportResult.Error(localizedBadgeImportLimit(STREAM_BADGE_IMPORT_LIMIT))
            }
            val payload = httpGetText(normalizedUrl)
            val parsedImport = StreamBadgeRulesParser.parse(
                sourceUrl = normalizedUrl,
                payload = payload,
            )
            streamBadgeRules = currentRules.upsert(parsedImport, activate = true)
            publish()
            saveStreamBadgeRules()
            StreamBadgeImportResult.Success(streamBadgeRules)
        } catch (error: Exception) {
            if (error is CancellationException) throw error
            StreamBadgeImportResult.Error(error.message ?: localizedBadgeImportFailed())
        }
    }

    fun setActiveStreamBadgeRulesSource(sourceUrl: String) {
        ensureLoaded()
        val currentRules = streamBadgeRules.normalized()
        val nextRules = currentRules.setActiveSource(sourceUrl)
        if (nextRules == currentRules) return
        streamBadgeRules = nextRules
        publish()
        saveStreamBadgeRules()
    }

    fun deleteStreamBadgeRulesSource(sourceUrl: String) {
        ensureLoaded()
        val currentRules = streamBadgeRules.normalized()
        val nextRules = currentRules.removeSource(sourceUrl)
        if (nextRules == currentRules) return
        streamBadgeRules = nextRules
        publish()
        saveStreamBadgeRules()
    }

    fun setShowFileSizeBadges(enabled: Boolean) {
        ensureLoaded()
        if (showFileSizeBadges == enabled) return
        showFileSizeBadges = enabled
        publish()
        StreamBadgeSettingsStorage.saveShowFileSizeBadges(enabled)
    }

    fun setShowAddonLogo(enabled: Boolean) {
        ensureLoaded()
        if (showAddonLogo == enabled) return
        showAddonLogo = enabled
        publish()
        StreamBadgeSettingsStorage.saveShowAddonLogo(enabled)
    }

    fun setShowInPlayer(enabled: Boolean) {
        ensureLoaded()
        if (showInPlayer == enabled) return
        showInPlayer = enabled
        publish()
        StreamBadgeSettingsStorage.saveShowInPlayer(enabled)
    }

    fun setPlayerBadgeSource(source: String) {
        ensureLoaded()
        if (playerBadgeSource == source) return
        playerBadgeSource = source
        publish()
        StreamBadgeSettingsStorage.savePlayerBadgeSource(source)
    }

    fun setBadgePlacement(placement: StreamBadgePlacement) {
        ensureLoaded()
        if (badgePlacement == placement) return
        badgePlacement = placement
        publish()
        StreamBadgeSettingsStorage.saveStreamBadgePlacement(placement.name)
    }

    fun setBackgroundMode(mode: StreamBackgroundMode) {
        ensureLoaded()
        if (backgroundMode == mode) return
        backgroundMode = mode
        publish()
        StreamBadgeSettingsStorage.saveStreamBackgroundMode(mode.name.lowercase())
    }

    fun setGroupingMode(mode: StreamGroupingMode) {
        ensureLoaded()
        if (groupingMode == mode) return
        groupingMode = mode
        publish()
        StreamBadgeSettingsStorage.saveStreamGroupingMode(mode.name.lowercase())
    }

    fun setListOpensWith(mode: StreamListOpensWith) {
        ensureLoaded()
        if (listOpensWith == mode) return
        listOpensWith = mode
        publish()
        StreamBadgeSettingsStorage.saveStreamListOpensWith(mode.name.lowercase())
    }

    private fun loadFromDisk() {
        hasLoaded = true
        val storedRules = parseStreamBadgeRules(StreamBadgeSettingsStorage.loadStreamBadgeRules())
        val legacyRules = if (storedRules == null) {
            parseStreamBadgeRules(StreamBadgeSettingsStorage.loadLegacyDebridStreamBadgeRules())
        } else {
            null
        }
        streamBadgeRules = storedRules ?: legacyRules ?: StreamBadgeRules()
        showFileSizeBadges = StreamBadgeSettingsStorage.loadShowFileSizeBadges() ?: true
        showAddonLogo = StreamBadgeSettingsStorage.loadShowAddonLogo() ?: false
        showInPlayer = StreamBadgeSettingsStorage.loadShowInPlayer() ?: false
        playerBadgeSource = StreamBadgeSettingsStorage.loadPlayerBadgeSource().orEmpty()
        backgroundMode = StreamBadgeSettingsStorage.loadStreamBackgroundMode()
            ?.let { storedMode -> StreamBackgroundMode.entries.firstOrNull { it.name.equals(storedMode, ignoreCase = true) } }
            ?: StreamBackgroundDefaults.platformDefault
        groupingMode = StreamBadgeSettingsStorage.loadStreamGroupingMode()
            ?.let { stored -> StreamGroupingMode.entries.firstOrNull { it.name.equals(stored, ignoreCase = true) } }
            ?: StreamGroupingMode.QUALITY
        listOpensWith = StreamBadgeSettingsStorage.loadStreamListOpensWith()
            ?.let { stored -> StreamListOpensWith.entries.firstOrNull { it.name.equals(stored, ignoreCase = true) } }
            ?: StreamListOpensWith.BEST_PICK
        badgePlacement = StreamBadgeSettingsStorage.loadStreamBadgePlacement()
            ?.let { storedPlacement ->
                StreamBadgePlacement.entries.firstOrNull { placement ->
                    placement.name.equals(storedPlacement, ignoreCase = true)
                }
            }
            ?: StreamBadgePlacement.BOTTOM
        if (legacyRules != null) {
            saveStreamBadgeRules()
            StreamBadgeSettingsStorage.clearLegacyDebridStreamBadgeRules()
        }
        publish()
    }

    private fun publish() {
        _uiState.value = StreamBadgeSettingsUiState(
            rules = streamBadgeRules,
            showFileSizeBadges = showFileSizeBadges,
            showAddonLogo = showAddonLogo,
            showInPlayer = showInPlayer,
            playerBadgeSource = playerBadgeSource,
            badgePlacement = badgePlacement,
            backgroundMode = backgroundMode,
            groupingMode = groupingMode,
            listOpensWith = listOpensWith,
        )
    }

    private fun saveStreamBadgeRules() {
        val normalizedRules = streamBadgeRules.normalized()
        val payload = if (normalizedRules.hasImport) {
            json.encodeToString(normalizedRules)
        } else {
            ""
        }
        StreamBadgeSettingsStorage.saveStreamBadgeRules(payload)
    }

    private fun parseStreamBadgeRules(value: String?): StreamBadgeRules? {
        if (value.isNullOrBlank()) return null
        val decodedRules = try {
            json.decodeFromString<StreamBadgeRules>(value).normalized()
        } catch (_: SerializationException) {
            null
        } catch (_: IllegalArgumentException) {
            null
        }
        if (decodedRules?.hasImport == true) return decodedRules

        val legacyRules = try {
            json.decodeFromString<LegacyStreamBadgeRules>(value)
                .toBadgeRules()
                .normalized()
        } catch (_: SerializationException) {
            null
        } catch (_: IllegalArgumentException) {
            null
        }
        return legacyRules?.takeIf { it.hasImport } ?: decodedRules
    }
}

@Serializable
private data class LegacyStreamBadgeRules(
    val sourceUrl: String = "",
    val filters: List<StreamBadgeFilter> = emptyList(),
    val groups: List<StreamBadgeGroup> = emptyList(),
) {
    fun toBadgeRules(): StreamBadgeRules =
        StreamBadgeRules(
            imports = listOf(
                StreamBadgeImport(
                    sourceUrl = sourceUrl,
                    filters = filters,
                    groups = groups,
                ),
            ),
        )
}
