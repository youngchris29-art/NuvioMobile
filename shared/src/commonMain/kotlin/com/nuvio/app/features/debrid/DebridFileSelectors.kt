package com.nuvio.app.features.debrid

import com.nuvio.app.features.streams.StreamClientResolve

class TorboxFileSelector {
    fun selectFile(
        files: List<TorboxTorrentFileDto>,
        resolve: StreamClientResolve,
        season: Int?,
        episode: Int?,
    ): TorboxTorrentFileDto? = selectDebridFile(
        files = files,
        resolve = resolve,
        season = season,
        episode = episode,
        path = { it.displayName() },
        isPlayable = {
            it.mimeType.orEmpty().startsWith("video/", ignoreCase = true) || it.displayName().hasVideoExtension()
        },
        size = { it.size ?: 0L },
    )
}

class RealDebridFileSelector {
    fun selectFile(
        files: List<RealDebridTorrentFileDto>,
        resolve: StreamClientResolve,
        season: Int?,
        episode: Int?,
    ): RealDebridTorrentFileDto? = selectDebridFile(
        files = files,
        resolve = resolve,
        season = season,
        episode = episode,
        path = { it.path.orEmpty() },
        isPlayable = { it.displayName().hasVideoExtension() },
        size = { it.bytes ?: 0L },
    )
}

class PremiumizeDirectDownloadFileSelector {
    fun selectFile(
        files: List<PremiumizeDirectDownloadFileDto>,
        resolve: StreamClientResolve,
        season: Int?,
        episode: Int?,
    ): PremiumizeDirectDownloadFileDto? = selectDebridFile(
        files = files,
        resolve = resolve,
        season = season,
        episode = episode,
        path = { it.path.orEmpty() },
        isPlayable = { !it.link.isNullOrBlank() && it.displayName().hasVideoExtension() },
        size = { it.size ?: 0L },
    )
}

fun PremiumizeDirectDownloadFileDto.displayName(): String =
    path.orEmpty().substringAfterLast('/').substringAfterLast('\\').ifBlank { path.orEmpty() }

/**
 * A leaf file flattened out of AllDebrid's `magnet/files` folder tree. Public (like the other
 * provider file DTOs in this file) since `AllDebridFileSelector.selectFile` — also public —
 * exposes it in its signature.
 *
 * Fork: [name] holds the file's path relative to the magnet root (folder names joined with `/`),
 * mirroring TorBox's `name` and Premiumize's `path`, so the shared selector can match an exact
 * `behaviorHints.filename` path and tell apart repeated basenames in different season folders.
 * [displayName] returns the leaf filename.
 */
data class AllDebridFlatFile(
    val name: String,
    val size: Long?,
    val link: String,
)

fun AllDebridFlatFile.displayName(): String =
    name.substringAfterLast('/').ifBlank { name }

/**
 * AllDebrid's `magnet/files` response is a tree: file nodes carry `n`/`s`/`l`, folder nodes carry
 * `n`/`e` (children) instead. Flatten it to the leaf files only, keeping each file's folder path
 * in [AllDebridFlatFile.name] so selection can match on paths as well as basenames.
 */
internal fun List<AllDebridFileNodeDto>.flattenAllDebridFiles(): List<AllDebridFlatFile> {
    val result = mutableListOf<AllDebridFlatFile>()
    fun visit(nodes: List<AllDebridFileNodeDto>, parent: String) {
        nodes.forEach { node ->
            val nodeName = node.n.orEmpty()
            val nodePath = if (parent.isEmpty()) nodeName else "$parent/$nodeName"
            val children = node.e
            if (!children.isNullOrEmpty()) {
                visit(children, nodePath)
            } else {
                val link = node.l?.takeIf { it.isNotBlank() } ?: return@forEach
                result.add(AllDebridFlatFile(name = nodePath, size = node.s, link = link))
            }
        }
    }
    visit(this, "")
    return result
}

