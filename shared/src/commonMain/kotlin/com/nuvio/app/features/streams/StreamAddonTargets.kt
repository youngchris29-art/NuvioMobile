package com.nuvio.app.features.streams

import com.nuvio.app.features.addons.ManagedAddon
import com.nuvio.app.features.addons.enabledAddons

/**
 * Pure selection of the enabled stream add-ons that serve [type] and accept [videoId] (or, on the
 * second BUG-74 pass, [imdbVideoId]), in the user's add-on order, each paired with the id to
 * request from it. JS plugin scrapers are not part of this list; the repository handles them
 * separately.
 *
 * BUG-74: each addon is asked with the id IT accepts. `videoId` first (so a tmdb-only or
 * prefix-less addon keeps working exactly as before), then the resolved IMDb id if this is
 * the second pass. Before this, one id was used for the whole fan-out and every addon that
 * disagreed with its namespace was dropped without a word.
 */
fun streamAddonTargets(
    installed: List<ManagedAddon>,
    type: String,
    videoId: String,
    imdbVideoId: String?,
): List<InstalledStreamAddonTarget> =
    installed.enabledAddons()
        .mapNotNull { addon ->
            val manifest = addon.manifest ?: return@mapNotNull null
            val streamResources = manifest.resources.filter { resource ->
                resource.name == "stream" && resource.types.contains(type)
            }
            val requestId = when {
                streamResources.any { StreamVideoIdRemap.accepts(it.idPrefixes, videoId) } -> videoId
                imdbVideoId != null &&
                    streamResources.any { StreamVideoIdRemap.accepts(it.idPrefixes, imdbVideoId) } -> imdbVideoId
                else -> return@mapNotNull null
            }

            InstalledStreamAddonTarget(
                addonName = addon.displayTitle.ifBlank { manifest.name },
                addonId = addon.streamAddonInstanceId(manifest.id),
                manifest = manifest,
                videoId = requestId,
            )
        }
