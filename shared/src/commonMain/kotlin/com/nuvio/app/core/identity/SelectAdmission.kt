package com.nuvio.app.core.identity

/*
 * Rule G (spec 31.1, revision 15): selection admission. A select carries the account token its
 * picker row was displayed and PIN-checked under; the barrier decides with this pure function
 * inside ONE commit section of the apply that reads the current token and the published profile
 * list and writes the slot, so neither can change between the decision and the write.
 */
enum class SelectOrigin { PickerTap, AutoEnter, Restore, DeleteFallback }

/** [slot] is ignored for [SelectOrigin.DeleteFallback], which chooses its own fallback from the current list. */
data class SelectRequest(val slot: Int, val displayedUnder: AccountToken, val origin: SelectOrigin)

enum class SelectRejection { AccountChanged, SlotGone, Phase }

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
        listed: List<Int>,
        deleting: Int?,
        activeSlot: Int,
    ): Admission = when {
        !gated -> Admission.Reject(SelectRejection.Phase)
        current == null || current != request.displayedUnder -> Admission.Reject(SelectRejection.AccountChanged)
        request.origin == SelectOrigin.DeleteFallback ->
            if (deleting == null || activeSlot != deleting) {
                Admission.Reject(SelectRejection.SlotGone) // the user moved on while the delete waited
            } else {
                Admission.Admit(listed.filter { it != deleting }.minOrNull() ?: NONE_REMAIN)
            }
        request.slot !in listed -> Admission.Reject(SelectRejection.SlotGone)
        else -> Admission.Admit(request.slot)
    }
}
