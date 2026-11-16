package com.nuvio.app.features.watchprogress

import kotlinx.atomicfu.locks.SynchronizedObject
import kotlinx.atomicfu.locks.synchronized
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asStateFlow
import kotlinx.coroutines.flow.getAndUpdate
import kotlinx.coroutines.flow.update
import kotlinx.serialization.SerialName
import kotlinx.serialization.Serializable
import kotlinx.serialization.decodeFromString
import kotlinx.serialization.encodeToString
import kotlinx.serialization.json.Json

@Serializable
private data class StoredContinueWatchingPreferences(
    val isVisible: Boolean = true,
    val style: ContinueWatchingSectionStyle = ContinueWatchingSectionStyle.Card,
    val upNextFromFurthestEpisode: Boolean = true,
    @SerialName("use_episode_thumbnails_in_cw")
    val useEpisodeThumbnails: Boolean = true,
    @SerialName("show_unaired_next_up")
    val showUnairedNextUp: Boolean = true,
    @SerialName("blur_continue_watching_next_up")
    val blurNextUp: Boolean = false,
    val dismissedNextUpKeys: Set<String> = emptySet(),
    val showResumePromptOnLaunch: Boolean = true,
    @SerialName("sort_mode")
    val sortMode: ContinueWatchingSortMode = ContinueWatchingSortMode.DEFAULT,
    @SerialName("click_action")
    val clickAction: ContinueWatchingClickAction = ContinueWatchingClickAction.STREAM,
)

object ContinueWatchingPreferencesRepository {
    private val json = Json {
        ignoreUnknownKeys = true
        encodeDefaults = true
        // A value a newer phone build adds to an enum field reads as that field's default instead
        // of failing the whole decode (which would reset every preference, dismissed keys included).
        coerceInputValues = true
    }

    private val _uiState = MutableStateFlow(ContinueWatchingPreferencesUiState())
    val uiState: StateFlow<ContinueWatchingPreferencesUiState> = _uiState.asStateFlow()

    // Fork (batch D review r1 F4): mutators run off the main thread too (`WatchingActions`
    // marks a series watched on `Dispatchers.Default` and restores its dismissed Next Up keys from
    // there), so every state write is an atomic `update` and the loaded flag sits under the same
    // `SynchronizedObject` lock the fork's other repositories use.
    private val loadLock = SynchronizedObject()
    private var hasLoaded = false

    fun ensureLoaded() {
        synchronized(loadLock) {
            if (hasLoaded) return
            loadFromDisk()
        }
    }

    fun onProfileChanged() {
        synchronized(loadLock) { loadFromDisk() }
    }

    fun clearLocalState() {
        synchronized(loadLock) {
            hasLoaded = false
            _uiState.value = ContinueWatchingPreferencesUiState()
        }
    }

    internal fun applyFromSync(
        isVisible: Boolean,
        style: ContinueWatchingSectionStyle,
        upNextFromFurthestEpisode: Boolean,
        useEpisodeThumbnails: Boolean = true,
        showUnairedNextUp: Boolean = true,
        blurNextUp: Boolean = false,
        dismissedNextUpKeys: Set<String>,
    ) {
        ensureLoaded()
        val normalizedKeys = dismissedNextUpKeys
            .map(String::trim)
            .filter(String::isNotBlank)
            .toSet()
        _uiState.update { state ->
            state.copy(
                isVisible = isVisible,
                style = style,
                upNextFromFurthestEpisode = upNextFromFurthestEpisode,
                useEpisodeThumbnails = useEpisodeThumbnails,
                showUnairedNextUp = showUnairedNextUp,
                blurNextUp = blurNextUp,
                dismissedNextUpKeys = normalizedKeys,
            )
        }
        persist()
    }

    private fun loadFromDisk() {
        hasLoaded = true

        val payload = ContinueWatchingPreferencesStorage.loadPayload().orEmpty().trim()
        if (payload.isEmpty()) {
            _uiState.value = ContinueWatchingPreferencesUiState()
            return
        }

        val stored = runCatching {
            json.decodeFromString<StoredContinueWatchingPreferences>(payload)
        }.getOrNull()

        _uiState.value = if (stored != null) {
            ContinueWatchingPreferencesUiState(
                isVisible = stored.isVisible,
                style = stored.style,
                upNextFromFurthestEpisode = stored.upNextFromFurthestEpisode,
                useEpisodeThumbnails = stored.useEpisodeThumbnails,
                showUnairedNextUp = stored.showUnairedNextUp,
                blurNextUp = stored.blurNextUp,
                dismissedNextUpKeys = stored.dismissedNextUpKeys,
                showResumePromptOnLaunch = stored.showResumePromptOnLaunch,
                sortMode = stored.sortMode,
                clickAction = stored.clickAction,
            )
        } else {
            ContinueWatchingPreferencesUiState()
        }
    }

