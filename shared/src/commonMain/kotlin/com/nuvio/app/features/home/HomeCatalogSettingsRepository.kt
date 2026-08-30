package com.nuvio.app.features.home

import com.nuvio.app.features.addons.ManagedAddon
import com.nuvio.app.features.collection.Collection
import com.nuvio.app.features.collection.CollectionRepository
import com.nuvio.app.core.i18n.StringKey
import com.nuvio.app.core.i18n.resourceString
import co.touchlab.kermit.Logger
import kotlinx.atomicfu.atomic
import kotlinx.atomicfu.locks.SynchronizedObject
import kotlinx.atomicfu.locks.synchronized
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asStateFlow
import kotlinx.serialization.Serializable
import kotlinx.serialization.decodeFromString
import kotlinx.serialization.encodeToString
import kotlinx.serialization.json.Json

data class HomeCatalogSettingsItem(
    val key: String,
    val defaultTitle: String,
    val addonName: String,
    val customTitle: String = "",
    val enabled: Boolean = true,
    val heroSourceEnabled: Boolean = true,
    val order: Int = 0,
    val isCollection: Boolean = false,
    val collectionId: String? = null,
    val isPinnedToTop: Boolean = false,
) {
    val displayTitle: String
        get() = customTitle.ifBlank { defaultTitle }
}

data class HomeCatalogSettingsUiState(
    val heroEnabled: Boolean = true,
    val showCatalogType: Boolean = true,
    val hideUnreleasedContent: Boolean = false,
    val hideCatalogUnderline: Boolean = false,
    /** UX-8: hide the whole Discover section on the Search screen (tvOS-authored, shared-namespace synced). */
    val hideDiscover: Boolean = false,
    val items: List<HomeCatalogSettingsItem> = emptyList(),
) {
    val signature: String
        get() = buildString {
            append(heroEnabled)
            append('|')
            append(showCatalogType)
            append('|')
            append(hideUnreleasedContent)
            append('|')
            append(hideCatalogUnderline)
            append('|')
            append(hideDiscover)
            append('|')
            append(
                items.joinToString(separator = "|") { item ->
                    "${item.key}:${item.order}:${item.enabled}:${item.heroSourceEnabled}:${item.customTitle}"
                }
            )
        }
}

data class HomeCatalogPreference(
    val customTitle: String,
    val enabled: Boolean,
    val heroSourceEnabled: Boolean,
    val order: Int,
)

data class HomeCatalogSettingsSnapshot(
    val heroEnabled: Boolean,
    val showCatalogType: Boolean,
    val hideUnreleasedContent: Boolean,
    val hideCatalogUnderline: Boolean,
    val hideDiscover: Boolean,
    val preferences: Map<String, HomeCatalogPreference>,
)

@Serializable
private data class StoredHomeCatalogPreference(
    val key: String,
    val customTitle: String = "",
    val enabled: Boolean = true,
    val heroSourceEnabled: Boolean = true,
    val order: Int = 0,
    /**
     * The owning addon's sync id, stamped at write time from the definition that produced this
     * entry ("" for collections and for records written before 2026-08-30). The drift-refill in
     * [HomeCatalogSettingsRepository.normalizePreferences] needs "is this orphaned key's addon
     * still present?", and the key alone cannot answer that: keys are "<addonId>:<type>:<catalogId>"
     * where BOTH the addon id and the catalog id may contain ':', so every prefix heuristic has a
     * collision (Codex 2026-08-30 rounds 3-4: loaded "foo" vs loading "foo:movie"). Exact id
     * comparison against the current definition set is unambiguous; "" fails closed (never counts
     * as a vanished selection). Local storage only — the sync payload has its own addon_id field.
     */
    val addonId: String = "",
)

@Serializable
private data class StoredHomeCatalogSettingsPayload(
    val heroEnabled: Boolean = true,
    val showCatalogType: Boolean = true,
    val hideUnreleasedContent: Boolean = false,
    val hideCatalogUnderline: Boolean = false,
    val hideDiscover: Boolean = false,
    val items: List<StoredHomeCatalogPreference> = emptyList(),
)

