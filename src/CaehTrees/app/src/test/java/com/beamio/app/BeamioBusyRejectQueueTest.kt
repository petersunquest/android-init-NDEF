package com.beamio.app

import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

/** Busy callee: the busy reject goes to the new caller at once, once per call. */
class BeamioBusyRejectQueueTest {
    private data class Offer(val callId: String)
    private fun sentNow(d: BeamioBusyRejectQueue.Decision<Offer>): Offer? =
        (d as? BeamioBusyRejectQueue.Decision.SendNow<Offer>)?.offer

    @Test
    fun inCallIncomingSendsBusyAtOnce() {
        val q = BeamioBusyRejectQueue<Offer>()
        // We are in a call; a second caller's offer is already resolved.
        assertEquals(Offer("b"), sentNow(q.busyCallArrived("b", "sb", "busy", Offer("b"))))
        assertEquals(0, q.waitingCount)
    }

    @Test
    fun peerHangsUpFirstAfterTheRejectWentOut() {
        val q = BeamioBusyRejectQueue<Offer>()
        q.busyCallArrived("b", "sb", "busy", Offer("b"))
        // The other party of our call hangs up first: nothing is left to send twice.
        assertEquals(emptyList<BeamioBusyRejectQueue.Waiting>(), q.ownCallEnded())
    }

    @Test
    fun peerHangsUpFirstWhileTheOfferWasNotResolved() {
        val q = BeamioBusyRejectQueue<Offer>()
        assertEquals(BeamioBusyRejectQueue.Decision.Wait, q.busyCallArrived("b", "sb", "busy", null))
        // Our call ends from the other side: the waiting reject still goes out.
        assertEquals(listOf(BeamioBusyRejectQueue.Waiting("b", "sb", "busy")), q.ownCallEnded())
        assertEquals(0, q.waitingCount)
    }

    @Test
    fun lateOfferGoesOutWhenItResolvesDuringOurCall() {
        val q = BeamioBusyRejectQueue<Offer>()
        q.busyCallArrived("b", "sb", "busy", null)
        assertNull(q.offerResolved("other", ""))
        // Found by the session id as well as the call id.
        assertEquals(BeamioBusyRejectQueue.Waiting("b", "sb", "busy"), q.offerResolved("", "sb"))
        assertEquals(emptyList<BeamioBusyRejectQueue.Waiting>(), q.ownCallEnded())
    }

    @Test
    fun theSameBusyCallWaitsOnce() {
        val q = BeamioBusyRejectQueue<Offer>()
        q.busyCallArrived("b", "sb", "busy", null)
        q.busyCallArrived("b", "sb", "busy", null)
        assertEquals(1, q.waitingCount)
        // Resolved on the repeat: sent now and no longer waiting.
        assertEquals(Offer("b"), sentNow(q.busyCallArrived("b", "sb", "busy", Offer("b"))))
        assertEquals(0, q.waitingCount)
    }

    /** RC3b b1 (iOS, same rule here): the same call seen twice gets one reject. */
    @Test
    fun theSameCallGetsOneRejectOnly() {
        val q = BeamioBusyRejectQueue<Offer>()
        assertEquals(Offer("b"), sentNow(q.busyCallArrived("b", "sb", "busy", Offer("b"))))
        assertEquals(BeamioBusyRejectQueue.Decision.AlreadySent, q.busyCallArrived("b", "sb", "busy", null))
        assertEquals(BeamioBusyRejectQueue.Decision.AlreadySent, q.busyCallArrived("", "sb", "busy", Offer("b")))
        assertEquals(0, q.waitingCount)
        assertTrue(q.ownCallEnded().isEmpty())
        q.busyCallArrived("c", "sc", "busy", null)
        q.offerResolved("c", "sc")
        assertEquals(BeamioBusyRejectQueue.Decision.AlreadySent, q.busyCallArrived("c", "sc", "busy", Offer("c")))
        q.busyCallArrived("d", "sd", "busy", null)
        q.ownCallEnded()
        assertEquals(BeamioBusyRejectQueue.Decision.AlreadySent, q.busyCallArrived("d", "", "busy", null))
    }

    @Test
    fun sentMemoryIsBounded() {
        val q = BeamioBusyRejectQueue<Offer>()
        for (i in 0 until 100) q.busyCallArrived("c$i", "", "busy", Offer("o"))
        assertEquals(BeamioBusyRejectQueue.SENT_MEMORY, q.sentCount)
        assertTrue(q.wasSent("c99", ""))
        assertFalse(q.wasSent("c0", ""))
    }
}
