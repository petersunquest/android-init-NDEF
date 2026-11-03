package com.beamio.app

import java.util.concurrent.ConcurrentHashMap

/**
 * Decides what an FCM call wake may do before anything rings.
 *
 * The push carries the ring window's end (`expiresAt`, set by the caller to
 * dial time + 3 min) and FCM's send time. A push delivered after the window is
 * a missed call: no ring. A push delivered late but inside the window may be
 * for a call the caller already cancelled (the cancel is a signed chat message
 * in our mailbox): hold the ring until the mailbox listen has replayed it.
 * A caller-cancel wake (`action=end`) never rings.
 */
object BeamioIncomingPushGate {
    enum class Verdict { RING, HOLD_FOR_MAILBOX, EXPIRED, END }

    /** Same as the PWA ring window (3 min) plus its 15 s slack for clock skew. */
    const val RING_WINDOW_MS = 195_000L
    /** Normal pushes arrive in under 1.5 s; later than this, check the mailbox first. */
    const val LATE_PUSH_MS = 5_000L
    /** Longest the ring may wait for the mailbox replay on a late push. */
    const val HOLD_MAX_MS = 5_000L
    /** After the listen attaches, time allowed for the replay to deliver a stored cancel. */
    const val HOLD_AFTER_ATTACH_MS = 1_500L

    fun verdict(nowMs: Long, sentAtMs: Long, expiresAtRaw: String?, action: String?): Verdict {
        if (action?.trim()?.equals("end", ignoreCase = true) == true) return Verdict.END
        val expiresAt = normalizeMs(expiresAtRaw)
        if (expiresAt > 0 && expiresAt <= nowMs) return Verdict.EXPIRED
        val age = if (sentAtMs > 0) nowMs - sentAtMs else 0L
        if (age > RING_WINDOW_MS) return Verdict.EXPIRED
        if (age > LATE_PUSH_MS) return Verdict.HOLD_FOR_MAILBOX
        return Verdict.RING
    }

    /** Accept millisecond and Unix-second values. */
    fun normalizeMs(raw: String?): Long {
        val n = raw?.trim()?.toDoubleOrNull() ?: return 0L
        if (!n.isFinite() || n <= 0) return 0L
        return if (n < 100_000_000_000.0) (n * 1000).toLong() else n.toLong()
    }

    /** Call ids a caller-cancel push named (process memory; the push is not signed by the caller). */
    private val endPushAt = ConcurrentHashMap<String, Long>()

    fun noteEndPush(callId: String, sessionId: String, nowMs: Long = System.currentTimeMillis()) {
        listOf(callId, sessionId).map { it.trim() }.filter { it.isNotEmpty() }.forEach { endPushAt[it] = nowMs }
        if (endPushAt.size > 100) {
            val cutoff = nowMs - 10 * 60_000L
            endPushAt.entries.removeIf { it.value < cutoff }
        }
    }

    fun endPushSeen(callId: String, sessionId: String): Boolean =
        listOf(callId, sessionId).map { it.trim() }.any { it.isNotEmpty() && endPushAt.containsKey(it) }

    /**
     * Did an incoming call ring here? true when the ring record has it; false
     * only when the record covers the call's time (started before it, still
     * kept); null when this phone cannot know.
     */
    fun rangAnswer(recorded: Boolean, sinceMs: Long, createdAtMs: Long, nowMs: Long, keepMs: Long): Boolean? {
        if (recorded) return true
        if (sinceMs <= 0L || createdAtMs <= 0L) return null
        if (createdAtMs < sinceMs || createdAtMs < nowMs - keepMs) return null
        return false
    }
}
