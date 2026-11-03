package com.beamio.app

import android.media.AudioManager

/**
 * What the incoming ringtone does, from the phone's sound settings.
 * Pure functions, so the rules are unit-tested off the device.
 */
internal object BeamioRingPolicy {
    enum class Plan { SILENT, VIBRATE_ONLY, RING, RING_AND_VIBRATE }

    /** Same rules as a carrier call: silent mode is quiet, vibrate mode only vibrates. */
    fun plan(ringerMode: Int, vibrateWhenRinging: Boolean): Plan = when (ringerMode) {
        AudioManager.RINGER_MODE_SILENT -> Plan.SILENT
        AudioManager.RINGER_MODE_VIBRATE -> Plan.VIBRATE_ONLY
        else -> if (vibrateWhenRinging) Plan.RING_AND_VIBRATE else Plan.RING
    }

    fun plays(plan: Plan): Boolean = plan == Plan.RING || plan == Plan.RING_AND_VIBRATE

    fun vibrates(plan: Plan): Boolean = plan == Plan.VIBRATE_ONLY || plan == Plan.RING_AND_VIBRATE

    /** Trimmed, non-blank, distinct ids of one call (call id, session id, aliases). */
    fun callKeys(ids: Collection<String>): Set<String> =
        ids.map { it.trim() }.filter { it.isNotEmpty() }.toCollection(LinkedHashSet())

    /** The ids name the call that is ringing now. */
    fun sameCall(ringing: Set<String>, ids: Collection<String>): Boolean {
        if (ringing.isEmpty()) return false
        return callKeys(ids).any { ringing.contains(it) }
    }
}
