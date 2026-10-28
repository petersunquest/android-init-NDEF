package com.beamio.app
import network.conet.chat.BeamioOpenPgpHost
import network.conet.chat.BeamioSiCipherPost
import network.conet.chat.BeamioChatPgpStore

import android.content.Context
import android.os.Handler
import android.os.Looper
import android.os.PowerManager
import android.util.Log
import org.json.JSONObject
import java.security.SecureRandom
import java.util.concurrent.ConcurrentHashMap
import java.util.concurrent.Executors
import java.util.concurrent.atomic.AtomicReference

/**
 * Native voice signaling over entry nodes (`BeamioSiCipherPost`) — no PWA.
 * Decline / Accept: AES-GCM control → `voice_uplink` encrypted to **caller mailbox route PGP**.
 * Dialer: native `voice_listen` on offer.sessionId to receive accept/reject + own media.
 */
object BeamioNativeVoiceSignaling {
    private const val TAG = "BeamioNativeVoice"
    private val io = Executors.newSingleThreadExecutor()
    private val main = Handler(Looper.getMainLooper())
    private val cache = ConcurrentHashMap<String, BeamioVoiceOfferIdentity.ResolvedIdentity>()
    private val inFlightDecline = ConcurrentHashMap.newKeySet<String>()
    private val inFlightAccept = ConcurrentHashMap.newKeySet<String>()
    private val activeCall = AtomicReference<ActiveCall?>(null)
    /** Second call while the glass window or an active call owns the mic. Uplink waits until both are gone. */
    private data class DeferredStickyDecline(
        val callId: String,
        val sessionId: String,
        val reason: String,
    )
    private val deferredStickyDeclines = mutableListOf<DeferredStickyDecline>()
    private val deferredLock = Any()

    enum class Role {
        CALLEE,
        DIALER,
    }

    /** Dialer-only: VoIP wake + offerArmor for mailbox `voice_listen` (native owns push). */
    data class DialerWake(
        val callId: String,
        val calleeEoa: String,
        val expiresAt: Long,
        /** Unix seconds for mailbox pushTimestamp. */
        val pushTimestamp: Long,
        val offerArmor: String,
    )

    data class ActiveCall(
        val role: Role,
        val offer: BeamioVoiceOfferIdentity.ResolvedIdentity,
        /** Local `voice_listen` sessionId. */
        val listenSessionId: String,
        /** Peer listen for uplink `targetSessionId` (dialer: empty until accept). */
        val peerMediaSessionId: String,
        /** Encrypt-to / uplink `to`. */
        val peerEoa: String,
        val localEoa: String,
        /** Dialer starts listen-only until remote accept enables PCM. */
        val mediaEnabled: Boolean,
        val dialerWake: DialerWake? = null,
    ) {
        /** Callee accept listen id (compat alias). */
        val acceptSessionId: String get() = listenSessionId
    }

    fun rememberOffer(resolved: BeamioVoiceOfferIdentity.ResolvedIdentity) {
        if (resolved.callId.isBlank() || resolved.sessionKey.isBlank()) return
        cache[resolved.callId] = resolved
        if (resolved.sessionId.isNotBlank()) {
            cache[resolved.sessionId] = resolved
        }
    }

    fun cachedOffer(callId: String, sessionId: String): BeamioVoiceOfferIdentity.ResolvedIdentity? {
        if (callId.isNotBlank()) cache[callId]?.let { return it }
        if (sessionId.isNotBlank()) cache[sessionId]?.let { return it }
        return null
    }

    fun forgetOffer(callId: String, sessionId: String) {
        if (callId.isNotBlank()) cache.remove(callId)
        if (sessionId.isNotBlank()) cache.remove(sessionId)
        val cur = activeCall.get()
        if (cur != null && (cur.offer.callId == callId || cur.offer.sessionId == sessionId)) {
            activeCall.compareAndSet(cur, null)
        }
    }

    fun currentActiveCall(): ActiveCall? = activeCall.get()

    fun updateActiveCall(next: ActiveCall) {
        activeCall.set(next)
    }

    fun clearActiveCall() {
        activeCall.set(null)
        flushDeferredStickyDeclinesIfIdle()
    }

