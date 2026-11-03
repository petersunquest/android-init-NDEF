package com.beamio.app

import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

/** Force-stop notice: cases seen on the Samsung S25 (One UI 9 / Android 17), RC2 2026-11-02. */
class BeamioDeliveryHealthTest {
    @Test
    fun exitDescriptions() {
        assertTrue(BeamioDeliveryHealth.exitWasForceStop(true, "stop com.beamio.app due to from pid 27180"))
        assertFalse(BeamioDeliveryHealth.exitWasForceStop(true, "kill background"))
        assertFalse(BeamioDeliveryHealth.exitWasForceStop(true, "remove task"))
        assertFalse(BeamioDeliveryHealth.exitWasForceStop(false, "stop com.beamio.app"))
        assertFalse(BeamioDeliveryHealth.exitWasForceStop(true, null))
    }

    @Test
    fun startFlagIsCheckedAgainstTheExitRecord() {
        // Force stop, then the launcher: flag true, last exit a force stop.
        assertEquals("exit:100", BeamioDeliveryHealth.combineForceStop(true, "exit:100", 7))
        // Background kill after that, then the launcher: flag still true, last exit "kill background".
        assertEquals("", BeamioDeliveryHealth.combineForceStop(true, "", 7))
        // No exit record: trust the flag.
        assertEquals("start:7", BeamioDeliveryHealth.combineForceStop(true, null, 7))
        // Flag false (e.g. a push woke the app): no notice.
        assertEquals("", BeamioDeliveryHealth.combineForceStop(false, "exit:100", 7))
        // Android 11–14: the exit record alone.
        assertEquals("exit:100", BeamioDeliveryHealth.combineForceStop(null, "exit:100", 7))
        assertEquals("", BeamioDeliveryHealth.combineForceStop(null, null, 7))
    }
}
