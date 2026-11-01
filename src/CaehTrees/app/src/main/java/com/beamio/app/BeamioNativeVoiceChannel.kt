package com.beamio.app
import network.conet.chat.BeamioOpenPgpHost
import network.conet.chat.BeamioSiCipherPost
import network.conet.chat.BeamioChatPgpStore

import android.Manifest
import android.content.Context
import android.content.pm.PackageManager
import android.media.AudioAttributes
import android.media.AudioFormat
import android.media.AudioRecord
import android.media.AudioTrack
import android.media.MediaRecorder
import android.os.Handler
import android.os.Looper
import android.util.Log
import androidx.core.content.ContextCompat
import org.json.JSONObject
import java.io.BufferedInputStream
import java.io.OutputStreamWriter
import java.net.HttpURLConnection
import java.net.URL
import java.util.concurrent.Executors
import java.util.concurrent.atomic.AtomicBoolean
import java.util.concurrent.atomic.AtomicInteger
import java.util.concurrent.atomic.AtomicReference

/**
 * Native temporary voice relay: `voice_listen` SSE + AES PCM uplink/downlink,
 * plus in-call video as JPEG frames. Wire format matches iOS
 * `BeamioNativeVoiceChannel` and the PWA:
 * - audio: `BPCM` + u32-LE sample rate + int16-LE mono PCM
 * - video: `BJPG` + u16-LE width + u16-LE height + u32-LE frameId + JPEG
 * - control: AES JSON (`voice_video_enable_v1` / `voice_video_disable_v1`, …)
 * All three share one uplink `seq` counter.
 * No PWA — EncryptedSharedPreferences route PGP + `BeamioSiCipherPost` entry path.
 */
object BeamioNativeVoiceChannel {
    private const val TAG = "BeamioNativeVoiceCh"
    private const val SAMPLE_RATE = 16_000
    /**
     * 160 ms per packet: each packet costs a route-PGP encrypt plus a relay POST,
     * so 80 ms packets could not be sent in real time (≈40 % dropped).
     */
    private const val UPLINK_FRAME_MS = 160
    private const val UPLINK_FRAME_BYTES = SAMPLE_RATE * UPLINK_FRAME_MS / 1000 * 2
    /** Playout depth before audio starts, and again after an underrun. */
    private const val PLAYOUT_TARGET_BYTES = SAMPLE_RATE * 2 * 320 / 1000
    /**
     * Adaptive depth (industry-style adaptive jitter buffer): every underrun adds
     * 160 ms up to 800 ms; 10 s without one takes 80 ms back. Frames arrive
     * through a different random entry each time, so arrival spread can exceed
     * a fixed 320 ms.
     */
    private const val PLAYOUT_MAX_TARGET_BYTES = SAMPLE_RATE * 2 * 800 / 1000
    private const val PLAYOUT_STEP_UP_BYTES = SAMPLE_RATE * 2 * 160 / 1000
    private const val PLAYOUT_STEP_DOWN_BYTES = SAMPLE_RATE * 2 * 80 / 1000
    private const val PLAYOUT_DECAY_MS = 10_000L
    /** Latency cap stays this far above the current depth. */
    private const val PLAYOUT_CAP_HEADROOM_BYTES = SAMPLE_RATE * 2 * 400 / 1000
    /** Fade-in after a gap or underrun so the restart does not click. */
    private const val FADE_SAMPLES = SAMPLE_RATE * 5 / 1000
    /** Missing frames filled with silence at most (keeps timing without long holes). */
    private const val MAX_CONCEAL_FRAMES = 2
    /** The track counts as dry when less than 20 ms of written audio is left. */
    private const val UNDERRUN_GUARD_FRAMES = SAMPLE_RATE * 20 / 1000
    /** Video is shown this long after its earliest possible arrival (≈ audio delay). */
    private const val VIDEO_PLAYOUT_DELAY_MS = 300L
    private const val RX_MAX_PENDING = 48
    private val PCM_MAGIC = byteArrayOf(0x42, 0x50, 0x43, 0x4D) // "BPCM"
    private val JPG_MAGIC = byteArrayOf(0x42, 0x4A, 0x50, 0x47) // "BJPG"
    /**
     * Video v2: `BJP2` + u16-LE width + u16-LE height + u32-LE frameId + u64-LE
     * capture time (Unix ms) + JPEG. The relay drops every outer field except
     * seq/timestamp/payload, so the capture time rides inside the AES payload.
     */
    private val JP2_MAGIC = byteArrayOf(0x42, 0x4A, 0x50, 0x32) // "BJP2"
    /** Media capability announced in `voice_media_caps_v1` (2 = split-seq video + BJP2). */
    private const val LOCAL_VIDEO_CAPS = 2
    /**
     * Split-seq video frames use seq ≥ this. Audio and controls count up from 1,
     * so the ranges never meet: a lost or late video frame no longer stalls audio.
     */
    const val VIDEO_SEQ_BASE = 1_000_000_000
    private const val MAX_VIDEO_IN_FLIGHT = 2
    private const val MAX_AUDIO_IN_FLIGHT = 10
    /** Reachable entries kept per call; each frame picks one at random. */
    private const val ENTRY_POOL_TARGET = 6
    /** Refill in the background when the pool falls below this. */
    private const val ENTRY_POOL_MIN = 3
    private const val FAILED_ENTRY_COOLDOWN_MS = 60_000L
    /** An entry whose average post time exceeds this leaves the pool. */
    private const val SLOW_ENTRY_MS = 600.0
    private const val SLOW_ENTRY_MIN_SAMPLES = 3
    /**
     * Largest audio packet when the sender is behind (~250 ms). The SI relay
     * rejects a frame whose base64 payload exceeds 12 000 chars (≈ 8.9 KB raw),
     * answering `invalid_voice_frame`.
     */
    private const val MAX_PACKET_BYTES = 8_000
    private val io = Executors.newCachedThreadPool()

    // ---- Link health (in-call reconnect / connection lost) ----
    // The media SSE can drop mid-call (entry restart, network switch). Once
    // media runs, a 1 s watchdog reopens `voice_listen` on the same sessionId
    // through a new random entry (backoff 1/2/4/8 s; voice_unlisten first when
    // the node still holds the old socket). Only the session capability goes
    // out: no wallet, no signature, no wake fields (no re-ring). No peer frame
    // AND no accepted uplink for LINK_LOST_LIMIT_MS ends the call.
    private const val RX_STALE_RECONNECT_MS = 8_000L
    private const val MEDIA_START_GRACE_MS = 12_000L
    const val LINK_LOST_LIMIT_MS = 25_000L
    private const val MUTED_KEEPALIVE_MS = 1_000L
    private const val V2_PAUSE_MS = 2_000L
    private val linkTimer = Executors.newSingleThreadScheduledExecutor()
    @Volatile private var linkTask: java.util.concurrent.ScheduledFuture<*>? = null
    private val listenGen = AtomicInteger(0)
    private val listenAlive = AtomicBoolean(false)
    private val reconnectInFlight = AtomicBoolean(false)
    @Volatile private var mediaStartedAt = 0L
    @Volatile private var lastRxAt = 0L
    @Volatile private var lastTxOkAt = 0L
    @Volatile private var reconnecting = false
    @Volatile private var reconnectAttempt = 0
    @Volatile private var nextReconnectAt = 0L
    @Volatile private var linkLostFired = false
    @Volatile private var lastListenEntry: String? = null
    @Volatile private var lastKeepaliveAt = 0L
    private val rxHandler = Handler(Looper.getMainLooper())
    private val running = AtomicBoolean(false)
    private val mediaLive = AtomicBoolean(false)
    private val uplinkSeq = AtomicInteger(1)
    private val uplinkInFlight = AtomicBoolean(false)
    private val uplinkPostOk = AtomicInteger(0)

    /** Per-call audio uplink tally, [0] = v1 frames, [1] = v2 chunks (bytes on the wire, timing). */
    private class WireTally {
        var n = 0
        var fail = 0
        var bytes = 0L
        var encMs = 0L
        var postMs = 0L
        var postMax = 0L
        fun line(): String {
            val d = n.coerceAtLeast(1)
            return "n=$n fail=$fail avgB=${bytes / d} encAvg=${encMs / d}ms postAvg=${postMs / d}ms postMax=${postMax}ms"
        }
    }
    private val audioTally = arrayOf(WireTally(), WireTally())
    private val uplinkDrop = AtomicInteger(0)
    private val activeRef = AtomicReference<BeamioNativeVoiceSignaling.ActiveCall?>(null)
    private val appCtx = AtomicReference<Context?>(null)
    private var listenConn: HttpURLConnection? = null
    private var audioRecord: AudioRecord? = null
    private var audioTrack: AudioTrack? = null
    private val captureStarted = AtomicBoolean(false)
    private val captureMuted = AtomicBoolean(false)
    private val pcmPendingLock = Any()
    private var pcmPending = ByteArray(0)
    private val rxLock = Any()
    private var rxNextSeq: Int? = null
    private val rxPendingPcm = HashMap<Int, ByteArray>()
    private var rxJitterRunnable: Runnable? = null

    /** Peer route crypto, resolved once per call and shared by audio, video and control. */
    private class UplinkRoute(
        val routeArmored: String,
        val roster: List<BeamioChatPgpStore.SiNode>,
        val exclude: Set<String>,
        /** Each frame goes to a different random entry (CoNET Chat: random entry per delivery). */
        val entries: EntryRotation,
    )

    /**
     * Probed, reachable entries for this call. [next] returns a random one that
     * differs from the previous pick, without probing (a per-frame probe made
     * frames late). Failed entries leave the pool for [FAILED_ENTRY_COOLDOWN_MS].
     */
    private class EntryRotation(first: String) {
        private val lock = Any()
        private val healthy = ArrayList<String>().apply { add(first) }
        private val failedUntil = HashMap<String, Long>()
        private var last: String? = null

        fun next(): String? = synchronized(lock) {
            if (healthy.isEmpty()) return null
            val choices = if (healthy.size > 1) healthy.filter { it != last } else healthy
            val pick = choices.random()
            last = pick
            pick
        }

        fun add(ip: String) = synchronized(lock) {
            val until = failedUntil[ip]
            if (until != null && until > System.currentTimeMillis()) return@synchronized
            if (ip !in healthy) healthy.add(ip)
        }

        fun markFailed(ip: String) = synchronized(lock) {
            healthy.remove(ip)
            latencyEwma.remove(ip)
            samples.remove(ip)
            failedUntil[ip] = System.currentTimeMillis() + FAILED_ENTRY_COOLDOWN_MS
        }

        private val latencyEwma = HashMap<String, Double>()
        private val samples = HashMap<String, Int>()

        /**
         * Record one post time. A slow entry makes its frames late and drains the
         * peer's playout buffer, so it leaves the pool like an unreachable one.
         * Returns true when [ip] was dropped as slow.
         */
        fun recordLatency(ip: String, ms: Long): Boolean = synchronized(lock) {
            if (ip !in healthy) return@synchronized false
            val prev = latencyEwma[ip]
            val next = if (prev == null) ms.toDouble() else prev * 0.7 + ms * 0.3
            latencyEwma[ip] = next
            val n = (samples[ip] ?: 0) + 1
            samples[ip] = n
            if (n >= SLOW_ENTRY_MIN_SAMPLES && next > SLOW_ENTRY_MS && healthy.size > 1) {
                healthy.remove(ip)
                latencyEwma.remove(ip)
                samples.remove(ip)
                failedUntil[ip] = System.currentTimeMillis() + FAILED_ENTRY_COOLDOWN_MS
                true
            } else {
                false
            }
        }