object HomeCatalogSettingsRepository {
    const val HERO_SOURCE_SELECTION_LIMIT = 2

    private val log = Logger.withTag("HomeCatalogSettingsRepository")

    private val json = Json {
        ignoreUnknownKeys = true
        encodeDefaults = true
    }

    private val _uiState = MutableStateFlow(HomeCatalogSettingsUiState())
    val uiState: StateFlow<HomeCatalogSettingsUiState> = _uiState.asStateFlow()

    private var hasLoaded = false
    private var definitions: List<HomeCatalogDefinition> = emptyList()
    private var collectionDefinitions: List<CollectionCatalogDefinition> = emptyList()
    // Serializes every read-modify-write of the preferences map (CollectionRepository's
    // mutationLock precedent): the atomic reference makes reads safe, but two concurrent
    // whole-map reassignments (a sync pull vs a user reorder) would otherwise drop one side's
    // change wholesale. Reentrant — normalizePreferences() runs under callers' locks too.
    private val preferencesMutationLock = SynchronizedObject()
    private val preferencesRef = atomic<Map<String, StoredHomeCatalogPreference>>(emptyMap())
    private var preferences: Map<String, StoredHomeCatalogPreference>
        get() = preferencesRef.value
        set(value) {
            preferencesRef.value = value
        }
    private var heroEnabled = true
    private var showCatalogType = true
    private var hideUnreleasedContent = false
    private var hideCatalogUnderline = false
    private var hideDiscover = false

    fun onProfileChanged() {
        hasLoaded = false
        synchronized(preferencesMutationLock) { preferences = emptyMap() }
        heroEnabled = true
        showCatalogType = true
        hideUnreleasedContent = false
        hideCatalogUnderline = false
        hideDiscover = false
        definitions = emptyList()
        collectionDefinitions = emptyList()
        _uiState.value = HomeCatalogSettingsUiState()
    }

    fun clearLocalState() {
        hasLoaded = false
        definitions = emptyList()
        collectionDefinitions = emptyList()
        synchronized(preferencesMutationLock) { preferences = emptyMap() }
        heroEnabled = true
        showCatalogType = true
        hideUnreleasedContent = false
        hideCatalogUnderline = false
        hideDiscover = false
        _uiState.value = HomeCatalogSettingsUiState()
    }

    fun syncCatalogs(addons: List<ManagedAddon>) {
        ensureLoaded()
        val incomingDefinitions = buildHomeCatalogDefinitions(addons)
        if (!shouldReplaceCatalogDefinitions(definitions.size, incomingDefinitions.size)) {
            // Deliberate tradeoff (Codex 2026-08-29, declined twice): yes, this also rejects the
            // one LEGITIMATE empty — the user removing/disabling their last addon mid-session,
            // whose dead rows then linger in Home Rows. But `definitions` is session-scoped
            // in-memory state: the very next launch starts empty and shows the true empty state,
            // while ACCEPTING empties here reopens the blank-pane clobber this guard exists for
            // (no caller can distinguish "last addon removed" from "manifests not fetched yet"
            // without new cross-layer plumbing). Stale-for-a-session beats blank-forever; profile
            // switches and wipes clear through onProfileChanged()/clearLocalState() as before.
            log.w { "syncCatalogs() — ignored an empty definition set; keeping ${definitions.size} known catalogs (transient addon emission must not blank Home Rows)" }
            return
        }
        definitions = incomingDefinitions
        collectionDefinitions = buildCollectionDefinitions(CollectionRepository.collections.value)
        if (definitions.isEmpty() && collectionDefinitions.isEmpty()) {
            publish()
            return
        }
        normalizePreferences()
        enforcePinnedCollectionsAtTop()
        publish()
        persist()
    }

    fun syncCollections(collections: List<Collection>) {
        ensureLoaded()
        collectionDefinitions = buildCollectionDefinitions(collections)
        normalizePreferences()
        enforcePinnedCollectionsAtTop()
        publish()
        persist()
        HomeRepository.applyCurrentSettings()
    }

