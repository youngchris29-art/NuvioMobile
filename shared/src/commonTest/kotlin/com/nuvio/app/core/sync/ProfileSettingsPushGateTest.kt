package com.nuvio.app.core.sync

import kotlin.test.Test
import kotlin.test.assertFalse
import kotlin.test.assertNull
import kotlin.test.assertTrue

// Pure-function coverage for ProfileSettingsSync's addon-wipe class guard (see
// docs/addon-wipe-investigation-2026-08-28.md). Deliberately does not touch ProfileSettingsSync
// itself — it's a singleton with network/platform dependencies — so this only exercises the
// top-level decision functions the observer delegates to (the pull gate, and the fork's
// echo-marker consumption below).
class ProfileSettingsPushGateTest {
    private val userA = SettingsPullToken(userId = "user-a", profileId = 1)
    private val userAOtherProfile = SettingsPullToken(userId = "user-a", profileId = 2)
    private val userB = SettingsPullToken(userId = "user-b", profileId = 1)

    @Test
    fun `blocks push when neither token exists`() {
        assertFalse(settingsPushAllowed(settledToken = null, currentToken = null))
    }

    @Test
    fun `blocks push when current token is null`() {
        assertFalse(settingsPushAllowed(settledToken = userA, currentToken = null))
    }

    @Test
    fun `blocks push when settled token is null`() {
        assertFalse(settingsPushAllowed(settledToken = null, currentToken = userA))
    }

    @Test
    fun `allows push when settled and current tokens match`() {
        assertTrue(settingsPushAllowed(settledToken = userA, currentToken = userA))
    }

    @Test
    fun `blocks push when same user but different profileId`() {
        assertFalse(settingsPushAllowed(settledToken = userA, currentToken = userAOtherProfile))
    }

    @Test
    fun `blocks push when same profileId but different userId`() {
        assertFalse(settingsPushAllowed(settledToken = userA, currentToken = userB))
    }

    // Fork: the echo marker must suppress the very next emission only — see
    // consumeSettingsSkipMarker's doc for the profile-reselect sequence that left the server stuck
    // on a superseded value when a mismatched marker survived.
    @Test
    fun `no marker never suppresses a push`() {
        val decision = consumeSettingsSkipMarker(marker = null, signature = "S")
        assertFalse(decision.skipPush)
        assertNull(decision.remainingMarker)
    }

    @Test
    fun `a matching marker suppresses one push and then expires`() {
        val decision = consumeSettingsSkipMarker(marker = "S", signature = "S")
        assertTrue(decision.skipPush)
        assertNull(decision.remainingMarker)
    }

    @Test
    fun `a mismatched marker pushes and still expires`() {
        val first = consumeSettingsSkipMarker(marker = "S", signature = "T")
        assertFalse(first.skipPush)
        assertNull(first.remainingMarker)

        // The S that follows must push: with the marker expired it is an ordinary emission, not
        // the echo of a profile reselect that happened two edits ago.
        val second = consumeSettingsSkipMarker(marker = first.remainingMarker, signature = "S")
        assertFalse(second.skipPush)
        assertNull(second.remainingMarker)
    }
}