        fun size(): Int = synchronized(lock) { healthy.size }

        /** Entries to skip when probing for more: in the pool or cooling down. */
        fun known(): Set<String> = synchronized(lock) {
            val now = System.currentTimeMillis()
            healthy.toSet() + failedUntil.filterValues { it > now }.keys
        }
    }
    private val entryRefillRunning = AtomicBoolean(false)
    private val uplinkFailStreak = AtomicInteger(0)
    private val uplinkRoute = AtomicReference<UplinkRoute?>(null)
    private val uplinkRouteResolving = AtomicBoolean(false)
    private val videoInFlight = AtomicInteger(0)
    private val audioInFlight = AtomicInteger(0)
    private val videoFrameId = AtomicInteger(0)
    /** Peer's announced video capability (0 until `voice_media_caps_v1` arrives). */
    private val peerVideoCaps = AtomicInteger(0)
    private val capsSent = AtomicInteger(0)
    private val videoSeqOffset = AtomicInteger(0)
    private val stats = BeamioVideoStats()
    /**
     * QA switch for before/after runs: when `files/beamio-video-legacy` exists
     * (`adb shell run-as com.beamio.app touch files/beamio-video-legacy`), calls
     * use the previous behaviour (no caps, shared-seq BJPG) while `[VideoStats]`
     * still logs. Read once per call.
     */
    @Volatile private var legacyMode = false

    // Voice channel v2: the node sees only `CVC2 ‖ locator ‖ mac ‖ blob` per chunk.
    /** Write key registered with our own voice_listen; the peer learns it from caps. */
    @Volatile private var ownWriteKey = ByteArray(0)
    /** Our node answered voice_ready with `v: 2`. */
    private val ownChanV2 = AtomicBoolean(false)
    /** Peer's v2 channel once its caps said `chan: 2`. */
    private val peerV2 = AtomicReference<BeamioVoiceChannelV2.Peer?>(null)
    /** A v2 chunk was refused: the rest of the call uses v1. */
    private val v2Disabled = AtomicBoolean(false)
    /**
     * `target_voice_session_not_found`: the peer's listen is down (reconnecting)
     * or reopened without v2. Frames go as v1 until this time, then v2 again;
     * the peer re-listens with the same write key.
     */
    @Volatile private var v2PausedUntil = 0L
    private val v2TxOk = AtomicInteger(0)
    private val v2Rx = AtomicInteger(0)
    private val statsUnderrunsSeen = AtomicInteger(0)

    /** Soft mute: keep AudioRecord running but skip AES uplink frames. */
    fun setCaptureMuted(muted: Boolean) {
        captureMuted.set(muted)
        Log.i(TAG, "captureMuted=$muted")
    }

    fun isRunning(): Boolean = running.get()

    fun start(context: Context, active: BeamioNativeVoiceSignaling.ActiveCall) {
        val app = context.applicationContext
        appCtx.set(app)
        stopInternal(keepApp = true)
        legacyMode = java.io.File(app.filesDir, "beamio-video-legacy").exists()
        if (legacyMode) Log.i(TAG, "QA legacy video mode")
        activeRef.set(active)
        running.set(true)
        mediaLive.set(active.mediaEnabled)
        uplinkSeq.set(1)
        uplinkInFlight.set(false)
        uplinkPostOk.set(0)
        uplinkDrop.set(0)
        synchronized(audioTally) { audioTally[0] = WireTally(); audioTally[1] = WireTally() }
        synchronized(pcmPendingLock) { pcmPending = ByteArray(0) }
        resetRxJitter()
        resetVideoState()
        ownWriteKey = BeamioVoiceChannelV2.randomWriteKey()
        captureStarted.set(false)
        captureMuted.set(false)
        Log.i(
            TAG,
            "start role=${active.role} callId=${active.offer.callId.take(12)} listen=${active.listenSessionId.take(12)} peerMedia=${active.peerMediaSessionId.take(12)} media=${active.mediaEnabled}",
        )
        val gen = listenGen.incrementAndGet()
        io.execute { startVoiceListen(app, active, reconnect = false, gen = gen) }
        if (active.mediaEnabled) {
            beginLinkWatch()
            io.execute { startCapture(app, active) }
        }
    }

    /** Dialer: remote accept arrived — enable PCM capture/playback on existing listen. */
    fun enableMedia(context: Context, active: BeamioNativeVoiceSignaling.ActiveCall) {
        val app = context.applicationContext
        appCtx.set(app)
        activeRef.set(active)
        mediaLive.set(true)
        beginLinkWatch()
        // Accept arrived: the ringback must stop before the mic / speaker open.
        BeamioCallTonePlayer.stopRingback("voice-media", mediaStarting = true)
        Log.i(TAG, "enableMedia peerSession=${active.peerMediaSessionId.take(12)}")
        if (!running.get()) return
        if (audioRecord != null) return
        // Do not pre-set captureStarted — startCapture owns that flag (and may
        // leave it false while awaiting RECORD_AUDIO).
        captureStarted.set(false)
        io.execute { startCapture(app, active) }
    }

    /**
     * After the user grants RECORD_AUDIO (InCall / MainActivity dialog), retry
     * PCM capture if the temporary channel is still live and not yet recording.
     */
    fun retryCaptureAfterMicPermission() {
        val app = appCtx.get() ?: return
        val active = activeRef.get() ?: return
        if (!running.get() || !mediaLive.get()) return
        if (audioRecord != null) {
            Log.i(TAG, "retryCapture skip — already capturing")
            return
        }
        Log.i(TAG, "retryCapture after RECORD_AUDIO grant callId=${active.offer.callId.take(12)}")
        captureStarted.set(false)
        io.execute { startCapture(app, active) }
    }

    fun stop() {
        stopInternal(keepApp = false)
    }

    private fun stopInternal(keepApp: Boolean) {
        // Capture before tear-down: dialer Stop must free mailbox voice_listen
        // so the next redial can re-occupy the same (or a new) sessionId.
        val previous = activeRef.get()
        val listenSessionId = previous?.listenSessionId?.trim().orEmpty()
        val app = appCtx.get()
        running.set(false)
        mediaLive.set(false)
        endLinkWatch()
        listenGen.incrementAndGet()
        captureStarted.set(false)
        captureMuted.set(false)
        uplinkInFlight.set(false)
        synchronized(pcmPendingLock) { pcmPending = ByteArray(0) }
        resetRxJitter()
        resetVideoState()
        try {
            listenConn?.disconnect()
        } catch (_: Exception) {
        }
        listenConn = null
        releaseVoiceEffects()
        try {
            audioRecord?.stop()
            audioRecord?.release()
        } catch (_: Exception) {
        }
        audioRecord = null
        try {
            audioTrack?.stop()
            audioTrack?.release()
        } catch (_: Exception) {
        }
        audioTrack = null
        activeRef.set(null)
        if (!keepApp) appCtx.set(null)
        if (listenSessionId.length >= 16 && app != null) {
            val relay = previous?.dialerWake
            io.execute { postVoiceUnlisten(app, listenSessionId, relay) }
        }
        Log.i(
            TAG,
            "stopped uplinkOk=${uplinkPostOk.get()} uplinkDrop=${uplinkDrop.get()} lastSeq=${uplinkSeq.get()}",
        )
        synchronized(audioTally) {
            Log.i(TAG, "audio wire v1 ${audioTally[0].line()} | v2 ${audioTally[1].line()}")
        }
    }

    /**
     * Best-effort `voice_unlisten` to the node holding the session: the call's
     * relay node when there is one, else own mailbox (entry ≠ that node).
     */
    private fun postVoiceUnlisten(
        app: Context,
        sessionId: String,
        relay: BeamioNativeVoiceSignaling.DialerWake? = null,
    ) {
        try {
            val secrets = BeamioChatPgpStore.load(app) ?: run {
                Log.w(TAG, "unlisten — no secrets")
                return
            }
            if (!secrets.hasRoutePublic) {
                Log.w(TAG, "unlisten — missing own route PGP")
                return
            }
            val command =
                JSONObject()
                    .put("command", "voice_unlisten")
                    .put("sessionId", sessionId)
                    .put("timestamp", System.currentTimeMillis() / 1000L)
                    .toString()
            val encryptWait = Object()
            var armor: String? = null
            var encryptError: String? = null
            val relayRoute = relay?.relayRouteArmored?.takeIf { it.contains("BEGIN PGP PUBLIC KEY") }
            BeamioNativeRoutePgp.encryptToRouteAsync(app, 
                relayRoute ?: secrets.routePublicKeyArmor,
                command,
            ) { result ->
                result.onSuccess { armor = it }
                    .onFailure { encryptError = it.message }
                synchronized(encryptWait) { encryptWait.notifyAll() }
            }
            synchronized(encryptWait) {
                if (armor == null && encryptError == null) encryptWait.wait(8_000L)
            }
            val encrypted = armor
            if (encrypted.isNullOrBlank() || !encrypted.contains("BEGIN PGP MESSAGE")) {
                Log.w(TAG, "unlisten encrypt failed: ${encryptError ?: "timeout"}")
                return
            }
            val roster = BeamioNativeVoiceSignaling.rosterOf(secrets)
            val exclude = buildSet {
                BeamioSiCipherPost.normalizeIp(secrets.mailboxIp)?.let { add(it) }
                if (relayRoute != null) BeamioSiCipherPost.normalizeIp(relay.relayIp)?.let { add(it) }
            }
            val posted = BeamioSiCipherPost.post(encrypted, roster, exclude, maxAttempts = 3)
            Log.i(TAG, "voice_unlisten session=${sessionId.take(12)} ok=${posted.ok}")
        } catch (e: Exception) {
            Log.w(TAG, "voice_unlisten failed: ${e.message}")
        }
    }

    // ---- Link health ----

    /** Media just started (callee on Answer, dialer on Accept): arm the watchdog. */
    private fun beginLinkWatch() {
        val now = System.currentTimeMillis()
        mediaStartedAt = now
        lastRxAt = now
        lastTxOkAt = now
        reconnecting = false
        reconnectAttempt = 0
        nextReconnectAt = 0L
        linkLostFired = false
        linkTask?.cancel(false)
        linkTask = linkTimer.scheduleWithFixedDelay(
            { runCatching { linkTick() }.onFailure { Log.w(TAG, "link tick: ${it.message}") } },
            1, 1, java.util.concurrent.TimeUnit.SECONDS,
        )
    }

    private fun endLinkWatch() {
        linkTask?.cancel(false)
        linkTask = null
        reconnectInFlight.set(false)
        listenAlive.set(false)
        if (reconnecting) {
            reconnecting = false
            InCallScreenModel.setReconnecting(false)
            InCallActivity.refreshStateIfShowing()
        }
    }

    /** A peer frame (media, control or keepalive) arrived. */
    private fun noteRx() {
        lastRxAt = System.currentTimeMillis()
        if (reconnecting) {
            reconnecting = false
            reconnectAttempt = 0
            Log.i(TAG, "link restored")
            InCallScreenModel.setReconnecting(false)
            InCallActivity.refreshStateIfShowing()
        }
    }