    fun snapshot(): HomeCatalogSettingsSnapshot {
        ensureLoaded()
        return HomeCatalogSettingsSnapshot(
            heroEnabled = heroEnabled,
            showCatalogType = showCatalogType,
            hideUnreleasedContent = hideUnreleasedContent,
            hideCatalogUnderline = hideCatalogUnderline,
            hideDiscover = hideDiscover,
            preferences = preferences.mapValues { (_, value) ->
                HomeCatalogPreference(
                    customTitle = value.customTitle,
                    enabled = value.enabled,
                    heroSourceEnabled = value.heroSourceEnabled,
                    order = value.order,
                )
            },
        )
    }

    fun setHeroEnabled(enabled: Boolean) {
        ensureLoaded()
        heroEnabled = enabled
        publish()
        persist()
        HomeRepository.applyCurrentSettings()
    }

    fun setShowCatalogType(enabled: Boolean) {
        ensureLoaded()
        if (showCatalogType == enabled) return
        showCatalogType = enabled
        publish()
        persist()
        HomeRepository.applyCurrentSettings()
        HomeCatalogSettingsSyncService.triggerPush()
    }

    fun setHideUnreleasedContent(enabled: Boolean) {
        ensureLoaded()
        if (hideUnreleasedContent == enabled) return
        hideUnreleasedContent = enabled
        publish()
        persist()
        HomeRepository.applyCurrentSettings()
        HomeCatalogSettingsSyncService.triggerPush()
    }

    fun setHideCatalogUnderline(enabled: Boolean) {
        ensureLoaded()
        if (hideCatalogUnderline == enabled) return
        hideCatalogUnderline = enabled
        publish()
        persist()
        HomeCatalogSettingsSyncService.triggerPush()
    }

    /** UX-8: hide the entire Discover section on the Search screen. Per-profile, synced (shared namespace). */
    fun setHideDiscover(enabled: Boolean) {
        ensureLoaded()
        if (hideDiscover == enabled) return
        hideDiscover = enabled
        publish()
        persist()
        HomeCatalogSettingsSyncService.triggerPush()
    }

    fun setHeroSourceEnabled(key: String, enabled: Boolean) {
        ensureLoaded()
        val current = preferences[key] ?: defaultPreferenceForMissingKey(key) ?: return
        val updated = when {
            current.heroSourceEnabled == enabled -> current
            !enabled -> current.copy(heroSourceEnabled = false)
            // Rejected at the limit: nothing changes, so the hero must not reshuffle either.
            selectedHeroSourceCount(excludingKey = key) >= HERO_SOURCE_SELECTION_LIMIT -> current
            else -> current.copy(heroSourceEnabled = true)
        }
        if (updated == current) return
        // BUG-42: an ACCEPTED explicit Hero Sources change is the one thing that redraws the hero.
        // Reset, store, and republish as one unit so no load-scope publish can interleave.
        HomeRepository.resetHeroSelectionAround {
            synchronized(preferencesMutationLock) { preferences = preferences + (key to updated) }
            publish()
            persist()
            HomeRepository.applyCurrentSettings()
            // Deliberately local-only (no HomeCatalogSettingsSyncService.triggerPush()) — same as
            // the pushRemote = false this used to pass.
        }
    }

    fun setEnabled(key: String, enabled: Boolean) {
        updatePreference(key) { preference ->
            preference.copy(enabled = enabled)
        }
    }

    fun setCustomTitle(key: String, title: String) {
        updatePreference(key) { preference ->
            preference.copy(customTitle = title)
        }
    }

    fun resetToDefaults() {
        ensureLoaded()
        HomeRepository.resetHeroSelectionAround { // BUG-42: atomic with the mutation + republish
            heroEnabled = true
            showCatalogType = true
            hideUnreleasedContent = false
            hideCatalogUnderline = false
            hideDiscover = false
            synchronized(preferencesMutationLock) { preferences = emptyMap() }
            normalizePreferences()
            publish()
            persist()
            HomeRepository.applyCurrentSettings()
        }
        HomeCatalogSettingsSyncService.triggerPush()
    }

    fun moveUp(key: String) {
        move(key = key, direction = -1)
    }

    fun moveDown(key: String) {
        move(key = key, direction = 1)
    }

