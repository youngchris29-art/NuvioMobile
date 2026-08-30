package com.nuvio.app.features.home

import com.nuvio.app.features.addons.AddonCatalog
import com.nuvio.app.features.addons.AddonManifest
import com.nuvio.app.features.addons.AddonResource
import com.nuvio.app.features.addons.ManagedAddon
import com.nuvio.app.features.collection.Collection
import com.nuvio.app.features.collection.CollectionFolder
import com.nuvio.app.features.collection.CollectionRepository
import kotlin.test.AfterTest
import kotlin.test.BeforeTest
import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertFalse
import kotlin.test.assertTrue

/**
 * Coverage for the 2026-08-29/30 hero-source drift bug: `normalizePreferences()` only
 * auto-enables an entry with NO stored preference at all, so once every survivor of a catalog-key
 * change carries a stored `heroSourceEnabled=false` (which normalize itself wrote there on an
 * earlier pass), the selection could get stranded at zero forever. See the drift-refill block in
 * `HomeCatalogSettingsRepository.normalizePreferences()`.
 *
 * Exercises the singleton repository directly (unlike `HomeCatalogDefinitionsGuardTest`, which
 * deliberately avoids it) — reset via `clearLocalState()` plus wiping the persisted payload so a
 * stale on-disk preference set from another test/run can't leak into `ensureLoaded()`.
 */
class HomeCatalogSettingsHeroDriftTest {

    private val addonId = "drift-test-addon"

    @BeforeTest
    fun setUp() {
        HomeCatalogSettingsRepository.clearLocalState()
        HomeCatalogSettingsStorage.savePayload("")
        CollectionRepository.clearLocalState()
    }

    @AfterTest
    fun tearDown() {
        HomeCatalogSettingsRepository.clearLocalState()
        HomeCatalogSettingsStorage.savePayload("")
        CollectionRepository.clearLocalState()
    }

    private fun addonWithCatalogs(catalogIds: List<String>, id: String = addonId): ManagedAddon {
        val manifest = AddonManifest(
            id = id,
            name = "Drift Test Addon",
            description = "",
            version = "1.0.0",
            resources = listOf(AddonResource(name = "catalog", types = listOf("movie"))),
            types = listOf("movie"),
            catalogs = catalogIds.map { catalogId -> AddonCatalog(type = "movie", id = catalogId, name = catalogId) },
            transportUrl = "https://example.com/$id/manifest.json",
        )
        return ManagedAddon(manifestUrl = manifest.transportUrl, manifest = manifest, enabled = true)
    }

    private fun key(catalogId: String, id: String = addonId) = "$id:movie:$catalogId"

    private fun heroEnabledKeys(): Set<String> =
        HomeCatalogSettingsRepository.uiState.value.items
            .filter { it.heroSourceEnabled }
            .mapTo(mutableSetOf()) { it.key }

    private fun itemFor(key: String): HomeCatalogSettingsItem =
        HomeCatalogSettingsRepository.uiState.value.items.first { it.key == key }

    @Test
    fun driftRefillRecoversASelectionStrandedOnRemovedCatalogKeys() {
        val fullAddon = addonWithCatalogs(listOf("c1", "c2", "c3", "c4", "c5"))
        HomeCatalogSettingsRepository.syncCatalogs(listOf(fullAddon))

        // Defaults: the first two in display order are hero-enabled, the rest are not — and are
        // now stored as heroSourceEnabled=false, exactly the drift precondition.
        assertEquals(setOf(key("c1"), key("c2")), heroEnabledKeys())

        // A user moves the selection onto c4/c5 — c1..c3 now all carry a STORED false.
        HomeCatalogSettingsRepository.setHeroSourceEnabled(key("c1"), false)
        HomeCatalogSettingsRepository.setHeroSourceEnabled(key("c2"), false)
        HomeCatalogSettingsRepository.setHeroSourceEnabled(key("c4"), true)
        HomeCatalogSettingsRepository.setHeroSourceEnabled(key("c5"), true)
        assertEquals(setOf(key("c4"), key("c5")), heroEnabledKeys())

        // The addon's manifest changes shape and c4/c5 (the whole active selection) disappear.
        val shrunkAddon = addonWithCatalogs(listOf("c1", "c2", "c3"))
        HomeCatalogSettingsRepository.syncCatalogs(listOf(shrunkAddon))

        // Drift-refill recovers exactly LIMIT entries among the survivors, first in display order
        // — never left stranded at zero.
        val enabled = heroEnabledKeys()
        assertEquals(HomeCatalogSettingsRepository.HERO_SOURCE_SELECTION_LIMIT, enabled.size)
        assertEquals(setOf(key("c1"), key("c2")), enabled)
        assertFalse(itemFor(key("c3")).heroSourceEnabled)
    }