    /** Mailbox `voice_listen` accepts `[0-9a-fA-F-]{16,64}` — 32 hex chars. */
    fun randomMailboxVoiceSessionId(): String {
        val bytes = ByteArray(16).also { SecureRandom().nextBytes(it) }
        return bytes.joinToString("") { b -> "%02x".format(b) }
    }

    // MARK: - Dialer (outgoing)

    /**
     * Native owns dialer `voice_listen` + VoIP wake (offerArmor). PWA must not
     * start worker listen on the same sessionId (SI session_conflict).
     */
    fun attachOutgoingDialer(
        context: Context,
        callId: String,
        sessionId: String,
        sessionKey: String,
        peerEoa: String,
        wake: DialerWake? = null,
    ) {
        val app = context.applicationContext
        val trimmedCall = callId.trim()
        val trimmedSession = sessionId.trim()
        val trimmedKey = sessionKey.trim()
        val peer = peerEoa.trim().lowercase()
        if (trimmedSession.isBlank() || trimmedKey.isBlank()) {
            Log.w(TAG, "dialer skip — missing sessionId/sessionKey")
            return
        }
        if (!peer.matches(Regex("^0x[0-9a-f]{40}$"))) {
            Log.w(TAG, "dialer skip — bad peerEoa")
            return
        }
        val secrets = BeamioChatPgpStore.load(app) ?: run {
            Log.w(TAG, "dialer — missing Chat PGP secrets")
            return
        }
        val localEoa = secrets.eoa.trim().lowercase()
        if (!localEoa.matches(Regex("^0x[0-9a-f]{40}$"))) {
            Log.w(TAG, "dialer — missing local eoa")
            return
        }
        val resolvedWake = wake?.let { raw ->
            val normalized = DialerWake(
                callId = raw.callId.trim().ifBlank {
                    if (trimmedCall.isBlank()) trimmedSession else trimmedCall
                },
                calleeEoa = raw.calleeEoa.trim().lowercase().ifBlank { peer },
                expiresAt = raw.expiresAt,
                pushTimestamp = raw.pushTimestamp,
                offerArmor = raw.offerArmor.trim(),
            )
            if (!normalized.offerArmor.contains("BEGIN PGP MESSAGE")) {
                Log.w(TAG, "dialer — wake offerArmor missing; listen without push")
                null
            } else {
                normalized
            }
        }
        val offer = BeamioVoiceOfferIdentity.ResolvedIdentity(
            callerEoa = localEoa,
            beamioTag = null,
            shortAddress = "",
            callId = if (trimmedCall.isBlank()) trimmedSession else trimmedCall,
            sessionId = trimmedSession,
            sessionKey = trimmedKey,
            to = peer,
        )
        rememberOffer(offer)
        val active = ActiveCall(
            role = Role.DIALER,
            offer = offer,
            listenSessionId = trimmedSession,
            peerMediaSessionId = "",
            peerEoa = peer,
            localEoa = localEoa,
            mediaEnabled = false,
            dialerWake = resolvedWake,
        )
        activeCall.set(active)
        Log.i(
            TAG,
            "dialer attach callId=${offer.callId.take(12)} session=${trimmedSession.take(12)} " +
                "peer=${peer.takeLast(8)} wake=${if (resolvedWake == null) "no" else "yes"}",
        )
        BeamioNativeVoiceChannel.start(app, active)
    }

    /** Remote accept on dialer listen — enable media + notify Telecom / PWA UI. */
    fun dialerDidReceiveAccept(context: Context, peerAcceptSessionId: String) {
        val peerSession = peerAcceptSessionId.trim()
        if (peerSession.isBlank()) return
        val cur = activeCall.get() ?: return
        if (cur.role != Role.DIALER) return
        val next = cur.copy(
            peerMediaSessionId = peerSession,
            mediaEnabled = true,
        )
        activeCall.set(next)
        Log.i(
            TAG,
            "dialer accept peerSession=${peerSession.take(12)} callId=${next.offer.callId.take(12)}",
        )
        BeamioNativeVoiceChannel.enableMedia(context.applicationContext, next)
        main.post {
            BeamioTelecomService.markOutgoingConnected(
                context.applicationContext,
                next.offer.callId,
                next.listenSessionId,
            )
            MainActivity.dispatchSystemCallAction(
                "callAnswered",
                next.offer.callId,
                next.listenSessionId,
                context.applicationContext,
            )
        }
    }

