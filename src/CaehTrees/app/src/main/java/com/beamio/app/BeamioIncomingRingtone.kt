package com.beamio.app

import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent
import android.content.IntentFilter
import android.media.AudioAttributes
import android.media.AudioFocusRequest
import android.media.AudioManager
import android.media.MediaPlayer
import android.media.RingtoneManager
import android.os.Build
import android.os.Handler
import android.os.Looper
import android.os.PowerManager
import android.os.VibrationEffect
import android.os.Vibrator
import android.os.VibratorManager
import android.provider.Settings
import android.util.Log
import androidx.core.content.ContextCompat

/**
 * The only source of the incoming ringtone. Beamio calls are self-managed, so
 * Telecom never rings for them, and the incoming notification channel is
 * silent (v16) so the two never ring together.
 *
 * Follows the phone's sound mode like a carrier call ([BeamioRingPolicy]):
 * silent mode is quiet, vibrate mode only vibrates, and a mode change while
 * ringing applies at once.
 */
internal object BeamioIncomingRingtone {
    private const val TAG = "BeamioVoiceCall"
    private const val WAKE_MS = 180_000L
    private val main = Handler(Looper.getMainLooper())
    private val lock = Any()
    private var appContext: Context? = null
    private var player: MediaPlayer? = null
    private var wakeLock: PowerManager.WakeLock? = null
    private var focusRequest: AudioFocusRequest? = null
    private var vibrating = false
    private var modeReceiver: BroadcastReceiver? = null
    /** Ids of the call that rings now; empty when nothing rings. */
    private var ringingKeys: Set<String> = emptySet()

    /**
     * Ring for one call. [ids] are its call id, session id and aliases.
     * [stillRinging] is checked again on the main thread, so a call that ended
     * between this call and the start never rings.
     * Start and stop both run in post order on the main thread.
     */
    fun start(context: Context, ids: Collection<String>, stillRinging: () -> Boolean = { true }) {
        val app = context.applicationContext
        val keys = BeamioRingPolicy.callKeys(ids)
        if (keys.isEmpty()) return
        main.post { startOnMain(app, keys, stillRinging) }
    }

    /** Stop only if [ids] name the call that rings now (another call's end leaves it). */
    fun stopFor(ids: Collection<String>, reason: String) {
        val keys = BeamioRingPolicy.callKeys(ids)
        main.post {
            synchronized(lock) {
                if (BeamioRingPolicy.sameCall(ringingKeys, keys)) stopLocked(reason)
            }
        }
    }

    /** Stop whatever rings. */
    fun stop(reason: String = "stop") {
        main.post { synchronized(lock) { stopLocked(reason) } }
    }

    private fun startOnMain(app: Context, keys: Set<String>, stillRinging: () -> Boolean) {
        synchronized(lock) {
            if (!runCatching(stillRinging).getOrDefault(false)) {
                Log.i(TAG, "System ringtone not started; call already closed or muted")
                return
            }
            if (BeamioRingPolicy.sameCall(ringingKeys, keys)) {
                ringingKeys = ringingKeys + keys
                return
            }
            stopLocked("replaced")
            appContext = app
            ringingKeys = keys
            watchRingerMode(app)
            applyPlanLocked(app)
        }
    }

    /** (Re)start sound and vibration for the current sound mode. */
    private fun applyPlanLocked(app: Context) {
        releasePlayerLocked()
        cancelVibrate(app)
        val audio = app.getSystemService(AudioManager::class.java)
        if (audio == null) {
            Log.w(TAG, "System ringtone skipped — audio unavailable")
            return
        }
        val plan = BeamioRingPolicy.plan(audio.ringerMode, vibrateWhenRinging(app))
        if (plan == BeamioRingPolicy.Plan.SILENT) {
            releaseCpu()
            Log.i(TAG, "System ringtone skipped — ringer silent")
            return
        }
        holdCpu(app)
        if (BeamioRingPolicy.vibrates(plan)) vibrate(app)
        if (!BeamioRingPolicy.plays(plan)) {
            Log.i(TAG, "System ringtone vibrate-only")
            return
        }
        val uri = RingtoneManager.getActualDefaultRingtoneUri(app, RingtoneManager.TYPE_RINGTONE)
            ?: RingtoneManager.getDefaultUri(RingtoneManager.TYPE_RINGTONE)
        if (uri == null) {
            Log.w(TAG, "System ringtone unavailable")
            return
        }
        val attributes = AudioAttributes.Builder()
            .setUsage(AudioAttributes.USAGE_NOTIFICATION_RINGTONE)
            .setContentType(AudioAttributes.CONTENT_TYPE_SONIFICATION)
            .build()
        requestFocus(audio, attributes)
        val created = MediaPlayer()
        player = created
        val keys = ringingKeys
        created.setAudioAttributes(attributes)
        created.isLooping = true
        created.setOnPreparedListener { ready ->
            synchronized(lock) {
                if (player !== ready || ringingKeys != keys) return@setOnPreparedListener
                runCatching { ready.start() }
                    .onSuccess {
                        Log.i(TAG, "System ringtone started plan=$plan ringVolume=${audio.getStreamVolume(AudioManager.STREAM_RING)}")
                    }
                    .onFailure { Log.w(TAG, "System ringtone start failed") }
            }
        }
        created.setOnErrorListener { _, _, _ ->
            Log.w(TAG, "System ringtone error")
            true
        }
        runCatching {
            created.setDataSource(app, uri)
            created.prepareAsync()
        }.onFailure {
            Log.w(TAG, "System ringtone unavailable")
            created.release()
            if (player === created) player = null
        }
    }

