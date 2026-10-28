package com.beamio.app

import android.app.Activity
import android.app.ActivityManager
import android.content.Context
import android.content.Intent
import android.graphics.Outline
import android.os.Build
import android.os.Bundle
import android.os.PowerManager
import android.util.Log
import android.view.View
import android.view.ViewOutlineProvider
import android.view.WindowManager
import android.widget.ImageView
import android.widget.TextView
import android.window.OnBackInvokedDispatcher
import java.lang.ref.WeakReference

/**
 * Lock-screen incoming window for a third-party VoIP app.
 * The stock phone app only draws its full-screen card for the default dialer.
 * This window is launched by the notification full-screen intent so it can
 * appear over the keyguard and play the system ringtone.
 */
class IncomingCallActivity : Activity() {
    private var callId: String = ""
    private var sessionId: String = ""
    private var claimedTag: String = ""

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        showOverLockScreen()
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.TIRAMISU) {
            onBackInvokedDispatcher.registerOnBackInvokedCallback(
                OnBackInvokedDispatcher.PRIORITY_DEFAULT,
            ) { }
        }
        setContentView(R.layout.activity_incoming_call)
        applyBannerEdgeInsets()
        clipAvatar()
        bindActions()
        instance = WeakReference(this)
        render(intent)
        raiseIncomingTask()
        Log.i(TAG, "Incoming window showing titlePresent=${titlePresent(intent)} taskId=$taskId")
    }

    override fun onResume() {
        super.onResume()
        raiseIncomingTask()
    }

    /** Keep this activity's task above MainActivity when both are alive. */
    private fun raiseIncomingTask() {
        @Suppress("DEPRECATION")
        runCatching {
            val am = getSystemService(ACTIVITY_SERVICE) as ActivityManager
            am.moveTaskToFront(taskId, 0)
        }
    }

    /**
     * Force L/R/top edge on the nested inset host. Root [fitsSystemWindows] only
     * clears the status bar; putting the product edge on that same view is a no-op
     * because the framework replaces its padding with system insets.
     */
    private fun applyBannerEdgeInsets() {
        val edgePx = resources.getDimensionPixelSize(R.dimen.incoming_call_banner_edge)
        val host = findViewById<View>(R.id.incoming_call_banner_inset) ?: return
        host.setPadding(edgePx, edgePx, edgePx, host.paddingBottom)
        Log.i(TAG, "Incoming banner edgePx=$edgePx density=${resources.displayMetrics.density}")
    }

    override fun onNewIntent(intent: Intent) {
        val nextCall = intent.getStringExtra(BeamioTelecomService.EXTRA_CALL_ID).orEmpty()
        val nextSession = intent.getStringExtra(BeamioTelecomService.EXTRA_SESSION_ID).orEmpty()
        if (!matches(nextCall, nextSession)) {
            if (!BeamioTelecomService.wasBusyRejected(nextCall, nextSession)) {
                BeamioTelecomService.rejectSecondaryWhileBusy(this, nextCall, nextSession)
            }
            return
        }
        super.onNewIntent(intent)
        setIntent(intent)
        render(intent)
    }

    override fun onDestroy() {
        if (instance?.get() === this) instance = null
        super.onDestroy()
        // Answer keeps the Telecom connection ACTIVE, so this flush no-ops
        // until the call itself ends. Decline / timeout can send queued busy
        // uplinks once the glass window is gone.
        BeamioNativeVoiceSignaling.flushDeferredStickyDeclinesIfIdle()
    }

    @Deprecated("Incoming calls stay up until Decline, Answer, or Mute.")
    override fun onBackPressed() {
        // The window is the system incoming-call surface. Back must not drop it.
    }

    private fun showOverLockScreen() {
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O_MR1) {
            setShowWhenLocked(true)
            setTurnScreenOn(true)
        } else {
            @Suppress("DEPRECATION")
            window.addFlags(
                WindowManager.LayoutParams.FLAG_SHOW_WHEN_LOCKED or
                    WindowManager.LayoutParams.FLAG_TURN_SCREEN_ON,
            )
        }
        window.addFlags(WindowManager.LayoutParams.FLAG_KEEP_SCREEN_ON)
    }

    private fun clipAvatar() {
        val avatar = findViewById<ImageView>(R.id.incoming_call_avatar)
        avatar.outlineProvider = object : ViewOutlineProvider() {
            override fun getOutline(view: View, outline: Outline) {
                outline.setOval(0, 0, view.width, view.height)
            }
        }
        avatar.clipToOutline = true
    }

    private fun bindActions() {
        findViewById<View>(R.id.incoming_call_decline).setOnClickListener {
            it.isEnabled = false
            BeamioTelecomService.finishIncomingCall(this, "callRejected", callId, sessionId)
        }
        findViewById<View>(R.id.incoming_call_answer).setOnClickListener {
            it.isEnabled = false
            BeamioTelecomService.finishIncomingCall(this, "callAnswered", callId, sessionId)
        }
        findViewById<View>(R.id.incoming_call_mute).setOnClickListener {
            it.isEnabled = false
            BeamioTelecomService.silenceIncomingWindow(this, callId, sessionId)
        }
    }

    private fun render(source: Intent?) {
        callId = source?.getStringExtra(BeamioTelecomService.EXTRA_CALL_ID).orEmpty().trim()
        sessionId = source?.getStringExtra(BeamioTelecomService.EXTRA_SESSION_ID).orEmpty().trim()
        claimedTag = source?.getStringExtra(BeamioTelecomService.EXTRA_CLAIMED_TAG).orEmpty().trim()
        val title = source?.getStringExtra(BeamioTelecomService.EXTRA_INCOMING_TITLE).orEmpty()
            .ifBlank { getString(R.string.incoming_call_body) }
        val body = source?.getStringExtra(BeamioTelecomService.EXTRA_INCOMING_BODY).orEmpty()
            .ifBlank { getString(R.string.incoming_call_glass_subtitle) }
        findViewById<TextView>(R.id.incoming_call_title).text = title
        findViewById<TextView>(R.id.incoming_call_body).text = body
        bindAvatar(title)
    }

    private fun bindAvatar(title: String) {
        val avatar = findViewById<ImageView>(R.id.incoming_call_avatar)
        val fallback = findViewById<ImageView>(R.id.incoming_call_avatar_fallback)
        val seed = claimedTag.ifBlank { title }
        val bitmap = BeamioTelecomService.cachedCallerAvatar(seed)
        if (bitmap == null) {
            avatar.visibility = View.GONE
            fallback.visibility = View.VISIBLE
            return
        }
        avatar.setImageBitmap(bitmap)
        avatar.visibility = View.VISIBLE
        fallback.visibility = View.GONE
    }

    private fun matches(callId: String, sessionId: String): Boolean {
        val call = callId.trim()
        val session = sessionId.trim()
        if (call.isEmpty() && session.isEmpty()) return this.callId.isEmpty() && this.sessionId.isEmpty()
        return (call.isNotEmpty() && call == this.callId) ||
            (session.isNotEmpty() && session == this.sessionId)
    }

    private fun finishFromCall() {
        if (isFinishing) return
        finish()
    }

    companion object {
        private const val TAG = "BeamioVoiceCall"
        private var instance: WeakReference<IncomingCallActivity>? = null

        /** Ids of the glass window that is on screen. Empty when it is finishing. */
        fun shownCallKeys(): Set<String> {
            val activity = instance?.get() ?: return emptySet()
            if (activity.isFinishing || activity.isDestroyed) return emptySet()
            return listOf(activity.callId, activity.sessionId)
                .map { it.trim() }
                .filter { it.isNotEmpty() }
                .toSet()
        }

        fun present(context: Context, launch: Intent) {
            val callId = launch.getStringExtra(BeamioTelecomService.EXTRA_CALL_ID).orEmpty()
            val sessionId = launch.getStringExtra(BeamioTelecomService.EXTRA_SESSION_ID).orEmpty()
            if (BeamioTelecomService.wasBusyRejected(callId, sessionId)) return
            if (BeamioTelecomService.anotherCallOwnsChrome(callId, sessionId)) {
                BeamioTelecomService.rejectSecondaryWhileBusy(context, callId, sessionId)
                return
            }
            val run = Runnable { presentOnMain(context.applicationContext, launch) }
            if (android.os.Looper.myLooper() == android.os.Looper.getMainLooper()) run.run()
            else android.os.Handler(android.os.Looper.getMainLooper()).post(run)
        }

        private fun presentOnMain(app: Context, launch: Intent) {
            wakeScreen(app)
            val showing = instance?.get()
            if (showing != null && !showing.isFinishing) {
                val nextCall = launch.getStringExtra(BeamioTelecomService.EXTRA_CALL_ID).orEmpty()
                val nextSession = launch.getStringExtra(BeamioTelecomService.EXTRA_SESSION_ID).orEmpty()
                val shown = shownCallKeys()
                val sameWindow = listOf(nextCall, nextSession).any { it.isNotBlank() && shown.contains(it) }
                if (!sameWindow) return
                showing.render(launch)
                showing.raiseIncomingTask()
                return
            }
            val opening = Intent(launch).apply {
                setClass(app, IncomingCallActivity::class.java)
                // Same-task stack on top of MainActivity (REORDER_TO_FRONT).
                // Separate singleInstance affinity put a translucent window
                // under opaque MainActivity on Samsung — glass drawn but invisible.
                addFlags(
                    Intent.FLAG_ACTIVITY_NEW_TASK or
                        Intent.FLAG_ACTIVITY_SINGLE_TOP or
                        Intent.FLAG_ACTIVITY_REORDER_TO_FRONT or
                        Intent.FLAG_ACTIVITY_NO_USER_ACTION,
                )
            }
            runCatching { app.startActivity(opening) }
                .onSuccess {
                    Log.i(TAG, "Incoming window startActivity dispatched (FSI if BAL blocks)")
                }
                .onFailure {
                    Log.i(TAG, "Incoming window start deferred to fullScreenIntent")
                }
        }

        private fun wakeScreen(app: Context) {
            val power = app.getSystemService(PowerManager::class.java) ?: return
            @Suppress("DEPRECATION")
            val screen = power.newWakeLock(
                PowerManager.SCREEN_BRIGHT_WAKE_LOCK or
                    PowerManager.ACQUIRE_CAUSES_WAKEUP or
                    PowerManager.ON_AFTER_RELEASE,
                "beamio:incoming-screen",
            )
            screen.setReferenceCounted(false)
            runCatching { screen.acquire(10_000L) }
        }

        fun stopRinging() {
            BeamioIncomingRingtone.stop()
        }

        fun isShowing(): Boolean {
            val activity = instance?.get() ?: return false
            return !activity.isFinishing
        }

        fun bringToFront(context: Context) {
            val activity = instance?.get() ?: return
            present(context, activity.intent ?: return)
        }

        fun refreshAvatarIfShowing() {
            val activity = instance?.get() ?: return
            val title = activity.findViewById<TextView>(R.id.incoming_call_title)?.text?.toString().orEmpty()
            activity.bindAvatar(title)
        }

        fun finishIfMatching(callId: String, sessionId: String) {
            val activity = instance?.get()
            if (activity != null && !activity.matches(callId, sessionId)) return
            BeamioIncomingRingtone.stop()
            activity?.finishFromCall()
        }

        fun finishIfShowing() {
            BeamioIncomingRingtone.stop()
            instance?.get()?.finishFromCall()
        }

        fun updateShownCaller(
            callId: String,
            sessionId: String,
            displayName: String,
            peerAddress: String,
            claimedTag: String,
            claimedAddress: String,
            identityWarning: String,
        ) {
            val activity = instance?.get() ?: return
            if (!activity.matches(callId, sessionId)) return
            val title = displayName.trim().ifBlank {
                claimedTag.trim().ifBlank { peerAddress.trim() }
            }.ifBlank { activity.getString(R.string.incoming_call_body) }
            val body = identityWarning.trim().ifBlank {
                activity.getString(R.string.incoming_call_glass_subtitle)
            }
            activity.claimedTag = claimedTag.trim().ifBlank { activity.claimedTag }
            activity.findViewById<TextView>(R.id.incoming_call_title)?.text = title
            activity.findViewById<TextView>(R.id.incoming_call_body)?.text = body
            activity.bindAvatar(title)
            if (claimedAddress.isNotBlank()) {
                activity.intent?.putExtra(BeamioTelecomService.EXTRA_CLAIMED_ADDRESS, claimedAddress)
            }
        }

        private fun titlePresent(source: Intent?): Boolean {
            return !source?.getStringExtra(BeamioTelecomService.EXTRA_INCOMING_TITLE).isNullOrBlank()
        }
    }
}