    fun moveByIndex(fromIndex: Int, toIndex: Int) {
        ensureLoaded()
        val allKeys = allOrderedKeys()
        if (allKeys.isEmpty()) return
        if (fromIndex !in allKeys.indices || toIndex !in allKeys.indices) return
        if (fromIndex == toIndex) return
        val orderedKeys = allKeys.toMutableList()
        orderedKeys.add(toIndex, orderedKeys.removeAt(fromIndex))
        synchronized(preferencesMutationLock) {
            val updatedPreferences = preferences.toMutableMap()
            orderedKeys.forEachIndexed { index, itemKey ->
                val current = updatedPreferences[itemKey] ?: return@forEachIndexed
                updatedPreferences[itemKey] = current.copy(order = index)
            }
            preferences = updatedPreferences
        }
        publish()
        persist()
        HomeRepository.applyCurrentSettings()
        HomeCatalogSettingsSyncService.triggerPush()
    }

    private fun ensureLoaded() {
        if (hasLoaded) return
        hasLoaded = true

        val payload = HomeCatalogSettingsStorage.loadPayload().orEmpty().trim()
        if (payload.isEmpty()) return

        val parsedPayload = runCatching {
            json.decodeFromString<StoredHomeCatalogSettingsPayload>(payload)
        }.getOrNull()

        if (parsedPayload != null) {
            heroEnabled = parsedPayload.heroEnabled
            showCatalogType = parsedPayload.showCatalogType
            hideUnreleasedContent = parsedPayload.hideUnreleasedContent
            hideCatalogUnderline = parsedPayload.hideCatalogUnderline
            hideDiscover = parsedPayload.hideDiscover
            synchronized(preferencesMutationLock) { preferences = parsedPayload.items.associateBy { it.key } }
            publish()
            return
        }

        val legacyItems = runCatching {
            json.decodeFromString<List<StoredHomeCatalogPreference>>(payload)
        }.getOrDefault(emptyList())

        synchronized(preferencesMutationLock) { preferences = legacyItems.associateBy { it.key } }
        publish()
    }

