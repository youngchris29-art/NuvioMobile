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
 * Fork additions:
 * - In steps 1 and 2, when several files match, basenames with a standalone `sample` token are
 *   dropped and the result is used only if exactly one file remains, otherwise null.
 * - When the episode pattern matches nothing, no filename hint was given and the provider has a
 *   stable index, the file at `fileIdx` is chosen only if it is playable, carries no explicit
 *   SxxEyy/NxM marker, names the requested episode in an anchored position (after ` - `, or after
 *   e / ep / episode / #, optional leading zeros and `v2` suffix), and is the only playable file
 *   in the list that does.
 * - `hasStableFileIndex` = false (AllDebrid) skips that fallback and step 4's index lookup, and
 *   lets a filename miss with no episode request fall through to the largest playable video.
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
        // Fork: drop `sample` clips when a filename matches several files.
        if (matches.isNotEmpty()) return matches.singleOrDropSamples(path)
    }

    val episodePattern = buildEpisodePattern(season ?: resolve.season, episode ?: resolve.episode)
    if (episodePattern != null) {
        val matches = playable.filter {
            episodePattern.containsMatchIn(path(it).normalizedPath().substringAfterLast('/'))
        }
        // Fork: `Show.S01E05.mkv` next to `Show.S01E05.sample.mkv` is not ambiguous; ignore samples.
        if (matches.isNotEmpty()) return matches.singleOrDropSamples(path)
        // Fork: anime / absolute-numbered packs (`Show - 05.mkv`) have no SxxEyy names, so the
        // pattern finds nothing. With no filename hint, trust the add-on's fileIdx only as a
        // POSITIVE, UNIQUE match: the file at fileIdx must exist, be playable, carry no explicit
        // SxxEyy/NxM marker, and name the requested episode in an anchored position (after ` - `,
        // or after e / ep / episode / #; see [buildAnchoredEpisodePattern]), and it must be the ONLY
        // playable file in the list that does. fileIdx is not guaranteed to be a position in this
        // provider's list, so anything looser could play another episode (title numbers, season
        // markers, resolutions, dates). Limit: in season > 1 an absolute-numbered name rarely
        // equals the per-season episode number, so that case returns null rather than guessing.
        if (hasStableFileIndex && names.isEmpty()) {
            val wantedEpisode = episode ?: resolve.episode
            resolve.fileIdx?.let { index ->
                val candidate = files.getOrNull(index)
                if (candidate != null && wantedEpisode != null && isPlayable(candidate)) {
                    val anchored = buildAnchoredEpisodePattern(wantedEpisode)
                    fun basename(file: T) = path(file).normalizedPath().substringAfterLast('/')
                    val matching = playable.filter { anchored.containsMatchIn(basename(it)) }
                    if (!explicitEpisodeMarker.containsMatchIn(basename(candidate)) &&
                        matching.size == 1 && matching.single() === candidate
                    ) {
                        return candidate
                    }
                }
            }
        }
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

// Fork: several matches -> ignore files whose basename has a standalone `sample` segment; keep
// the result only if exactly one file remains ("Sampler" or "Resampled" are not samples).
private fun <T> List<T>.singleOrDropSamples(path: (T) -> String): T? {
    singleOrNull()?.let { return it }
    return filterNot { sampleSegment.containsMatchIn(path(it).normalizedPath().substringAfterLast('/')) }
        .singleOrNull()
}

// Fork: an episode number counts only in an explicit position: after ` - ` / ` -` (anime
// convention), or after e / ep / episode / # that is not part of a longer word. Leading zeros and
// a `v2` version suffix are allowed. Every lookbehind is fixed-width (Kotlin/Native).
private fun buildAnchoredEpisodePattern(episode: Int): Regex = Regex(
    "(?:(?<=\\s-\\s)|(?<=\\s-)|(?<![a-z0-9])(?:episode|ep|e|#)[\\s._]{0,2})0*$episode(?:v\\d+)?(?![0-9])",
    RegexOption.IGNORE_CASE,
)

private val sampleSegment = Regex("(?<![a-z0-9])sample(?![a-z0-9])", RegexOption.IGNORE_CASE)

// Fork: a basename carrying its own SxxEyy / NxM marker names a specific episode.
private val explicitEpisodeMarker = Regex(
    "(?<![a-z0-9])(?:s\\d+e\\d+|\\d{1,2}x\\d{1,3})(?![0-9])",
    RegexOption.IGNORE_CASE,
)

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