    fun setVisible(isVisible: Boolean) {
        ensureLoaded()
        _uiState.update { state -> state.copy(isVisible = isVisible) }
        persist()
    }

    fun setStyle(style: ContinueWatchingSectionStyle) {
        ensureLoaded()
        _uiState.update { state -> state.copy(style = style) }
        persist()
    }

    fun setUpNextFromFurthestEpisode(enabled: Boolean) {
        ensureLoaded()
        _uiState.update { state -> state.copy(upNextFromFurthestEpisode = enabled) }
        persist()
    }

    fun setUseEpisodeThumbnails(enabled: Boolean) {
        ensureLoaded()
        _uiState.update { state -> state.copy(useEpisodeThumbnails = enabled) }
        persist()
    }

    fun setShowUnairedNextUp(enabled: Boolean) {
        ensureLoaded()
        _uiState.update { state -> state.copy(showUnairedNextUp = enabled) }
        persist()
    }

    fun setBlurNextUp(enabled: Boolean) {
        ensureLoaded()
        _uiState.update { state -> state.copy(blurNextUp = enabled) }
        persist()
    }

    fun addDismissedNextUpKey(key: String) {
        ensureLoaded()
        val normalizedKey = key.trim()
        if (normalizedKey.isBlank()) return
        val previous = _uiState.getAndUpdate { state ->
            if (normalizedKey in state.dismissedNextUpKeys) {
                state
            } else {
                state.copy(dismissedNextUpKeys = state.dismissedNextUpKeys + normalizedKey)
            }
        }
        if (normalizedKey in previous.dismissedNextUpKeys) return
        persist()
    }

    fun setShowResumePromptOnLaunch(enabled: Boolean) {
        ensureLoaded()
        _uiState.update { state -> state.copy(showResumePromptOnLaunch = enabled) }
        persist()
    }

    fun setSortMode(mode: ContinueWatchingSortMode) {
        ensureLoaded()
        val previous = _uiState.getAndUpdate { state ->
            if (state.sortMode == mode) state else state.copy(sortMode = mode)
        }
        if (previous.sortMode == mode) return
        persist()
    }

    fun setClickAction(action: ContinueWatchingClickAction) {
        ensureLoaded()
        val previous = _uiState.getAndUpdate { state ->
            if (state.clickAction == action) state else state.copy(clickAction = action)
        }
        if (previous.clickAction == action) return
        persist()
    }

    fun removeDismissedNextUpKeysForContent(contentId: String) {
        ensureLoaded()
        val normalizedContentId = contentId.trim()
        if (normalizedContentId.isBlank()) return
        val prefix = "$normalizedContentId|"
        val matches: (String) -> Boolean = { it == normalizedContentId || it.startsWith(prefix) }
        val previous = _uiState.getAndUpdate { state ->
            val filtered = state.dismissedNextUpKeys.filterNot(matches).toSet()
            if (filtered.size == state.dismissedNextUpKeys.size) state else state.copy(dismissedNextUpKeys = filtered)
        }
        if (previous.dismissedNextUpKeys.none(matches)) return
        persist()
    }

    private fun persist() {
        // Review r2 P3-5: one snapshot; reading `_uiState.value` per field could persist a torn
        // mix of two concurrent updates (the mutators run on more than one dispatcher).
        val state = _uiState.value
        ContinueWatchingPreferencesStorage.savePayload(
            json.encodeToString(
                StoredContinueWatchingPreferences(
                    isVisible = state.isVisible,
                    style = state.style,
                    upNextFromFurthestEpisode = state.upNextFromFurthestEpisode,
                    useEpisodeThumbnails = state.useEpisodeThumbnails,
                    showUnairedNextUp = state.showUnairedNextUp,
                    blurNextUp = state.blurNextUp,
                    dismissedNextUpKeys = state.dismissedNextUpKeys,
                    showResumePromptOnLaunch = state.showResumePromptOnLaunch,
                    sortMode = state.sortMode,
                    clickAction = state.clickAction,
                ),
            ),
        )
    }
}
