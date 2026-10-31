package com.beamio.app

import android.util.Log

/**
 * Outgoing call timing trail (`CallTiming` tag), matching the PWA's
 * `[CallTiming]` lines. Each line carries wall-clock milliseconds so PWA and
 * native stages line up in logcat. Never logs keys, routes, addresses or
 * message content.
 */
object BeamioCallTiming {
    private const val TAG = "CallTiming"

    @Volatile private var dialId = ""
    @Volatile private var tapAt = 0L

    /** The PWA sent `prepareSystemCall` with its dial id and tap time. */
    fun begin(dialId: String, tapAt: Long) {
        this.dialId = dialId
        this.tapAt = tapAt
    }

    fun mark(stage: String, extra: String = "") {
        val id = dialId
        if (id.isEmpty()) return
        val now = System.currentTimeMillis()
        val since = if (tapAt > 0L) "+${now - tapAt}" else "+?"
        Log.i(TAG, "[CallTiming] $id native:$stage t=$now $since${if (extra.isEmpty()) "" else " $extra"}")
        // The dial's last stage: later calls must not log under this dial id.
        if (stage == "listen-open" || stage == "prepare-cancelled") {
            if (dialId == id) dialId = ""
        }
    }
}
