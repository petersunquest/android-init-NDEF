package com.beamio.app

import com.beamio.app.BeamioCallFgsPolicy.StaleDismiss
import org.junit.Assert.assertArrayEquals
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

/**
 * 2026-11-03, Samsung on Release 1.0.160: returning to MainActivity mid-call
 * stopped the call service, and the microphone was silenced ~5 s after the
 * app left the screen (the service ran as phoneCall only).
 */
class BeamioCallFgsPolicyTest {
    private val phoneCall = BeamioCallFgsPolicy.PHONE_CALL
    private val mic = BeamioCallFgsPolicy.MICROPHONE
    private val short = BeamioCallFgsPolicy.SHORT_SERVICE

    @Test
    fun androidTypeValues() {
        // ServiceInfo.FOREGROUND_SERVICE_TYPE_* (API 29 / 30 / 34).
        assertEquals(4, phoneCall)
        assertEquals(128, mic)
        assertEquals(2048, short)
    }

    @Test
    fun callInProgressTriesMicrophoneFirstThenPhoneCallThenShortService() {
        assertArrayEquals(intArrayOf(phoneCall or mic, phoneCall, short), BeamioCallFgsPolicy.ongoingTypes(micGranted = true))
    }

    @Test
    fun noRecordAudioPermissionNeverAsksForTheMicrophoneType() {
        // The microphone type without RECORD_AUDIO throws on Android 14+.
        assertArrayEquals(intArrayOf(phoneCall, short), BeamioCallFgsPolicy.ongoingTypes(micGranted = false))
    }

    @Test
    fun ringingNeverUsesTheMicrophoneType() {
        // Ringing often starts from an FCM wake in the background, where microphone is refused.
        BeamioCallFgsPolicy.ringingTypes().forEach { assertFalse(BeamioCallFgsPolicy.hasMicrophone(it)) }
        assertArrayEquals(intArrayOf(phoneCall, short), BeamioCallFgsPolicy.ringingTypes())
    }

    @Test
    fun hasMicrophone() {
        assertTrue(BeamioCallFgsPolicy.hasMicrophone(phoneCall or mic))
        assertFalse(BeamioCallFgsPolicy.hasMicrophone(phoneCall))
        assertFalse(BeamioCallFgsPolicy.hasMicrophone(short))
        assertFalse(BeamioCallFgsPolicy.hasMicrophone(0))
    }

    @Test
    fun upgradeWhenACallAnsweredInTheBackgroundComesToTheFront() {
        assertTrue(BeamioCallFgsPolicy.needsMicrophoneUpgrade(sdk = 35, ongoingShown = true, currentTypes = phoneCall, micGranted = true))
        // shortService fallback also gets upgraded.
        assertTrue(BeamioCallFgsPolicy.needsMicrophoneUpgrade(sdk = 34, ongoingShown = true, currentTypes = short, micGranted = true))
    }

    @Test
    fun noUpgradeWhenNotNeededOrNotPossible() {
        // Already has it.
        assertFalse(BeamioCallFgsPolicy.needsMicrophoneUpgrade(35, true, phoneCall or mic, true))
        // Ringing or muted hold, not a call in progress.
        assertFalse(BeamioCallFgsPolicy.needsMicrophoneUpgrade(35, false, phoneCall, true))
        // No permission: the type would throw.
        assertFalse(BeamioCallFgsPolicy.needsMicrophoneUpgrade(35, true, phoneCall, false))
        // Before Android 14 the manifest types (phoneCall | microphone) apply already.
        assertFalse(BeamioCallFgsPolicy.needsMicrophoneUpgrade(33, true, 0, true))
    }

    @Test
    fun liveCallIsNeverStale() {
        // The 1.0.160 bug: connected call, MainActivity resumes, nothing else up.
        assertEquals(StaleDismiss.SKIP_LIVE_CALL, BeamioCallFgsPolicy.staleDismiss(false, false, false, liveCall = true))
    }

    @Test
    fun nothingLiveIsDismissed() {
        assertEquals(StaleDismiss.DISMISS, BeamioCallFgsPolicy.staleDismiss(false, false, false, false))
    }

    @Test
    fun earlierSkipsKeepTheirOrder() {
        assertEquals(StaleDismiss.SKIP_GLASS_SHOWING, BeamioCallFgsPolicy.staleDismiss(true, true, true, true))
        assertEquals(StaleDismiss.SKIP_PRESENT_IN_FLIGHT, BeamioCallFgsPolicy.staleDismiss(false, true, true, true))
        assertEquals(StaleDismiss.SKIP_RINGING, BeamioCallFgsPolicy.staleDismiss(false, false, true, true))
        assertEquals(StaleDismiss.SKIP_RINGING, BeamioCallFgsPolicy.staleDismiss(false, false, true, false))
    }
}