    private fun normalizePreferences() = synchronized(preferencesMutationLock) {
        val current = preferences
        data class UnifiedEntry(val key: String, val isCollection: Boolean, val addonId: String)
        val catalogEntries = definitions.map { UnifiedEntry(it.key, false, it.addonIdForSync()) }
        val collectionEntries = collectionDefinitions.map { UnifiedEntry(it.key, true, "") }
        val allEntries = catalogEntries + collectionEntries
        val knownKeys = allEntries.mapTo(linkedSetOf(), UnifiedEntry::key)
        var nextOrder = (current.values.maxOfOrNull(StoredHomeCatalogPreference::order) ?: -1) + 1

        val orderedEntries = allEntries.mapIndexed { defaultIndex, entry ->
            Triple(
                entry,
                current[entry.key]?.order ?: (nextOrder + defaultIndex),
                defaultIndex,
            )
        }.sortedWith(
            compareBy<Triple<UnifiedEntry, Int, Int>>(
                { it.second },
                { it.third },
            ),
        ).map { it.first }

        val normalized = current
            .filterKeys { it !in knownKeys }
            .toMutableMap()
        var enabledHeroSourceCount = 0
        orderedEntries.forEach { entry ->
            val stored = current[entry.key]
            val heroSourceEnabled = if (entry.isCollection) {
                false
            } else {
                (stored?.heroSourceEnabled ?: true) &&
                    enabledHeroSourceCount < HERO_SOURCE_SELECTION_LIMIT
            }
            if (heroSourceEnabled) {
                enabledHeroSourceCount += 1
            }
            normalized[entry.key] = StoredHomeCatalogPreference(
                key = entry.key,
                customTitle = stored?.customTitle.orEmpty(),
                enabled = stored?.enabled ?: true,
                heroSourceEnabled = heroSourceEnabled,
                order = stored?.order ?: nextOrder++,
                addonId = entry.addonId,
            )
        }

        // Drift-refill (bug reproduced live 2026-08-29/30): the loop above only auto-enables an
        // entry that has NO stored preference at all (`stored?.heroSourceEnabled ?: true`). On a
        // long-lived profile every beyond-the-cap entry already carries a stored
        // heroSourceEnabled=false — normalize itself wrote it there on an earlier pass — so if the
        // two previously-selected keys ever drop out of `definitions`/`collectionDefinitions` (an
        // addon manifest reshuffled catalog ids, or the addon was removed), every SURVIVING entry
        // is "stored=false" and the loop lands on zero enabled. There is no future pass where any
        // of those keys would organically regain stored=true — the selection is stranded empty
        // forever, and hero trailer location silently degrades along with it.
        //
        // Distinguish that DRIFT (a selection stranded on vanished keys) from a user who
        // deliberately turned every hero source off on catalogs that are still here, AND from an
        // addon that simply has not loaded yet. A key only counts as VANISHED when all three hold:
        // its stored preference says heroSourceEnabled=true, it no longer resolves to any
        // definition, and its stamped `addonId` matches an addon in the current definition set —
        // an EXACT id comparison, never a key-prefix heuristic: addon ids and catalog ids may both
        // contain ':', so every prefix parse of a key has a collision (Codex rounds 3-4). Records
        // stamped "" (pre-2026-08-30, or collections) fail closed and never count as vanished.
        // That last clause is what makes this safe under
        // incremental manifest loading (Codex 2026-08-30 P1): on a cold start the callers feed
        // syncCatalogs() only the addons whose manifests are READY, so the selection's addon can
        // be legitimately absent for a while — its keys are then "not known" but must not be
        // treated as gone, or an unlucky manifest completion order would reassign (and, worse,
        // consume) a perfectly valid selection on an ordinary launch. The price: a selection held
        // by an addon that was genuinely REMOVED stays stranded at zero rather than refilled —
        // but the Settings rows are reachable and honest about "0 of 2 selected", so the user can
        // recover manually, and no data is ever destroyed by guessing wrong.
        val presentAddonIds = definitions.mapTo(mutableSetOf()) { it.addonIdForSync() }
        val vanishedSelectionKeys = current.keys.filter { key ->
            val pref = current.getValue(key)
            pref.heroSourceEnabled &&
                key !in knownKeys &&
                pref.addonId.isNotEmpty() &&
                pref.addonId in presentAddonIds
        }
        if (vanishedSelectionKeys.isNotEmpty()) {
            var refilled = 0
            if (enabledHeroSourceCount == 0 && orderedEntries.any { !it.isCollection }) {
                orderedEntries.forEach { entry ->
                    if (refilled >= HERO_SOURCE_SELECTION_LIMIT) return@forEach
                    if (entry.isCollection) return@forEach
                    val existing = normalized[entry.key] ?: return@forEach
                    if (existing.heroSourceEnabled) return@forEach
                    normalized[entry.key] = existing.copy(heroSourceEnabled = true)
                    refilled += 1
                }
            }
            // Consume the drift signal unconditionally once the keys are PROVABLY stale — their
            // addon answered this sync and no longer offers them (Codex 2026-08-30 P2: consuming
            // only inside the refill branch left the markers alive whenever a newly-added catalog
            // had already defaulted a slot to true, and a user's later deliberate all-off was then
            // misclassified as drift on the next pass). The entry itself stays in the map
            // (order/customTitle survive), it just no longer votes as a stranded selection; if the
            // same catalog id ever returns it re-enters the ordinary cap logic like any other
            // entry with a stored preference.
            vanishedSelectionKeys.forEach { key ->
                normalized[key]?.let { pref ->
                    normalized[key] = pref.copy(heroSourceEnabled = false)
                }
            }
            log.i {
                "normalizePreferences() — hero-source selection keys ${vanishedSelectionKeys.size} " +
                    "vanished from their (still-present) addon's catalogs; refilled $refilled " +
                    "entr${if (refilled == 1) "y" else "ies"} in display order and consumed the markers"
            }
        }

        preferences = normalized.toMap()
    }

