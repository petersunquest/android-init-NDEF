package com.beamio.app

import android.media.AudioManager
import com.beamio.app.BeamioRingPolicy.Plan
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

/** Incoming ringtone rules (RC3d, 2026-11-02): follow the phone's sound mode, stop by call id. */
class BeamioRingPolicyTest {
    @Test
    fun silentModeIsQuiet() {
        // The Samsung S25 sat in this mode for all of RC2–RC3c.
        for (vibrate in listOf(true, false)) {
            val plan = BeamioRingPolicy.plan(AudioManager.RINGER_MODE_SILENT, vibrate)
            assertEquals(Plan.SILENT, plan)
            assertFalse(BeamioRingPolicy.plays(plan))
            assertFalse(BeamioRingPolicy.vibrates(plan))
        }
    }

    @Test
    fun vibrateModeOnlyVibrates() {
        for (vibrate in listOf(true, false)) {
            val plan = BeamioRingPolicy.plan(AudioManager.RINGER_MODE_VIBRATE, vibrate)
            assertEquals(Plan.VIBRATE_ONLY, plan)
            assertFalse(BeamioRingPolicy.plays(plan))
            assertTrue(BeamioRingPolicy.vibrates(plan))
        }
    }

    @Test
    fun soundModeRingsAndVibratesOnlyWhenTheSettingIsOn() {
        val ringOnly = BeamioRingPolicy.plan(AudioManager.RINGER_MODE_NORMAL, false)
        assertEquals(Plan.RING, ringOnly)
        assertTrue(BeamioRingPolicy.plays(ringOnly))
        assertFalse(BeamioRingPolicy.vibrates(ringOnly))

        val both = BeamioRingPolicy.plan(AudioManager.RINGER_MODE_NORMAL, true)
        assertEquals(Plan.RING_AND_VIBRATE, both)
        assertTrue(BeamioRingPolicy.plays(both))
        assertTrue(BeamioRingPolicy.vibrates(both))
    }

    @Test
    fun callKeysDropBlanksAndDuplicates() {
        assertEquals(
            setOf("call-1", "sess-1"),
            BeamioRingPolicy.callKeys(listOf(" call-1 ", "", "sess-1", "call-1", "  ")),
        )
        assertTrue(BeamioRingPolicy.callKeys(listOf("", " ")).isEmpty())
    }

    @Test
    fun silencedCallDoesNotRingAgainButTheNextCallDoes() {
        // Volume / power key while ringing (Telecom onSilence): this call is latched silent.
        val silenced = BeamioRingPolicy.callKeys(listOf("call-1", "sess-1", "orig-1"))
        // A later arm of the same call (re-post, hidden-overlay fallback) uses any of its ids.
        assertTrue(BeamioRingPolicy.sameCall(silenced, listOf("primary-key", "call-1")))
        assertTrue(BeamioRingPolicy.sameCall(silenced, listOf("orig-1")))
        // The next call rings normally.
        assertFalse(BeamioRingPolicy.sameCall(silenced, listOf("call-2", "sess-2")))
    }

    @Test
    fun stopMatchesOnlyTheRingingCall() {
        val ringing = BeamioRingPolicy.callKeys(listOf("primary-key", "call-1", "sess-1"))
        // Answer / decline / timeout / caller cancel of this call, by any of its ids.
        assertTrue(BeamioRingPolicy.sameCall(ringing, listOf("call-1", "")))
        assertTrue(BeamioRingPolicy.sameCall(ringing, listOf("", "sess-1")))
        assertTrue(BeamioRingPolicy.sameCall(ringing, listOf(" primary-key ")))
        // A busy-rejected second call or a stale end must not stop this ring.
        assertFalse(BeamioRingPolicy.sameCall(ringing, listOf("call-2", "sess-2")))
        assertFalse(BeamioRingPolicy.sameCall(ringing, listOf("", "")))
        // Nothing rings: nothing to stop.
        assertFalse(BeamioRingPolicy.sameCall(emptySet(), listOf("call-1")))
    }
}
