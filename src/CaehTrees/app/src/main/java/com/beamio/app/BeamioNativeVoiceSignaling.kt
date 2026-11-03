package com.beamio.app
import network.conet.chat.BeamioOpenPgpHost
import network.conet.chat.BeamioSiCipherPost
import network.conet.chat.BeamioChatPgpStore
import network.conet.chat.BeamioConetChatSignBroker

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
    private val inFlightHangup = ConcurrentHashMap.newKeySet<String>()
    /** Calls the peer already ended; the local end must not send `voice_end_v1` back. */
    private val peerEndedKeys = ConcurrentHashMap.newKeySet<String>()
    private val activeCall = AtomicReference<ActiveCall?>(null)
    /**
     * Second call while the glass window or an active call owns the mic: its busy
     * reject goes out at once when the offer is resolved; otherwise it waits for
     * the offer, or for our call to end.
     */
    private val busyRejects = BeamioBusyRejectQueue<BeamioVoiceOfferIdentity.ResolvedIdentity>()
    private val deferredLock = Any()

    enum class Role {
        CALLEE,
        DIALER,
    }

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
        /** Voice protocol v3: the call's four paid channels (null for older calls). */
        val v3: BeamioVoiceV3.Call? = null,
    ) {
        /** Callee accept listen id (compat alias). */
        val acceptSessionId: String get() = listenSessionId
    }

    fun rememberOffer(incoming: BeamioVoiceOfferIdentity.ResolvedIdentity) {
        if (incoming.callId.isBlank() || !incoming.answerable) return
        val resolved = incoming
        cache[resolved.callId] = resolved
        if (resolved.sessionId.isNotBlank()) {
            cache[resolved.sessionId] = resolved
        }
        // A busy reject that waited for this offer goes out now, during our call.
        val waitingBusy = synchronized(deferredLock) { busyRejects.offerResolved(resolved.callId, resolved.sessionId) }
        if (waitingBusy != null) {
            val app = stickyDeclineApp ?: BeamioVoiceV3.appContext
            if (app != null) {
                Log.i(TAG, "busy reject offer resolved; sending callId=${resolved.callId.take(8)}")
                sendDecline(app, resolved.callId, resolved.sessionId, reason = waitingBusy.reason)
            }
            return
        }
        BeamioVoiceV3.appContext?.let { prepareAcceptChannels(it, resolved) }
    }

    /** Callee: the four paid channels built while the call rang (memory only, nothing sent). */
    private val preparedChannels = java.util.concurrent.ConcurrentHashMap<String, Pair<List<BeamioVoiceV3.Own>, Long>>()
    private val preparing = java.util.Collections.newSetFromMap(java.util.concurrent.ConcurrentHashMap<String, Boolean>())

    /**
     * Callee, while it rings: create the four paid channels, pick our relays and sign
     * + encrypt our first listens, all on this device. Nothing is sent before Answer
     * (the relays learn nothing, nothing is paid); declined or timed-out calls just
     * drop it from memory. Saves the crypto WebView work on Answer.
     */
    fun prepareAcceptChannels(context: Context, offer: BeamioVoiceOfferIdentity.ResolvedIdentity) {
        val app = context.applicationContext
        val callId = offer.callId
        val now = System.currentTimeMillis()
        preparedChannels.entries.removeAll { e ->
            (now - e.value.second > 300_000L).also { old -> if (old) BeamioVoiceV3.PreparedListens.drop(e.value.first.map { it.channel.sid }) }
        }
        if (preparedChannels.containsKey(callId) || !preparing.add(callId)) return
        Thread {
            try {
                val secrets = BeamioChatPgpStore.load(app) ?: return@Thread
                val localEoa = secrets.eoa.trim().lowercase()
                val payerKey = BeamioVoiceV3.payerKey(app, localEoa) ?: return@Thread
                val started = System.currentTimeMillis()
                val made = (0 until 4).map { BeamioVoiceV3.newPaidChannel(app, payerKey, localEoa) ?: return@Thread }.toMutableList()
                BeamioVoiceV3.RelayNodes.attach(app)
                val exclude = setOfNotNull(BeamioSiCipherPost.normalizeIp(secrets.mailboxIp))
                val avoid = listOf(secrets.routePublicKeyArmor, offer.callerRouteArmored)
                val voiceRelay = BeamioVoiceV3.RelayNodes.pick(exclude, avoid) ?: return@Thread
                val videoRelay = BeamioVoiceV3.RelayNodes.pick(exclude, avoid) ?: return@Thread
                made[2] = made[2].copy(relay = voiceRelay)
                made[3] = made[3].copy(relay = videoRelay)
                if (activeCall.get()?.offer?.callId == callId) return@Thread  // Answer came first.
                BeamioVoiceV3.PreparedListens.prepare(app, made[2])
                BeamioVoiceV3.PreparedListens.prepare(app, made[3])
                preparedChannels[callId] = made to System.currentTimeMillis()
                Log.i(TAG, "v3 accept channels prepared while ringing callId=${callId.take(8)} ms=${System.currentTimeMillis() - started}")
            } catch (e: Exception) {
                Log.w(TAG, "v3 prepare failed: ${e.message}")
            } finally {
                preparing.remove(callId)
            }
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
        dropDialerCancel(callId, sessionId)
    }

    fun currentActiveCall(): ActiveCall? = activeCall.get()

    fun updateActiveCall(next: ActiveCall) {
        activeCall.set(next)
    }

    fun clearActiveCall() {
        activeCall.set(null)
        dropDialerCancel(null, null)
        flushDeferredStickyDeclinesIfIdle()
    }

    /** Mailbox `voice_listen` accepts `[0-9a-fA-F-]{16,64}` — 32 hex chars. */
    fun randomMailboxVoiceSessionId(): String {
        val bytes = ByteArray(16).also { SecureRandom().nextBytes(it) }
        return bytes.joinToString("") { b -> "%02x".format(b) }
    }

    // MARK: - Dialer cancel (built natively while the call rings)

    /**
     * The caller-cancel Chat message for our ringing outgoing call: `voice_end_v1`,
     * signed with the wallet key the chat SDK keeps and encrypted to the callee's
     * user PGP key, the same envelope the page's Chat send produces. Built when the
     * dial starts and held in memory only; dropped when the call connects, is
     * rejected, times out or ends. A hang-up before the callee answers posts it
     * from the Telecom end, so the cancel never waits for the page. Same rules as iOS.
     */
    private data class DialerCancel(
        val callId: String,
        val sessionId: String,
        val armor: String,
        /** Callee mailbox (entry A must not be mailbox B) and our own mailbox. */
        val excludeIps: Set<String>,
        /** `timestamp` inside the signed signal (ms): the end time the callee records. */
        val signedAtMs: Long = 0L,
        /** Copies built for this call (1 = the dial-time copy). */
        val copies: Int = 1,
    )

    private val dialerCancelLock = Any()
    private var dialerCancel: DialerCancel? = null
    /** The call whose cancel (or timeout) was posted; a copy finishing later is not stored. */
    private var dialerCancelSpentCallId = ""

    /**
     * The signed `timestamp` is the callee's record end time, and signing plus
     * encrypting at the hang-up takes 0.1–2 s. So the held cancel is rebuilt while
     * the call rings and the hang-up posts the newest one at once (same as iOS).
     */
    // The next copy starts this long after the previous one is done; a build
    // takes about 0.5–1.5 s here, so 1 s keeps the held copy within about 2.5 s
    // of the hang-up (RC2 measured 2.7–3.5 s with 2 s).
    private const val DIALER_CANCEL_REFRESH_MS = 1_000L
    /**
     * Our `voice_call_timeout_v1` for the ringing call, signed at dial with the
     * end of the ring window as its time (known in advance). Posted when the
     * window ends and the callee has not answered; same envelope as the cancel.
     */
    private var dialerTimeout: DialerCancel? = null

    /** Ring window for every call (PWA `INCOMING_CALL_RING_TIMEOUT_MS`, iOS `ringWindowMs`). */
    private const val RING_WINDOW_MS = 60_000L
    private val dialerCancelPrep = Executors.newSingleThreadExecutor()
    private val dialerCancelSend = Executors.newSingleThreadExecutor()

    /** Same lifetime the page puts on a voice signal (`VOICE_CALL_MAX_DURATION_MS`). */
    private const val VOICE_SIGNAL_LIFETIME_MS = 15L * 60L * 1000L

    /** Drop the prebuilt cancel (any call when both ids are null). */
    private fun dropDialerCancel(callId: String?, sessionId: String?) {
        synchronized(dialerCancelLock) {
            val cur = dialerCancel ?: return
            if ((callId == null && sessionId == null) ||
                (!callId.isNullOrBlank() && cur.callId == callId) ||
                (!sessionId.isNullOrBlank() && cur.sessionId == sessionId)
            ) {
                dialerCancel = null
                dialerTimeout = null
            }
        }
    }

    private fun stillRingingDialer(callId: String): Boolean {
        val cur = activeCall.get() ?: return false
        return cur.role == Role.DIALER && cur.offer.callId == callId && !cur.mediaEnabled
    }

    /** Still ringing and its cancel / timeout not posted yet. */
    private fun dialerCancelLive(callId: String): Boolean =
        stillRingingDialer(callId) && synchronized(dialerCancelLock) { dialerCancelSpentCallId != callId }

    private fun prepareDialerCancel(
        app: Context,
        callId: String,
        sessionId: String,
        localEoa: String,
        peerEoa: String,
        timeoutAtMs: Long,
    ) {
        // Signed natively only: without the SDK-held wallet key the page sends instead.
        if (!BeamioConetChatSignBroker.hasLocalSigner()) {
            Log.i(TAG, "dialer cancel not prepared: no local signer")
            return
        }
        dialerCancelPrep.execute {
            val started = System.currentTimeMillis()
            try {
                // The cancel is wrapped to the callee's mailbox route key (entry sees
                // only that mailbox's key ID), so both keys are needed.
                val keys = BeamioAddressPgp.searchKey(peerEoa)
                if (keys == null || !keys.userPublicKeyArmored.contains("BEGIN PGP PUBLIC KEY") ||
                    !keys.routePublicKeyArmored.contains("BEGIN PGP PUBLIC KEY")
                ) {
                    Log.i(TAG, "dialer cancel not prepared: callee key")
                    return@execute
                }
                val secrets = BeamioChatPgpStore.load(app) ?: return@execute
                // Without the callee mailbox an entry could be mailbox B: the page sends instead.
                val mailboxIp = BeamioAddressPgp.mailboxIp(keys.routePgpKeyID, rosterOf(secrets))
                    ?.let { BeamioSiCipherPost.normalizeIp(it) }
                if (mailboxIp == null) {
                    Log.i(TAG, "dialer cancel not prepared: callee mailbox")
                    return@execute
                }
                if (!stillRingingDialer(callId)) return@execute
                // Same exclusions as the page send: callee mailbox and our own mailbox.
                val exclude = setOfNotNull(mailboxIp, BeamioSiCipherPost.normalizeIp(secrets.mailboxIp))
                /** Sign, encrypt to the callee and wrap to its mailbox: one Chat message. */
                fun seal(type: String, stampMs: Long, done: (String?) -> Unit) {
                    val text = JSONObject()
                        .put("type", type)
                        .put("callId", callId)
                        .put("sessionId", sessionId)
                        .put("from", localEoa)
                        .put("to", peerEoa)
                        .put("createdAt", stampMs)
                        .put("expiresAt", stampMs + VOICE_SIGNAL_LIFETIME_MS)
                        .put("timestamp", stampMs)
                        .toString()
                    BeamioConetChatSignBroker.requestEip191(text, 10_000L) { signed ->
                        val signature = signed.getOrNull()
                        if (signature.isNullOrBlank() || !stillRingingDialer(callId)) {
                            Log.i(TAG, "dialer $type not prepared: sign")
                            return@requestEip191 done(null)
                        }
                        val envelope = JSONObject()
                            .put("timestamp", stampMs)
                            .put("text", text)
                            .put("from", localEoa)
                            .put("signMessage", signature)
                            .toString()
                        BeamioOpenPgpHost.shared(app).encryptUtf8JsonBase64(envelope, keys.userPublicKeyArmored) { encrypted ->
                            val userArmor = encrypted.getOrNull()
                            if (userArmor == null || !userArmor.contains("BEGIN PGP MESSAGE")) {
                                Log.i(TAG, "dialer $type not prepared: encrypt")
                                return@encryptUtf8JsonBase64 done(null)
                            }
                            BeamioOpenPgpHost.shared(app).wrapArmorToMailboxWork(userArmor, keys.routePublicKeyArmored, false) { wrapped ->
                                val armor = wrapped.getOrNull()
                                if (armor == null || !armor.contains("BEGIN PGP MESSAGE")) {
                                    Log.i(TAG, "dialer $type not prepared: wrap")
                                    return@wrapArmorToMailboxWork done(null)
                                }
                                done(armor)
                            }
                        }
                    }
                }
                /**
                 * One copy of the cancel with the current time; held if the call still
                 * rings, then the next copy is scheduled. Stops once the call connects,
                 * ends or the cancel is posted; a failed rebuild keeps the older copy.
                 */
                fun buildCancel(copy: Int, afterFirst: () -> Unit) {
                    if (!dialerCancelLive(callId)) return
                    val stampMs = System.currentTimeMillis()
                    seal("voice_end_v1", stampMs) { armor ->
                        val stored = armor != null && synchronized(dialerCancelLock) {
                            if (stillRingingDialer(callId) && dialerCancelSpentCallId != callId) {
                                dialerCancel = DialerCancel(callId, sessionId, armor, exclude, stampMs, copy)
                                true
                            } else {
                                false
                            }
                        }
                        if (copy == 1) {
                            Log.i(
                                TAG,
                                "dialer cancel prepared=${if (stored) "yes" else "no"} " +
                                    "callId=${callId.take(8)} ms=${System.currentTimeMillis() - started}",
                            )
                            afterFirst()
                        }
                        if (stored || (copy > 1 && dialerCancelLive(callId))) {
                            main.postDelayed(
                                { dialerCancelPrep.execute { buildCancel(copy + 1) {} } },
                                DIALER_CANCEL_REFRESH_MS,
                            )
                        }
                    }
                }
                buildCancel(1) {
                    // The timeout is signed after the first cancel: the cancel is the one a hang-up needs first.
                    seal("voice_call_timeout_v1", timeoutAtMs) { timeoutArmor ->
                        val ready = timeoutArmor != null && synchronized(dialerCancelLock) {
                            if (stillRingingDialer(callId)) {
                                dialerTimeout = DialerCancel(callId, sessionId, timeoutArmor, exclude)
                            }
                            dialerTimeout?.callId == callId
                        }
                        Log.i(TAG, "dialer timeout prepared=${if (ready) "yes" else "no"} callId=${callId.take(8)}")
                    }
                }
            } catch (e: Exception) {
                Log.w(TAG, "dialer cancel not prepared: ${e.message}")
            }
        }
    }

    /**
     * Local end of our outgoing call. When the callee has not answered and the
     * cancel is ready, post it now and return true. The page is told
     * (`dialerCancelPosting`, then `dialerCancelSent` / `dialerCancelFailed`) and
     * does not send its own. Call before the page gets `callEnded`.
     */
    fun postDialerCancelIfRinging(context: Context, callId: String, sessionId: String): Boolean {
        val cancel = synchronized(dialerCancelLock) {
            val c = dialerCancel ?: return false
            val matches = (callId.isNotBlank() && c.callId == callId) ||
                (sessionId.isNotBlank() && c.sessionId == sessionId)
            if (!matches || !stillRingingDialer(c.callId)) return false
            dialerCancel = null
            dialerTimeout = null
            dialerCancelSpentCallId = c.callId
            c
        }
        val app = context.applicationContext
        // No context: these must not take the single pending-action slot.
        MainActivity.dispatchSystemCallAction("dialerCancelPosting", cancel.callId, cancel.sessionId)
        dialerCancelSend.execute {
            val wake = acquireUplinkWakeLock(app, "dialer-cancel")
            val started = System.currentTimeMillis()
            var ok = false
            try {
                val roster = BeamioChatPgpStore.load(app)?.let { rosterOf(it) }.orEmpty()
                // Warm entry, straight POST; a second entry joins if the first is slow.
                ok = BeamioSiCipherPost.post(cancel.armor, roster, cancel.excludeIps, 4, 600L).ok
                if (!ok) ok = BeamioSiCipherPost.post(cancel.armor, roster, cancel.excludeIps).ok
            } catch (e: Exception) {
                Log.w(TAG, "dialer cancel post failed: ${e.message}")
            } finally {
                Log.i(
                    TAG,
                    "dialer cancel posted callId=${cancel.callId.take(8)} " +
                        "ok=${if (ok) "yes" else "no"} ms=${System.currentTimeMillis() - started} " +
                        "signedAgoMs=${started - cancel.signedAtMs} copies=${cancel.copies}",
                )
                MainActivity.dispatchSystemCallAction(
                    if (ok) "dialerCancelSent" else "dialerCancelFailed",
                    cancel.callId,
                    cancel.sessionId,
                )
                try {
                    if (wake?.isHeld == true) wake.release()
                } catch (_: Exception) {
                }
            }
        }
        return true
    }

    /**
     * The ring window of our outgoing call ended unanswered: tell the callee
     * (`voice_call_timeout_v1`, signed at dial), then close the call as timed
     * out ([dialerDidReceiveReject] tells the page `callTimedOut`, which records
     * `timed_out` without sending its own). Answer, reject or hang-up already
     * changed the call, so a late timer does nothing.
     */
    private fun dialerRingWindowEnded(app: Context, callId: String) {
        if (!dialerCancelLive(callId)) return
        val timeout = synchronized(dialerCancelLock) {
            val t = dialerTimeout?.takeIf { it.callId == callId }
            dialerTimeout = null
            dialerCancel = null
            dialerCancelSpentCallId = callId
            t
        }
        Log.i(TAG, "dialer ring window ended callId=${callId.take(8)} prepared=${if (timeout != null) "yes" else "no"}")
        if (timeout != null) {
            dialerCancelSend.execute {
                val wake = acquireUplinkWakeLock(app, "dialer-timeout")
                val started = System.currentTimeMillis()
                var ok = false
                try {
                    val roster = BeamioChatPgpStore.load(app)?.let { rosterOf(it) }.orEmpty()
                    ok = BeamioSiCipherPost.post(timeout.armor, roster, timeout.excludeIps, 4, 600L).ok
                    if (!ok) ok = BeamioSiCipherPost.post(timeout.armor, roster, timeout.excludeIps).ok
                } catch (e: Exception) {
                    Log.w(TAG, "dialer timeout post failed: ${e.message}")
                } finally {
                    Log.i(TAG, "dialer timeout posted callId=${callId.take(8)} ok=${if (ok) "yes" else "no"} ms=${System.currentTimeMillis() - started}")
                    try {
                        if (wake?.isHeld == true) wake.release()
                    } catch (_: Exception) {
                    }
                }
            }
        }
        dialerDidReceiveReject(app, "callTimedOut")
    }

    // MARK: - Dialer (outgoing)

    /**
     * Our outgoing call (voice v3): the page already sent the offer to the
     * callee's mailbox. Nothing opens while ringing; the callee's accept (a
     * chat message to our mailbox) brings our channels ([dialerDidReceiveAcceptV3]).
     */
    fun attachOutgoingDialer(
        context: Context,
        callId: String,
        sessionId: String,
        peerEoa: String,
        /** The offer's `createdAt` (ms) from the page; 0 = now. The ring window starts there. */
        offerCreatedAtMs: Long = 0L,
    ) {
        val app = context.applicationContext
        // While it rings: keep the SDK's warm entries fresh for the listens after the accept.
        network.conet.chat.BeamioEntryPool.warmNow()
        val trimmedCall = callId.trim()
        val trimmedSession = sessionId.trim()
        val peer = peerEoa.trim().lowercase()
        if (trimmedSession.isBlank()) {
            Log.w(TAG, "dialer skip — missing sessionId")
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
        val offer = BeamioVoiceOfferIdentity.ResolvedIdentity(
            callerEoa = localEoa,
            beamioTag = null,
            shortAddress = "",
            callId = if (trimmedCall.isBlank()) trimmedSession else trimmedCall,
            sessionId = trimmedSession,
            to = peer,
            proto = 3,
        )
        val active = ActiveCall(
            role = Role.DIALER,
            offer = offer,
            listenSessionId = trimmedSession,
            peerMediaSessionId = "",
            peerEoa = peer,
            localEoa = localEoa,
            mediaEnabled = false,
        )
        activeCall.set(active)
        dropDialerCancel(null, null)
        val attachedAt = System.currentTimeMillis()
        val timeoutAtMs = (if (offerCreatedAtMs in 1..attachedAt) offerCreatedAtMs else attachedAt) + RING_WINDOW_MS
        prepareDialerCancel(app, offer.callId, trimmedSession, localEoa, peer, timeoutAtMs)
        val dialCallId = offer.callId
        main.postDelayed({ dialerRingWindowEnded(app, dialCallId) }, (timeoutAtMs - attachedAt).coerceAtLeast(0L))
        peerRinging.remove(offer.callId)
        // A receipt can beat this attach (the page posts the offer first): keep it.
        val now = System.currentTimeMillis()
        earlyRinging.entries.removeIf { now - it.value.second > 600_000L }
        val early = earlyRinging.remove(offer.callId)
        if (early != null && early.first == peer) {
            peerRinging.add(offer.callId)
            Log.i(TAG, "ringing receipt received (before attach) callId=${offer.callId.take(12)}")
            // Posted after this UI-thread block, which also runs beginOutgoing (it resets the screen).
            android.os.Handler(android.os.Looper.getMainLooper()).post {
                InCallScreenModel.notePeerWake(offer.callId, InCallScreenModel.PeerWake.RINGING)
                InCallActivity.refreshStateIfShowing()
            }
        }
        schedulePeerWakeCheck(offer.callId)
        // Five rings of the local ringback without a receipt: Unreachable.
        val createdAt = if (offerCreatedAtMs in 1..attachedAt) offerCreatedAtMs else attachedAt
        val unreachableMs = BeamioDialerReceiptRule.unreachableAfterMs(ringbackCountry(app))
        main.postDelayed(
            { dialerPeerUnreachable(app, dialCallId, unreachableMs) },
            BeamioDialerReceiptRule.delayMs(createdAt, System.currentTimeMillis(), unreachableMs),
        )
        Log.i(TAG, "dialer attach callId=${offer.callId.take(12)} session=${trimmedSession.take(12)} peer=${peer.takeLast(8)}")
    }

    // MARK: - Wake receipt (`voice_call_ringing_v1`)

    /** Caller: no receipt within this time → "Their phone may be restricting Beamio". */
    const val PEER_WAKE_TIMEOUT_MS = 8_000L

    /** Own thread: a slow entry must not hold up Decline / Accept on [io]. */
    private val ringingIo = Executors.newSingleThreadExecutor()
    /** Calls this device already told the caller about (callId → time sent). */
    private val ringingSent = ConcurrentHashMap<String, Long>()
    /** Dials whose callee sent the receipt. */
    private val peerRinging = ConcurrentHashMap.newKeySet<String>()
    /** Receipts that arrived before [attachOutgoingDialer] (callId → sender, time). */
    private val earlyRinging = ConcurrentHashMap<String, Pair<String, Long>>()

    /**
     * Callee: tell the caller this device is ringing, once per call. Same path as
     * Decline / Accept: caller user-PGP, caller mailbox route layer, random entry;
     * NoPush (the caller is dialing in the foreground). Never for our own dial.
     */
    fun sendRingingIfNeeded(context: Context, offer: BeamioVoiceOfferIdentity.ResolvedIdentity) {
        if (!offer.answerable || offer.callId.isBlank()) return
        val caller = offer.callerEoa.trim().lowercase()
        if (!caller.matches(Regex("^0x[0-9a-f]{40}$"))) return
        val now = System.currentTimeMillis()
        ringingSent.entries.removeIf { now - it.value > 600_000L }
        if (ringingSent.putIfAbsent(offer.callId, now) != null) return
        val app = context.applicationContext
        ringingIo.execute {
            var ok = false
            try {
                val secrets = BeamioChatPgpStore.load(app) ?: return@execute
                val localEoa = secrets.eoa.trim().lowercase()
                if (!localEoa.matches(Regex("^0x[0-9a-f]{40}$")) || localEoa == caller) return@execute
                val body = JSONObject()
                    .put("type", "voice_call_ringing_v1")
                    .put("callId", offer.callId)
                    .put("sessionId", offer.sessionId)
                    .put("from", localEoa)
                    .put("to", caller)
                    .put("createdAt", now)
                    .put("timestamp", now)
                var attempt = 0
                while (attempt < 2 && !ok) {
                    if (attempt > 0) Thread.sleep(700L)
                    ok = BeamioVoiceV3.postChatMessage(
                        app, body.toString(), localEoa,
                        offer.callerPgpArmored, offer.callerRouteArmored, noPush = true,
                    )
                    attempt += 1
                }
                Log.i(TAG, "ringing receipt callId=${offer.callId.take(12)} ok=$ok")
            } catch (e: Exception) {
                Log.w(TAG, "ringing receipt failed: ${e.message}")
            } finally {
                if (!ok) ringingSent.remove(offer.callId)
            }
        }
    }

    private fun schedulePeerWakeCheck(callId: String) {
        android.os.Handler(android.os.Looper.getMainLooper()).postDelayed({
            val cur = activeCall.get()
            val stillRinging = cur != null && cur.role == Role.DIALER &&
                cur.offer.callId == callId && !cur.mediaEnabled
            if (!stillRinging || peerRinging.contains(callId)) return@postDelayed
            Log.i(TAG, "no ringing receipt in 8 s callId=${callId.take(12)}")
            InCallScreenModel.notePeerWake(callId, InCallScreenModel.PeerWake.RESTRICTED)
            InCallActivity.refreshStateIfShowing()
        }, PEER_WAKE_TIMEOUT_MS)
    }

    /**
     * The country the platform ringback follows (AOSP `ToneGenerator`: network
     * country, else SIM country). Blank when unknown (CEPT cadence).
     */
    private fun ringbackCountry(context: Context): String = runCatching {
        val tm = context.getSystemService(android.telephony.TelephonyManager::class.java)
        val network = tm?.networkCountryIso.orEmpty().trim()
        // Dual SIM, not registered: the platform reads the SIM country too.
        if (network.length == 2) network else tm?.simCountryIso.orEmpty().trim()
    }.getOrDefault("")

    /**
     * No ringing receipt after five rings: the callee's phone never got the call
     * (force stopped, switched off, push blocked). Main thread.
     * - posts the cancel signed at dial, so a late push cannot ring the callee
     *   for a call that is over (the page gets `dialerCancelPosting` first and
     *   sends no cancel of its own; with no cancel ready the page sends one);
     * - tells the page `callUnreachable` (it records `unreachable`);
     * - stops the ringback, shows "Unreachable", closes the screen and the
     *   Telecom call 2 s later.
     * The 60 s ring-window timer then finds no call and does nothing, and a
     * receipt that comes later matches no call.
     */
    private fun dialerPeerUnreachable(app: Context, callId: String, afterMs: Long) {
        if (!BeamioDialerReceiptRule.endsUnreachable(stillRingingDialer(callId), peerRinging.contains(callId))) return
        val sessionId = activeCall.get()?.listenSessionId.orEmpty()
        val posted = postDialerCancelIfRinging(app, callId, sessionId)
        val cur = activeCall.get()
        if (cur == null || cur.role != Role.DIALER || cur.offer.callId != callId || cur.mediaEnabled) return
        if (!activeCall.compareAndSet(cur, null)) return
        synchronized(dialerCancelLock) {
            dialerCancel = null
            dialerTimeout = null
            dialerCancelSpentCallId = callId
        }
        Log.i(
            TAG,
            "dialer unreachable (no ringing receipt in ${afterMs / 1000} s) callId=${callId.take(12)} " +
                "cancel=${if (posted) "native" else "page"}",
        )
        BeamioNativeVoiceChannel.stop()
        MainActivity.dispatchSystemCallAction("callUnreachable", callId, sessionId, app)
        BeamioCallTonePlayer.stopRingback("unreachable", mediaStarting = true)
        InCallScreenModel.showUnreachable(callId)
        main.postDelayed({
            InCallScreenModel.end(callId)
            InCallActivity.finishIfMatching(callId, sessionId)
            BeamioTelecomService.disconnectOutgoingQuiet(app, callId, sessionId)
        }, 2_000L)
    }

    /** Caller: the callee's device sent `voice_call_ringing_v1` for our dial. */
    fun dialerDidReceiveRinging(callId: String, from: String) {
        val cur = activeCall.get()
        if (cur == null || cur.role != Role.DIALER || cur.offer.callId != callId || cur.peerEoa != from) {
            // Not attached yet (or an older call is still active): attachOutgoingDialer checks this.
            if (callId.isNotBlank()) earlyRinging[callId] = from.lowercase() to System.currentTimeMillis()
            return
        }
        peerRinging.add(callId)
        Log.i(TAG, "ringing receipt received callId=${callId.take(12)}")
        android.os.Handler(android.os.Looper.getMainLooper()).post {
            InCallScreenModel.notePeerWake(callId, InCallScreenModel.PeerWake.RINGING)
            InCallActivity.refreshStateIfShowing()
        }
    }

    /** The channel learned the peer's relays (or moved ours): keep the call copy in step. */
    fun updateV3Call(callId: String, v3: BeamioVoiceV3.Call) {
        while (true) {
            val cur = activeCall.get() ?: return
            if (cur.offer.callId != callId) return
            if (activeCall.compareAndSet(cur, cur.copy(v3 = v3))) return
        }
    }

    /**
     * Every inbound chat message from the native chat module (signer recovered
     * as `from`). v3 dialer: the callee's accept / decline / timeout.
     */
    fun observeChatEvent(context: Context, payload: JSONObject) {
        val event = payload.optJSONObject("event") ?: return
        if (event.optString("type") != "event:message") return
        val body = event.optJSONObject("payload") ?: return
        val line = body.optString("line")
        val from = body.optString("from").trim().lowercase()
        if (!from.matches(Regex("^0x[0-9a-f]{40}$"))) return
        // v3 dialer: the callee's device is ringing (wake receipt).
        if (line.contains("voice_call_ringing_v1")) {
            val ringing = voiceSignal(line, setOf("voice_call_ringing_v1")) ?: return
            dialerDidReceiveRinging(ringing.optString("callId"), from)
            return
        }
        if (!line.contains("voice_call_accept_v1") && !line.contains("voice_call_reject_v1") &&
            !line.contains("voice_call_timeout_v1")
        ) return
        val signal = voiceSignal(line, setOf("voice_call_accept_v1", "voice_call_reject_v1", "voice_call_timeout_v1")) ?: return
        val type = signal.optString("type")
        if (type == "voice_call_accept_v1") {
            if (signal.optInt("proto", 0) == 3) dialerDidReceiveAcceptV3(context, signal, from)
        } else {
            // Off the main thread: ending the dialer closes its HTTP connections.
            io.execute { dialerDidReceiveRejectV3(context, type, signal.optString("callId"), from, signal.optString("reason")) }
        }
    }

    /** A voice signal object inside a chat line (nested `text`, base64 envelopes). */
    private fun voiceSignal(line: String, types: Set<String>): JSONObject? {
        fun walk(value: Any?, depth: Int): JSONObject? {
            if (depth >= 8 || value == null) return null
            if (value is String) {
                val t = value.trim()
                if (t.startsWith("{")) return walk(runCatching { JSONObject(t) }.getOrNull(), depth + 1)
                val decoded = runCatching {
                    String(android.util.Base64.decode(t, android.util.Base64.DEFAULT), Charsets.UTF_8)
                }.getOrNull()?.trim()
                if (decoded != null && decoded.startsWith("{")) {
                    return walk(runCatching { JSONObject(decoded) }.getOrNull(), depth + 1)
                }
                return null
            }
            if (value !is JSONObject) return null
            if (value.optString("type") in types) return value
            return if (value.has("text")) walk(value.opt("text"), depth + 1) else null
        }
        return walk(line, 0)
    }

    /**
     * v3 dialer: the callee's accept arrived on our mailbox. Pick our relays,
     * open our two channels, start media.
     */
    fun dialerDidReceiveAcceptV3(context: Context, accept: JSONObject, from: String) {
        val app = context.applicationContext
        val callId = accept.optString("callId")
        val ringId = accept.optString("sessionId")
        val cur = activeCall.get() ?: return
        if (cur.role != Role.DIALER || cur.offer.proto != 3 || cur.offer.callId != callId ||
            cur.offer.sessionId != ringId || cur.peerEoa != from || cur.mediaEnabled || cur.v3 != null
        ) return
        if (!inFlightAccept.add("v3:$callId")) return
        BeamioCallTiming.mark("accept-rx")
        Log.i(TAG, "v3 accept rx callId=${callId.take(12)}")
        io.execute {
            try {
                val ch = accept.optJSONObject("ch") ?: return@execute
                BeamioVoiceV3.RelayNodes.attach(app)
                var call = BeamioVoiceV3.callFromAccept(app, callId, ch) ?: run {
                    Log.w(TAG, "v3 accept unusable")
                    return@execute
                }
                val secrets = BeamioChatPgpStore.load(app) ?: return@execute
                val exclude = setOfNotNull(BeamioSiCipherPost.normalizeIp(secrets.mailboxIp))
                val calleeRoute = BeamioAddressPgp.searchKey(cur.peerEoa)?.routePublicKeyArmored.orEmpty()
                val avoid = listOf(secrets.routePublicKeyArmor, calleeRoute)
                val voiceRelay = BeamioVoiceV3.RelayNodes.pick(exclude, avoid)
                val videoRelay = BeamioVoiceV3.RelayNodes.pick(exclude, avoid)
                if (voiceRelay == null || videoRelay == null) {
                    Log.w(TAG, "v3 accept: no relay nodes cached")
                    return@execute
                }
                call = call.copy(
                    ownVoice = call.ownVoice.copy(relay = voiceRelay),
                    ownVideo = call.ownVideo.copy(relay = videoRelay),
                )
                val live = activeCall.get() ?: return@execute
                if (live.role != Role.DIALER || live.offer.callId != callId || live.mediaEnabled) return@execute
                val next = live.copy(v3 = call, peerMediaSessionId = call.peerVoice.channel.sid, mediaEnabled = true)
                if (!activeCall.compareAndSet(live, next)) return@execute
                dropDialerCancel(null, null)
                BeamioCallTonePlayer.stopRingback("voice-media", mediaStarting = true)
                BeamioNativeVoiceChannel.start(app, next)
                main.post {
                    if (InCallScreenModel.markConnected(next.offer.callId)) InCallActivity.refreshStateIfShowing()
                    BeamioTelecomService.markOutgoingConnected(app, next.offer.callId, next.listenSessionId)
                    MainActivity.dispatchSystemCallAction("callAnswered", next.offer.callId, next.listenSessionId, app)
                }
            } catch (e: Exception) {
                Log.w(TAG, "v3 accept failed: ${e.message}")
            } finally {
                inFlightAccept.remove("v3:$callId")
            }
        }
    }

    /** v3 dialer: the callee declined or timed out (chat message to our mailbox). */
    fun dialerDidReceiveRejectV3(context: Context, type: String, callId: String, from: String, reason: String = "") {
        val cur = activeCall.get() ?: return
        if (cur.role != Role.DIALER || cur.offer.proto != 3 || cur.offer.callId != callId ||
            cur.peerEoa != from || cur.mediaEnabled
        ) return
        // Only the verified callee (signer == the peer we dialed) can say "busy".
        if (type == "voice_call_reject_v1" && reason == "busy") {
            dialerDidReceiveBusy(context)
            return
        }
        dialerDidReceiveReject(context, if (type == "voice_call_timeout_v1") "callTimedOut" else "callRejected")
    }

    /**
     * Peer hung up (AES `voice_end_v1` on the media channel). End the call the
     * same way the local End button does, so the call page, Telecom call and
     * PWA all close, but without sending a hangup back to the peer.
     */
    fun peerDidEnd(context: Context, frameCallId: String, frameSessionId: String) {
        val cur = activeCall.get()
        val screen = if (InCallScreenModel.isLive()) InCallScreenModel.snapshot() else null
        val callId = screen?.callId?.ifBlank { null } ?: cur?.offer?.callId?.ifBlank { null } ?: frameCallId
        val sessionId = screen?.sessionId?.ifBlank { null }
            ?: cur?.offer?.sessionId?.ifBlank { null }
            ?: frameSessionId
        if (callId.isBlank() && sessionId.isBlank()) {
            Log.i(TAG, "peer ended — no local call to close")
            return
        }
        listOf(callId, sessionId, frameCallId, frameSessionId)
            .filter { it.isNotBlank() }
            .forEach { peerEndedKeys.add(it) }
        Log.i(TAG, "peer ended callId=${callId.take(12)} → local end")
        val app = context.applicationContext
        main.post { BeamioTelecomService.end(app, callId, sessionId) }
    }

    /**
     * The callee is in another call: the page records "busy", the call screen
     * says so, the busy tone plays on the call (about 3 s), then the screen and
     * the Telecom call close (no second page emit).
     */
    fun dialerDidReceiveBusy(context: Context) {
        val cur = activeCall.get() ?: return
        if (cur.role != Role.DIALER) return
        val callId = cur.offer.callId
        val sessionId = cur.listenSessionId
        activeCall.set(null)
        dropDialerCancel(null, null)
        Log.i(TAG, "dialer callBusy callId=${callId.take(12)}")
        BeamioNativeVoiceChannel.stop()
        val app = context.applicationContext
        main.post {
            MainActivity.dispatchSystemCallAction("callBusy", callId, sessionId, app)
            InCallScreenModel.showBusy(callId)
            BeamioCallTonePlayer.playBusy {
                InCallScreenModel.end(callId)
                InCallActivity.finishIfMatching(callId, sessionId)
                BeamioTelecomService.disconnectOutgoingQuiet(app, callId, sessionId)
            }
        }
    }

    /** The callee declined or timed out (chat message to our mailbox). */
    fun dialerDidReceiveReject(context: Context, action: String) {
        val cur = activeCall.get() ?: return
        if (cur.role != Role.DIALER) return
        val callId = cur.offer.callId
        val sessionId = cur.listenSessionId
        activeCall.set(null)
        dropDialerCancel(null, null)
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
            // Close the dialer's native call screen.
            InCallScreenModel.end(callId)
            InCallActivity.finishIfMatching(callId, sessionId)
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
            // Busy: tell the new caller now, so it hears the busy tone while it dials.
            // The dialer cancel already seals with the OpenPgp host during a live
            // call; only an offer we still have to resolve waits (resolving it here
            // would open the host for a caller we have not even decrypted).
            val trimmedReason = reason.trim().ifBlank { "busy" }
            val resolved = cachedOffer(callId, sessionId)?.takeIf { it.answerable }
            val decision = synchronized(deferredLock) {
                busyRejects.busyCallArrived(callId, sessionId, trimmedReason, resolved)
            }
            stickyDeclineApp = app
            when (decision) {
                is BeamioBusyRejectQueue.Decision.SendNow -> {
                    val now = decision.offer
                    Log.i(TAG, "busy reject now callId=${now.callId.take(8)}")
                    return sendDecline(app, now.callId, now.sessionId, reason = trimmedReason)
                }
                BeamioBusyRejectQueue.Decision.AlreadySent -> {
                    // Same call seen again: one reject is enough.
                    Log.i(TAG, "busy reject already sent callIdPresent=${callId.isNotBlank()}")
                    return
                }
                BeamioBusyRejectQueue.Decision.Wait -> {
                    Log.i(TAG, "busy reject waits for the offer callIdPresent=${callId.isNotBlank()}")
                    return
                }
            }
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
                if (offer == null || !offer.answerable) {
                    offer = BeamioVoiceOfferIdentity.resolveBlocking(app, callId, sessionId, 45_000L)
                }
                if (offer == null || !offer.answerable) {
                    Log.w(TAG, "decline skip — no v3 offer callId=${callId.take(12)}")
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
                // A failed post (entry down) is retried briefly.
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
                    // To the caller's mailbox: the caller has no channel while ringing.
                    ok = BeamioVoiceV3.postChatMessage(
                        app, body.toString(), localEoa,
                        offer.callerPgpArmored, offer.callerRouteArmored, noPush = false,
                    )
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
     * Backstop for busy rejects whose offer never resolved during our call: send
     * them once the glass window, the active call and any Telecom connection are
     * gone (resolving opens [BeamioOpenPgpHost], which could replace the incoming card).
     */
    fun flushDeferredStickyDeclinesIfIdle() {
        if (Looper.myLooper() != Looper.getMainLooper()) {
            main.post { flushDeferredStickyDeclinesIfIdle() }
            return
        }
        if (BeamioTelecomService.hasStickyVoiceChrome()) return
        val app = stickyDeclineApp ?: return
        val pending = synchronized(deferredLock) {
            if (busyRejects.waitingCount == 0) return
            busyRejects.ownCallEnded()
        }
        Log.i(TAG, "busy reject after our call ended count=${pending.size}")
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

    /**
     * Local End Call — AES `voice_end_v1` on the caller's temporary relay so the
     * browser dialer tears down immediately (Chat PGP alone can lag or miss while
     * the dialer is on the voice SSE). Must run **before** [forgetOffer].
     */
    fun sendHangup(context: Context, callId: String, sessionId: String) {
        val app = context.applicationContext
        // `or` (not `||`) so both keys are cleared.
        val peerGone = (callId.isNotBlank() && peerEndedKeys.remove(callId)) or
            (sessionId.isNotBlank() && peerEndedKeys.remove(sessionId))
        if (peerGone) {
            Log.i(TAG, "hangup skip — peer already ended callId=${callId.take(12)}")
            return
        }
        val key = "$callId|$sessionId"
        if (!inFlightHangup.add(key)) {
            Log.i(TAG, "hangup already in-flight key=${key.take(24)}")
            return
        }
        // v3: AES voice_end on the peer's voice channel (the call holds its keys).
        activeCall.get()?.takeIf {
            it.v3 != null && it.mediaEnabled &&
                ((callId.isNotBlank() && it.offer.callId == callId) || (sessionId.isNotBlank() && it.offer.sessionId == sessionId))
        }?.let { live ->
            io.execute {
                try {
                    val nowMs = System.currentTimeMillis()
                    val body = JSONObject()
                        .put("type", "voice_end_v1")
                        .put("callId", live.offer.callId)
                        .put("sessionId", live.offer.sessionId)
                        .put("from", live.localEoa)
                        .put("to", live.peerEoa)
                        .put("reason", "ended")
                        .put("createdAt", nowMs)
                        .put("timestamp", nowMs)
                    val ok = BeamioNativeVoiceChannel.postV3Control(app, body, live.v3!!)
                    Log.i(TAG, "v3 hangup callId=${live.offer.callId.take(12)} ok=$ok")
                    if (!ok) {
                        // The channel frame did not go (we may not know the peer's relay yet,
                        // or its channel is gone): tell its mailbox instead, as Decline does.
                        val sent = postHangupToMailbox(app, live, body.toString())
                        Log.i(TAG, "v3 hangup mailbox fallback callId=${live.offer.callId.take(12)} ok=$sent")
                    }
                } finally {
                    inFlightHangup.remove(key)
                }
            }
            return
        }
        // No v3 call with channels (never connected): nothing to tell the peer;
        // a ringing call ends through Decline or the dialer cancel.
        inFlightHangup.remove(key)
        Log.i(TAG, "hangup skip — no connected v3 call callId=${callId.take(12)}")
    }

    /**
     * `voice_end_v1` to the peer's mailbox (signed chat message), for when the
     * channel frame cannot be sent. Callee: the caller's keys came in the offer;
     * caller: the callee's keys from the chain. Two tries. Blocking.
     */
    private fun postHangupToMailbox(app: Context, live: ActiveCall, text: String): Boolean {
        val keys = HangupMailboxKeys.pick(
            role = live.role,
            offerPgp = live.offer.callerPgpArmored,
            offerRoute = live.offer.callerRouteArmored,
            lookup = { BeamioAddressPgp.searchKey(live.peerEoa)?.let { it.userPublicKeyArmored to it.routePublicKeyArmored } },
        ) ?: return false
        repeat(2) { attempt ->
            if (attempt > 0) runCatching { Thread.sleep(600L) }
            if (BeamioVoiceV3.postChatMessage(app, text, live.localEoa, keys.first, keys.second, noPush = true)) return true
        }
        return false
    }

    /** Telecom Answer: voice v3 accept to the caller's mailbox; starts our channels. */
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
                if (offer == null || !offer.answerable) {
                    offer = BeamioVoiceOfferIdentity.resolveBlocking(app, callId, sessionId, 45_000L)
                }
                if (offer == null || !offer.answerable) {
                    Log.w(TAG, "accept skip — no v3 offer callId=${callId.take(12)}")
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
                sendAcceptV3(app, offer, localEoa)
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

    /**
     * v3 Answer: create the four paid channels (our wallet pays), open our two
     * on relays we pick, and send the accept to the caller's mailbox as a chat
     * message (recipient PGP + mailbox route layer, random entry). On [io].
     */
    private fun sendAcceptV3(app: Context, offer: BeamioVoiceOfferIdentity.ResolvedIdentity, localEoa: String) {
        val payerKey = BeamioVoiceV3.payerKey(app, localEoa) ?: run {
            Log.w(TAG, "v3 accept — no stored wallet key")
            return
        }
        BeamioCallTiming.mark("accept-v3-start")
        val prepared = preparedChannels.remove(offer.callId)
            ?.takeIf { System.currentTimeMillis() - it.second < 300_000L }?.first
        val cv: BeamioVoiceV3.Own
        val cV: BeamioVoiceV3.Own
        val ev: BeamioVoiceV3.Own
        val eV: BeamioVoiceV3.Own
        if (prepared != null) {
            Log.i(TAG, "v3 accept uses channels prepared while ringing callId=${offer.callId.take(8)}")
            cv = prepared[0]; cV = prepared[1]; ev = prepared[2]; eV = prepared[3]
        } else {
            val made = (0 until 4).map {
                BeamioVoiceV3.newPaidChannel(app, payerKey, localEoa) ?: run {
                    Log.w(TAG, "v3 accept — sign failed")
                    return
                }
            }
            BeamioVoiceV3.RelayNodes.attach(app)
            val secrets = BeamioChatPgpStore.load(app) ?: return
            val exclude = setOfNotNull(BeamioSiCipherPost.normalizeIp(secrets.mailboxIp))
            val avoid = listOf(secrets.routePublicKeyArmor, offer.callerRouteArmored)
            val voiceRelay = BeamioVoiceV3.RelayNodes.pick(exclude, avoid)
            val videoRelay = BeamioVoiceV3.RelayNodes.pick(exclude, avoid)
            if (voiceRelay == null || videoRelay == null) {
                Log.w(TAG, "v3 accept — no relay nodes cached")
                return
            }
            cv = made[0]; cV = made[1]
            ev = made[2].copy(relay = voiceRelay)
            eV = made[3].copy(relay = videoRelay)
        }
        val ch = BeamioVoiceV3.acceptChannels(cv, cV, ev, eV) ?: return
        val nowMs = System.currentTimeMillis()
        val text = JSONObject()
            .put("type", "voice_call_accept_v1")
            .put("proto", 3)
            .put("callId", offer.callId)
            .put("sessionId", offer.sessionId)
            .put("from", localEoa)
            .put("to", offer.callerEoa.lowercase())
            .put("createdAt", nowMs)
            .put("timestamp", nowMs)
            .put("codec", "audio/pcm;rate=16000")
            .put("ch", ch)
            .toString()
        val active = ActiveCall(
            role = Role.CALLEE,
            offer = offer,
            listenSessionId = ev.channel.sid,
            peerMediaSessionId = cv.channel.sid,
            peerEoa = offer.callerEoa.lowercase(),
            localEoa = localEoa,
            mediaEnabled = true,
            v3 = BeamioVoiceV3.Call(
                callId = offer.callId,
                ownVoice = ev,
                ownVideo = eV,
                peerVoice = BeamioVoiceV3.Peer(cv.channel),
                peerVideo = BeamioVoiceV3.Peer(cV.channel),
            ),
        )
        activeCall.set(active)
        // Our listens open beside the accept post; the caller's media waits for them anyway.
        BeamioNativeVoiceChannel.start(app, active)
        var ok = false
        for (attempt in 0 until 3) {
            ok = BeamioVoiceV3.postChatMessage(
                app, text, localEoa, offer.callerPgpArmored, offer.callerRouteArmored, noPush = true,
            )
            Log.i(TAG, "v3 accept post attempt=${attempt + 1} ok=$ok")
            if (ok) break
            runCatching { Thread.sleep(600L * (attempt + 1)) }
        }
        BeamioCallTiming.mark("accept-v3-sent")
        if (!ok) {
            BeamioNativeVoiceChannel.stop()
            activeCall.compareAndSet(active, null)
            return
        }
        MainActivity.dispatchSystemCallAction("callConnected", offer.callId, offer.sessionId)
    }

    fun rosterOf(secrets: BeamioChatPgpStore.Secrets): List<BeamioChatPgpStore.SiNode> {
        if (secrets.siNodes.isNotEmpty()) return secrets.siNodes
        return secrets.entryDomains.mapNotNull { raw ->
            val ip = BeamioSiCipherPost.normalizeIp(raw) ?: return@mapNotNull null
            BeamioChatPgpStore.SiNode(ip)
        }
    }
}