    @Test
    fun deliberateAllOffSelectionOnSurvivingKeysIsNotRefilled() {
        val addon = addonWithCatalogs(listOf("c1", "c2", "c3"))
        HomeCatalogSettingsRepository.syncCatalogs(listOf(addon))
        assertEquals(setOf(key("c1"), key("c2")), heroEnabledKeys())

        // The user explicitly turns every hero source off, on catalogs that keep existing.
        HomeCatalogSettingsRepository.setHeroSourceEnabled(key("c1"), false)
        HomeCatalogSettingsRepository.setHeroSourceEnabled(key("c2"), false)
        assertTrue(heroEnabledKeys().isEmpty())

        // Re-sync with the identical catalog set — nothing vanished, so this was a deliberate
        // all-off choice, not drift, and must stay untouched.
        HomeCatalogSettingsRepository.syncCatalogs(listOf(addon))

        assertTrue(
            heroEnabledKeys().isEmpty(),
            "a deliberate all-off selection on surviving keys must never be silently refilled",
        )
    }

    @Test
    fun driftRefillFiresOnceAndDoesNotOverrideALaterDeliberateAllOff() {
        // Codex 2026-08-30 P2: the orphaned stored-true entries that prove drift are preserved in
        // the map, so without consuming them after the refill they would classify EVERY later
        // normalize pass as drifted — including one where the user has since deliberately turned
        // every surviving hero source off.
        val fullAddon = addonWithCatalogs(listOf("c1", "c2", "c3", "c4", "c5"))
        HomeCatalogSettingsRepository.syncCatalogs(listOf(fullAddon))
        HomeCatalogSettingsRepository.setHeroSourceEnabled(key("c1"), false)
        HomeCatalogSettingsRepository.setHeroSourceEnabled(key("c2"), false)
        HomeCatalogSettingsRepository.setHeroSourceEnabled(key("c4"), true)
        HomeCatalogSettingsRepository.setHeroSourceEnabled(key("c5"), true)

        // Drift: the selection's keys vanish and the refill recovers c1/c2.
        val shrunkAddon = addonWithCatalogs(listOf("c1", "c2", "c3"))
        HomeCatalogSettingsRepository.syncCatalogs(listOf(shrunkAddon))
        assertEquals(setOf(key("c1"), key("c2")), heroEnabledKeys())

        // The user then deliberately turns the refilled pair off — on keys that still exist.
        HomeCatalogSettingsRepository.setHeroSourceEnabled(key("c1"), false)
        HomeCatalogSettingsRepository.setHeroSourceEnabled(key("c2"), false)
        assertTrue(heroEnabledKeys().isEmpty())

        // Any later sync with the same surviving set must respect that choice: the c4/c5 orphan
        // markers were consumed by the first refill, so this is a deliberate all-off, not drift.
        HomeCatalogSettingsRepository.syncCatalogs(listOf(shrunkAddon))
        assertTrue(
            heroEnabledKeys().isEmpty(),
            "the drift refill must fire once per drift, not on every pass while orphans linger",
        )
    }

    @Test
    fun partialManifestLoadNeverTreatsAnUnloadedAddonsSelectionAsDrift() {
        // Codex 2026-08-30 P1: on a cold start the callers feed syncCatalogs() only the addons
        // whose manifests are READY. An unlucky completion order used to make the selection's
        // addon look "vanished", steal its slots for the loaded subset, and consume the markers —
        // destroying a valid selection on an ordinary launch. Absent addon ⇒ not drift.
        val addonA = addonWithCatalogs(listOf("c1", "c2", "c3"))
        val addonB = addonWithCatalogs(listOf("b1", "b2"), id = "drift-test-addon-b")
        HomeCatalogSettingsRepository.syncCatalogs(listOf(addonA, addonB))

        // Move the whole selection onto addon B.
        HomeCatalogSettingsRepository.setHeroSourceEnabled(key("c1"), false)
        HomeCatalogSettingsRepository.setHeroSourceEnabled(key("c2"), false)
        HomeCatalogSettingsRepository.setHeroSourceEnabled(key("b1", "drift-test-addon-b"), true)
        HomeCatalogSettingsRepository.setHeroSourceEnabled(key("b2", "drift-test-addon-b"), true)
        assertEquals(
            setOf(key("b1", "drift-test-addon-b"), key("b2", "drift-test-addon-b")),
            heroEnabledKeys(),
        )

        // New session (in-memory reset; persisted preferences survive), and addon A's manifest
        // arrives first — B is not in this sync at all.
        HomeCatalogSettingsRepository.clearLocalState()
        HomeCatalogSettingsRepository.syncCatalogs(listOf(addonA))

        // No refill fired: A's catalogs all carry a stored false, and B's absence is not drift.
        assertTrue(
            heroEnabledKeys().isEmpty(),
            "an addon that has not loaded yet must not have its selection reassigned",
        )

        // B's manifest lands — the untouched selection comes straight back.
        HomeCatalogSettingsRepository.syncCatalogs(listOf(addonA, addonB))
        assertEquals(
            setOf(key("b1", "drift-test-addon-b"), key("b2", "drift-test-addon-b")),
            heroEnabledKeys(),
        )
    }

