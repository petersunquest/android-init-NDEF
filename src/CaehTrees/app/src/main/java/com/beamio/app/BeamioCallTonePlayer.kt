package com.beamio.app

import android.media.AudioManager
import android.media.ToneGenerator
import android.os.Handler
import android.os.Looper
import android.util.Log

/**
 * Ringback tone for the dialer ("calling the other side" beeps), same role
 * as the iOS shell's `BeamioCallTonePlayer`.
 *
 * Uses the platform [ToneGenerator] supervisory ringtone (`TONE_SUP_RINGTONE`:
 * 425 Hz 1 s on / 4 s off, or the local variant for the SIM country), so there
 * is no audio file. It plays on the voice-call stream, which follows the
 * Telecom call route (earpiece, speaker, Bluetooth).
 *
 * Plays only while [InCallScreenModel] shows an outgoing call that is not
 * connected, and only after Telecom created the DIALING connection (so the
 * call audio mode is set). Stops on Accept ([BeamioNativeVoiceChannel.enableMedia],
 * before any AudioRecord / AudioTrack opens), on [InCallScreenModel.markConnected],
 * on [InCallScreenModel.end], and when the Telecom connection leaves DIALING.
 */
object BeamioCallTonePlayer {
    private const val TAG = "BeamioCallTone"
    /** Relative to the voice-call stream volume (0..100). */
    private const val VOLUME = 60
    /** Telecom switches the audio mode right after DIALING; start after that. */
    private const val START_DELAY_MS = 250L

    private val lock = Any()
    private val main = Handler(Looper.getMainLooper())
    private var tone: ToneGenerator? = null
    /** Voice media started for this dial: no ringback until the next dial. */
    private var mediaStarted = false

    /** A new dial (or no call): allow the ringback again. */
    fun resetForNewDial() {
        synchronized(lock) { mediaStarted = false }
    }

    /** The outgoing Telecom connection is DIALING. */
    fun onOutgoingConnectionDialing() {
        main.postDelayed({ startIfDialing("telecom-dialing") }, START_DELAY_MS)
    }

    private fun startIfDialing(reason: String) {
        synchronized(lock) {
            if (tone != null || mediaStarted) return
            if (!InCallScreenModel.isLive() || InCallScreenModel.isConnected()) return
            val generator = runCatching { ToneGenerator(AudioManager.STREAM_VOICE_CALL, VOLUME) }
                .onFailure { Log.w(TAG, "ringback ToneGenerator failed: ${it.message}") }
                .getOrNull() ?: return
            if (!generator.startTone(ToneGenerator.TONE_SUP_RINGTONE)) {
                generator.release()
                Log.w(TAG, "ringback startTone refused reason=$reason")
                return
            }
            tone = generator
            Log.i(TAG, "ringback start reason=$reason")
        }
    }

    /**
     * Stop now. [mediaStarting] = the voice channel is about to open the mic and
     * speaker for this call: keep the ringback off until the next dial.
     */
    fun stopRingback(reason: String, mediaStarting: Boolean = false) {
        synchronized(lock) {
            if (mediaStarting) mediaStarted = true
            val generator = tone ?: return
            tone = null
            runCatching {
                generator.stopTone()
                generator.release()
            }
            Log.i(TAG, "ringback stop reason=$reason")
        }
    }
}
