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
 * Native temporary voice relay: `voice_listen` SSE + AES PCM uplink/downlink.
 * No PWA — EncryptedSharedPreferences route PGP + `BeamioSiCipherPost` entry path.
 */
object BeamioNativeVoiceChannel {
    private const val TAG = "BeamioNativeVoiceCh"
    private const val SAMPLE_RATE = 16_000
    private val io = Executors.newCachedThreadPool()
    private val running = AtomicBoolean(false)
    private val mediaLive = AtomicBoolean(false)
    private val uplinkSeq = AtomicInteger(1)
    private val activeRef = AtomicReference<BeamioNativeVoiceSignaling.ActiveCall?>(null)
    private val appCtx = AtomicReference<Context?>(null)
    private var listenConn: HttpURLConnection? = null
    private var audioRecord: AudioRecord? = null
    private var audioTrack: AudioTrack? = null
    private val captureStarted = AtomicBoolean(false)

    fun start(context: Context, active: BeamioNativeVoiceSignaling.ActiveCall) {
        val app = context.applicationContext
        appCtx.set(app)
        stopInternal(keepApp = true)
        activeRef.set(active)
        running.set(true)
        mediaLive.set(active.mediaEnabled)
        uplinkSeq.set(1)
        captureStarted.set(false)
        Log.i(
            TAG,
            "start role=${active.role} callId=${active.offer.callId.take(12)} listen=${active.listenSessionId.take(12)} media=${active.mediaEnabled}",
        )
        io.execute { startVoiceListen(app, active) }
        if (active.mediaEnabled) {
            io.execute { startCapture(app, active) }
        }
    }

