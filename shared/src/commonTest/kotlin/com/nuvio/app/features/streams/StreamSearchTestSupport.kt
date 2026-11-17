package com.nuvio.app.features.streams

import com.nuvio.app.features.addons.AddonManifest
import com.nuvio.app.features.addons.AddonResource
import com.nuvio.app.features.addons.ManagedAddon
import com.nuvio.app.features.debrid.DebridProviders
import com.nuvio.app.features.debrid.DebridServiceCredential
import com.nuvio.app.features.plugins.PluginScraper
import kotlinx.coroutines.CompletableDeferred
import kotlinx.coroutines.NonCancellable
import kotlinx.coroutines.withContext

/** W4 test support: add-ons, targets and a scripted fetcher for the source-search session tests. */
internal object SearchFixtures {
    fun managedAddon(id: String, types: List<String> = listOf("movie", "series"), idPrefixes: List<String> = emptyList()): ManagedAddon {
        val url = "https://$id.example.com/manifest.json"
        return ManagedAddon(
            manifestUrl = url,
            manifest = AddonManifest(
                id = id,
                name = id,
                description = "",
                version = "1.0.0",
                resources = listOf(AddonResource(name = "stream", types = types, idPrefixes = idPrefixes)),
                types = types,
                transportUrl = url,
            ),
        )
    }

    fun target(id: String, requestId: String = "tt1"): InstalledStreamAddonTarget {
        val addon = managedAddon(id)
        return InstalledStreamAddonTarget(
            addonName = id,
            addonId = addon.streamAddonInstanceId(id),
            manifest = addon.manifest!!,
            videoId = requestId,
        )
    }

    fun targets(
        addons: List<String> = listOf("a", "b"),
        videoId: String = "tt1:1:1",
        season: Int? = 1,
        episode: Int? = 1,
        requestId: String = videoId,
        debrid: String = "none",
        plugins: List<PluginProviderGroup> = emptyList(),
        account: DebridServiceCredential? = null,
        pluginGeneration: Long = 0L,
    ) = StreamSearchTargets(
        type = "series",
        videoId = videoId,
        season = season,
        episode = episode,
        streamAddons = addons.map { target(it, requestId) },
        pluginProviderGroups = plugins,
        debrid = StreamSearchDebrid(debrid, account),
        pluginGeneration = pluginGeneration,
    )

    fun torbox(apiKey: String) = DebridServiceCredential(DebridProviders.Torbox, apiKey)

    fun scraper(id: String) = PluginScraper(
        id = id,
        repositoryUrl = "https://repo.example.com",
        name = id,
        description = "",
        version = "1",
        filename = "$id.js",
        supportedTypes = listOf("movie", "series"),
        enabled = true,
        manifestEnabled = true,
        code = "",
    )

    fun stream(addonId: String, label: String, infoHash: String? = null) = StreamItem(
        name = label,
        title = label,
        url = if (infoHash == null) "https://cdn.example.com/$label.mkv" else null,
        infoHash = infoHash,
        addonName = addonId.substringAfter("addon:").substringBefore(":"),
        addonId = addonId,
    )
}

/**
 * A scripted [StreamSearchFetcher]: answers at once with one stream per add-on unless a gate was
 * queued for that add-on with [hold], counts every call, and lets a test script the cache check.
 * Gates are consumed in call order, so a second search of the same add-on can get its own gate.
 */
internal class ScriptedSearchFetcher : StreamSearchFetcher {
    private val gates = mutableMapOf<String, ArrayDeque<CompletableDeferred<Result<List<StreamItem>>>>>()

    /** Every add-on fetch, as "<add-on name>@<request id>", in call order. */
    val addonFetches = mutableListOf<String>()

    /** Review r8: the add-on fetches asked with `forceRefresh` (no-cache), same form. */
    val forcedFetches = mutableListOf<String>()
    var scraperRuns = 0
    var cacheChecks = 0

    /** The API key of the account each cache check ran with (null: no account), in call order. */
    val checkedWith = mutableListOf<String?>()

    /** A gated fetch that ignores cancellation, so its answer arrives after its search was dropped. */
    var gatesIgnoreCancellation = false

    var answer: (InstalledStreamAddonTarget) -> Result<List<StreamItem>> = { target ->
        Result.success(listOf(SearchFixtures.stream(target.addonId, "${target.addonName}-${target.videoId}")))
    }
    var cacheCheck: (AddonStreamGroup) -> AddonStreamGroup = { it }
    var scraperAnswer: (PluginProviderGroup, PluginScraper) -> StreamLoadCompletion.PluginScraper = { group, scraper ->
        StreamLoadCompletion.PluginScraper(group.addonId, listOf(SearchFixtures.stream(group.addonId, scraper.id)), null)
    }

    fun hold(addonName: String): CompletableDeferred<Result<List<StreamItem>>> =
        CompletableDeferred<Result<List<StreamItem>>>().also { gates.getOrPut(addonName) { ArrayDeque() }.addLast(it) }

    fun fetchCount(addonName: String): Int = addonFetches.count { it.substringBefore("@") == addonName }

    override suspend fun fetchAddon(target: InstalledStreamAddonTarget, type: String, forceRefresh: Boolean): Result<List<StreamItem>> {
        addonFetches += "${target.addonName}@${target.videoId}"
        if (forceRefresh) forcedFetches += "${target.addonName}@${target.videoId}"
        val gate = gates[target.addonName]?.removeFirstOrNull() ?: return answer(target)
        return if (gatesIgnoreCancellation) withContext(NonCancellable) { gate.await() } else gate.await()
    }

    override suspend fun runScraper(
        group: PluginProviderGroup,
        scraper: PluginScraper,
        targets: StreamSearchTargets,
    ): StreamLoadCompletion.PluginScraper {
        scraperRuns++
        return scraperAnswer(group, scraper)
    }

    override suspend fun withDebridAvailability(
        group: AddonStreamGroup,
        account: com.nuvio.app.features.debrid.DebridServiceCredential?,
    ): AddonStreamGroup {
        cacheChecks++
        checkedWith += account?.apiKey
        return cacheCheck(group)
    }
}
