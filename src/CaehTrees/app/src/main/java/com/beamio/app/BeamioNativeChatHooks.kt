package com.beamio.app

import android.content.Context
import android.os.Handler
import android.os.Looper
import android.util.Log
import network.conet.chat.BeamioConetChatModule
import network.conet.chat.BeamioEntryPool
import network.conet.chat.BeamioGuardianNodeWatch
import org.json.JSONObject
import java.util.concurrent.atomic.AtomicBoolean

/**
 * Call layer side of the native chat module's mailbox listen.
 *
 * - While a call rings, dials or is up, the page's background `pause` is
 *   deferred, so the listen stays connected (other senders' messages and the
 *   peer's call control keep arriving).
 * - A call push wakes the listen from the stored identity without waiting for
 *   the page ([wakeForCallPush] → `BeamioConetChatModule.wake`).
 * - The module recognises a peer's `voice_end_v1` / `voice_call_timeout_v1`
 *   Chat message and hands it here; the matching call ends natively (same rule
 *   as iOS). The page still records it from the same message.
 */
object BeamioNativeChatHooks {
    private const val TAG = "BeamioVoiceCall"
    private val installed = AtomicBoolean(false)

    fun install(context: Context) {
        if (!installed.compareAndSet(false, true)) return
        val app = context.applicationContext
        BeamioConetChatModule.keepListenWhile = { BeamioTelecomService.isCallInProgress() }
        // Warm entries stay ready while a call rings, dials or is up.
        BeamioEntryPool.attach(app)
        BeamioEntryPool.holdWhile = { BeamioTelecomService.isCallInProgress() }
        BeamioConetChatModule.callControlObserver = { type, callId, sessionId, from ->
            onPeerCallControl(app, type, callId, sessionId, from)
        }
        BeamioConetChatModule.nativeObserver = { payload ->
            logStatus(payload)
            // v3: the callee's accept / decline reaches the dialer as a chat message.
            BeamioNativeVoiceSignaling.observeChatEvent(app, payload)
        }
    }

    /** FCM call wake: open the mailbox listen now, page or not. */
    fun wakeForCallPush(context: Context) {
        install(context)
        // Warm entries from the cached node table now; the chain check runs alongside.
        BeamioEntryPool.hold("incomingCall")
        BeamioEntryPool.warmNow()
        BeamioGuardianNodeWatch.kick(context)
        val started = BeamioConetChatModule.wake(context.applicationContext, "incomingCall")
        Log.i(TAG, "chat listen for call push started=$started")
    }

    private fun logStatus(payload: JSONObject) {
        val event = payload.optJSONObject("event") ?: return
        if (event.optString("type") != "event:status") return
        val st = event.optJSONObject("payload")
        Log.i(TAG, "chat status ${st?.optString("status")} ${st?.optString("detail").orEmpty()}")
    }

    private fun onPeerCallControl(app: Context, type: String, callId: String, sessionId: String, from: String) {
        Log.i(TAG, "chat end signal type=$type callId=${callId.take(12)}")
        // The recovered signer must be the caller when the offer is known;
        // otherwise the secret call ids are the only check.
        val caller = BeamioNativeVoiceSignaling.cachedOffer(callId, sessionId)
            ?.callerEoa?.trim()?.lowercase().orEmpty()
        if (caller.isNotEmpty() && caller != from.trim().lowercase()) {
            Log.w(TAG, "chat end ignored: signer is not the caller")
            return
        }
        // A redelivered end for a call that is already over must not touch the current one.
        if (!BeamioTelecomService.isLiveCall(callId, sessionId)) {
            Log.i(TAG, "chat end for no live call; ignored")
            return
        }
        BeamioNativeVoiceSignaling.peerDidEnd(app, callId, sessionId)
    }
}