    private fun linkTick() {
        if (!running.get() || !mediaLive.get() || linkLostFired) return
        val active = activeRef.get() ?: return
        val app = appCtx.get() ?: return
        val now = System.currentTimeMillis()
        val rxIdle = now - lastRxAt
        val txIdle = now - lastTxOkAt
        if (rxIdle >= LINK_LOST_LIMIT_MS && txIdle >= LINK_LOST_LIMIT_MS) {
            linkLostFired = true
            Log.w(TAG, "connection lost rxIdle=${rxIdle / 1000}s txIdle=${txIdle / 1000}s attempts=$reconnectAttempt")
            InCallScreenModel.connectionLost(app, active.offer.callId, active.offer.sessionId)
            return
        }
        val silent = now - mediaStartedAt >= MEDIA_START_GRACE_MS && rxIdle >= RX_STALE_RECONNECT_MS
        if (listenAlive.get() && !silent) return
        if (!reconnecting) {
            reconnecting = true
            reconnectAttempt = 0
            nextReconnectAt = now
            Log.i(TAG, "link reconnecting listenAlive=${listenAlive.get()} rxIdle=${rxIdle / 1000}s")
            InCallScreenModel.setReconnecting(true)
            InCallActivity.refreshStateIfShowing()
        }
        if (reconnectInFlight.get() || now < nextReconnectAt) return
        reconnectAttempt += 1
        val backoff = minOf(8_000L, 1_000L shl (reconnectAttempt - 1).coerceAtMost(3))
        // A fresh listen needs a few seconds to show peer frames before it is judged again.
        nextReconnectAt = now + maxOf(backoff, 4_000L)
        startReconnect(app, active, unlistenFirst = reconnectAttempt > 1)
    }

    /**
     * Reopen `voice_listen` for the same session through a new random entry.
     * The first attempt assumes the node already dropped the old socket; later
     * ones send `voice_unlisten` first (the node answers session_conflict while
     * it still holds the old one).
     */
    private fun startReconnect(
        app: Context,
        active: BeamioNativeVoiceSignaling.ActiveCall,
        unlistenFirst: Boolean,
    ) {
        reconnectInFlight.set(true)
        val gen = listenGen.incrementAndGet()
        listenAlive.set(false)
        val stale = listenConn
        listenConn = null
        Log.i(TAG, "voice_listen reconnect attempt=$reconnectAttempt unlisten=$unlistenFirst")
        io.execute {
            try {
                runCatching { stale?.disconnect() }
                if (unlistenFirst) {
                    postVoiceUnlisten(app, active.listenSessionId, active.dialerWake)
                    Thread.sleep(1_500L)
                }
                if (running.get() && gen == listenGen.get()) {
                    startVoiceListen(app, active, reconnect = true, gen = gen)
                }
            } finally {
                if (gen == listenGen.get()) reconnectInFlight.set(false)
            }
        }
    }

    private fun sendMutedKeepalive(
        context: Context,
        active: BeamioNativeVoiceSignaling.ActiveCall,
        routeArmored: String,
        roster: List<BeamioChatPgpStore.SiNode>,
        exclude: Set<String>,
    ) {
        uplinkPcmFrame(context, ByteArray(320 * 2), active, routeArmored, roster, exclude, keepalive = true)
    }

    private fun startVoiceListen(
        context: Context,
        active: BeamioNativeVoiceSignaling.ActiveCall,
        reconnect: Boolean = false,
        gen: Int = listenGen.get(),
    ) {
        val secrets = BeamioChatPgpStore.load(context) ?: run {
            Log.w(TAG, "listen — no secrets")
            return
        }
        if (!secrets.hasRoutePublic) {
            Log.w(TAG, "listen — missing own route PGP")
            return
        }
        val commandObj = JSONObject()
            .put("command", "voice_listen")
            .put("sessionId", active.listenSessionId)
            .put("timestamp", System.currentTimeMillis() / 1000L)
        if (!legacyMode && BeamioVoiceChannelV2.locator(active.listenSessionId) != null && ownWriteKey.size == 32) {
            commandObj.put("v", 2)
            commandObj.put("wk", android.util.Base64.encodeToString(ownWriteKey, android.util.Base64.NO_WRAP))
        }
        val baseCommand = commandObj.toString()
        // Legacy wake: the node holding our session calls the push API and so
        // learns the callee wallet. Used only when the callee's own mailbox did
        // not ring the callee (`voice_offer_store` push; old nodes never do).
        val wake = active.dialerWake
        // Per-call relay node (not own mailbox). The PWA already delivered the
        // offer to the callee's mailbox through a random entry, so the listen
        // carries no offerArmor and no node is asked to forward it.
        val relayRoute = wake?.relayRouteArmored?.takeIf { it.contains("BEGIN PGP PUBLIC KEY") }
        if (
            !reconnect &&
            wake != null &&
            (relayRoute != null || wake.offerArmor.contains("BEGIN PGP MESSAGE")) &&
            wake.calleeEoa.isNotBlank() &&
            wake.callId.isNotBlank()
        ) {
            commandObj.put("callId", wake.callId)
            commandObj.put("targetWallet", wake.calleeEoa)
            commandObj.put("expiresAt", wake.expiresAt)
            commandObj.put("pushTimestamp", wake.pushTimestamp)
            if (relayRoute == null) commandObj.put("offerArmor", wake.offerArmor)
        }
        val wakeCommand = commandObj.toString().takeIf { it != baseCommand }

        // Ask the callee's own mailbox to index the offer and ring the callee,
        // beside the listen encrypts; pick the listen variant from its answer.
        val calleeRang = java.util.concurrent.CompletableFuture<Boolean>()
        if (wake != null && wakeCommand != null && wake.offerArmor.contains("BEGIN PGP MESSAGE") && !legacyMode) {
            io.execute { calleeRang.complete(runCatching { storeOfferOnCalleeMailbox(context, secrets, wake, active.listenSessionId) }.getOrDefault(false)) }
        } else {
            calleeRang.complete(false)
        }
        val listenRoute = relayRoute ?: secrets.routePublicKeyArmor
        val baseArmor = java.util.concurrent.CompletableFuture<String?>()
        val wakeArmor = java.util.concurrent.CompletableFuture<String?>()
        BeamioNativeRoutePgp.encryptToRouteAsync(context, listenRoute, baseCommand) { baseArmor.complete(it.getOrNull()) }
        if (wakeCommand != null) {
            BeamioNativeRoutePgp.encryptToRouteAsync(context, listenRoute, wakeCommand) { wakeArmor.complete(it.getOrNull()) }
        } else {
            wakeArmor.complete(null)
        }
        val armorBase = runCatching { baseArmor.get(12, java.util.concurrent.TimeUnit.SECONDS) }.getOrNull()
        val armorWake = runCatching { wakeArmor.get(12, java.util.concurrent.TimeUnit.SECONDS) }.getOrNull()
        BeamioCallTiming.mark("listen-encrypted")
        val rang = runCatching { calleeRang.get(3, java.util.concurrent.TimeUnit.SECONDS) }.getOrDefault(false)
        val useLegacyWake = wakeCommand != null && !rang
        if (wakeCommand != null) {
            Log.i(TAG, "callee wake by ${if (rang) "callee-mailbox" else "legacy-listen"}")
            BeamioCallTiming.mark("wake-path", if (rang) "callee-mailbox" else "legacy-listen")
        }
        val encrypted = if (useLegacyWake) armorWake else armorBase
        if (encrypted.isNullOrBlank() || !encrypted.contains("BEGIN PGP MESSAGE")) {
            Log.w(TAG, "listen encrypt failed")
            return
        }

        val roster = BeamioNativeVoiceSignaling.rosterOf(secrets)
        val exclude = buildSet {
            BeamioSiCipherPost.normalizeIp(secrets.mailboxIp)?.let { add(it) }
            // Entry must not be the node that holds the session.
            if (relayRoute != null) BeamioSiCipherPost.normalizeIp(wake.relayIp)?.let { add(it) }
        }
        // A reconnect avoids the entry that just failed when another is left.
        val avoid = lastListenEntry
        val entry = (if (reconnect && avoid != null) {
            BeamioSiCipherPost.getRandomNode(roster, excludeIps = exclude + avoid)
        } else null) ?: BeamioSiCipherPost.getRandomNode(roster, excludeIps = exclude)
        val entryIp = entry?.let { BeamioSiCipherPost.normalizeIp(it.ip) }
        if (entryIp == null) {
            Log.w(TAG, "listen — no reachable entry IP")
            return
        }
        if (gen != listenGen.get() || !running.get()) return
        val url = BeamioSiCipherPost.postUrl(entryIp) ?: return
        val body = JSONObject().put("data", encrypted).toString()
        Log.i(
            TAG,
            "voice_listen entry=$entryIp session=${active.listenSessionId.take(12)} " +
                "node=${if (relayRoute != null) "relay" else "own-mailbox"}",
        )

        var conn: HttpURLConnection? = null
        val started = System.currentTimeMillis()
        try {
            conn = (URL(url).openConnection() as HttpURLConnection).apply {
                requestMethod = "POST"
                connectTimeout = 15_000
                readTimeout = 3_600_000
                doOutput = true
                setRequestProperty("Content-Type", "application/json")
                setRequestProperty("Accept", "text/event-stream")
                setRequestProperty("Connection", "keep-alive")
            }
            listenConn = conn
            OutputStreamWriter(conn.outputStream, Charsets.UTF_8).use { it.write(body) }
            val code = conn.responseCode
            val latency = (System.currentTimeMillis() - started).toInt()
            if (code !in 200..299) {
                if (code == 0) {
                    BeamioSiCipherPost.scoreEntry(entryIp, reachable = false, latencyMs = latency)
                } else {
                    BeamioSiCipherPost.scoreEntry(entryIp, reachable = true, latencyMs = 500)
                }
                Log.w(TAG, "listen HTTP $code")
                return
            }
            BeamioSiCipherPost.scoreEntry(entryIp, reachable = true, latencyMs = latency)
            BeamioCallTiming.mark("listen-open", "http=$latency")
            if (gen == listenGen.get()) {
                listenAlive.set(true)
                lastListenEntry = entryIp
            }
            if (reconnect) {
                reconnectInFlight.set(false)
                Log.i(TAG, "voice_listen reopened entry=$entryIp")
            }
            val stream = BufferedInputStream(conn.inputStream)
            val buf = ByteArray(4096)
            val sse = StringBuilder()
            while (running.get() && gen == listenGen.get()) {
                val n = stream.read(buf)
                if (n < 0) break
                sse.append(String(buf, 0, n, Charsets.UTF_8))
                while (true) {
                    val crlf = sse.indexOf("\r\n\r\n")
                    val lf = sse.indexOf("\n\n")
                    val idx = when {
                        crlf >= 0 && (lf < 0 || crlf <= lf) -> crlf to 4
                        lf >= 0 -> lf to 2
                        else -> break
                    }
                    val block = sse.substring(0, idx.first)
                    sse.delete(0, idx.first + idx.second)
                    handleSseBlock(context, block, active)
                }
            }
        } catch (e: Exception) {
            val latency = (System.currentTimeMillis() - started).toInt()
            BeamioSiCipherPost.scoreEntry(entryIp, reachable = false, latencyMs = latency)
            if (running.get()) Log.w(TAG, "listen error: ${e.message}")
        } finally {
            try {
                conn?.disconnect()
            } catch (_: Exception) {
            }
            if (listenConn === conn) listenConn = null
            if (gen == listenGen.get()) listenAlive.set(false)
            if (running.get() && gen == listenGen.get()) Log.i(TAG, "voice_listen closed")
        }
    }

