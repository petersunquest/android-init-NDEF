package com.beamio.app

/**
 * Dialer wake receipt rules (`voice_call_ringing_v1`). Pure, for unit tests.
 *
 * - 8 s without a receipt: "Their phone may be restricting Beamio"; the call
 *   keeps ringing ([BeamioNativeVoiceSignaling.PEER_WAKE_TIMEOUT_MS]).
 * - Five ringback rings without one: "Unreachable", the dialer posts its
 *   cancel and ends the call. A receipt after that is ignored.
 *
 * The ringback is the platform `TONE_SUP_RINGTONE`, whose cadence follows the
 * network (else SIM) country the way AOSP `ToneGenerator` picks its region.
 * The browser and iOS play 1 s on / 4 s off: five rings = 25 s. To stay within
 * a few seconds of them, the Android time is kept between 20 and 30 s.
 */
object BeamioDialerReceiptRule {
    const val RINGS = 5
    const val MIN_UNREACHABLE_MS = 20_000L
    const val MAX_UNREACHABLE_MS = 30_000L

    /** One ring cycle (on + off) of the platform ringback for this country (ISO 3166 alpha-2). */
    fun ringCycleMs(countryIso: String?): Long = when (countryIso.orEmpty().trim().lowercase()) {
        // ANSI: 440+480 Hz, 2 s on / 4 s off.
        "us", "ca" -> 6_000L
        // Japan: 400 Hz, 1 s on / 2 s off.
        "jp" -> 3_000L
        // Double ring 0.4 / 0.2 / 0.4 s on, 2 s off.
        "gb", "au", "ie", "sg", "in" -> 3_000L
        // Hong Kong: double ring, 3 s off.
        "hk" -> 4_000L
        // CEPT (everywhere else): 425 Hz, 1 s on / 4 s off.
        else -> 5_000L
    }

    /** Five rings of the local ringback, from the offer's `createdAt`, kept in 20–30 s. */
    fun unreachableAfterMs(countryIso: String?): Long =
        (ringCycleMs(countryIso) * RINGS).coerceIn(MIN_UNREACHABLE_MS, MAX_UNREACHABLE_MS)

    /**
     * Five rings ended: end as unreachable only while the dial still rings (no
     * accept, decline, hang-up or timeout yet) and no receipt came.
     */
    fun endsUnreachable(stillRinging: Boolean, rang: Boolean): Boolean = stillRinging && !rang

    /** Delay from [nowMs] until [afterMs] past [createdAtMs]; 0 when already past. */
    fun delayMs(createdAtMs: Long, nowMs: Long, afterMs: Long): Long =
        (createdAtMs + afterMs - nowMs).coerceAtLeast(0L)
}