    /** Dialer: remote accept arrived — enable PCM capture/playback on existing listen. */
    fun enableMedia(context: Context, active: BeamioNativeVoiceSignaling.ActiveCall) {
        val app = context.applicationContext
        appCtx.set(app)
        activeRef.set(active)
        mediaLive.set(true)
        Log.i(TAG, "enableMedia peerSession=${active.peerMediaSessionId.take(12)}")
        if (running.get() && captureStarted.compareAndSet(false, true)) {
            io.execute { startCapture(app, active) }
        }
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
        captureStarted.set(false)
        try {
            listenConn?.disconnect()
        } catch (_: Exception) {
        }
        listenConn = null
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
            io.execute { postVoiceUnlisten(app, listenSessionId) }
        }
        Log.i(TAG, "stopped")
    }

    /** Best-effort `voice_unlisten` to own mailbox route (entry ≠ B). SI drops session without EIP-191. */
    private fun postVoiceUnlisten(app: Context, sessionId: String) {
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
            BeamioOpenPgpHost.shared(app).encryptToRoute(
                secrets.routePublicKeyArmor,
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
            }
            val posted = BeamioSiCipherPost.post(encrypted, roster, exclude, maxAttempts = 3)
            Log.i(TAG, "voice_unlisten session=${sessionId.take(12)} ok=${posted.ok}")
        } catch (e: Exception) {
            Log.w(TAG, "voice_unlisten failed: ${e.message}")
        }
    }

    private fun startVoiceListen(context: Context, active: BeamioNativeVoiceSignaling.ActiveCall) {
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
        // Dialer owns VoIP wake: mailbox notifies callee when offerArmor is present.
        val wake = active.dialerWake
        if (
            wake != null &&
            wake.offerArmor.contains("BEGIN PGP MESSAGE") &&
            wake.calleeEoa.isNotBlank() &&
            wake.callId.isNotBlank()
        ) {
            commandObj.put("callId", wake.callId)
            commandObj.put("targetWallet", wake.calleeEoa)
            commandObj.put("expiresAt", wake.expiresAt)
            commandObj.put("pushTimestamp", wake.pushTimestamp)
            commandObj.put("offerArmor", wake.offerArmor)
        }
        val command = commandObj.toString()

        val encryptWait = Object()
        var armor: String? = null
        var encryptError: String? = null
        BeamioOpenPgpHost.shared(context).encryptToRoute(
            secrets.routePublicKeyArmor,
            command,
        ) { result ->
            result.onSuccess { armor = it }
                .onFailure { encryptError = it.message }
            synchronized(encryptWait) { encryptWait.notifyAll() }
        }
        synchronized(encryptWait) {
            if (armor == null && encryptError == null) encryptWait.wait(12_000L)
        }
        val encrypted = armor
        if (encrypted.isNullOrBlank() || !encrypted.contains("BEGIN PGP MESSAGE")) {
            Log.w(TAG, "listen encrypt failed: ${encryptError ?: "timeout"}")
            return
        }

        val roster = BeamioNativeVoiceSignaling.rosterOf(secrets)
        val exclude = buildSet {
            BeamioSiCipherPost.normalizeIp(secrets.mailboxIp)?.let { add(it) }
        }
        val entry = BeamioSiCipherPost.getRandomNode(roster, excludeIps = exclude)
        val entryIp = entry?.let { BeamioSiCipherPost.normalizeIp(it.ip) }
        if (entryIp == null) {
            Log.w(TAG, "listen — no reachable entry IP")
            return
        }
        val url = BeamioSiCipherPost.postUrl(entryIp) ?: return
        val body = JSONObject().put("data", encrypted).toString()
        Log.i(TAG, "voice_listen entry=$entryIp session=${active.listenSessionId.take(12)}")

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
            val stream = BufferedInputStream(conn.inputStream)
            val buf = ByteArray(4096)
            val sse = StringBuilder()
            while (running.get()) {
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
        }
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
            Log.i(TAG, "listen handshake ok")
            return
        }
        val type = obj.optString("type")
        val command = obj.optString("command")
        if (type == "voice_frame_v1" || command == "voice_uplink") {
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
        val asText = try {
            String(plain, Charsets.UTF_8)
        } catch (_: Exception) {
            null
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
                }
                return
            } catch (_: Exception) {
                // fall through to PCM
            }
        }
        if (!mediaLive.get()) return
        playPcm(plain)
    }

    private fun startCapture(context: Context, active: BeamioNativeVoiceSignaling.ActiveCall) {
        captureStarted.set(true)
        if (ContextCompat.checkSelfPermission(context, Manifest.permission.RECORD_AUDIO)
            != PackageManager.PERMISSION_GRANTED
        ) {
            Log.w(TAG, "RECORD_AUDIO not granted — no uplink")
            return
        }
        val minBuf = AudioRecord.getMinBufferSize(
            SAMPLE_RATE,
            AudioFormat.CHANNEL_IN_MONO,
            AudioFormat.ENCODING_PCM_16BIT,
        )
        if (minBuf <= 0) {
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
            Log.w(TAG, "AudioRecord create fail: ${e.message}")
            return
        }
        if (record.state != AudioRecord.STATE_INITIALIZED) {
            record.release()
            Log.w(TAG, "AudioRecord not initialized")
            return
        }
        audioRecord = record
        try {
            record.startRecording()
        } catch (e: Exception) {
            Log.w(TAG, "startRecording fail: ${e.message}")
            return
        }
        Log.i(TAG, "capture started 16k mono")
        val buf = ByteArray(minBuf)
        while (running.get() && mediaLive.get()) {
            val n = try {
                record.read(buf, 0, buf.size)
            } catch (_: Exception) {
                break
            }
            if (n <= 0) continue
            val live = activeRef.get() ?: active
            uplinkPcm(context, buf.copyOf(n), live)
        }
    }

    private fun uplinkPcm(
        context: Context,
        pcm: ByteArray,
        active: BeamioNativeVoiceSignaling.ActiveCall,
    ) {
        if (!running.get() || !mediaLive.get() || pcm.isEmpty()) return
        if (active.peerMediaSessionId.isBlank()) return
        val peer = active.peerEoa.lowercase()
        if (!peer.matches(Regex("^0x[0-9a-f]{40}$"))) return
        val seq = uplinkSeq.getAndIncrement()
        val payload = try {
            BeamioVoiceAesGcm.encryptBytes(active.offer.sessionKey, pcm)
        } catch (_: Exception) {
            return
        }
        val nowMs = System.currentTimeMillis()
        val secrets = BeamioChatPgpStore.load(context) ?: return
        val localEoa = active.localEoa
        val keys = BeamioAddressPgp.searchKey(peer) ?: return
        if (!keys.routePublicKeyArmored.contains("BEGIN PGP PUBLIC KEY")) return
        val roster = BeamioNativeVoiceSignaling.rosterOf(secrets)
        val exclude = buildSet {
            BeamioAddressPgp.mailboxIp(keys.routePgpKeyID, roster)?.let { add(it) }
            BeamioSiCipherPost.normalizeIp(secrets.mailboxIp)?.let { add(it) }
        }
        val uplink = JSONObject()
            .put("command", "voice_uplink")
            .put("type", "voice_frame_v1")
            .put("walletAddress", localEoa)
            .put("from", localEoa)
            .put("callId", active.offer.callId)
            .put("sessionId", active.listenSessionId)
            .put("targetSessionId", active.peerMediaSessionId)
            .put("to", peer)
            .put("direction", "uplink")
            .put("seq", seq)
            .put("frameTimestamp", nowMs)
            .put("payload", payload)
            .put("timestamp", nowMs / 1000L)

        BeamioOpenPgpHost.shared(context).encryptToRoute(
            keys.routePublicKeyArmored,
            uplink.toString(),
        ) { result ->
            val armor = result.getOrNull() ?: return@encryptToRoute
            if (!armor.contains("BEGIN PGP MESSAGE")) return@encryptToRoute
            BeamioSiCipherPost.post(armor, roster, exclude, maxAttempts = 2)
        }
    }

    private fun playPcm(pcm: ByteArray) {
        if (pcm.isEmpty() || !running.get() || !mediaLive.get()) return
        var track = audioTrack
        if (track == null) {
            val minBuf = AudioTrack.getMinBufferSize(
                SAMPLE_RATE,
                AudioFormat.CHANNEL_OUT_MONO,
                AudioFormat.ENCODING_PCM_16BIT,
            )
            if (minBuf <= 0) return
            track = AudioTrack.Builder()
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
                .setBufferSizeInBytes(minBuf * 2)
                .setTransferMode(AudioTrack.MODE_STREAM)
                .build()
            audioTrack = track
            try {
                track.play()
            } catch (_: Exception) {
                return
            }
        }
        try {
            track.write(pcm, 0, pcm.size)
        } catch (_: Exception) {
        }
    }
}