    /**
     * `voice_offer_store` with `push: 1` to the callee's own mailbox (route key,
     * entry ≠ that mailbox). A v2 mailbox indexes the offer, finds the callee from
     * the offer's recipient key ID, rings it, and answers `pushed: true`; then our
     * listen carries no callee wallet. Old mailboxes never say so.
     */
    private fun storeOfferOnCalleeMailbox(
        context: Context,
        secrets: BeamioChatPgpStore.Secrets,
        wake: BeamioNativeVoiceSignaling.DialerWake,
        sessionId: String,
    ): Boolean {
        val keys = BeamioAddressPgp.searchKey(wake.calleeEoa) ?: run {
            Log.w(TAG, "offer index — no callee route key")
            return false
        }
        val command = JSONObject()
            .put("command", "voice_offer_store")
            .put("callId", wake.callId)
            .put("sessionId", sessionId)
            .put("offerArmor", wake.offerArmor)
            .put("expiresAt", wake.expiresAt)
            .put("push", 1)
            .put("pushTimestamp", wake.pushTimestamp)
            .put("timestamp", System.currentTimeMillis() / 1000L)
            .toString()
        val armor = runCatching { BeamioNativeRoutePgp.encryptToRoute(keys.routePublicKeyArmored, command) }.getOrNull()
            ?: return false
        val roster = BeamioNativeVoiceSignaling.rosterOf(secrets)
        val exclude = buildSet {
            BeamioAddressPgp.mailboxIp(keys.routePgpKeyID, roster)?.let { add(it) }
            BeamioSiCipherPost.normalizeIp(secrets.mailboxIp)?.let { add(it) }
        }
        val posted = BeamioSiCipherPost.post(armor, roster, exclude, maxAttempts = 2)
        val pushed = posted.ok && runCatching { JSONObject(posted.body).optBoolean("pushed", false) }.getOrDefault(false)
        Log.i(TAG, "offer index callId=${wake.callId.take(12)} ok=${posted.ok} pushed=$pushed")
        BeamioCallTiming.mark("native-offer-index", if (posted.ok) "ok" else "fail")
        return pushed
    }

    private fun handleSseBlock(
        context: Context,
        block: String,
        started: BeamioNativeVoiceSignaling.ActiveCall,
    ) {
        val dataLines = block.lineSequence()
            .map { it.trimEnd() }
            .filter { it.startsWith("data:") }
            .map { it.removePrefix("data:").trim() }
            .toList()
        if (dataLines.isEmpty()) return
        val payload = dataLines.joinToString("\n")
        val obj = try {
            JSONObject(payload)
        } catch (_: Exception) {
            return
        }
        if (obj.optString("kind") == "udp" || obj.optBoolean("ok", false)) {
            val v2 = obj.optInt("v", 1) == 2
            Log.i(TAG, "listen handshake ok chan=${if (v2) 2 else 1}")
            listenAlive.set(true)
            // Caps that went out before the handshake said chan 1: resend.
            if (v2 && ownChanV2.compareAndSet(false, true) && capsSent.get() > 0) sendMediaCaps("chan-v2")
            return
        }
        if (obj.optString("t") == "c") {
            // A v2 chunk is a peer frame for the link watchdog too.
            noteRx()
            handleInboundChunk(context, obj.optString("d"), started)
            return
        }
        val type = obj.optString("type")
        val command = obj.optString("command")
        if (type == "voice_frame_v1" || command == "voice_uplink") {
            noteRx()
            handleInboundFrame(context, obj, started)
        }
    }

    private fun handleInboundFrame(
        context: Context,
        frame: JSONObject,
        started: BeamioNativeVoiceSignaling.ActiveCall,
    ) {
        if (!running.get()) return
        val live = activeRef.get() ?: started
        val payloadB64 = frame.optString("payload")
        if (payloadB64.isBlank()) return
        val plain = try {
            BeamioVoiceAesGcm.decryptBytes(live.offer.sessionKey, payloadB64)
        } catch (e: Exception) {
            Log.w(TAG, "decrypt fail: ${e.message}")
            return
        }
        val seq = if (frame.has("seq")) frame.optInt("seq", -1) else -1
        handleInboundPlain(context, plain, live, seq, frame.optLong("frameTimestamp", 0L))
    }

    /** v2 chunk on our own channel: AES with AAD = CVC2 ‖ our locator; seq and time are inside. */
    private fun handleInboundChunk(context: Context, blobB64: String, started: BeamioNativeVoiceSignaling.ActiveCall) {
        if (!running.get() || blobB64.isBlank()) return
        val live = activeRef.get() ?: started
        val loc = BeamioVoiceChannelV2.locator(live.listenSessionId) ?: return
        val opened = try {
            BeamioVoiceChannelV2.openChunk(
                live.offer.sessionKey,
                loc,
                android.util.Base64.decode(blobB64, android.util.Base64.DEFAULT),
            )
        } catch (e: Exception) {
            Log.w(TAG, "v2 chunk open fail: ${e.message}")
            return
        }
        if (v2Rx.incrementAndGet() == 1) Log.i(TAG, "first v2 chunk rx kind=${opened.kind}")
        handleInboundPlain(context, opened.data, live, opened.seq, opened.captureMs)
    }

    /** One decrypted frame (v1 payload or v2 chunk data). */
    private fun handleInboundPlain(
        context: Context,
        plain: ByteArray,
        live: BeamioNativeVoiceSignaling.ActiveCall,
        seq: Int,
        senderTsMs: Long,
    ) {
        if (seq >= VIDEO_SEQ_BASE) {
            // Split-seq video (the peer saw our caps): never touches the audio
            // reorder buffer, so its loss or delay cannot stall audio.
            if (mediaLive.get()) handleInboundVideo(plain, 0L)
            maybeFlushStats()
            return
        }
        if (startsWith(plain, JPG_MAGIC) || startsWith(plain, JP2_MAGIC)) {
            // Video shares the audio seq counter: mark the slot so the PCM
            // jitter buffer does not stall waiting for it.
            if (mediaLive.get()) {
                markRxSeqConsumed(seq)
                handleInboundVideo(plain, senderTsMs)
            }
            maybeFlushStats()
            return
        }
        val asText = if (startsWith(plain, PCM_MAGIC)) {
            null
        } else {
            try {
                String(plain, Charsets.UTF_8)
            } catch (_: Exception) {
                null
            }
        }
        if (asText != null && asText.trimStart().startsWith("{")) {
            try {
                val json = JSONObject(asText)
                val t = json.optString("type")
                Log.i(TAG, "control frame type=$t role=${live.role}")
                if (live.role == BeamioNativeVoiceSignaling.Role.DIALER) {
                    if (t == "voice_call_accept_v1") {
                        val peerSession = json.optString("sessionId").trim()
                        BeamioNativeVoiceSignaling.dialerDidReceiveAccept(context, peerSession)
                        return
                    }
                    if (t == "voice_call_reject_v1" || t == "voice_call_timeout_v1") {
                        val action = if (t == "voice_call_timeout_v1") "callTimedOut" else "callRejected"
                        BeamioNativeVoiceSignaling.dialerDidReceiveReject(context, action)
                        return
                    }
                }
                if (t == "voice_end_v1" || t == "voice_call_reject_v1") {
                    stop()
                    // Peer hung up: close the call page and Telecom call too.
                    BeamioNativeVoiceSignaling.peerDidEnd(
                        context,
                        json.optString("callId").trim(),
                        json.optString("sessionId").trim(),
                    )
                    return
                }
                // Control frames also take a seq on the sender.
                markRxSeqConsumed(seq)
                if (t == "voice_media_caps_v1") {
                    notePeerCaps(json)
                    return
                }
                if (t == "voice_video_enable_v1") {
                    notePeerCaps(json)
                    // The peer is about to send video: make sure it knows what
                    // we can receive (our earlier caps may have been lost).
                    sendMediaCaps("peer-video-on")
                    return
                }
                if (t == "voice_video_disable_v1") {
                    rxHandler.post { InCallActivity.applyPeerVideoFrameIfShowing(null) }
                }
                return
            } catch (_: Exception) {
                // fall through to PCM
            }
        }
        if (!mediaLive.get()) return
        val pcm = stripPcmHeader(plain) ?: return
        noteRxAudio(pcm.size)
        stats.update { it.audioRx += 1 }
        if (seq >= 0) {
            enqueueRxPcm(seq, pcm)
        } else {
            playPcm(pcm)
        }
    }

    private var rxAudioStartMs = 0L
    private var rxAudioBytes = 0L
    private var rxAudioPackets = 0

    /** Diagnostics: received audio duration vs wall time (should stay near 100 %). */
    private fun noteRxAudio(bytes: Int) {
        val now = System.currentTimeMillis()
        synchronized(rxLock) {
            if (rxAudioStartMs == 0L) rxAudioStartMs = now
            rxAudioBytes += bytes
            rxAudioPackets += 1
            if (rxAudioPackets % 25 == 0) {
                val wall = (now - rxAudioStartMs).coerceAtLeast(1L)
                val audioMs = rxAudioBytes * 1000 / (SAMPLE_RATE * 2)
                Log.i(TAG, "rx audio ${audioMs}ms over ${wall}ms wall (${audioMs * 100 / wall}%) packets=$rxAudioPackets avgMs=${audioMs / rxAudioPackets}")
            }
        }
    }

    private var echoCanceler: android.media.audiofx.AcousticEchoCanceler? = null
    private var noiseSuppressor: android.media.audiofx.NoiseSuppressor? = null
    private var gainControl: android.media.audiofx.AutomaticGainControl? = null

    /**
     * Turn on the platform echo canceller, noise suppressor and AGC for the mic
     * session. VOICE_COMMUNICATION alone does not guarantee AEC on every device;
     * without it the far end hears its own voice back from our speaker.
     */
    private fun attachVoiceEffects(sessionId: Int) {
        releaseVoiceEffects()
        if (android.media.audiofx.AcousticEchoCanceler.isAvailable()) {
            echoCanceler = runCatching {
                android.media.audiofx.AcousticEchoCanceler.create(sessionId)?.apply { enabled = true }
            }.getOrNull()
        }
        if (android.media.audiofx.NoiseSuppressor.isAvailable()) {
            noiseSuppressor = runCatching {
                android.media.audiofx.NoiseSuppressor.create(sessionId)?.apply { enabled = true }
            }.getOrNull()
        }
        if (android.media.audiofx.AutomaticGainControl.isAvailable()) {
            gainControl = runCatching {
                android.media.audiofx.AutomaticGainControl.create(sessionId)?.apply { enabled = true }
            }.getOrNull()
        }
        Log.i(
            TAG,
            "voice effects aec=${echoCanceler?.enabled == true} ns=${noiseSuppressor?.enabled == true} " +
                "agc=${gainControl?.enabled == true}",
        )
    }

    private fun releaseVoiceEffects() {
        runCatching { echoCanceler?.release() }
        runCatching { noiseSuppressor?.release() }
        runCatching { gainControl?.release() }
        echoCanceler = null
        noiseSuppressor = null
        gainControl = null
    }

    private fun startsWith(bytes: ByteArray, magic: ByteArray): Boolean {
        if (bytes.size < magic.size) return false
        for (i in magic.indices) if (bytes[i] != magic[i]) return false
        return true
    }

    /** `BPCM` + u32-LE rate + PCM → PCM at 16 kHz. Headerless PCM passes through. */
    private fun stripPcmHeader(plain: ByteArray): ByteArray? {
        if (!startsWith(plain, PCM_MAGIC)) {
            return if (plain.size >= 2 && plain.size % 2 == 0) plain else null
        }
        if (plain.size < 10) return null
        val rate = (plain[4].toInt() and 0xFF) or
            ((plain[5].toInt() and 0xFF) shl 8) or
            ((plain[6].toInt() and 0xFF) shl 16) or
            ((plain[7].toInt() and 0xFF) shl 24)
        val body = plain.copyOfRange(8, 8 + ((plain.size - 8) / 2) * 2)
        if (rate == SAMPLE_RATE) return body
        if (rate !in 8_000..48_000 || body.isEmpty()) return null
        // Linear resample to 16 kHz.
        val count = body.size / 2
        val outCount = maxOf(1, (count.toLong() * SAMPLE_RATE / rate).toInt())
        val out = ByteArray(outCount * 2)
        fun sample(i: Int): Int =
            (body[2 * i].toInt() and 0xFF) or (body[2 * i + 1].toInt() shl 8)
        for (i in 0 until outCount) {
            val pos = i.toDouble() * rate / SAMPLE_RATE
            val i0 = minOf(pos.toInt(), count - 1)
            val i1 = minOf(i0 + 1, count - 1)
            val f = pos - i0
            val v = (sample(i0) * (1 - f) + sample(i1) * f).toInt().coerceIn(-32768, 32767)
            out[2 * i] = (v and 0xFF).toByte()
            out[2 * i + 1] = ((v shr 8) and 0xFF).toByte()
        }
        return out
    }