    private fun publish() {
        val collectionMap = collectionDefinitions.associateBy { it.key }
        val catalogItems = definitions
            .map { definition ->
                val preference = preferences[definition.key]
                HomeCatalogSettingsItem(
                    key = definition.key,
                    defaultTitle = definition.defaultTitle,
                    addonName = definition.addonName,
                    customTitle = preference?.customTitle.orEmpty(),
                    enabled = preference?.enabled ?: true,
                    heroSourceEnabled = preference?.heroSourceEnabled ?: true,
                    // BUG-12: unknown keys sort to the BACK, matching allOrderedKeys() — the two
                    // orderings must agree or moveByIndex() applies UI indices to the wrong rows.
                    order = preference?.order ?: Int.MAX_VALUE,
                )
            }

        val collectionItems = collectionDefinitions.map { colDef ->
            val preference = preferences[colDef.key]
            HomeCatalogSettingsItem(
                key = colDef.key,
                defaultTitle = colDef.title,
                addonName = colDef.subtitle,
                customTitle = preference?.customTitle.orEmpty(),
                enabled = preference?.enabled ?: true,
                heroSourceEnabled = false,
                order = preference?.order ?: Int.MAX_VALUE, // BUG-12: keep in sync with allOrderedKeys()
                isCollection = true,
                collectionId = colDef.collectionId,
                isPinnedToTop = colDef.isPinnedToTop,
            )
        }

        val items = (catalogItems + collectionItems)
            .sortedBy { it.order }

        _uiState.value = HomeCatalogSettingsUiState(
            heroEnabled = heroEnabled,
            showCatalogType = showCatalogType,
            hideUnreleasedContent = hideUnreleasedContent,
            hideCatalogUnderline = hideCatalogUnderline,
            hideDiscover = hideDiscover,
            items = items,
        )
    }

    private fun persist() {
        HomeCatalogSettingsStorage.savePayload(
            json.encodeToString(
                StoredHomeCatalogSettingsPayload(
                    heroEnabled = heroEnabled,
                    showCatalogType = showCatalogType,
                    hideUnreleasedContent = hideUnreleasedContent,
                    hideCatalogUnderline = hideCatalogUnderline,
                    hideDiscover = hideDiscover,
                    items = preferences.values.sortedBy { it.order },
                ),
            ),
        )
    }

    private fun updatePreference(
        key: String,
        pushRemote: Boolean = true,
        transform: (StoredHomeCatalogPreference) -> StoredHomeCatalogPreference,
    ) {
        ensureLoaded()
        val current = preferences[key] ?: defaultPreferenceForMissingKey(key) ?: return
        val updated = transform(current)
        if (updated == current) return
        synchronized(preferencesMutationLock) { preferences = preferences + (key to updated) }
        publish()
        persist()
        HomeRepository.applyCurrentSettings()
        if (pushRemote) {
            HomeCatalogSettingsSyncService.triggerPush()
        }
    }

    private fun selectedHeroSourceCount(excludingKey: String? = null): Int {
        val catalogKeys = definitions.mapTo(mutableSetOf()) { it.key }
        return preferences.count { (itemKey, preference) ->
            itemKey != excludingKey && itemKey in catalogKeys && preference.heroSourceEnabled
        }
    }

    private fun move(
        key: String,
        direction: Int,
    ) {
        ensureLoaded()
        val orderedKeys = allOrderedKeys().toMutableList()
        if (orderedKeys.isEmpty()) return

        val currentIndex = orderedKeys.indexOf(key)
        if (currentIndex == -1) return

        val targetIndex = currentIndex + direction
        if (targetIndex !in orderedKeys.indices) return

        val movingKey = orderedKeys.removeAt(currentIndex)
        orderedKeys.add(targetIndex, movingKey)

        synchronized(preferencesMutationLock) {
            val updatedPreferences = preferences.toMutableMap()
            orderedKeys.forEachIndexed { index, itemKey ->
                val current = updatedPreferences[itemKey] ?: return@forEachIndexed
                updatedPreferences[itemKey] = current.copy(order = index)
            }
            preferences = updatedPreferences
        }

        publish()
        persist()
        HomeRepository.applyCurrentSettings()
        HomeCatalogSettingsSyncService.triggerPush()
    }

