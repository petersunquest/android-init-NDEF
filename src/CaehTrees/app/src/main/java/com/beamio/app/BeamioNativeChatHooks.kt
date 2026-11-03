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
        trackAppForeground(app)
    }

    /** Activities of this app that are started (visible). Main thread. */
    private var startedActivities = 0

    /**
     * The app does not run in the background: tell the chat module when the
     * app goes to the background (no activity visible) and comes back. The
     * module pauses the mailbox listen in the background unless a call rings,
     * dials or is up, and reconnects at once in the foreground.
     */
    private fun trackAppForeground(app: Context) {
        val application = app as? android.app.Application ?: return
        application.registerActivityLifecycleCallbacks(object : android.app.Application.ActivityLifecycleCallbacks {
            override fun onActivityStarted(activity: android.app.Activity) {
                startedActivities += 1
                if (startedActivities == 1) BeamioConetChatModule.appForeground(app, activity.javaClass.simpleName)
            }

            override fun onActivityStopped(activity: android.app.Activity) {
                startedActivities = (startedActivities - 1).coerceAtLeast(0)
                // A rotation stops and starts the activity: the module waits
                // before pausing, and the start cancels it.
                if (startedActivities == 0) BeamioConetChatModule.appBackground(activity.javaClass.simpleName)
            }

            override fun onActivityCreated(activity: android.app.Activity, savedInstanceState: android.os.Bundle?) = Unit
            override fun onActivityResumed(activity: android.app.Activity) = Unit
            override fun onActivityPaused(activity: android.app.Activity) = Unit
            override fun onActivitySaveInstanceState(activity: android.app.Activity, outState: android.os.Bundle) = Unit
            override fun onActivityDestroyed(activity: android.app.Activity) = Unit
        })
        // Installed by a call push with no activity on screen: the app is in the background.
        ringHandler.postDelayed({
            if (startedActivities == 0) BeamioConetChatModule.appBackground("launchedInBackground")
        }, 2_000L)
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

    private val ringHandler = Handler(Looper.getMainLooper())
    private var ringCatchUp: Runnable? = null
    /** Times after the ring starts at which the listen is reopened; then every [RING_CATCH_UP_REPEAT_MS]. */
    private val RING_CATCH_UP_AT_MS = longArrayOf(5_000L, 10_000L, 16_000L, 24_000L, 35_000L, 50_000L)
    private const val RING_CATCH_UP_REPEAT_MS = 30_000L

    /**
     * An incoming call started ringing. The caller's cancel is a chat message to
     * our mailbox, and the mailbox keeps it until we ACK it and sends it again on
     * every new listen. A cancel that missed the current listen (stored while the
     * listen was being set up after a push wake, or written to a dead listen of a
     * killed process) would otherwise wait for the next reconnect, and the call
     * would ring to the full ring time. So reopen the listen now and then until
     * this call stops ringing.
     */
    fun startIncomingRingCatchUp(context: Context, callId: String, sessionId: String) {
        install(context)
        ringHandler.post {
            ringCatchUp?.let { ringHandler.removeCallbacks(it) }
            var step = 0
            lateinit var tick: Runnable
            tick = Runnable {
                if (ringCatchUp !== tick) return@Runnable
                if (!BeamioTelecomService.isIncomingRinging(callId, sessionId)) {
                    ringCatchUp = null
                    return@Runnable
                }
                val refreshed = BeamioConetChatModule.refreshListen("incomingRing")
                Log.i(TAG, "ring catch-up step=$step listenRefreshed=$refreshed")
                step += 1
                val next = if (step < RING_CATCH_UP_AT_MS.size) {
                    RING_CATCH_UP_AT_MS[step] - RING_CATCH_UP_AT_MS[step - 1]
                } else {
                    RING_CATCH_UP_REPEAT_MS
                }
                ringHandler.postDelayed(tick, next)
            }
            ringCatchUp = tick
            ringHandler.postDelayed(tick, RING_CATCH_UP_AT_MS[0])
        }
    }

    /** When the mailbox listen last reported "listening" (it replays stored messages on attach). */
    @Volatile
    var listenAttachedAt: Long = 0L
        private set

    /**
     * Make the mailbox send its stored messages again now: reopen a connected
     * listen, or start one. Used when a call push may be stale.
     */
    fun pullMailboxNow(context: Context, reason: String) {
        install(context)
        val refreshed = BeamioConetChatModule.refreshListen(reason)
        val started = if (refreshed) false else BeamioConetChatModule.wake(context.applicationContext, reason)
        Log.i(TAG, "mailbox pull for $reason refreshed=$refreshed started=$started")
    }

    private fun logStatus(payload: JSONObject) {
        val event = payload.optJSONObject("event") ?: return
        if (event.optString("type") != "event:status") return
        val st = event.optJSONObject("payload")
        if (st?.optString("status") == "listening") listenAttachedAt = System.currentTimeMillis()
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
            if (type == "voice_end_v1") {
                // A late call push may still be waiting to ring this call: settle it,
                // so the ring never starts. A call already over keeps its record.
                BeamioTelecomService.notePeerEndedBeforeRing(app, callId, sessionId)
            }
            Log.i(TAG, "chat end for no live call; ignored")
            return
        }
        BeamioNativeVoiceSignaling.peerDidEnd(app, callId, sessionId)
    }
}