    /** Decode a `BJPG` frame and queue it for paced display as the peer video background. */
    private fun handleInboundVideo(plain: ByteArray, senderTsMs: Long) {
        val v2 = startsWith(plain, JP2_MAGIC)
        val header = if (v2) 20 else 12
        if (plain.size <= header) return
        val captureMs = if (v2) getLe64(plain, 12) else 0L
        val bitmap = try {
            android.graphics.BitmapFactory.decodeByteArray(plain, header, plain.size - header)
        } catch (_: Exception) {
            null
        } ?: return
        stats.update {
            it.rxIn += 1
            it.rxBytes += plain.size
        }
        if (captureMs > 0L) stats.noteRxTiming(captureMs, System.currentTimeMillis())
        scheduleVideoFrame(bitmap, if (captureMs > 0L) captureMs else senderTsMs)
    }

    // MARK: - Video playout

    private val videoLock = Any()
    private var videoMinDeltaMs: Long? = null
    private var videoLastSenderTs = 0L
    /** Capture time of the newest remote frame shown (main thread). */
    private var videoShownCaptureMs = 0L

    /**
     * Frames arrive in bursts over the relay. Show each one at its sender time
     * plus a fixed delay over the best (lowest) observed transit, so playback
     * keeps the sender's cadence. Out-of-order and duplicate frames are dropped.
     */
    private fun scheduleVideoFrame(bitmap: android.graphics.Bitmap, senderTsMs: Long) {
        val now = System.currentTimeMillis()
        if (senderTsMs <= 0L) {
            rxHandler.post {
                stats.update { it.rxShown += 1 }
                InCallActivity.applyPeerVideoFrameIfShowing(bitmap)
            }
            return
        }
        val waitMs: Long
        synchronized(videoLock) {
            if (senderTsMs <= videoLastSenderTs) {
                stats.update { it.rxSuperseded += 1 }
                return
            }
            videoLastSenderTs = senderTsMs
            val delta = now - senderTsMs
            // Track the fastest transit; relax slowly so a slower path is adopted.
            val prev = videoMinDeltaMs
            val min = if (prev == null) delta else minOf(delta, prev + 2L)
            videoMinDeltaMs = min
            waitMs = (senderTsMs + min + VIDEO_PLAYOUT_DELAY_MS - now).coerceAtLeast(0L)
        }
        rxHandler.postDelayed({
            if (!running.get() || !mediaLive.get()) return@postDelayed
            // Main thread. A newer frame already shown wins: never step back.
            if (senderTsMs < videoShownCaptureMs) {
                stats.update { it.rxSuperseded += 1 }
                return@postDelayed
            }
            videoShownCaptureMs = senderTsMs
            stats.update { it.rxShown += 1 }
            InCallActivity.applyPeerVideoFrameIfShowing(bitmap)
        }, waitMs)
    }

    private fun resetVideoPlayout() {
        synchronized(videoLock) {
            videoMinDeltaMs = null
            videoLastSenderTs = 0L
        }
        rxHandler.post { videoShownCaptureMs = 0L }
    }

    /** Fill a seq slot with an empty chunk so the PCM jitter drain moves past it. */
    private fun markRxSeqConsumed(seq: Int) {
        if (seq < 0) return
        enqueueRxPcm(seq, ByteArray(0))
    }

    private fun resetRxJitter() {
        synchronized(rxLock) {
            rxJitterRunnable?.let { rxHandler.removeCallbacks(it) }
            rxJitterRunnable = null
            rxNextSeq = null
            rxPendingPcm.clear()
        }
    }

    /** Playout jitter: buffer late/OOO seq ~120ms, then contiguous play; timeout → skip gap. */
    private fun enqueueRxPcm(seq: Int, pcm: ByteArray) {
        val toPlay = ArrayList<ByteArray>()
        synchronized(rxLock) {
            val next = rxNextSeq
            if (next != null && seq < next) return
            if (rxPendingPcm.containsKey(seq)) return
            rxPendingPcm[seq] = pcm
            if (rxNextSeq == null) {
                rxNextSeq = seq
            }
            if (rxPendingPcm.size > RX_MAX_PENDING) {
                skipRxGapLocked(reason = "overflow", out = toPlay)
            } else {
                drainRxLocked(out = toPlay)
                scheduleRxJitterIfNeededLocked()
            }
        }
        for (chunk in toPlay) playPcm(chunk)
    }

    private fun drainRxLocked(out: MutableList<ByteArray>) {
        var next = rxNextSeq ?: return
        while (true) {
            val pcm = rxPendingPcm.remove(next) ?: break
            out.add(pcm)
            next += 1
        }
        rxNextSeq = next
        if (rxPendingPcm.isEmpty()) {
            rxJitterRunnable?.let { rxHandler.removeCallbacks(it) }
            rxJitterRunnable = null
        }
    }

    private fun scheduleRxJitterIfNeededLocked() {
        val next = rxNextSeq ?: return
        val hasLater = rxPendingPcm.keys.any { it > next }
        if (!hasLater) return
        if (rxJitterRunnable != null) return
        val work = Runnable {
            val toPlay = ArrayList<ByteArray>()
            synchronized(rxLock) {
                rxJitterRunnable = null
                skipRxGapLocked(reason = "timeout", out = toPlay)
            }
            for (chunk in toPlay) playPcm(chunk)
        }
        rxJitterRunnable = work
        // Reorder wait follows the adaptive playout depth.
        rxHandler.postDelayed(work, playoutTargetBytes * 1000L / (SAMPLE_RATE * 2))
    }

    private fun skipRxGapLocked(reason: String, out: MutableList<ByteArray>) {
        val next = rxNextSeq ?: return
        val later = rxPendingPcm.keys.filter { it > next }
        val minKey = later.minOrNull() ?: return
        Log.i(TAG, "rx jitter skip $next..<$minKey reason=$reason")
        stats.update { it.audioGapSkip += 1 }
        rxJitterRunnable?.let { rxHandler.removeCallbacks(it) }
        rxJitterRunnable = null
        // Fill lost audio with short silence so the timeline is not compressed;
        // the next real frame fades in (see playout loop).
        repeat(minOf(minKey - next, MAX_CONCEAL_FRAMES)) { out.add(ByteArray(UPLINK_FRAME_BYTES)) }
        playFadeNext = true
        rxNextSeq = minKey
        drainRxLocked(out = out)
        scheduleRxJitterIfNeededLocked()
    }

    private fun startCapture(context: Context, active: BeamioNativeVoiceSignaling.ActiveCall) {
        if (!running.get() || !mediaLive.get()) return
        if (ContextCompat.checkSelfPermission(context, Manifest.permission.RECORD_AUDIO)
            != PackageManager.PERMISSION_GRANTED
        ) {
            // Keep captureStarted=false so grant → retryCaptureAfterMicPermission can start.
            captureStarted.set(false)
            Log.w(TAG, "RECORD_AUDIO not granted — no uplink; awaiting permission dialog")
            Handler(Looper.getMainLooper()).post {
                InCallActivity.requestMicForVoiceUplinkIfShowing()
                MainActivity.requestMicForVoiceUplink()
            }
            return
        }
        if (!captureStarted.compareAndSet(false, true)) return
        val minBuf = AudioRecord.getMinBufferSize(
            SAMPLE_RATE,
            AudioFormat.CHANNEL_IN_MONO,
            AudioFormat.ENCODING_PCM_16BIT,
        )
        if (minBuf <= 0) {
            captureStarted.set(false)
            Log.w(TAG, "AudioRecord min buffer invalid")
            return
        }
        val record = try {
            AudioRecord(
                MediaRecorder.AudioSource.VOICE_COMMUNICATION,
                SAMPLE_RATE,
                AudioFormat.CHANNEL_IN_MONO,
                AudioFormat.ENCODING_PCM_16BIT,
                minBuf * 2,
            )
        } catch (e: Exception) {
            captureStarted.set(false)
            Log.w(TAG, "AudioRecord create fail: ${e.message}")
            return
        }
        if (record.state != AudioRecord.STATE_INITIALIZED) {
            record.release()
            captureStarted.set(false)
            Log.w(TAG, "AudioRecord not initialized")
            return
        }
        audioRecord = record
        attachVoiceEffects(record.audioSessionId)
        try {
            record.startRecording()
        } catch (e: Exception) {
            try {
                record.release()
            } catch (_: Exception) {
            }
            audioRecord = null
            captureStarted.set(false)
            Log.w(TAG, "startRecording fail: ${e.message}")
            return
        }
        Log.i(
            TAG,
            "capture started 16k mono uplinkSeq=${uplinkSeq.get()} frameBytes=$UPLINK_FRAME_BYTES peerMedia=${active.peerMediaSessionId.take(12)}",
        )
        // Resolve route crypto once — per-buffer searchKey/PGP setup starved Soft inbound.
        val secrets = BeamioChatPgpStore.load(context)
        if (secrets == null) {
            Log.w(TAG, "uplink abort — no ChatPgp secrets")
            return
        }
        val peer = active.peerEoa.lowercase()
        if (!peer.matches(Regex("^0x[0-9a-f]{40}$"))) {
            Log.w(TAG, "uplink abort — bad peerEoa")
            return
        }
        val roster = BeamioNativeVoiceSignaling.rosterOf(secrets)
        val (routeArmored, exclude) = peerSessionRoute(active, peer, roster, secrets) ?: run {
            Log.w(TAG, "uplink abort — peer session route missing")
            return
        }
        pickEntryIp(roster, exclude)?.let { entry ->
            val route = UplinkRoute(routeArmored, roster, exclude, EntryRotation(entry))
            if (uplinkRoute.compareAndSet(null, route)) {
                Log.i(TAG, "uplink route first entry=$entry")
                refillEntries(route)
            }
        }
        val buf = ByteArray(minBuf)
        while (running.get() && mediaLive.get()) {
            val n = try {
                record.read(buf, 0, buf.size)
            } catch (_: Exception) {
                break
            }
            if (n <= 0) continue
            if (captureMuted.get()) {
                // No microphone audio while muted. A 20 ms silent packet each
                // second tells the peer this side is still on the call, and its
                // accept/fail result tells us whether the peer still is.
                val now = System.currentTimeMillis()
                if (now - lastKeepaliveAt >= MUTED_KEEPALIVE_MS) {
                    lastKeepaliveAt = now
                    sendMutedKeepalive(context, activeRef.get() ?: active, routeArmored, roster, exclude)
                }
                continue
            }
            val live = activeRef.get() ?: active
            appendAndMaybeUplink(
                context = context,
                pcmChunk = buf.copyOf(n),
                active = live,
                routeArmored = routeArmored,
                roster = roster,
                exclude = exclude,
            )
        }
    }