    /** Remote reject / timeout on dialer listen. */
    fun dialerDidReceiveReject(context: Context, action: String) {
        val cur = activeCall.get() ?: return
        if (cur.role != Role.DIALER) return
        val callId = cur.offer.callId
        val sessionId = cur.listenSessionId
        activeCall.set(null)
        val webAction = if (action == "callTimedOut") "callTimedOut" else "callRejected"
        Log.i(TAG, "dialer $webAction callId=${callId.take(12)}")
        BeamioNativeVoiceChannel.stop()
        main.post {
            MainActivity.dispatchSystemCallAction(
                webAction,
                callId,
                sessionId,
                context.applicationContext,
            )
            // Tear down Telecom UI without a second PWA emit (already sent reject/timeout).
            BeamioTelecomService.disconnectOutgoingQuiet(
                context.applicationContext,
                callId,
                sessionId,
            )
        }
    }

    // MARK: - Callee Decline / Accept

    /** iOS UIBackgroundTask parity — keep CPU awake for entry uplink. */
    private fun acquireUplinkWakeLock(context: Context, tag: String): PowerManager.WakeLock? {
        return try {
            val pm = context.getSystemService(Context.POWER_SERVICE) as PowerManager
            @Suppress("DEPRECATION")
            pm.newWakeLock(PowerManager.PARTIAL_WAKE_LOCK, "beamio:voice:$tag").also {
                it.setReferenceCounted(false)
                it.acquire(60_000L)
            }
        } catch (e: Exception) {
            Log.w(TAG, "wakeLock failed: ${e.message}")
            null
        }
    }

    /**
     * Telecom / notification Decline — fire-and-forget; skips PWA.
     *
     * [protectStickyChrome] is the busy path: the glass window or an in-call
     * WebView is live. Opening [BeamioOpenPgpHost] here replaces that window
     * (same failure as iOS OpenPgpHost WKWebView). Queue the ids and encrypt
     * only after chrome is idle. Default reason stays `declined` for a user Decline.
     */
    fun sendDecline(
        context: Context,
        callId: String,
        sessionId: String,
        reason: String = "declined",
        protectStickyChrome: Boolean = false,
    ) {
        val app = context.applicationContext
        if (protectStickyChrome) {
            val trimmedReason = reason.trim().ifBlank { "busy" }
            synchronized(deferredLock) {
                val already = deferredStickyDeclines.any {
                    it.callId == callId && it.sessionId == sessionId && it.reason == trimmedReason
                }
                if (!already) {
                    deferredStickyDeclines.add(
                        DeferredStickyDecline(callId, sessionId, trimmedReason),
                    )
                }
            }
            stickyDeclineApp = app
            Log.i(
                TAG,
                "decline deferred — no OpenPgp WebView while voice chrome is live " +
                    "callIdPresent=${callId.isNotBlank()}",
            )
            return
        }
        val key = "$callId|$sessionId"
        if (!inFlightDecline.add(key)) {
            Log.i(TAG, "decline already in-flight key=${key.take(24)}")
            return
        }
        io.execute {
            val wake = acquireUplinkWakeLock(app, "decline")
            try {
                var offer = cachedOffer(callId, sessionId)
                if (offer == null || offer.sessionKey.isBlank()) {
                    offer = BeamioVoiceOfferIdentity.resolveBlocking(app, callId, sessionId, 45_000L)
                }
                if (offer == null || offer.sessionKey.isBlank()) {
                    Log.w(TAG, "decline skip — no offer/sessionKey callId=${callId.take(12)}")
                    return@execute
                }
                val secrets = BeamioChatPgpStore.load(app) ?: run {
                    Log.w(TAG, "decline — no ChatPgp secrets")
                    return@execute
                }
                val localEoa = secrets.eoa.trim().lowercase()
                if (!localEoa.matches(Regex("^0x[0-9a-f]{40}$"))) {
                    Log.w(TAG, "decline — missing local eoa")
                    return@execute
                }
                val nowMs = System.currentTimeMillis()
                val body = JSONObject()
                    .put("type", "voice_call_reject_v1")
                    .put("callId", offer.callId)
                    .put("sessionId", offer.sessionId)
                    .put("from", localEoa)
                    .put("to", offer.callerEoa.lowercase())
                    .put("reason", reason.ifBlank { "declined" })
                    .put("createdAt", nowMs)
                    .put("timestamp", nowMs)
                // Dialer listen may not be registered yet → SI
                // target_voice_session_not_found. Retry briefly; PWA also
                // sends user-PGP gossip as the durable backup.
                var ok = false
                var attempt = 0
                while (attempt < 4 && !ok) {
                    if (attempt > 0) {
                        try {
                            Thread.sleep(700L * attempt)
                        } catch (_: InterruptedException) {
                            break
                        }
                    }
                    ok = postControlUplink(app, offer, localEoa, body, offer.sessionId)
                    Log.i(
                        TAG,
                        "decline uplink callId=${offer.callId.take(12)} attempt=${attempt + 1} ok=$ok",
                    )
                    attempt += 1
                }
                forgetOffer(offer.callId, offer.sessionId)
            } catch (e: Exception) {
                Log.w(TAG, "decline failed: ${e.message}")
            } finally {
                inFlightDecline.remove(key)
                try {
                    if (wake?.isHeld == true) wake.release()
                } catch (_: Exception) {
                }
            }
        }
    }