    fun exportToSyncPayload(): SyncHomeCatalogPayload {
        ensureLoaded()
        val catalogDefinitionsByKey = definitions.associateBy { it.key }
        val collectionDefinitionsByKey = collectionDefinitions.associateBy { it.key }
        val items = preferences.values.sortedBy { it.order }.map { pref ->
            val catalogDefinition = catalogDefinitionsByKey[pref.key]
            val collectionDefinition = collectionDefinitionsByKey[pref.key]
            val isCollection = collectionDefinition != null || pref.key.startsWith("collection_")
            if (isCollection) {
                SyncCatalogItem(
                    addonId = "",
                    type = "",
                    catalogId = "",
                    enabled = pref.enabled,
                    order = pref.order,
                    customTitle = pref.customTitle,
                    isCollection = true,
                    collectionId = collectionDefinition?.collectionId ?: pref.key.removePrefix("collection_"),
                    key = pref.key,
                )
            } else {
                val legacyParts = pref.key.split(':', limit = 3)
                SyncCatalogItem(
                    addonId = catalogDefinition?.addonIdForSync() ?: legacyParts.getOrElse(0) { "" },
                    type = catalogDefinition?.type ?: legacyParts.getOrElse(1) { "" },
                    catalogId = catalogDefinition?.catalogId ?: legacyParts.getOrElse(2) { "" },
                    enabled = pref.enabled,
                    order = pref.order,
                    customTitle = pref.customTitle,
                    isCollection = false,
                    key = pref.key,
                )
            }
        }
        return SyncHomeCatalogPayload(
            showCatalogType = showCatalogType,
            hideUnreleasedContent = hideUnreleasedContent,
            hideCatalogUnderline = hideCatalogUnderline,
            hideDiscover = hideDiscover,
            items = items,
        )
    }

    fun applyFromRemote(payload: SyncHomeCatalogPayload) {
        ensureLoaded()
        showCatalogType = payload.showCatalogType
        hideUnreleasedContent = payload.hideUnreleasedContent
        hideCatalogUnderline = payload.hideCatalogUnderline
        hideDiscover = payload.hideDiscover
        if (payload.items.isNotEmpty()) {
            synchronized(preferencesMutationLock) {
            val existingHeroState = preferences.mapValues { it.value.heroSourceEnabled }
            val remotePreferences = payload.items.associate { item ->
                val key = item.preferenceKey()
                key to StoredHomeCatalogPreference(
                    key = key,
                    customTitle = item.customTitle,
                    enabled = item.enabled,
                    heroSourceEnabled = existingHeroState[key] ?: true,
                    order = item.order,
                    // Owner stamp: PRESERVE the local one, never adopt the remote's (Codex
                    // 2026-08-30 round 5 P2). The remote `addon_id` can come from the exporter's
                    // legacy `split(':', limit = 3)` fallback, which mis-splits colon-containing
                    // addon ids ("foo:sub:movie:c1" → "foo") — adopting it would overwrite an
                    // exact local stamp with an ambiguous one and reopen the false-vanished
                    // consumption this field exists to prevent. Keys the local definition set
                    // knows are re-stamped exactly by the normalizePreferences() call right below;
                    // unknown keys keep their prior exact stamp or fail closed at "".
                    addonId = preferences[key]?.addonId.orEmpty(),
                )
            }
            val remoteKeys = remotePreferences.keys
            val knownKeys = knownPreferenceKeys()
            val preservedPreferences = preferences.filterKeys { key ->
                key !in remoteKeys && (key in knownKeys || key.requiresExplicitSyncKey())
            }
            preferences = preservedPreferences + remotePreferences
            normalizePreferences()
            }
        }
        hasLoaded = true
        publish()
        persist()
        HomeRepository.applyCurrentSettings()
    }

    private fun allOrderedKeys(): List<String> {
        val catalogKeys = definitions.map { it.key }
        val collectionKeys = collectionDefinitions.map { it.key }
        return (catalogKeys + collectionKeys)
            .sortedBy { key -> preferences[key]?.order ?: Int.MAX_VALUE }
    }

