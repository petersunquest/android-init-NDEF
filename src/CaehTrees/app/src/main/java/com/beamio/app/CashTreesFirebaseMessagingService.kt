package com.beamio.app

import android.util.Log
import com.google.firebase.messaging.FirebaseMessagingService
import com.google.firebase.messaging.RemoteMessage

/**
 * Offline chat badge via FCM.
 * Server sends notification + data when badge > 0 so background/killed apps still
 * get a system tray entry + `notification_count` (launcher badge). Foreground
 * delivery hits [onMessageReceived] and we apply a silent local badge notification.
 */
class CashTreesFirebaseMessagingService : FirebaseMessagingService() {
    override fun onCreate() {
        super.onCreate()
        // A push cold start reaches here before the FCM SDK posts the offline chat
        // entry; without the channel it would land in FCM's fallback channel.
        CashTreesNativeAppStateBridge.ensureOfflineChatChannel(applicationContext)
    }

    override fun onNewToken(token: String) {
        CashTreesPushRegistration.onNewToken(applicationContext, token)
    }

    override fun onMessageReceived(message: RemoteMessage) {
        BeamioGuardianRoster.kick(this)
        val data = message.data
        val type = data["type"]?.trim().orEmpty()
        Log.i(
            TAG,
            "FCM received type=${type.ifBlank { "<empty>" }} keys=${data.keys.sorted()}",
        )
        if (type == "voiceCall" || type == "beamioVoiceCall") {
            val callId = data["callId"]?.trim().orEmpty()
            Log.i(
                TAG,
                "FCM voice wake received callIdPresent=${callId.isNotBlank()} " +
                    "sessionIdPresent=${data["sessionId"]?.isNullOrBlank() == false}",
            )
            val sessionId = data["sessionId"]?.trim().orEmpty()
            val now = System.currentTimeMillis()
            val verdict = BeamioIncomingPushGate.verdict(now, message.sentTime, data["expiresAt"], data["action"])
            val lateMs = if (message.sentTime > 0) now - message.sentTime else -1L
            when (verdict) {
                BeamioIncomingPushGate.Verdict.END -> {
                    // Caller-cancel wake: never a ring. If its call rings, fetch the
                    // caller's signed end now instead of at the next catch-up step.
                    BeamioIncomingPushGate.noteEndPush(callId, sessionId)
                    val ringing = BeamioTelecomService.isIncomingRinging(callId, sessionId)
                    Log.i(TAG, "FCM call end wake; not ringing (callRinging=$ringing)")
                    if (ringing) BeamioNativeChatHooks.pullMailboxNow(applicationContext, "callEndPush")
                    return
                }
                BeamioIncomingPushGate.Verdict.EXPIRED -> {
                    // Past the ring window: a missed call. The page records it from the
                    // offer in the mailbox (as missed, or cancelled if the caller's end is there).
                    Log.i(TAG, "FCM voice wake past the ring window lateMs=$lateMs; not ringing (missed)")
                    return
                }
                BeamioIncomingPushGate.Verdict.HOLD_FOR_MAILBOX -> {
                    if (!holdLatePushForMailbox(callId, sessionId, lateMs)) return
                }
                BeamioIncomingPushGate.Verdict.RING -> Unit
            }
            if (BeamioIncomingPushGate.endPushSeen(callId, sessionId)) {
                Log.i(TAG, "FCM voice wake after its end push; not ringing")
                return
            }
            if (BeamioTelecomService.wasBusyRejected(callId, sessionId)) return
            // Claim or busy-reject before any encryption WebView. A second call
            // must not open OpenPgp while the first glass window is up.
            BeamioTelecomService.showIncomingCallWakeNotification(
                applicationContext,
                callId,
                sessionId,
            )
            if (BeamioTelecomService.wasBusyRejected(callId, sessionId)) return
            // Open the chat mailbox listen now (stored keys, no page needed): the
            // caller's cancel and other senders' messages arrive while it rings.
            BeamioNativeChatHooks.wakeForCallPush(applicationContext)
            // Prefetch the offer (caller keys) BEFORE CallStyle so Decline can
            // AES-encrypt voice_call_reject_v1 (same race as iOS PushKit).
            // FCM stays opaque (no caller identity in push); resolve upgrades title.
            if (callId.isNotBlank()) {
                BeamioVoiceOfferIdentity.scheduleResolveDelayed(
                    applicationContext,
                    callId,
                    sessionId,
                    delayMs = 0L,
                ) { identity ->
                    // Upgrade the same small incoming window to @BeamioTag.
                    val tag = identity.beamioTag.orEmpty()
                    val display = tag.ifBlank { identity.shortAddress }
                    BeamioTelecomService.showIncomingCallNotification(
                        applicationContext,
                        callId = identity.callId,
                        peerAddress = identity.callerEoa,
                        displayName = display,
                        sessionId = identity.sessionId,
                        claimedTag = tag,
                        claimedAddress = identity.callerEoa,
                    )
                }
            }
            return
        }
        if (type != "chatBadge" && type != "syncChatBadge") return
        val badgeRaw = data["badge"] ?: data["unread"] ?: return
        val badge = badgeRaw.toIntOrNull()?.coerceIn(0, 999) ?: return
        CashTreesNativeAppStateBridge.applyAppIconBadge(applicationContext, badge)
    }

    /**
     * A late push may be for a call the caller already ended: its signed end sits
     * in our mailbox, which replays stored messages when the listen attaches.
     * Open the listen and wait (on this FCM worker thread, which keeps the wake
     * alive) until it attached and had time to replay, at most a few seconds.
     * Returns false when the call ended meanwhile (no ring).
     */
    private fun holdLatePushForMailbox(callId: String, sessionId: String, lateMs: Long): Boolean {
        val start = System.currentTimeMillis()
        Log.i(TAG, "FCM voice wake late lateMs=$lateMs; checking the mailbox before ringing")
        BeamioTelecomService.restoreSettledIncoming(applicationContext)
        BeamioNativeChatHooks.pullMailboxNow(applicationContext, "lateCallPush")
        val deadline = start + BeamioIncomingPushGate.HOLD_MAX_MS
        while (true) {
            val now = System.currentTimeMillis()
            if (BeamioTelecomService.isIncomingClosed(callId, sessionId) ||
                BeamioIncomingPushGate.endPushSeen(callId, sessionId)
            ) {
                Log.i(TAG, "late call push: call already ended; not ringing waitedMs=${now - start}")
                return false
            }
            val attachedAt = BeamioNativeChatHooks.listenAttachedAt
            val replayed = attachedAt >= start && now - attachedAt >= BeamioIncomingPushGate.HOLD_AFTER_ATTACH_MS
            if (replayed || now >= deadline) {
                Log.i(TAG, "late call push: no end found; ringing waitedMs=${now - start} listenAttached=${attachedAt >= start}")
                return true
            }
            try {
                Thread.sleep(150L)
            } catch (_: InterruptedException) {
                return true
            }
        }
    }

    private companion object {
        const val TAG = "BeamioVoiceCall"
    }
}