    private fun stopLocked(reason: String) {
        val wasRinging = ringingKeys.isNotEmpty()
        val app = appContext
        releasePlayerLocked()
        if (app != null) {
            abandonFocus(app)
            cancelVibrate(app)
            unwatchRingerMode(app)
        }
        releaseCpu()
        ringingKeys = emptySet()
        if (wasRinging) Log.i(TAG, "System ringtone stopped reason=$reason")
    }

    private fun releasePlayerLocked() {
        player?.let { active ->
            runCatching { if (active.isPlaying) active.stop() }
            runCatching { active.release() }
        }
        player = null
    }

    /** Silent / vibrate / sound switched while ringing: follow it at once. */
    private fun watchRingerMode(app: Context) {
        if (modeReceiver != null) return
        val receiver = object : BroadcastReceiver() {
            override fun onReceive(context: Context, intent: Intent) {
                // RINGER_MODE_CHANGED is sticky: registering delivers the current
                // mode at once. The plan was just applied for it — skip, or the
                // player is torn down and rebuilt right after it starts.
                if (isInitialStickyBroadcast) return
                synchronized(lock) {
                    if (ringingKeys.isEmpty()) return
                    Log.i(TAG, "System ringtone follows ringer mode change")
                    applyPlanLocked(app)
                }
            }
        }
        runCatching {
            ContextCompat.registerReceiver(
                app,
                receiver,
                IntentFilter(AudioManager.RINGER_MODE_CHANGED_ACTION),
                ContextCompat.RECEIVER_NOT_EXPORTED,
            )
            modeReceiver = receiver
        }.onFailure { Log.w(TAG, "Ringer mode watch unavailable") }
    }

    private fun unwatchRingerMode(app: Context) {
        val receiver = modeReceiver ?: return
        modeReceiver = null
        runCatching { app.unregisterReceiver(receiver) }
    }

    private fun holdCpu(app: Context) {
        if (wakeLock?.isHeld == true) return
        val power = app.getSystemService(PowerManager::class.java) ?: return
        val cpu = power.newWakeLock(PowerManager.PARTIAL_WAKE_LOCK, "beamio:incoming-ringtone")
        cpu.setReferenceCounted(false)
        cpu.acquire(WAKE_MS)
        wakeLock = cpu
    }

    private fun releaseCpu() {
        wakeLock?.let { held -> if (held.isHeld) runCatching { held.release() } }
        wakeLock = null
    }

    private fun requestFocus(audio: AudioManager, attributes: AudioAttributes) {
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
            if (focusRequest != null) return
            val request = AudioFocusRequest.Builder(AudioManager.AUDIOFOCUS_GAIN_TRANSIENT)
                .setAudioAttributes(attributes)
                .setAcceptsDelayedFocusGain(false)
                .build()
            focusRequest = request
            audio.requestAudioFocus(request)
        } else {
            @Suppress("DEPRECATION")
            audio.requestAudioFocus(
                null,
                AudioManager.STREAM_RING,
                AudioManager.AUDIOFOCUS_GAIN_TRANSIENT,
            )
        }
    }

    private fun abandonFocus(app: Context) {
        val audio = app.getSystemService(AudioManager::class.java) ?: return
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
            focusRequest?.let { runCatching { audio.abandonAudioFocusRequest(it) } }
            focusRequest = null
        } else {
            @Suppress("DEPRECATION")
            audio.abandonAudioFocus(null)
        }
    }

    private fun vibrateWhenRinging(app: Context): Boolean {
        return runCatching {
            Settings.System.getInt(app.contentResolver, Settings.System.VIBRATE_WHEN_RINGING, 0) == 1
        }.getOrDefault(false)
    }

    private fun vibrate(app: Context) {
        val pattern = longArrayOf(0, 800, 600)
        runCatching {
            val vibrator = vibrator(app) ?: return
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
                val ringAttrs = AudioAttributes.Builder()
                    .setUsage(AudioAttributes.USAGE_NOTIFICATION_RINGTONE)
                    .build()
                @Suppress("DEPRECATION")
                vibrator.vibrate(VibrationEffect.createWaveform(pattern, 0), ringAttrs)
            } else {
                @Suppress("DEPRECATION")
                vibrator.vibrate(pattern, 0)
            }
            vibrating = true
        }.onFailure { Log.w(TAG, "Incoming vibrate skipped") }
    }

    private fun cancelVibrate(app: Context) {
        if (!vibrating) return
        vibrating = false
        runCatching { vibrator(app)?.cancel() }
    }

    private fun vibrator(app: Context): Vibrator? {
        return if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.S) {
            app.getSystemService(VibratorManager::class.java)?.defaultVibrator
        } else {
            @Suppress("DEPRECATION")
            app.getSystemService(Vibrator::class.java)
        }
    }
}