    /**
     * Accumulate AudioRecord chunks into 160 ms frames, then AES +
     * single-flight PGP encrypt → SI post. Prior path encrypted every minBuf
     * (~dozens/sec) and silently dropped under OpenPGP backpressure — Soft
     * dialer only ever saw Accept control.
     */
    private fun appendAndMaybeUplink(
        context: Context,
        pcmChunk: ByteArray,
        active: BeamioNativeVoiceSignaling.ActiveCall,
        routeArmored: String,
        roster: List<BeamioChatPgpStore.SiNode>,
        exclude: Set<String>,
    ) {
        if (!running.get() || !mediaLive.get() || pcmChunk.isEmpty()) return
        if (active.peerMediaSessionId.isBlank()) {
            if (uplinkDrop.getAndIncrement() < 3) {
                Log.w(TAG, "uplink skip — peerMediaSessionId blank")
            }
            return
        }
        // Adaptive packetization (any length decodes on every peer): send 160 ms
        // packets while a send slot is free; when all slots are busy keep the
        // audio and send it with the next packet (up to ~250 ms) instead of dropping.
        // The route is cleared after 3 failed posts (e.g. a network drop). The
        // packet below is only built once a route exists, so resolution must be
        // kicked here; otherwise uplink never resumed after the network returned.
        if (uplinkRoute.get() == null) routeOrResolve(active)
        var packet: ByteArray? = null
        synchronized(pcmPendingLock) {
            val merged = ByteArray(pcmPending.size + pcmChunk.size)
            System.arraycopy(pcmPending, 0, merged, 0, pcmPending.size)
            System.arraycopy(pcmChunk, 0, merged, pcmPending.size, pcmChunk.size)
            var rest = merged
            val slotFree = uplinkRoute.get() != null && audioInFlight.get() < MAX_AUDIO_IN_FLIGHT
            if (merged.size >= UPLINK_FRAME_BYTES && slotFree) {
                val whole = (merged.size / UPLINK_FRAME_BYTES) * UPLINK_FRAME_BYTES
                val take = minOf(whole, MAX_PACKET_BYTES)
                packet = merged.copyOfRange(0, take)
                rest = merged.copyOfRange(take, merged.size)
            }
            // Never keep more than one second of unsent audio: drop the oldest.
            val maxPending = SAMPLE_RATE * 2
            pcmPending = if (rest.size > maxPending) {
                rest.copyOfRange(rest.size - maxPending, rest.size)
            } else {
                rest
            }
        }
        packet?.let { uplinkPcmFrame(context, it, active, routeArmored, roster, exclude) }
    }

    private fun uplinkPcmFrame(
        context: Context,
        pcm: ByteArray,
        active: BeamioNativeVoiceSignaling.ActiveCall,
        routeArmored: String,
        roster: List<BeamioChatPgpStore.SiNode>,
        exclude: Set<String>,
        keepalive: Boolean = false,
    ) {
        if (!running.get() || !mediaLive.get() || pcm.isEmpty()) return
        if (captureMuted.get() && !keepalive) return
        if (active.peerMediaSessionId.isBlank()) return
        val route = uplinkRoute.get() ?: routeOrResolve(active) ?: return
        // Up to MAX_AUDIO_IN_FLIGHT posts at once (iOS: 6). Beyond that the
        // frame is dropped: late audio is worse than lost audio.
        if (audioInFlight.incrementAndGet() > MAX_AUDIO_IN_FLIGHT) {
            audioInFlight.decrementAndGet()
            val d = uplinkDrop.incrementAndGet()
            if (d <= 3 || d % 25 == 0) {
                Log.w(TAG, "uplink drop in-flight seq~${uplinkSeq.get()} drops=$d")
            }
            return
        }
        // Same wire as iOS / PWA: BPCM + u32-LE rate + PCM.
        val framed = ByteArray(8 + pcm.size)
        System.arraycopy(PCM_MAGIC, 0, framed, 0, 4)
        putLe32(framed, 4, SAMPLE_RATE)
        System.arraycopy(pcm, 0, framed, 8, pcm.size)
        postUplink(active, route, framed, mediaKind = null) {
            audioInFlight.decrementAndGet()
        }
    }

    // MARK: - Audio playout

    private val playLock = Object()
    private val playQueue = ArrayDeque<ByteArray>()
    private var playQueuedBytes = 0
    private var playThread: Thread? = null
    @Volatile private var playPrebuffering = true
    @Volatile private var playoutTargetBytes = PLAYOUT_TARGET_BYTES
    private var lastUnderrunAtMs = 0L
    private var lastDecayAtMs = 0L

    /** Caller holds [playLock]. */
    private fun growPlayoutTargetLocked() {
        val now = System.currentTimeMillis()
        lastUnderrunAtMs = now
        lastDecayAtMs = now
        val next = minOf(PLAYOUT_MAX_TARGET_BYTES, playoutTargetBytes + PLAYOUT_STEP_UP_BYTES)
        if (next != playoutTargetBytes) {
            playoutTargetBytes = next
            Log.i(TAG, "underrun — playout depth ${next * 1000 / (SAMPLE_RATE * 2)}ms")
        }
    }

    /** Caller holds [playLock]. */
    private fun decayPlayoutTargetLocked() {
        if (playoutTargetBytes <= PLAYOUT_TARGET_BYTES) return
        val now = System.currentTimeMillis()
        if (now - lastUnderrunAtMs < PLAYOUT_DECAY_MS || now - lastDecayAtMs < PLAYOUT_DECAY_MS) return
        lastDecayAtMs = now
        playoutTargetBytes = maxOf(PLAYOUT_TARGET_BYTES, playoutTargetBytes - PLAYOUT_STEP_DOWN_BYTES)
        Log.i(TAG, "stable — playout depth ${playoutTargetBytes * 1000 / (SAMPLE_RATE * 2)}ms")
    }
    @Volatile private var playFadeNext = true
    private val playDrop = AtomicInteger(0)
    private val playUnderruns = AtomicInteger(0)
    private val uplinkFailLogged = AtomicInteger(0)

    /**
     * Queue decoded PCM for playout. Never blocks the caller (SSE reader or
     * jitter timer); a dedicated thread feeds the AudioTrack.
     */
    private fun playPcm(pcm: ByteArray) {
        if (pcm.isEmpty() || !running.get() || !mediaLive.get()) return
        ensurePlayoutThread()
        synchronized(playLock) {
            playQueue.addLast(pcm)
            playQueuedBytes += pcm.size
            // Latency cap: drop the oldest audio, keep the newest.
            decayPlayoutTargetLocked()
            while (playQueuedBytes > playoutTargetBytes + PLAYOUT_CAP_HEADROOM_BYTES && playQueue.size > 1) {
                playQueuedBytes -= playQueue.removeFirst().size
                playFadeNext = true
                val d = playDrop.incrementAndGet()
                if (d <= 3 || d % 50 == 0) Log.w(TAG, "playout over latency cap; dropped oldest count=$d")
            }
            playLock.notifyAll()
        }
    }

    private fun ensurePlayoutThread() {
        synchronized(playLock) {
            if (playThread?.isAlive == true) return
            playPrebuffering = true
            playFadeNext = true
            playThread = Thread({ playoutLoop() }, "BeamioPlayout").apply { start() }
        }
    }

    /**
     * Industry-style playout buffer: hold [PLAYOUT_TARGET_BYTES] before starting
     * and again after every underrun, then write with blocking calls on this
     * thread so the track paces itself.
     */
    private fun playoutLoop() {
        val track = createAudioTrack() ?: return
        audioTrack = track
        // Frames handed to the track; with the playback head this gives what is
        // still queued inside the track (part of the jitter buffer too).
        var framesWritten = 0L
        try {
            while (running.get() && mediaLive.get()) {
                val chunk: ByteArray? = synchronized(playLock) {
                    when {
                        playPrebuffering && playQueuedBytes < playoutTargetBytes -> {
                            playLock.wait(20L)
                            null
                        }
                        playQueue.isEmpty() -> {
                            val played = track.playbackHeadPosition.toLong() and 0xFFFFFFFFL
                            val inTrack = framesWritten - played
                            if (inTrack > UNDERRUN_GUARD_FRAMES) {
                                // The track is still playing earlier audio: just wait
                                // for the next packet. Rebuffering here would insert
                                // a gap on every slightly late packet.
                                playLock.wait(10L)
                            } else {
                                // The track really ran dry: rebuffer before resuming.
                                playPrebuffering = true
                                playFadeNext = true
                                growPlayoutTargetLocked()
                                val u = playUnderruns.incrementAndGet()
                                if (u <= 3 || u % 20 == 0) Log.i(TAG, "playout underrun; rebuffering count=$u")
                            }
                            null
                        }
                        else -> {
                            if (playPrebuffering) {
                                playPrebuffering = false
                                Log.i(TAG, "playout start depthMs=${playQueuedBytes * 1000 / (SAMPLE_RATE * 2)}")
                            }
                            playQueue.removeFirst().also { playQueuedBytes -= it.size }
                        }
                    }
                }
                if (chunk == null) continue
                val out = if (playFadeNext) {
                    playFadeNext = false
                    fadeIn(chunk)
                } else {
                    chunk
                }
                val n = track.write(out, 0, out.size)
                if (n < 0) break
                framesWritten += n / 2
            }
        } catch (_: InterruptedException) {
        } catch (e: Exception) {
            Log.w(TAG, "playout loop ended: ${e.message}")
        } finally {
            runCatching { track.stop() }
            runCatching { track.release() }
            if (audioTrack === track) audioTrack = null
        }
    }

    private fun createAudioTrack(): AudioTrack? {
        val minBuf = AudioTrack.getMinBufferSize(
            SAMPLE_RATE,
            AudioFormat.CHANNEL_OUT_MONO,
            AudioFormat.ENCODING_PCM_16BIT,
        )
        if (minBuf <= 0) return null
        return runCatching {
            AudioTrack.Builder()
                .setAudioAttributes(
                    AudioAttributes.Builder()
                        .setUsage(AudioAttributes.USAGE_VOICE_COMMUNICATION)
                        .setContentType(AudioAttributes.CONTENT_TYPE_SPEECH)
                        .build(),
                )
                .setAudioFormat(
                    AudioFormat.Builder()
                        .setEncoding(AudioFormat.ENCODING_PCM_16BIT)
                        .setSampleRate(SAMPLE_RATE)
                        .setChannelMask(AudioFormat.CHANNEL_OUT_MONO)
                        .build(),
                )
                // The playout queue holds the jitter depth; keep the track buffer small.
                .setBufferSizeInBytes(maxOf(minBuf * 2, UPLINK_FRAME_BYTES))
                .setTransferMode(AudioTrack.MODE_STREAM)
                .build()
                .also { it.play() }
        }.onFailure { Log.w(TAG, "AudioTrack create failed: ${it.message}") }.getOrNull()
    }

    /** Linear 5 ms fade-in on 16-bit little-endian mono PCM. */
    private fun fadeIn(pcm: ByteArray): ByteArray {
        val out = pcm.copyOf()
        val n = minOf(FADE_SAMPLES, out.size / 2)
        for (i in 0 until n) {
            val v = (out[2 * i].toInt() and 0xFF) or (out[2 * i + 1].toInt() shl 8)
            val scaled = v * i / n
            out[2 * i] = (scaled and 0xFF).toByte()
            out[2 * i + 1] = ((scaled shr 8) and 0xFF).toByte()
        }
        return out
    }

    private fun resetPlayout() {
        synchronized(playLock) {
            playQueue.clear()
            playQueuedBytes = 0
            playPrebuffering = true
            playFadeNext = true
            playoutTargetBytes = PLAYOUT_TARGET_BYTES
            lastUnderrunAtMs = 0L
            lastDecayAtMs = 0L
            playLock.notifyAll()
        }
        playThread?.interrupt()
        playThread = null
        playDrop.set(0)
        playUnderruns.set(0)
        resetVideoPlayout()
    }