    @Test
    fun colonContainingAddonIdsDoNotFalselyReadAsPresentByPrefix() {
        // Codex 2026-08-30 round 3 P1: addon ids may contain ':'. With addon "X" loaded and addon
        // "X:sub" still loading, "X:sub"'s keys start with "X:" — a bare prefix test would call
        // them vanished-from-a-present-addon and consume the selection. The type-segment pin
        // ("X:movie:") must keep the absent addon's selection untouched.
        val base = addonWithCatalogs(listOf("c1", "c2"))
        val colonAddonId = "$addonId:sub"
        val colonAddon = addonWithCatalogs(listOf("b1", "b2"), id = colonAddonId)
        HomeCatalogSettingsRepository.syncCatalogs(listOf(base, colonAddon))

        HomeCatalogSettingsRepository.setHeroSourceEnabled(key("c1"), false)
        HomeCatalogSettingsRepository.setHeroSourceEnabled(key("c2"), false)
        HomeCatalogSettingsRepository.setHeroSourceEnabled(key("b1", colonAddonId), true)
        HomeCatalogSettingsRepository.setHeroSourceEnabled(key("b2", colonAddonId), true)
        assertEquals(setOf(key("b1", colonAddonId), key("b2", colonAddonId)), heroEnabledKeys())

        // New session; only the base addon has loaded. The colon addon's keys share its prefix.
        HomeCatalogSettingsRepository.clearLocalState()
        HomeCatalogSettingsRepository.syncCatalogs(listOf(base))
        assertTrue(
            heroEnabledKeys().isEmpty(),
            "the colon-prefixed sibling addon's selection must not be reassigned while it loads",
        )

        // The colon addon lands — its selection must have survived unconsumed.
        HomeCatalogSettingsRepository.syncCatalogs(listOf(base, colonAddon))
        assertEquals(setOf(key("b1", colonAddonId), key("b2", colonAddonId)), heroEnabledKeys())
    }

    @Test
    fun vanishedMarkersAreConsumedEvenWhenANewCatalogAlreadyFillsASlot() {
        // Codex 2026-08-30 P2: when the vanished selection coincides with a brand-new catalog
        // (no stored preference ⇒ defaults to enabled), the refill isn't needed — but the stale
        // markers still must be consumed, or a later deliberate all-off gets misread as drift.
        val original = addonWithCatalogs(listOf("c1", "c2"))
        HomeCatalogSettingsRepository.syncCatalogs(listOf(original))
        assertEquals(setOf(key("c1"), key("c2")), heroEnabledKeys())

        // Same addon reshapes: the selected pair is gone, a NEW catalog appears and auto-fills.
        val reshaped = addonWithCatalogs(listOf("c3"))
        HomeCatalogSettingsRepository.syncCatalogs(listOf(reshaped))
        assertEquals(setOf(key("c3")), heroEnabledKeys())

        // The user deliberately turns the survivor off; a later identical sync must respect it —
        // the c1/c2 markers were consumed above even though no refill ran.
        HomeCatalogSettingsRepository.setHeroSourceEnabled(key("c3"), false)
        HomeCatalogSettingsRepository.syncCatalogs(listOf(reshaped))
        assertTrue(
            heroEnabledKeys().isEmpty(),
            "stale vanished-selection markers must be consumed even when no refill was needed",
        )
    }

    @Test
    fun driftRefillNeverEnablesCollectionsAndNeverExceedsTheLimit() {
        val collection = Collection(
            id = "drift-test-collection",
            title = "Collection",
            folders = listOf(CollectionFolder(id = "f1", title = "Folder")),
        )
        CollectionRepository.setCollections(listOf(collection))
        val collectionKey = "collection_${collection.id}"

        val fullAddon = addonWithCatalogs(listOf("c1", "c2", "c3", "c4", "c5"))
        HomeCatalogSettingsRepository.syncCatalogs(listOf(fullAddon))
        assertEquals(setOf(key("c1"), key("c2")), heroEnabledKeys())
        assertFalse(itemFor(collectionKey).heroSourceEnabled)

        HomeCatalogSettingsRepository.setHeroSourceEnabled(key("c1"), false)
        HomeCatalogSettingsRepository.setHeroSourceEnabled(key("c2"), false)
        HomeCatalogSettingsRepository.setHeroSourceEnabled(key("c4"), true)
        HomeCatalogSettingsRepository.setHeroSourceEnabled(key("c5"), true)

        // Three catalogs survive (more than the limit) alongside the untouched collection.
        val shrunkAddon = addonWithCatalogs(listOf("c1", "c2", "c3"))
        HomeCatalogSettingsRepository.syncCatalogs(listOf(shrunkAddon))

        val enabled = heroEnabledKeys()
        assertEquals(HomeCatalogSettingsRepository.HERO_SOURCE_SELECTION_LIMIT, enabled.size)
        assertFalse(collectionKey in enabled)
        assertFalse(itemFor(collectionKey).heroSourceEnabled)
    }
}
