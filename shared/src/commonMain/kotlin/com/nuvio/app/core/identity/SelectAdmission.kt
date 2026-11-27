package com.nuvio.app.core.identity

/*
 * Rule G (spec 31.1, revision 15): selection admission. A select carries the account token its
 * picker row was displayed and PIN-checked under; the barrier decides with this pure function
 * inside ONE commit section of the apply that reads the current token and the published profile
 * list and writes the slot, so neither can change between the decision and the write.
 */
enum class SelectOrigin { PickerTap, AutoEnter, Restore, DeleteFallback }

/**
 * The row as it was displayed: [displayedUnder] is the account token of the list it came from
 * (built by DisplayedProfile.selectRequest, never assembled at tap time) and [row] the full row the
 * PIN check was made against. [slot] and [row] are ignored for [SelectOrigin.DeleteFallback].
 */
data class SelectRequest(
    val slot: Int,
    val displayedUnder: AccountToken,
    val origin: SelectOrigin,
    /** The row as displayed (review r6: the full row, so identity survives an empty `updatedAt`). */
    val row: com.nuvio.app.features.profiles.NuvioProfile? = null,
)

/** RowChanged (review r5): the row's lock state or revision changed since it was displayed and PIN-checked. */
enum class SelectRejection { AccountChanged, SlotGone, RowChanged, Phase }

sealed interface Admission {
    /** [slot] = -1: no profile remains, apply "active removed" (DeleteFallback only). */
    data class Admit(val slot: Int) : Admission
    data class Reject(val why: SelectRejection) : Admission
}

/** Why a row action was refused (review r7). */
enum class RowRejection { AccountChanged, SlotGone, RowReplaced, LockChanged }

/**
 * Review r7: THE rule for every action on a displayed row (select, auto-entry, edit/save, delete,
 * PIN set, PIN remove, adopting a PIN check's refreshed row). Called inside the section that acts
 * (the commit section, or the auth lane with the account check held), with the current account
 * token and the current list. A row is the same row when its list's token is current, its slot is
 * listed, the profile in that slot has the same id, and its lock state is unchanged. Pure.
 */
object RowAdmission {
    fun decide(
        displayed: com.nuvio.app.features.profiles.NuvioProfile,
        displayedUnder: AccountToken?,
        current: AccountToken?,
        listed: List<com.nuvio.app.features.profiles.NuvioProfile>,
    ): RowRejection? {
        if (displayedUnder == null || current != displayedUnder) return RowRejection.AccountChanged
        val row = listed.firstOrNull { it.profileIndex == displayed.profileIndex } ?: return RowRejection.SlotGone
        if (row.id != displayed.id) return RowRejection.RowReplaced
        if (row.pinEnabled != displayed.pinEnabled) return RowRejection.LockChanged
        return null
    }
}

object SelectAdmission {
    const val NONE_REMAIN = -1

    fun decide(
        request: SelectRequest,
        gated: Boolean,
        current: AccountToken?,
        listed: List<com.nuvio.app.features.profiles.NuvioProfile>,
        deleting: Int?,
        activeSlot: Int,
    ): Admission {
        val row = listed.firstOrNull { it.profileIndex == request.slot }
        return when {
            !gated -> Admission.Reject(SelectRejection.Phase)
            current == null || current != request.displayedUnder -> Admission.Reject(SelectRejection.AccountChanged)
            request.origin == SelectOrigin.DeleteFallback ->
                if (deleting == null || activeSlot != deleting) {
                    Admission.Reject(SelectRejection.SlotGone) // the user moved on while the delete waited
                } else {
                    Admission.Admit(listed.map { it.profileIndex }.filter { it != deleting }.minOrNull() ?: NONE_REMAIN)
                }
            row == null -> Admission.Reject(SelectRejection.SlotGone)
            request.row == null -> Admission.Reject(SelectRejection.RowChanged)
            else -> when (RowAdmission.decide(request.row, request.displayedUnder, current, listed)) {
                null -> Admission.Admit(request.slot)
                RowRejection.AccountChanged -> Admission.Reject(SelectRejection.AccountChanged)
                RowRejection.SlotGone -> Admission.Reject(SelectRejection.SlotGone)
                RowRejection.RowReplaced, RowRejection.LockChanged -> Admission.Reject(SelectRejection.RowChanged)
            }
        }
    }
}
