package com.beamio.app

import android.app.Activity
import android.content.Context
import android.content.Intent
import android.graphics.Color
import android.graphics.Outline
import android.media.Ringtone
import android.media.RingtoneManager
import android.graphics.drawable.GradientDrawable
import android.graphics.PixelFormat
import android.os.Build
import android.os.Handler
import android.os.Looper
import android.os.Bundle
import android.util.Log
import android.view.Gravity
import android.view.ViewOutlineProvider
import android.view.WindowManager
import android.view.View
import android.widget.ImageView
import android.widget.FrameLayout
import android.widget.LinearLayout
import android.widget.TextView

/**
 * Native incoming-call surface. Telecom self-managed accounts do not promise
 * that Android will render the dialer's incoming-call screen, so Beamio owns
 * this full-screen, lock-screen-safe surface.
 */
class IncomingCallActivity : Activity() {
    private var callId = ""
    private var sessionId = ""
    private val callerLookupHandler = Handler(Looper.getMainLooper())
    private var callerLookupAttempt = 0
    private val callerLookupRunnable = object : Runnable {
        override fun run() {
            if (!isFinishing && callerLookupAttempt < 30) {
                callerLookupAttempt += 1
                render(intent)
            }
        }
    }

    override fun onCreate(savedInstanceState: Bundle?) {
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.S) {
            splashScreen.setOnExitAnimationListener { splash -> splash.remove() }
        }
        super.onCreate(savedInstanceState)
        window.setFormat(PixelFormat.TRANSLUCENT)
        activeInstance = this
        appContext = applicationContext
        overridePendingTransition(0, 0)
        render(intent)
        Log.i("BeamioVoiceCall", "IncomingCallActivity scrim shown")
    }

    override fun onNewIntent(intent: Intent) {
        super.onNewIntent(intent)
        setIntent(intent)
        activeInstance = this
        render(intent)
    }

    private fun render(source: Intent) {
        callId = source.getStringExtra(BeamioTelecomService.EXTRA_CALL_ID).orEmpty()
        sessionId = source.getStringExtra(BeamioTelecomService.EXTRA_SESSION_ID).orEmpty()
        val claimed = source.getStringExtra(BeamioTelecomService.EXTRA_CLAIMED_TAG).orEmpty().trim()
        val rawName = source.getStringExtra(BeamioTelecomService.EXTRA_DISPLAY_NAME).orEmpty().trim()
        val title = when {
            claimed.isNotBlank() -> if (claimed.startsWith("@")) claimed else "@$claimed"
            rawName.isNotBlank() && !rawName.startsWith("0x", ignoreCase = true) ->
                rawName.substringBefore("  ").trim()
            else -> "Incoming call"
        }
        val warning = source.getStringExtra(BeamioTelecomService.EXTRA_IDENTITY_WARNING).orEmpty().trim()
        val subtitle = if (warning.isBlank() || warning == "Incoming voice call") {
            getString(R.string.incoming_call_glass_subtitle)
        } else {
            warning
        }
        val tag = claimed.ifBlank { title }
        findViewById<TextView>(R.id.incoming_call_title)?.let { titleView ->
            titleView.text = title
            findViewById<TextView>(R.id.incoming_call_body)?.text = subtitle
            applyAvatar(tag)
            return
        }
        val density = resources.displayMetrics.density
        val root = FrameLayout(this)
        val card = layoutInflater.inflate(R.layout.incoming_call_glass, root, false)
        card.findViewById<TextView>(R.id.incoming_call_title).text = title
        card.findViewById<TextView>(R.id.incoming_call_body).text = subtitle
        val avatarView = card.findViewById<ImageView>(R.id.incoming_call_avatar)
        avatarView.outlineProvider = object : ViewOutlineProvider() {
            override fun getOutline(view: View, outline: Outline) {
                outline.setOval(0, 0, view.width, view.height)
            }
        }
        avatarView.clipToOutline = true
        applyAvatar(tag, card)
        card.findViewById<View>(R.id.incoming_call_decline).setOnClickListener {
            finishCall("callRejected")
        }
        card.findViewById<View>(R.id.incoming_call_mute).setOnClickListener {
            Log.i("BeamioVoiceCall", "Incoming mute tapped")
            BeamioTelecomService.silenceIncomingWindow(this, callId, sessionId)
        }
        card.findViewById<View>(R.id.incoming_call_answer).setOnClickListener {
            finishCall("callAnswered")
        }
        val side = (16 * density).toInt()
        val top = (56 * density).toInt()
        root.addView(card, FrameLayout.LayoutParams(
            FrameLayout.LayoutParams.MATCH_PARENT,
            FrameLayout.LayoutParams.WRAP_CONTENT,
            Gravity.TOP,
        ).apply {
            leftMargin = side
            rightMargin = side
            topMargin = top
        })
        setContentView(root)
    }

    private fun applyAvatar(tag: String, root: View? = null) {
        val avatarView = root?.findViewById(R.id.incoming_call_avatar)
            ?: findViewById<ImageView>(R.id.incoming_call_avatar)
            ?: return
        val avatar = BeamioTelecomService.cachedCallerAvatar(tag) ?: return
        avatarView.setImageBitmap(avatar)
        avatarView.visibility = View.VISIBLE
        val fallback = root?.findViewById(R.id.incoming_call_avatar_fallback)
            ?: findViewById<View>(R.id.incoming_call_avatar_fallback)
        fallback?.visibility = View.GONE
    }

    private fun showScrim() {
        render(intent)
    }

    override fun onResume() {
        super.onResume()
        if (!isFinishing) {
            startRinging()
            ensureShellBehindCall()
        }
        Log.i("BeamioVoiceCall", "IncomingCallActivity onResume")
    }

    override fun onPause() {
        Log.i("BeamioVoiceCall", "IncomingCallActivity onPause finishing=$isFinishing")
        super.onPause()
    }

    override fun onStop() {
        Log.i("BeamioVoiceCall", "IncomingCallActivity onStop finishing=$isFinishing")
        if (isFinishing) stopRinging()
        super.onStop()
    }

    /**
     * FCM only carries call handles. The Consumer shell has to run behind this
     * window so the PWA can decrypt the offer and report the BeamioTag.
     * MainActivity uses the translucent call theme and moves itself back.
     */
    private fun ensureShellBehindCall() {
        if (MainActivity.isRunning()) return
        val launch = Intent(this, MainActivity::class.java).apply {
            action = Intent.ACTION_MAIN
            addCategory(Intent.CATEGORY_LAUNCHER)
            putExtra(BeamioTelecomService.EXTRA_WAKE_FOR_CALL, true)
            flags = Intent.FLAG_ACTIVITY_NEW_TASK or
                Intent.FLAG_ACTIVITY_SINGLE_TOP or
                Intent.FLAG_ACTIVITY_NO_ANIMATION
        }
        runCatching {
            startActivity(launch)
            overridePendingTransition(0, 0)
            Log.i("BeamioVoiceCall", "Consumer shell started behind the incoming window")
        }
    }

    override fun onDestroy() {
        Log.i("BeamioVoiceCall", "IncomingCallActivity onDestroy finishing=$isFinishing")
        callerLookupHandler.removeCallbacksAndMessages(null)
        stopRinging()
        if (activeInstance === this) activeInstance = null
        super.onDestroy()
    }

    private fun openBeamio() {
        val launch = Intent(this, MainActivity::class.java).apply {
            action = Intent.ACTION_MAIN
            addCategory(Intent.CATEGORY_LAUNCHER)
            putExtra(BeamioTelecomService.EXTRA_WAKE_FOR_CALL, true)
            flags = Intent.FLAG_ACTIVITY_NEW_TASK or Intent.FLAG_ACTIVITY_SINGLE_TOP
        }
        startActivity(launch)
        val keep = Intent(this, IncomingCallActivity::class.java).apply {
            action = "com.beamio.app.INCOMING_CALL"
            flags = Intent.FLAG_ACTIVITY_SINGLE_TOP or
                Intent.FLAG_ACTIVITY_REORDER_TO_FRONT or
                Intent.FLAG_ACTIVITY_NEW_TASK
            putExtras(intent)
        }
        startActivity(keep)
    }

    private fun finishCall(action: String) {
        BeamioTelecomService.finishIncomingCall(this, action, callId, sessionId)
        finish()
        overridePendingTransition(0, 0)
    }

    override fun finish() {
        super.finish()
        overridePendingTransition(0, 0)
    }

    private fun startRinging() {
        if (BeamioTelecomService.isIncomingMuted(callId, sessionId)) return
        if (ringing?.isPlaying == true) return
        val uri = RingtoneManager.getDefaultUri(RingtoneManager.TYPE_RINGTONE) ?: return
        ringing = RingtoneManager.getRingtone(this, uri)?.also { tone ->
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.P) tone.isLooping = true
            tone.play()
        }
    }

    companion object {
        @Volatile
        private var activeInstance: IncomingCallActivity? = null
        private var appContext: Context? = null
        private var ringing: Ringtone? = null

        fun stopRinging() {
            ringing?.stop()
            ringing = null
        }

        fun isShowing(): Boolean = activeInstance != null

        fun bringToFront(context: Context) {
            val activity = activeInstance ?: return
            val intent = Intent(context, IncomingCallActivity::class.java).apply {
                flags = Intent.FLAG_ACTIVITY_REORDER_TO_FRONT or
                    Intent.FLAG_ACTIVITY_SINGLE_TOP or
                    Intent.FLAG_ACTIVITY_NO_ANIMATION
                if (context !is Activity) {
                    addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
                }
                putExtras(activity.intent)
            }
            runCatching {
                context.startActivity(intent)
                if (context is Activity) context.overridePendingTransition(0, 0)
            }
        }

        fun refreshAvatarIfShowing() {
            activeInstance?.runOnUiThread {
                val activity = activeInstance ?: return@runOnUiThread
                activity.render(activity.intent)
            }
        }

        /** Close the visible incoming window only when it is this call. */
        fun finishIfMatching(callId: String, sessionId: String) {
            val activity = activeInstance ?: return
            val ended = listOf(callId, sessionId).map { it.trim() }.filter { it.isNotEmpty() }
            val shown = listOf(activity.callId, activity.sessionId).map { it.trim() }.filter { it.isNotEmpty() }
            if (ended.isNotEmpty() && shown.isNotEmpty() && ended.none { it in shown }) return
            finishIfShowing()
        }

        /** Close lock-screen UI when Answer/Decline came from the in-app buttons. */
        fun finishIfShowing() {
            val activity = activeInstance ?: return
            activeInstance = null
            activity.runOnUiThread {
                activity.finish()
                activity.overridePendingTransition(0, 0)
            }
        }

        /**
         * The PWA may learn the verified BeamioTag after the native screen has
         * already been launched. Re-render that same screen instead of leaving
         * the first address/generic fallback visible.
         */
        fun updateShownCaller(
            callId: String,
            sessionId: String,
            displayName: String,
            peerAddress: String,
            claimedTag: String,
            claimedAddress: String,
            identityWarning: String,
        ) {
            val activity = activeInstance
            if (activity == null) {
                // The PWA may deliver the verified identity before Android has
                // created the full-screen activity. Keep every handle in the
                // durable caller pool; render() will resolve it later.
                val context = appContext ?: run {
                    Log.w("BeamioVoiceCall", "updateShownCaller no activity/context")
                    return
                }
                val primaryKey = callId.trim().ifBlank { sessionId.trim() }
                if (primaryKey.isNotBlank()) {
                    BeamioTelecomService.rememberShownCaller(
                        context,
                        primaryKey,
                        peerAddress,
                        displayName,
                        claimedTag,
                        claimedAddress,
                        identityWarning,
                    )
                }
                if (sessionId.isNotBlank() && sessionId.trim() != primaryKey) {
                    BeamioTelecomService.rememberShownCaller(
                        context,
                        sessionId.trim(),
                        peerAddress,
                        displayName,
                        claimedTag,
                        claimedAddress,
                        identityWarning,
                    )
                }
                Log.i(
                    "BeamioVoiceCall",
                    "updateShownCaller queued without activity " +
                        "callIdPresent=${callId.isNotBlank()} " +
                        "sessionIdPresent=${sessionId.isNotBlank()}",
                )
                return
            }
            activity.runOnUiThread {
                val sameCall =
                    (callId.isNotBlank() && activity.callId == callId) ||
                        (sessionId.isNotBlank() && activity.sessionId == sessionId)
                Log.i(
                    "BeamioVoiceCall",
                    "updateShownCaller matched=" + sameCall +
                        " callIdPresent=" + callId.isNotBlank() +
                        " sessionIdPresent=" + sessionId.isNotBlank() +
                        " displayNamePresent=" + displayName.isNotBlank() +
                        " peerAddressPresent=" + peerAddress.isNotBlank(),
                )
                if (!sameCall) return@runOnUiThread
                activity.intent.putExtra(BeamioTelecomService.EXTRA_DISPLAY_NAME, displayName)
                activity.intent.putExtra(BeamioTelecomService.EXTRA_PEER_ADDRESS, peerAddress)
                activity.intent.putExtra(BeamioTelecomService.EXTRA_CLAIMED_TAG, claimedTag)
                activity.intent.putExtra(BeamioTelecomService.EXTRA_CLAIMED_ADDRESS, claimedAddress)
                activity.intent.putExtra(BeamioTelecomService.EXTRA_IDENTITY_WARNING, identityWarning)
                activity.render(activity.intent)
                Log.i("BeamioVoiceCall", "updateShownCaller rendered verified caller")
            }
        }
    }

    private fun capsule(text: String, background: String, foreground: String, sizeSp: Float = 16f): TextView =
        TextView(this).apply {
            this.text = text
            setTextColor(Color.parseColor(foreground))
            textSize = sizeSp
            gravity = Gravity.CENTER
            setPadding(28, 14, 28, 14)
            setBackground(
                GradientDrawable().apply {
                    cornerRadius = 80f
                    setColor(Color.parseColor(background))
                },
            )
        }

    private fun centeredParams() = LinearLayout.LayoutParams(
        LinearLayout.LayoutParams.WRAP_CONTENT,
        LinearLayout.LayoutParams.WRAP_CONTENT,
    ).apply {
        gravity = Gravity.CENTER_HORIZONTAL
        bottomMargin = 12
    }

    private fun actionParams() = LinearLayout.LayoutParams(0, 56, 1f).apply {
        marginStart = 8
        marginEnd = 8
    }

    private fun formatBeamioTag(raw: String): String {
        val value = raw.trim()
        if (value.isBlank() || value.startsWith("0x", ignoreCase = true)) return ""
        if (value.equals("Incoming voice call", ignoreCase = true)) return ""
        if (value.equals("Beamio contact", ignoreCase = true)) return ""
        return if (value.startsWith("@")) value else "@$value"
    }

    private fun formatCallerEoa(raw: String): String {
        val value = raw.trim()
        return if (value.startsWith("0x", ignoreCase = true) && value.length >= 42) value else ""
    }
}
