package com.beamio.app

import android.content.Context
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

/**
 * Plays the user's system ringtone on its own player.
 * A phone-call foreground notification often suppresses the channel sound,
 * so the lock-screen window cannot rely on the notification channel.
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
    private var playingKey: String = ""

    fun start(context: Context, callKey: String) {
        val app = context.applicationContext
        val key = callKey.trim()
        if (key.isEmpty()) return
        main.post { startOnMain(app, key) }
    }

    fun stop() {
        val run = Runnable { synchronized(lock) { stopLocked() } }
        if (Looper.myLooper() == Looper.getMainLooper()) run.run() else main.post(run)
    }

    private fun startOnMain(app: Context, key: String) {
        synchronized(lock) {
            if (playingKey == key && (player != null || wakeLock != null)) return
            stopLocked()
            appContext = app
            playingKey = key
            val audio = app.getSystemService(AudioManager::class.java)
            if (audio == null) {
                Log.w(TAG, "System ringtone skipped — audio unavailable")
                return
            }
            when (audio.ringerMode) {
                AudioManager.RINGER_MODE_SILENT -> {
                    Log.i(TAG, "System ringtone skipped — ringer silent")
                    return
                }
                AudioManager.RINGER_MODE_VIBRATE -> {
                    holdCpu(app)
                    vibrate(app)
                    Log.i(TAG, "System ringtone vibrate-only")
                    return
                }
            }
            holdCpu(app)
            if (vibrateWhenRinging(app)) vibrate(app)
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
            created.setAudioAttributes(attributes)
            created.isLooping = true
            created.setOnPreparedListener { ready ->
                synchronized(lock) {
                    if (player !== ready || playingKey != key) return@setOnPreparedListener
                    runCatching { ready.start() }
                        .onSuccess { Log.i(TAG, "System ringtone started") }
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
    }

    private fun stopLocked() {
        val app = appContext
        player?.let { active ->
            runCatching { if (active.isPlaying) active.stop() }
            runCatching { active.release() }
        }
        player = null
        if (app != null) {
            abandonFocus(app)
            cancelVibrate(app)
        }
        wakeLock?.let { lock -> if (lock.isHeld) runCatching { lock.release() } }
        wakeLock = null
        playingKey = ""
    }

    private fun holdCpu(app: Context) {
        val power = app.getSystemService(PowerManager::class.java) ?: return
        val cpu = power.newWakeLock(PowerManager.PARTIAL_WAKE_LOCK, "beamio:incoming-ringtone")
        cpu.setReferenceCounted(false)
        cpu.acquire(WAKE_MS)
        wakeLock = cpu
    }

    private fun requestFocus(audio: AudioManager, attributes: AudioAttributes) {
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
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
                vibrator.vibrate(VibrationEffect.createWaveform(pattern, 0))
            } else {
                @Suppress("DEPRECATION")
                vibrator.vibrate(pattern, 0)
            }
        }.onFailure { Log.w(TAG, "Incoming vibrate skipped") }
    }

    private fun cancelVibrate(app: Context) {
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