    private fun resetVideoState() {
        uplinkRoute.set(null)
        uplinkRouteResolving.set(false)
        videoInFlight.set(0)
        audioInFlight.set(0)
        uplinkFailStreak.set(0)
        uplinkFailLogged.set(0)
        videoFrameId.set(0)
        peerVideoCaps.set(0)
        capsSent.set(0)
        videoSeqOffset.set(0)
        ownChanV2.set(false)
        peerV2.set(null)
        v2Disabled.set(false)
        v2PausedUntil = 0L
        v2TxOk.set(0)
        v2Rx.set(0)
        stats.reset()
        statsUnderrunsSeen.set(0)
        synchronized(rxLock) {
            rxAudioStartMs = 0L
            rxAudioBytes = 0L
            rxAudioPackets = 0
        }
        resetPlayout()
    }

    // MARK: - Shared route

    /**
     * Peer route for uplink posts. Resolved off the main thread once per call;
     * returns null (and starts a resolve) until it is ready.
     */
    private fun routeOrResolve(active: BeamioNativeVoiceSignaling.ActiveCall): UplinkRoute? {
        uplinkRoute.get()?.let { return it }
        val app = appCtx.get() ?: return null
        if (uplinkRouteResolving.compareAndSet(false, true)) {
            io.execute {
                try {
                    resolveRoute(app, active)?.let {
                        if (uplinkRoute.compareAndSet(null, it) &&
                            (capsSent.get() == 0 || peerVideoCaps.get() == 0)
                        ) {
                            sendMediaCaps("route")
                        }
                    }
                } finally {
                    uplinkRouteResolving.set(false)
                }
            }
        }
        return null
    }

    private fun resolveRoute(context: Context, active: BeamioNativeVoiceSignaling.ActiveCall): UplinkRoute? {
        val secrets = BeamioChatPgpStore.load(context) ?: run {
            Log.w(TAG, "uplink route — no ChatPgp secrets")
            return null
        }
        val peer = active.peerEoa.lowercase()
        if (!peer.matches(Regex("^0x[0-9a-f]{40}$"))) {
            Log.w(TAG, "uplink route — bad peerEoa")
            return null
        }
        val roster = BeamioNativeVoiceSignaling.rosterOf(secrets)
        val (routeArmored, exclude) = peerSessionRoute(active, peer, roster, secrets) ?: run {
            Log.w(TAG, "uplink route — peer session route missing")
            return null
        }
        val entry = pickEntryIp(roster, exclude) ?: run {
            Log.w(TAG, "uplink route — no entry node")
            return null
        }
        Log.i(TAG, "uplink route first entry=$entry")
        val route = UplinkRoute(routeArmored, roster, exclude, EntryRotation(entry))
        refillEntries(route)
        return route
    }

    /**
     * Route key of the node holding the peer's voice session, plus the IPs an
     * entry must not be. Callee: the caller's per-call relay node from the
     * signed offer (older offers: the caller's mailbox). Dialer: the callee's
     * mailbox, where the callee listens.
     */
    private fun peerSessionRoute(
        active: BeamioNativeVoiceSignaling.ActiveCall,
        peer: String,
        roster: List<BeamioChatPgpStore.SiNode>,
        secrets: BeamioChatPgpStore.Secrets,
    ): Pair<String, Set<String>>? {
        val own = BeamioSiCipherPost.normalizeIp(secrets.mailboxIp)
        val relay = active.offer.relayRouteArmored
        if (active.role == BeamioNativeVoiceSignaling.Role.CALLEE && relay.contains("BEGIN PGP PUBLIC KEY")) {
            val exclude = setOfNotNull(BeamioSiCipherPost.normalizeIp(active.offer.relayIp), own)
            return relay to exclude
        }
        val keys = BeamioAddressPgp.searchKey(peer)
        if (keys == null || !keys.routePublicKeyArmored.contains("BEGIN PGP PUBLIC KEY")) return null
        val exclude = setOfNotNull(BeamioAddressPgp.mailboxIp(keys.routePgpKeyID, roster), own)
        return keys.routePublicKeyArmored to exclude
    }

    /** Probe more entries in the background until the pool has [ENTRY_POOL_TARGET]. */
    private fun refillEntries(route: UplinkRoute) {
        if (route.entries.size() >= ENTRY_POOL_TARGET) return
        if (!entryRefillRunning.compareAndSet(false, true)) return
        io.execute {
            try {
                var attempts = 0
                while (route.entries.size() < ENTRY_POOL_TARGET && attempts < ENTRY_POOL_TARGET * 2) {
                    attempts++
                    val ip = pickEntryIp(route.roster, route.exclude + route.entries.known()) ?: break
                    route.entries.add(ip)
                }
                Log.i(TAG, "uplink entry pool size=${route.entries.size()}")
            } finally {
                entryRefillRunning.set(false)
            }
        }
    }

    /** SDK pick first; else any roster node outside [exclude] and not marked unreachable. */
    private fun pickEntryIp(roster: List<BeamioChatPgpStore.SiNode>, exclude: Set<String>): String? {
        runCatching { BeamioSiCipherPost.getRandomNode(roster, exclude) }.getOrNull()
            ?.ip?.let { BeamioSiCipherPost.normalizeIp(it) }?.let { return it }
        return roster.asSequence()
            .mapNotNull { BeamioSiCipherPost.normalizeIp(it.ip) }
            .filter { it !in exclude && !BeamioSiCipherPost.isMarkedUnreachable(it) }
            .toList()
            .randomOrNull()
    }

    /**
     * One direct `POST /post` to the call's entry (iOS `postDirect`). A late
     * frame is useless, so there is no retry. ok = HTTP 2xx and body `ok` not false.
     */
    /** Set by [postDirect] when the entry could not be reached (vs an app-level error). */
    private val lastPostUnreachable = ThreadLocal<Boolean>()
    /** `error` from the last refused POST on this thread (v2 fallback). */
    private val lastPostError = ThreadLocal<String>()

    /**
     * A v2 chunk the node refused. Auth / invalid chunk: v1 for the rest of the
     * call. Channel not found: v1 for [V2_PAUSE_MS], then v2 again.
     */
    private fun noteV2Outcome(ok: Boolean, error: String) {
        if (ok) {
            if (v2TxOk.incrementAndGet() == 1) Log.i(TAG, "first v2 chunk accepted")
            return
        }
        if (error == "voice_chunk_auth" || error == "invalid_voice_chunk") {
            if (v2Disabled.compareAndSet(false, true)) Log.w(TAG, "v2 chunk refused ($error); falling back to v1")
        } else if (error == "target_voice_session_not_found") {
            val now = System.currentTimeMillis()
            if (now >= v2PausedUntil) Log.w(TAG, "v2 chunk target missing; v1 for ${V2_PAUSE_MS}ms")
            v2PausedUntil = now + V2_PAUSE_MS
        }
    }

    private fun postDirect(armor: String, ip: String): Boolean {
        lastPostUnreachable.set(false)
        lastPostError.set("")
        val started = System.currentTimeMillis()
        var conn: HttpURLConnection? = null
        return try {
            val url = runCatching { BeamioSiCipherPost.postUrl(ip) }.getOrNull() ?: "http://$ip/post"
            conn = (URL(url).openConnection() as HttpURLConnection).apply {
                requestMethod = "POST"
                connectTimeout = 6_000
                readTimeout = 6_000
                doOutput = true
                setRequestProperty("Content-Type", "application/json")
            }
            val body = JSONObject().put("data", armor).toString().toByteArray(Charsets.UTF_8)
            conn.outputStream.use { it.write(body) }
            val status = conn.responseCode
            val text = runCatching {
                (if (status in 200..299) conn.inputStream else conn.errorStream)
                    ?.bufferedReader()?.use { it.readText() }.orEmpty()
            }.getOrDefault("")
            var ok = status in 200..299
            if (ok) {
                runCatching { JSONObject(text) }.getOrNull()?.let { obj ->
                    if (obj.has("ok")) ok = obj.optBoolean("ok", false)
                    if (!ok) lastPostError.set(obj.optString("error"))
                }
            }
            if (!ok) {
                val f = uplinkFailLogged.incrementAndGet()
                if (f <= 5 || f % 50 == 0) {
                    Log.w(TAG, "uplink post fail ip=$ip status=$status body=${text.take(120)} count=$f")
                }
            }
            ok
        } catch (e: Exception) {
            val f = uplinkFailLogged.incrementAndGet()
            if (f <= 5 || f % 50 == 0) {
                Log.w(TAG, "uplink post error ip=$ip ${e.javaClass.simpleName}: ${e.message} count=$f")
            }
            // Unreachable entry: score it out so the next pick avoids it.
            lastPostUnreachable.set(true)
            runCatching {
                BeamioSiCipherPost.scoreEntry(ip, false, (System.currentTimeMillis() - started).toInt())
            }
            false
        } finally {
            conn?.disconnect()
        }
    }

    /** Count outcomes; three failures in a row drop the route so a new entry is picked. */
    private fun finishUplink(ok: Boolean, route: UplinkRoute) {
        if (ok) {
            uplinkFailStreak.set(0)
            return
        }
        if (uplinkFailStreak.incrementAndGet() >= 3) {
            uplinkFailStreak.set(0)
            if (uplinkRoute.compareAndSet(route, null)) {
                Log.w(TAG, "uplink entries failing — re-resolve route")
            }
        }
    }

    // MARK: - Video

    /**
     * Send one camera frame as `BJPG`. Frames are dropped (not queued) while
     * [MAX_VIDEO_IN_FLIGHT] posts are pending, so video can never back up audio.
     */
    fun sendVideoJpegFrame(
        jpeg: ByteArray,
        width: Int,
        height: Int,
        // The capture calls this on its analyzer thread right after encoding.
        encodeMs: Long = BeamioInCallVideoCapture.lastEncodeMs,
    ) {
        val captureMs = System.currentTimeMillis()
        val active = activeRef.get() ?: return
        if (!running.get() || !mediaLive.get() || jpeg.isEmpty()) return
        if (active.peerMediaSessionId.isBlank()) return
        stats.update {
            it.txCap += 1
            if (encodeMs >= 0) {
                it.capEncodeN += 1
                it.capEncodeMsSum += encodeMs
                it.capEncodeMsMax = maxOf(it.capEncodeMsMax, encodeMs)
            }
        }
        maybeFlushStats()
        val route = routeOrResolve(active) ?: run {
            stats.update { it.txDropRoute += 1 }
            return
        }
        // Audio first: skip video while audio has half its send slots in use.
        if (audioInFlight.get() >= MAX_AUDIO_IN_FLIGHT / 2) {
            stats.update { it.txDropAudio += 1 }
            return
        }
        if (videoInFlight.incrementAndGet() > MAX_VIDEO_IN_FLIGHT) {
            videoInFlight.decrementAndGet()
            stats.update { it.txDropBusy += 1 }
            return
        }
        val frameId = videoFrameId.incrementAndGet()
        // Split-seq + BJP2 only after the peer announced support; older peers
        // keep the shared-seq BJPG they understand.
        val split = peerVideoCaps.get() >= 2
        val header = if (split) 20 else 12
        val framed = ByteArray(header + jpeg.size)
        System.arraycopy(if (split) JP2_MAGIC else JPG_MAGIC, 0, framed, 0, 4)
        putLe16(framed, 4, width)
        putLe16(framed, 6, height)
        putLe32(framed, 8, frameId)
        if (split) putLe64(framed, 12, captureMs)
        System.arraycopy(jpeg, 0, framed, header, jpeg.size)
        val seq = if (split) VIDEO_SEQ_BASE + videoSeqOffset.incrementAndGet() else null
        postUplink(active, route, framed, mediaKind = "video", seqOverride = seq, jpegBytes = jpeg.size) {
            videoInFlight.decrementAndGet()
        }
    }

