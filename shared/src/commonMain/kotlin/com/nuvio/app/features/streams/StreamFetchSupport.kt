package com.nuvio.app.features.streams

import com.nuvio.app.features.addons.AddonManifest
import com.nuvio.app.features.addons.ManagedAddon
import com.nuvio.app.features.plugins.PluginRepositoryItem
import com.nuvio.app.features.plugins.PluginRuntimeResult
import com.nuvio.app.features.plugins.PluginScraper
import kotlinx.coroutines.CancellationException
import com.nuvio.app.core.i18n.StringKey
import com.nuvio.app.core.i18n.resourceString

data class InstalledStreamAddonTarget(
    val addonName: String,
    val addonId: String,
    val manifest: AddonManifest,
)

fun ManagedAddon.streamAddonInstanceId(manifestId: String): String =
    "addon:$manifestId:$manifestUrl"

data class PluginProviderGroup(
    val addonId: String,
    val addonName: String,
    val scrapers: List<PluginScraper>,
)

sealed interface StreamLoadCompletion {
    data class Addon(val group: AddonStreamGroup) : StreamLoadCompletion
    data class PluginScraper(
        val addonId: String,
        val streams: List<StreamItem>,
        val error: String?,
    ) : StreamLoadCompletion
}

fun List<PluginScraper>.toPluginProviderGroups(
    repositories: List<PluginRepositoryItem>,
    groupByRepository: Boolean,
): List<PluginProviderGroup> {
    if (!groupByRepository) {
        return map { scraper ->
            PluginProviderGroup(
                addonId = "plugin:${scraper.id}",
                addonName = scraper.name,
                scrapers = listOf(scraper),
            )
        }
    }

    val repoNameByUrl = repositories.associate { it.manifestUrl to it.name }
    return groupBy { it.repositoryUrl }
        .map { (repositoryUrl, scrapers) ->
            PluginProviderGroup(
                addonId = "plugin-repo:${repositoryUrl.lowercase()}",
                addonName = repoNameByUrl[repositoryUrl].orEmpty().ifBlank { repositoryUrl.fallbackRepositoryLabel() },
                scrapers = scrapers.sortedBy { it.name.lowercase() },
            )
        }
        .sortedBy { it.addonName.lowercase() }
}

fun List<AddonStreamGroup>.toEmptyStateReason(anyLoading: Boolean): StreamsEmptyStateReason? {
    if (anyLoading || any { it.streams.isNotEmpty() }) {
        return null
    }

    return if (isNotEmpty() && all { !it.error.isNullOrBlank() }) {
        StreamsEmptyStateReason.StreamFetchFailed
    } else {
        StreamsEmptyStateReason.NoStreamsFound
    }
}

suspend fun <T> runCatchingUnlessCancelled(block: suspend () -> T): Result<T> =
    try {
        Result.success(block())
    } catch (error: CancellationException) {
        throw error
    } catch (error: Throwable) {
        Result.failure(error)
    }

fun PluginRuntimeResult.toStreamItem(
    scraper: PluginScraper,
    addonName: String = scraper.name,
    addonId: String = "plugin:${scraper.id}",
    includeScraperNameInSubtitle: Boolean = false,
): StreamItem {
    val subtitleParts = listOfNotNull(
        scraper.name.takeIf { includeScraperNameInSubtitle && it.isNotBlank() },
        quality?.takeIf { it.isNotBlank() },
        size?.takeIf { it.isNotBlank() },
        language?.takeIf { it.isNotBlank() },
    )
    val requestHeaders = headers
        .orEmpty()
        .mapNotNull { (key, value) ->
            val headerName = key.trim()
            val headerValue = value.trim()
            if (headerName.isBlank() || headerValue.isBlank() || headerName.equals("Range", ignoreCase = true)) {
                null
            } else {
                headerName to headerValue
            }
        }
        .toMap()

    return StreamItem(
        name = name ?: title,
        description = subtitleParts.joinToString(" • ").ifBlank { null },
        url = url,
        infoHash = infoHash,
        sourceName = scraper.name,
        addonName = addonName,
        addonId = addonId,
        streamType = normalizeStreamType(type),
        behaviorHints = if (requestHeaders.isEmpty()) {
            StreamBehaviorHints()
        } else {
            StreamBehaviorHints(
                notWebReady = true,
                proxyHeaders = StreamProxyHeaders(request = requestHeaders),
            )
        },
        externalSubtitles = subtitles?.map {
            StreamSubtitle(
                url = it.url,
                language = it.language,
                name = it.name,
                headers = it.headers
            )
        } ?: emptyList()
    )
}

fun List<StreamItem>.sortedForGroupedDisplay(): List<StreamItem> =
    sortedWith(
        compareBy<StreamItem>(
            { it.sourceName.orEmpty().lowercase() },
            { it.streamLabel.lowercase() },
            { it.streamSubtitle.orEmpty().lowercase() },
        ),
    )

private fun String.fallbackRepositoryLabel(): String {
    val withoutQuery = substringBefore("?")
    val withoutManifest = withoutQuery.removeSuffix("/manifest.json")
    val host = withoutManifest.substringAfter("://", withoutManifest).substringBefore('/')
    return host.ifBlank {
        withoutManifest.substringAfterLast('/').ifBlank {
            resourceString("Plugin repository", StringKey.streams_plugin_repository_fallback)
        }
    }
}
