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
 * (ProfileState.listToken, never read at tap time), [pinEnabled] and [rowRevision] (the profile's
 * `updatedAt`) what the PIN check was made against. [slot], [pinEnabled] and [rowRevision] are
 * ignored for [SelectOrigin.DeleteFallback], which chooses its own fallback from the current list.
 */
data class SelectRequest(
    val slot: Int,
    val displayedUnder: AccountToken,
    val origin: SelectOrigin,
    val pinEnabled: Boolean = false,
    val rowRevision: String = "",
)

/** What admission needs of a listed row to tell that a change matters (review r5 #3). */
data class ListedRow(val slot: Int, val pinEnabled: Boolean, val revision: String)

/** RowChanged (review r5): the row's lock state or revision changed since it was displayed and PIN-checked. */
enum class SelectRejection { AccountChanged, SlotGone, RowChanged, Phase }

sealed interface Admission {
    /** [slot] = -1: no profile remains, apply "active removed" (DeleteFallback only). */
    data class Admit(val slot: Int) : Admission
    data class Reject(val why: SelectRejection) : Admission
}

object SelectAdmission {
    const val NONE_REMAIN = -1

    fun decide(
        request: SelectRequest,
        gated: Boolean,
        current: AccountToken?,
        listed: List<ListedRow>,
        deleting: Int?,
        activeSlot: Int,
    ): Admission {
        val row = listed.firstOrNull { it.slot == request.slot }
        return when {
            !gated -> Admission.Reject(SelectRejection.Phase)
            current == null || current != request.displayedUnder -> Admission.Reject(SelectRejection.AccountChanged)
            request.origin == SelectOrigin.DeleteFallback ->
                if (deleting == null || activeSlot != deleting) {
                    Admission.Reject(SelectRejection.SlotGone) // the user moved on while the delete waited
                } else {
                    Admission.Admit(listed.map { it.slot }.filter { it != deleting }.minOrNull() ?: NONE_REMAIN)
                }
            row == null -> Admission.Reject(SelectRejection.SlotGone)
            row.pinEnabled != request.pinEnabled || row.revision != request.rowRevision -> Admission.Reject(SelectRejection.RowChanged)
            else -> Admission.Admit(request.slot)
        }
    }
}
