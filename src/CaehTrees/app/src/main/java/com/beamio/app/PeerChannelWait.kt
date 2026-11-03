package com.beamio.app

/**
 * The caller sends `channel ready` before its own listen is up, so the callee's
 * first frames can reach the relay before the caller's channel exists. The relay
 * keeps nothing and answers `target_voice_session_not_found`. Until the first
 * frame of the call is accepted, such a frame is posted again to the same entry
 * every 150 ms for up to 3 s. After that the old rule holds: a late frame is
 * dropped. Pure (inputs injected) for the unit test; iOS has the same rule.
 */
object PeerChannelWait {
    const val WAIT_MS = 3_000L
    const val GAP_MS = 150L
    const val NOT_FOUND = "target_voice_session_not_found"

    data class Result(val ok: Boolean, val error: String, val tries: Int)

    fun post(
        seenBefore: Boolean,
        post: () -> Pair<Boolean, String>,
        sleep: (Long) -> Unit,
        now: () -> Long,
        waitMs: Long = WAIT_MS,
        gapMs: Long = GAP_MS,
    ): Result {
        var (ok, error) = post()
        var tries = 1
        if (seenBefore) return Result(ok, error, tries)
        val deadline = now() + waitMs
        while (!ok && error == NOT_FOUND && now() < deadline) {
            sleep(gapMs)
            val next = post()
            ok = next.first
            error = next.second
            tries++
        }
        return Result(ok, error, tries)
    }
}
