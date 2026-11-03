package com.beamio.app

import com.beamio.app.BeamioIncomingPushGate.Verdict
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

class BeamioIncomingPushGateTest {
    private val now = 1_800_000_000_000L

    @Test
    fun freshPushRingsAtOnce() {
        assertEquals(Verdict.RING, BeamioIncomingPushGate.verdict(now, now - 400, (now + 179_000).toString(), null))
    }

    @Test
    fun pushAfterTheRingWindowIsMissed() {
        // expiresAt (dial + 3 min) already passed.
        assertEquals(Verdict.EXPIRED, BeamioIncomingPushGate.verdict(now, now - 60_000, (now - 1).toString(), null))
        // No expiresAt, but FCM sent it more than the ring window ago.
        assertEquals(Verdict.EXPIRED, BeamioIncomingPushGate.verdict(now, now - 200_000, null, null))
    }

    @Test
    fun latePushInsideTheWindowWaitsForTheMailbox() {
        // Android T2 t2b: delivered 46 s late, caller had already hung up.
        assertEquals(Verdict.HOLD_FOR_MAILBOX, BeamioIncomingPushGate.verdict(now, now - 46_000, (now + 134_000).toString(), null))
        assertEquals(Verdict.RING, BeamioIncomingPushGate.verdict(now, now - 5_000, (now + 175_000).toString(), null))
    }

    @Test
    fun endPushNeverRings() {
        assertEquals(Verdict.END, BeamioIncomingPushGate.verdict(now, now - 100, (now + 170_000).toString(), "end"))
        assertEquals(Verdict.END, BeamioIncomingPushGate.verdict(now, now - 100, null, " END "))
        assertEquals(Verdict.RING, BeamioIncomingPushGate.verdict(now, now - 100, null, "ring"))
    }

    @Test
    fun missingTimesDoNotBlockARing() {
        assertEquals(Verdict.RING, BeamioIncomingPushGate.verdict(now, 0L, null, null))
        assertEquals(Verdict.RING, BeamioIncomingPushGate.verdict(now, 0L, "garbage", null))
    }

    @Test
    fun expiresAtInSecondsIsAccepted() {
        val secondsPast = ((now - 2_000) / 1000).toString()
        assertEquals(Verdict.EXPIRED, BeamioIncomingPushGate.verdict(now, now - 100, secondsPast, null))
        assertEquals(now - 2_000, BeamioIncomingPushGate.normalizeMs(secondsPast))
    }

    @Test
    fun endPushIsRememberedByEitherId() {
        BeamioIncomingPushGate.noteEndPush("gateCall", "gateSession", now)
        assertTrue(BeamioIncomingPushGate.endPushSeen("", "gateSession"))
        assertTrue(BeamioIncomingPushGate.endPushSeen("gateCall", "other"))
        assertFalse(BeamioIncomingPushGate.endPushSeen("x", "y"))
    }

    @Test
    fun rangAnswerOnlySaysNoWhenTheRecordCoversTheCall() {
        val keep = 3L * 24 * 60 * 60_000L
        val since = now - 60 * 60_000L
        assertEquals(true, BeamioIncomingPushGate.rangAnswer(true, 0L, 0L, now, keep))
        // T11: force stopped, no push, the call never rang.
        assertEquals(false, BeamioIncomingPushGate.rangAnswer(false, since, now - 120_000L, now, keep))
        // Before this version started recording, or older than the record keeps: unknown.
        assertEquals(null, BeamioIncomingPushGate.rangAnswer(false, since, since - 1, now, keep))
        assertEquals(null, BeamioIncomingPushGate.rangAnswer(false, now - 2 * keep, now - keep - 1, now, keep))
        assertEquals(null, BeamioIncomingPushGate.rangAnswer(false, 0L, now - 1_000L, now, keep))
        assertEquals(null, BeamioIncomingPushGate.rangAnswer(false, since, 0L, now, keep))
    }
}
