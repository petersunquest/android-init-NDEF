package com.beamio.app

/**
 * Busy callee: a second call arrives while we are in a call (or another call
 * rings here). Its caller must get `voice_call_reject_v1` reason=busy at once,
 * so it hears the busy tone and sees "On another call" while it still dials.
 *
 * The reject is sealed with the same [BeamioOpenPgpHost] the dialer cancel
 * already uses during a live call, so it no longer waits for our own call to
 * end. Only an offer that is not resolved yet waits: it goes out when the
 * offer resolves, or when our call ends (either side hangs up), whichever
 * comes first. Each call gets one busy reject (the same call can be seen
 * twice). Pure: no Android types, so it can be unit-tested.
 */
class BeamioBusyRejectQueue<Offer> {
    data class Waiting(val callId: String, val sessionId: String, val reason: String)

    sealed class Decision<out O> {
        /** Send the busy reject for this offer now. */
        data class SendNow<O>(val offer: O) : Decision<O>()
        /** The offer is not resolved yet: it waits for the resolve or our call's end. */
        object Wait : Decision<Nothing>()
        /** This call already got its busy reject: nothing to send. */
        object AlreadySent : Decision<Nothing>()
    }

    private val waiting = mutableListOf<Waiting>()
    /** Call and session ids that already got a busy reject (newest last). */
    private val sent = ArrayDeque<String>()

    val waitingCount: Int get() = waiting.size
    val sentCount: Int get() = sent.size

    /** A busy call arrived. */
    fun busyCallArrived(callId: String, sessionId: String, reason: String, resolved: Offer?): Decision<Offer> {
        if (wasSent(callId, sessionId)) {
            waiting.removeAll { it.matches(callId, sessionId) }
            return Decision.AlreadySent
        }
        if (resolved != null) {
            waiting.removeAll { it.matches(callId, sessionId) }
            markSent(callId, sessionId)
            return Decision.SendNow(resolved)
        }
        if (waiting.none { it.matches(callId, sessionId) && it.reason == reason }) {
            waiting.add(Waiting(callId, sessionId, reason))
        }
        return Decision.Wait
    }

    /** An offer resolved: when its busy reject was waiting, take it to send now. */
    fun offerResolved(callId: String, sessionId: String): Waiting? {
        val hit = waiting.firstOrNull { it.matches(callId, sessionId) } ?: return null
        waiting.remove(hit)
        markSent(hit.callId, hit.sessionId)
        markSent(callId, sessionId)
        return hit
    }

    /** Our own call ended (we or the peer hung up): everything still waiting goes now. */
    fun ownCallEnded(): List<Waiting> {
        val all = waiting.toList()
        waiting.clear()
        all.forEach { markSent(it.callId, it.sessionId) }
        return all
    }

    fun wasSent(callId: String, sessionId: String): Boolean =
        (callId.isNotBlank() && callId in sent) || (sessionId.isNotBlank() && sessionId in sent)

    private fun markSent(callId: String, sessionId: String) {
        for (id in listOf(callId, sessionId)) {
            if (id.isNotBlank() && id !in sent) sent.addLast(id)
        }
        while (sent.size > SENT_MEMORY) sent.removeFirst()
    }

    private fun Waiting.matches(id: String, session: String): Boolean =
        (id.isNotBlank() && (callId == id || sessionId == id)) ||
            (session.isNotBlank() && (sessionId == session || callId == session))

    companion object {
        const val SENT_MEMORY = 64
    }
}