    private fun enforcePinnedCollectionsAtTop() {
        // BUG-12: never rewrite the GLOBAL order while the catalog half of the key space is
        // unknown (syncCatalogs not yet called this session — e.g. a client that reaches Home
        // before Settings). Reindexing from collections alone assigns them order 0..n, colliding
        // with the catalog preferences' existing 0..n, and persist() then makes the scramble
        // permanent (and pushes it to the account on the next preference write).
        if (definitions.isEmpty()) return
        val orderedKeys = allOrderedKeys()
        if (orderedKeys.isEmpty()) return

        val pinnedCollectionKeys = collectionDefinitions
            .asSequence()
            .filter { it.isPinnedToTop }
            .map { it.key }
            .toSet()
        if (pinnedCollectionKeys.isEmpty()) return

        val pinnedKeys = orderedKeys.filter { it in pinnedCollectionKeys }
        if (pinnedKeys.isEmpty()) return

        val nonPinnedKeys = orderedKeys.filterNot { it in pinnedCollectionKeys }
        val reorderedKeys = pinnedKeys + nonPinnedKeys
        if (reorderedKeys == orderedKeys) return

        synchronized(preferencesMutationLock) {
            val updatedPreferences = preferences.toMutableMap()
            reorderedKeys.forEachIndexed { index, itemKey ->
                val current = updatedPreferences[itemKey] ?: return@forEachIndexed
                updatedPreferences[itemKey] = current.copy(order = index)
            }
            preferences = updatedPreferences
        }
    }

    private fun defaultPreferenceForMissingKey(key: String): StoredHomeCatalogPreference? {
        val isCollection = collectionDefinitions.any { it.key == key }
        val isCatalog = definitions.any { it.key == key }
        if (!isCollection && !isCatalog) return null

        return StoredHomeCatalogPreference(
            key = key,
            enabled = true,
            heroSourceEnabled = isCatalog &&
                selectedHeroSourceCount(excludingKey = key) < HERO_SOURCE_SELECTION_LIMIT,
            order = _uiState.value.items.firstOrNull { it.key == key }?.order
                ?: ((preferences.values.maxOfOrNull { it.order } ?: -1) + 1),
            addonId = definitions.firstOrNull { it.key == key }?.addonIdForSync().orEmpty(),
        )
    }

    private fun knownPreferenceKeys(): Set<String> =
        definitions.mapTo(mutableSetOf()) { it.key }.also { keys ->
            keys.addAll(collectionDefinitions.map { it.key })
        }

    private fun HomeCatalogDefinition.addonIdForSync(): String {
        val suffix = ":$type:$catalogId"
        return key.removeSuffix(suffix)
    }

    private fun SyncCatalogItem.preferenceKey(): String =
        key.ifBlank {
            if (isCollection) {
                "collection_$collectionId"
            } else {
                "$addonId:$type:$catalogId"
            }
        }

    private fun String.requiresExplicitSyncKey(): Boolean =
        !startsWith("collection_") && count { it == ':' } > 2
}

internal data class CollectionCatalogDefinition(
    val key: String,
    val collectionId: String,
    val title: String,
    val subtitle: String,
    val isPinnedToTop: Boolean,
)

// Fork: public (upstream: internal) — composeApp tests consume cross-module.
fun visibleCollectionsWithUniqueIds(collections: List<Collection>): List<Collection> =
    collections
        .filter { collection -> collection.folders.isNotEmpty() }
        .distinctBy(Collection::id)

internal fun buildCollectionDefinitions(collections: List<Collection>): List<CollectionCatalogDefinition> =
    visibleCollectionsWithUniqueIds(collections).map { collection ->
        CollectionCatalogDefinition(
            key = "collection_${collection.id}",
            collectionId = collection.id,
            title = collection.title,
            subtitle = resourceString("${collection.folders.size} folder(s)", StringKey.collections_folder_count, collection.folders.size),
            isPinnedToTop = collection.pinToTop,
        )
    }

/// Whether an incoming syncCatalogs() definition set may replace the current one. A transient
/// EMPTY set (an addon emission whose manifests haven't loaded yet, a removal pass, a
/// mid-bootstrap snapshot) must never wipe a non-empty set — profile switches and account wipes
/// clear definitions through onProfileChanged()/clearLocalState(), never through syncCatalogs().
internal fun shouldReplaceCatalogDefinitions(currentCount: Int, incomingCount: Int): Boolean =
    incomingCount > 0 || currentCount == 0