    /**
     * Announce what this build can receive (`voice_media_caps_v1`, AES control on
     * the shared seq). Old peers log the unknown type and ignore it.
     */
    private fun sendMediaCaps(reason: String) {
        if (legacyMode) return
        val active = activeRef.get() ?: return
        if (!running.get() || !mediaLive.get()) return
        if (active.peerMediaSessionId.isBlank()) return
        val route = uplinkRoute.get() ?: return
        capsSent.incrementAndGet()
        val body = JSONObject()
            .put("type", "voice_media_caps_v1")
            .put("callId", active.offer.callId)
            .put("sessionId", active.listenSessionId)
            .put("video", LOCAL_VIDEO_CAPS)
            .put("timestamp", System.currentTimeMillis())
        // v2: our node holds a v2 channel; give the peer its write key (inside AES).
        if (ownChanV2.get()) {
            body.put("chan", 2)
            body.put("wk", android.util.Base64.encodeToString(ownWriteKey, android.util.Base64.NO_WRAP))
        }
        postUplink(active, route, body.toString().toByteArray(Charsets.UTF_8), mediaKind = null) {}
        Log.i(TAG, "media caps sent video=$LOCAL_VIDEO_CAPS chan=${if (ownChanV2.get()) 2 else 1} reason=$reason")
    }

    /** Peer capability from `voice_media_caps_v1` or a video enable control. */
    private fun notePeerCaps(json: JSONObject) {
        if (!legacyMode && peerV2.get() == null && json.optInt("chan", 1) == 2) {
            val wk = runCatching { android.util.Base64.decode(json.optString("wk"), android.util.Base64.DEFAULT) }.getOrNull()
            val loc = activeRef.get()?.let { BeamioVoiceChannelV2.locator(it.peerMediaSessionId) }
            if (wk != null && wk.size == 32 && loc != null) {
                peerV2.set(BeamioVoiceChannelV2.Peer(loc, wk))
                Log.i(TAG, "peer channel v2")
            }
        }
        val video = json.optInt("video", 0)
        if (legacyMode || video <= 0) return
        val prev = peerVideoCaps.getAndSet(video)
        if (prev != video) Log.i(TAG, "peer media caps video=$video")
        // Reply once so both sides know even if our first announcement was lost.
        if (prev == 0 && json.optString("type") == "voice_media_caps_v1") sendMediaCaps("reply")
    }

    private fun maybeFlushStats() {
        val underruns = playUnderruns.get()
        val seen = statsUnderrunsSeen.getAndSet(underruns)
        if (underruns > seen) stats.update { it.audioUnderrun += underruns - seen }
        val mode = when {
            legacyMode -> "legacy"
            peerVideoCaps.get() >= 2 -> "v2"
            else -> "v1"
        }
        stats.maybeFlush(TAG, mode, peerVideoCaps.get())
    }

    /** Tell the peer this side's camera turned on or off. Does not touch the call. */
    fun sendVideoEnableControl(enabled: Boolean) {
        val active = activeRef.get() ?: return
        if (!running.get() || !mediaLive.get()) return
        if (active.peerMediaSessionId.isBlank()) return
        val route = routeOrResolve(active) ?: return
        val body = JSONObject()
            .put("type", if (enabled) "voice_video_enable_v1" else "voice_video_disable_v1")
            .put("callId", active.offer.callId)
            .put("sessionId", active.listenSessionId)
            .put("from", active.localEoa)
            // Inside the AES payload: the peer learns our capability even if
            // the caps frame was lost.
            .put("video", if (legacyMode) 0 else LOCAL_VIDEO_CAPS)
            .put("timestamp", System.currentTimeMillis())
        postUplink(active, route, body.toString().toByteArray(Charsets.UTF_8), mediaKind = null) {}
        Log.i(TAG, "video control enabled=$enabled callId=${active.offer.callId.take(12)}")
    }

    /** AES + route PGP + SI post on the io pool. [done] always runs once. */
    private fun postUplink(
        active: BeamioNativeVoiceSignaling.ActiveCall,
        route: UplinkRoute,
        plain: ByteArray,
        mediaKind: String?,
        seqOverride: Int? = null,
        jpegBytes: Int = 0,
        done: () -> Unit,
    ) {
        val app = appCtx.get() ?: run { done(); return }
        val seq = seqOverride ?: uplinkSeq.getAndIncrement()
        val isVideo = mediaKind == "video"
        val isAudio = mediaKind == null && startsWith(plain, PCM_MAGIC)
        val nowMs = System.currentTimeMillis()
        val encStarted = System.currentTimeMillis()
        val onArmor: (String?, Boolean) -> Unit = { armor, usedV2 ->
            postUplinkArmor(route, armor, usedV2, seq, mediaKind, isVideo, isAudio, jpegBytes, encStarted, done)
        }
        val peer = peerV2.get()
        if (!legacyMode && !v2Disabled.get() && peer != null && nowMs >= v2PausedUntil) {
            val kind = when {
                isVideo -> BeamioVoiceChannelV2.KIND_VIDEO
                isAudio -> BeamioVoiceChannelV2.KIND_AUDIO
                else -> BeamioVoiceChannelV2.KIND_CONTROL
            }
            val literal = runCatching {
                BeamioVoiceChannelV2.sealChunk(active.offer.sessionKey, peer, kind, seq, nowMs, 0, plain)
            }.getOrNull()
            if (literal != null) {
                BeamioNativeRoutePgp.encryptBinaryAsync(route.routeArmored, literal) { result ->
                    val armor = result.getOrNull()
                    if (armor != null) {
                        onArmor(armor, true)
                    } else {
                        postUplinkV1(app, active, route, plain, seq, nowMs, mediaKind, onArmor)
                    }
                }
                return
            }
        }
        postUplinkV1(app, active, route, plain, seq, nowMs, mediaKind, onArmor)
    }

    /** v1 `voice_uplink` route command (no wallet fields). */
    private fun postUplinkV1(
        app: Context,
        active: BeamioNativeVoiceSignaling.ActiveCall,
        route: UplinkRoute,
        plain: ByteArray,
        seq: Int,
        nowMs: Long,
        mediaKind: String?,
        onArmor: (String?, Boolean) -> Unit,
    ) {
        val payload = try {
            BeamioVoiceAesGcm.encryptBytes(active.offer.sessionKey, plain)
        } catch (e: Exception) {
            onArmor(null, false)
            return
        }
        val uplink = JSONObject()
            // Route command read by the peer's mailbox: no wallet fields (the
            // relay needs only session ids).
            .put("command", "voice_uplink")
            .put("type", "voice_frame_v1")
            .put("callId", active.offer.callId)
            .put("sessionId", active.listenSessionId)
            .put("targetSessionId", active.peerMediaSessionId)
            .put("direction", "uplink")
            .put("seq", seq)
            .put("frameTimestamp", nowMs)
            .put("payload", payload)
            .put("timestamp", nowMs / 1000L)
        if (mediaKind != null) uplink.put("mediaKind", mediaKind)
        BeamioNativeRoutePgp.encryptToRouteAsync(app, route.routeArmored, uplink.toString()) { result ->
            onArmor(result.getOrNull(), false)
        }
    }

    /** Stats + entry POST for one built frame. [done] always runs once. */
    private fun postUplinkArmor(
        route: UplinkRoute,
        armor: String?,
        usedV2: Boolean,
        seq: Int,
        mediaKind: String?,
        isVideo: Boolean,
        isAudio: Boolean,
        jpegBytes: Int,
        encStarted: Long,
        done: () -> Unit,
    ) {
        run {
            val encMs = System.currentTimeMillis() - encStarted
            if (armor.isNullOrBlank() || !armor.contains("BEGIN PGP MESSAGE")) {
                done()
                return
            }
            if (isVideo) {
                stats.update {
                    it.txSent += 1
                    it.txJpegBytes += jpegBytes
                    it.txWireBytes += armor.length
                    it.txEncMsSum += encMs
                }
            } else if (isAudio) {
                stats.update {
                    it.audioTx += 1
                    it.audioTxWireBytes += armor.length
                }
            }
            io.execute {
                try {
                    val entryIp = route.entries.next()
                    val postStarted = System.currentTimeMillis()
                    val queueMs = postStarted - encStarted - encMs
                    val ok = entryIp != null && postDirect(armor, entryIp)
                    val postMs = System.currentTimeMillis() - postStarted
                    if (usedV2) noteV2Outcome(ok, lastPostError.get().orEmpty())
                    if (isAudio) synchronized(audioTally) {
                        val t = audioTally[if (usedV2) 1 else 0]
                        t.n += 1
                        if (!ok) t.fail += 1
                        t.bytes += armor.length
                        t.encMs += encMs
                        t.postMs += postMs
                        t.postMax = maxOf(t.postMax, postMs)
                    }
                    if (isVideo) {
                        stats.update {
                            if (ok) it.txOk += 1 else it.txFail += 1
                            it.txPostMsSum += postMs
                            it.txPostMsMax = maxOf(it.txPostMsMax, postMs)
                        }
                    }
                    if (encMs + queueMs + postMs >= 900) {
                        // Diagnostics: which step makes a frame late (sender gaps on the peer).
                        Log.i(TAG, "uplink slow seq=$seq enc=${encMs}ms queue=${queueMs}ms post=${postMs}ms ok=$ok entry=$entryIp kind=${mediaKind ?: "audio"}")
                    }
                    if (ok && entryIp != null &&
                        route.entries.recordLatency(entryIp, System.currentTimeMillis() - postStarted)
                    ) {
                        Log.i(TAG, "uplink entry $entryIp slow — dropped from pool")
                    }
                    // Only an unreachable entry leaves the pool; an app-level
                    // error (closed peer session) says nothing about the entry.
                    if (!ok && entryIp != null && lastPostUnreachable.get() == true) {
                        route.entries.markFailed(entryIp)
                    }
                    if (route.entries.size() < ENTRY_POOL_MIN) refillEntries(route)
                    if (ok) {
                        lastTxOkAt = System.currentTimeMillis()
                        val n = uplinkPostOk.incrementAndGet()
                        if (n <= 3 || n % 100 == 0) {
                            Log.i(TAG, "uplink post ok seq=$seq kind=${mediaKind ?: "audio/control"} okCount=$n entry=$entryIp pool=${route.entries.size()}")
                        }
                    }
                    finishUplink(ok, route)
                } finally {
                    done()
                }
            }
        }
    }

    private fun putLe16(out: ByteArray, at: Int, value: Int) {
        val v = value.coerceIn(0, 0xFFFF)
        out[at] = (v and 0xFF).toByte()
        out[at + 1] = ((v shr 8) and 0xFF).toByte()
    }

    private fun putLe64(out: ByteArray, at: Int, value: Long) {
        for (i in 0 until 8) out[at + i] = ((value shr (8 * i)) and 0xFF).toByte()
    }

    private fun getLe64(src: ByteArray, at: Int): Long {
        var v = 0L
        for (i in 0 until 8) v = v or ((src[at + i].toLong() and 0xFF) shl (8 * i))
        return v
    }

    private fun putLe32(out: ByteArray, at: Int, value: Int) {
        out[at] = (value and 0xFF).toByte()
        out[at + 1] = ((value shr 8) and 0xFF).toByte()
        out[at + 2] = ((value shr 16) and 0xFF).toByte()
        out[at + 3] = ((value shr 24) and 0xFF).toByte()
    }
}
