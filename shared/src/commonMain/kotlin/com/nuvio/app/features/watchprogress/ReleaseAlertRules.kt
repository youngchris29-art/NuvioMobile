package com.nuvio.app.features.watchprogress

import com.nuvio.app.features.watching.domain.isoCalendarDateOrNull
import com.nuvio.app.features.trakt.parseTraktIsoDateTimeToEpochMs
import co.touchlab.kermit.Logger

fun parseReleaseDateToEpochMs(raw: String?): Long? {
    if (raw.isNullOrBlank()) return null
    val trimmed = raw.trim()
    val epochMs = parseTraktIsoDateTimeToEpochMs(trimmed)
    if (epochMs != null) return epochMs

    val datePart = isoCalendarDateOrNull(trimmed) ?: return null
    return CurrentDateProvider.localStartOfDayEpochMs(datePart)
}

class ReleaseAlertState(
    val isReleaseAlert: Boolean,
    val isNewSeasonRelease: Boolean,
)

fun calculateReleaseAlertState(
    seedLastUpdatedEpochMs: Long,
    seedSeasonNumber: Int?,
    nextSeasonNumber: Int?,
    releasedIso: String?,
): ReleaseAlertState {
    val releaseEpoch = parseReleaseDateToEpochMs(releasedIso)
    val nowMs = WatchProgressClock.nowEpochMs()

    val log = Logger.withTag("ReleaseAlert")
    log.d {
        "calculateReleaseAlertState inputs: releasedIso=$releasedIso, " +
        "releaseEpoch=$releaseEpoch, seedLastUpdatedEpochMs=$seedLastUpdatedEpochMs, " +
        "seedSeasonNumber=$seedSeasonNumber, nextSeasonNumber=$nextSeasonNumber, nowMs=$nowMs"
    }

    if (releaseEpoch == null) {
        log.d { "calculateReleaseAlertState failed: releaseEpoch is null" }
        return ReleaseAlertState(false, false)
    }

    val hasAired = nowMs >= releaseEpoch
    val sixtyDaysMs = 60L * 24 * 60 * 60 * 1000
    val isReleaseAlert = hasAired &&
        releaseEpoch > seedLastUpdatedEpochMs &&
        (nowMs - releaseEpoch) < sixtyDaysMs

    val isNewSeasonRelease = isReleaseAlert &&
        seedSeasonNumber != null &&
        nextSeasonNumber != null &&
        nextSeasonNumber != seedSeasonNumber

    log.d {
        "calculateReleaseAlertState result: isReleaseAlert=$isReleaseAlert (hasAired=$hasAired, " +
        "epoch>seed=${releaseEpoch > seedLastUpdatedEpochMs}, ageMs=${nowMs - releaseEpoch}), " +
        "isNewSeasonRelease=$isNewSeasonRelease"
    }

    return ReleaseAlertState(
        isReleaseAlert = isReleaseAlert,
        isNewSeasonRelease = isNewSeasonRelease
    )
}