    /**
     * Send queued busy declines only after the glass window, the active call,
     * and any ringing/active Telecom connection are all gone. Opening
     * [BeamioOpenPgpHost] earlier replaces the incoming card or steals the mic.
     */
    fun flushDeferredStickyDeclinesIfIdle() {
        if (Looper.myLooper() != Looper.getMainLooper()) {
            main.post { flushDeferredStickyDeclinesIfIdle() }
            return
        }
        if (BeamioTelecomService.hasStickyVoiceChrome()) return
        val app = stickyDeclineApp ?: return
        val pending = synchronized(deferredLock) {
            if (deferredStickyDeclines.isEmpty()) return
            val copy = deferredStickyDeclines.toList()
            deferredStickyDeclines.clear()
            copy
        }
        for (item in pending) {
            sendDecline(
                app,
                item.callId,
                item.sessionId,
                reason = item.reason,
                protectStickyChrome = false,
            )
        }
    }

    private var stickyDeclineApp: Context? = null

    /** Telecom Answer — AES accept on temporary relay; starts native channel. */
    fun sendAccept(context: Context, callId: String, sessionId: String) {
        val app = context.applicationContext
        val key = "$callId|$sessionId"
        if (!inFlightAccept.add(key)) {
            Log.i(TAG, "accept already in-flight key=${key.take(24)}")
            return
        }
        io.execute {
            val wake = acquireUplinkWakeLock(app, "accept")
            try {
                var offer = cachedOffer(callId, sessionId)
                if (offer == null || offer.sessionKey.isBlank()) {
                    offer = BeamioVoiceOfferIdentity.resolveBlocking(app, callId, sessionId, 45_000L)
                }
                if (offer == null || offer.sessionKey.isBlank()) {
                    Log.w(TAG, "accept skip — no offer/sessionKey callId=${callId.take(12)}")
                    return@execute
                }
                val secrets = BeamioChatPgpStore.load(app) ?: run {
                    Log.w(TAG, "accept — no ChatPgp secrets")
                    return@execute
                }
                val localEoa = secrets.eoa.trim().lowercase()
                if (!localEoa.matches(Regex("^0x[0-9a-f]{40}$"))) {
                    Log.w(TAG, "accept — missing local eoa")
                    return@execute
                }
                val acceptSessionId = randomMailboxVoiceSessionId()
                val nowMs = System.currentTimeMillis()
                val body = JSONObject()
                    .put("type", "voice_call_accept_v1")
                    .put("callId", offer.callId)
                    .put("sessionId", acceptSessionId)
                    .put("peerSessionId", offer.sessionId)
                    .put("from", localEoa)
                    .put("to", offer.callerEoa.lowercase())
                    .put("createdAt", nowMs)
                    .put("timestamp", nowMs)
                    .put("codec", "audio/pcm;rate=16000")
                // Outer frame targets the caller's ring listen (offer.sessionId).
                val ok = postControlUplink(app, offer, localEoa, body, offer.sessionId)
                Log.i(
                    TAG,
                    "accept uplink callId=${offer.callId.take(12)} acceptSession=${acceptSessionId.take(12)} ok=$ok",
                )
                if (ok) {
                    val active = ActiveCall(
                        role = Role.CALLEE,
                        offer = offer,
                        listenSessionId = acceptSessionId,
                        peerMediaSessionId = offer.sessionId,
                        peerEoa = offer.callerEoa.lowercase(),
                        localEoa = localEoa,
                        mediaEnabled = true,
                    )
                    activeCall.set(active)
                    BeamioNativeVoiceChannel.start(app, active)
                }
            } catch (e: Exception) {
                Log.w(TAG, "accept failed: ${e.message}")
            } finally {
                inFlightAccept.remove(key)
                try {
                    if (wake?.isHeld == true) wake.release()
                } catch (_: Exception) {
                }
            }
        }
    }

