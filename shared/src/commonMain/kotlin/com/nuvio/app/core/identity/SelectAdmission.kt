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
            row != request.row -> Admission.Reject(SelectRejection.RowChanged)
            else -> Admission.Admit(request.slot)
        }
    }
}