class AllDebridFileSelector {
    // Fork: AllDebrid is not an upstream provider. It shares upstream's requested-file rules
    // (exact filename/path, then an episode pattern; a miss or an ambiguous match returns null
    // rather than another episode), but its flattened file tree has no stable per-file index,
    // so there is no fileIdx lookup, and a request with no episode whose filename hint misses
    // still falls back to the largest playable video, as it did before the port.
    fun selectFile(
        files: List<AllDebridFlatFile>,
        resolve: StreamClientResolve,
        season: Int?,
        episode: Int?,
    ): AllDebridFlatFile? = selectDebridFile(
        files = files,
        resolve = resolve,
        season = season,
        episode = episode,
        path = { it.name },
        isPlayable = { it.name.hasVideoExtension() },
        size = { it.size ?: 0L },
        hasStableFileIndex = false,
    )
}

/**
 * Upstream `6aa42153`: one selection routine for every provider.
 *
 * 1. An explicit filename (`resolve.filename`, then the raw stream filename) must match exactly
 *    one playable file by path, then by basename (case-sensitive before case-insensitive).
 * 2. Otherwise the requested season/episode must match exactly one playable file's basename.
 * 3. A filename or episode request that finds nothing, or finds several files, returns null
 *    instead of guessing another file.
 * 4. With neither, `fileIdx` indexes the provider's file list; with no index, the largest
 *    playable video wins.
 *
 * Fork: [hasStableFileIndex] = false (AllDebrid) skips step 4's index lookup and lets a
 * filename miss with no episode request fall through to the largest playable video.
 */
private fun <T> selectDebridFile(
    files: List<T>,
    resolve: StreamClientResolve,
    season: Int?,
    episode: Int?,
    path: (T) -> String,
    isPlayable: (T) -> Boolean,
    size: (T) -> Long,
    hasStableFileIndex: Boolean = true,
): T? {
    val playable = files.filter(isPlayable)
    if (playable.isEmpty()) return null

    val names = listOfNotNull(resolve.filename, resolve.stream?.raw?.filename)
        .map { it.normalizedPath() }
        .filter { it.isNotBlank() }
        .distinct()
    for (name in names) {
        val matches = playable.matchingFiles(name, path)
        if (matches.isNotEmpty()) return matches.singleOrNull()
    }

    val episodePattern = buildEpisodePattern(season ?: resolve.season, episode ?: resolve.episode)
    if (episodePattern != null) {
        val matches = playable.filter {
            episodePattern.containsMatchIn(path(it).normalizedPath().substringAfterLast('/'))
        }
        if (matches.isNotEmpty()) return matches.singleOrNull()
        return null
    }

    if (hasStableFileIndex) {
        if (names.isNotEmpty()) return null
        resolve.fileIdx?.let { index ->
            return files.getOrNull(index)?.takeIf(isPlayable)
        }
    }

    return playable.maxByOrNull(size)
}

private fun String.normalizedPath(): String = trim().replace('\\', '/').removePrefix("/")

private fun <T> List<T>.matchingFiles(name: String, path: (T) -> String): List<T> {
    for (ignoreCase in listOf(false, true)) {
        val matches = filter {
            val filePath = path(it).normalizedPath()
            filePath.equals(name, ignoreCase = ignoreCase) ||
                (name.contains('/') && filePath.endsWith("/$name", ignoreCase = ignoreCase))
        }
        if (matches.isNotEmpty()) return matches
    }
    val basename = name.substringAfterLast('/')
    for (ignoreCase in listOf(false, true)) {
        val matches = filter {
            path(it).normalizedPath().substringAfterLast('/').equals(basename, ignoreCase = ignoreCase)
        }
        if (matches.isNotEmpty()) return matches
    }
    return emptyList()
}

private fun buildEpisodePattern(season: Int?, episode: Int?): Regex? {
    if (season == null || episode == null) return null
    return Regex(
        "(?<![a-z0-9])(?:s0*${season}e0*${episode}|0*${season}x0*${episode})(?![0-9])",
        RegexOption.IGNORE_CASE,
    )
}

private fun String.hasVideoExtension(): Boolean = videoExtensions.any { endsWith(it, ignoreCase = true) }

private val videoExtensions = setOf(
    ".mp4",
    ".mkv",
    ".webm",
    ".avi",
    ".mov",
    ".m4v",
    ".ts",
    ".m2ts",
    ".wmv",
    ".flv",
)