    private fun postControlUplink(
        context: Context,
        offer: BeamioVoiceOfferIdentity.ResolvedIdentity,
        localEoa: String,
        aesBody: JSONObject,
        frameSessionId: String,
    ): Boolean {
        val caller = offer.callerEoa.lowercase()
        if (!caller.matches(Regex("^0x[0-9a-f]{40}$"))) return false
        if (offer.sessionKey.isBlank() || frameSessionId.isBlank()) {
            Log.w(TAG, "control — missing sessionKey/frameSessionId")
            return false
        }

        val aesPayload = try {
            BeamioVoiceAesGcm.encryptUtf8Json(offer.sessionKey, aesBody)
        } catch (e: Exception) {
            Log.w(TAG, "AES encrypt failed: ${e.message}")
            return false
        }

        val keys = BeamioAddressPgp.searchKey(caller) ?: run {
            Log.w(TAG, "searchKey(caller) failed")
            return false
        }
        if (!keys.routePublicKeyArmored.contains("BEGIN PGP PUBLIC KEY")) return false

        val secrets = BeamioChatPgpStore.load(context) ?: return false
        val roster = rosterOf(secrets)
        if (roster.isEmpty()) {
            Log.w(TAG, "no SI roster")
            return false
        }
        val exclude = buildSet {
            BeamioAddressPgp.mailboxIp(keys.routePgpKeyID, roster)?.let { add(it) }
            BeamioSiCipherPost.normalizeIp(secrets.mailboxIp)?.let { add(it) }
        }

        val nowMs = System.currentTimeMillis()
        val uplink = JSONObject()
            .put("command", "voice_uplink")
            .put("type", "voice_frame_v1")
            .put("walletAddress", localEoa)
            .put("from", localEoa)
            .put("callId", offer.callId)
            .put("sessionId", frameSessionId)
            .put("targetSessionId", offer.sessionId)
            .put("to", caller)
            .put("direction", "uplink")
            .put("seq", 0)
            .put("frameTimestamp", nowMs)
            .put("payload", aesPayload)
            .put("timestamp", nowMs / 1000L)

        val encryptWait = Object()
        var armor: String? = null
        var encryptError: String? = null
        BeamioOpenPgpHost.shared(context).encryptToRoute(
            keys.routePublicKeyArmored,
            uplink.toString(),
        ) { result ->
            result.onSuccess { armor = it }
                .onFailure { encryptError = it.message }
            synchronized(encryptWait) { encryptWait.notifyAll() }
        }
        synchronized(encryptWait) {
            if (armor == null && encryptError == null) {
                encryptWait.wait(12_000L)
            }
        }
        val encrypted = armor
        if (encrypted.isNullOrBlank() || !encrypted.contains("BEGIN PGP MESSAGE")) {
            Log.w(TAG, "PGP encrypt to caller route failed: ${encryptError ?: "timeout"}")
            return false
        }

        return BeamioSiCipherPost.post(encrypted, roster, exclude).ok
    }

    fun rosterOf(secrets: BeamioChatPgpStore.Secrets): List<BeamioChatPgpStore.SiNode> {
        if (secrets.siNodes.isNotEmpty()) return secrets.siNodes
        return secrets.entryDomains.mapNotNull { raw ->
            val ip = BeamioSiCipherPost.normalizeIp(raw) ?: return@mapNotNull null
            BeamioChatPgpStore.SiNode(ip)
        }
    }
}
