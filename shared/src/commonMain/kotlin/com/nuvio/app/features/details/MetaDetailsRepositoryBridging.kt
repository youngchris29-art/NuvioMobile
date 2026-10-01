package com.nuvio.app.features.details

/*
 * Fork-only Swift bridging for MetaDetailsRepository (same pattern as
 * `features/mdblist/MdbListAccountControllerBridging.kt`). A Kotlin exception crossing into Swift
 * from a suspend function WITHOUT `@Throws` aborts the process; with it, Swift gets a catchable
 * error (`try await MetaDetailsRepository.shared.fetchChecked(type:id:cacheResult:)`). The ObjC
 * export drops default arguments, so the twin takes `cacheResult` explicitly (pass true for the
 * plain `fetch` behaviour).
 */

/** [MetaDetailsRepository.fetch], callable from Swift with `try await`. */
@Throws(Throwable::class)
suspend fun MetaDetailsRepository.fetchChecked(
    type: String,
    id: String,
    cacheResult: Boolean,
): MetaDetails? = fetch(type = type, id = id, cacheResult = cacheResult)
