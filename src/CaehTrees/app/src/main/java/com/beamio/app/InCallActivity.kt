package com.beamio.app

import android.app.KeyguardManager
import android.content.Context
import android.content.Intent
import android.media.AudioManager
import android.os.Build
import android.os.Bundle
import android.os.Handler
import android.os.Looper
import android.util.Log
import android.view.View
import android.view.WindowManager
import android.widget.ImageButton
import android.widget.ImageView
import android.widget.TextView
import androidx.activity.ComponentActivity
import androidx.activity.OnBackPressedCallback
import androidx.activity.result.contract.ActivityResultContracts
import androidx.core.view.ViewCompat
import androidx.core.view.WindowCompat
import androidx.core.view.WindowInsetsCompat
import java.lang.ref.WeakReference

/**
 * Native in-call page, same design as iOS [BeamioInCallScreen]: "Beamio Audio"
 * product line, caller, timer, then Mute / Speaker / End.
 *
 * After a lock-screen Answer it shows over the keyguard without unlocking, like
 * iOS CallKit. The unlock prompt appears only when the user leaves the call
 * screen or the mic permission dialog has to show.
 */
class InCallActivity : ComponentActivity() {
    private var callId: String = ""
    private var sessionId: String = ""
    private val mainHandler = Handler(Looper.getMainLooper())
    private var timerRunning = false
    /** When peer video fills the background, tools can collapse to the bottom strip. */
    private var toolsExpanded = true
    private var peerVideoActive = false
    private val timerTick = object : Runnable {
        override fun run() {
            if (!timerRunning || isFinishing) return
            bindTimer()
            mainHandler.postDelayed(this, 1_000L)
        }
    }

    /** This side's camera is sending video. */
    private var localVideoOn = false
    private var videoBusy = false

    private val cameraLauncher = registerForActivityResult(
        ActivityResultContracts.RequestPermission(),
    ) { granted ->
        Log.i(TAG, "CAMERA result granted=$granted")
        if (granted) {
            startLocalVideo()
        } else {
            videoBusy = false
            refreshVideoUi()
            showCallNotice(getString(R.string.in_call_camera_denied))
        }
    }

    private val recordAudioLauncher = registerForActivityResult(
        ActivityResultContracts.RequestPermission(),
    ) { granted ->
        Log.i(TAG, "RECORD_AUDIO result granted=$granted")
        if (granted) {
            BeamioNativeVoiceChannel.retryCaptureAfterMicPermission()
        } else {
            Log.w(TAG, "RECORD_AUDIO denied — native media uplink stays silent")
        }
    }

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        BeamioCallTiming.mark("screen-onCreate")
        instance = WeakReference(this)
        WindowCompat.setDecorFitsSystemWindows(window, false)
        showOverLockScreenAfterAnswer()
        setContentView(R.layout.activity_in_call)
        applySafeTopInset()
        clipProductIcon()
        bindControls()
        render(intent)
        ensureMicForVoiceUplink()
        onBackPressedDispatcher.addCallback(
            this,
            object : OnBackPressedCallback(true) {
                override fun handleOnBackPressed() {
                    minimizeCall()
                }
            },
        )
    }

    /**
     * Lock-screen Answer parity with iOS CallKit: the in-call UI shows over the
     * keyguard and stays there. Do not request a keyguard dismiss here — on a
     * secure lock that raises the PIN bouncer over the call screen at once.
     */
    private fun showOverLockScreenAfterAnswer() {
        window.addFlags(WindowManager.LayoutParams.FLAG_KEEP_SCREEN_ON)
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
    }

    private fun isKeyguardLocked(): Boolean =
        getSystemService(KeyguardManager::class.java)?.isKeyguardLocked == true

    /**
     * Ask the user to unlock, then run [onUnlocked]. Runs it at once when the
     * device is not locked.
     */
    private fun unlockThen(reason: String, onUnlocked: () -> Unit) {
        if (!isKeyguardLocked() || Build.VERSION.SDK_INT < Build.VERSION_CODES.O) {
            onUnlocked()
            return
        }
        Log.i(TAG, "requestDismissKeyguard reason=$reason")
        runCatching {
            getSystemService(KeyguardManager::class.java)?.requestDismissKeyguard(
                this,
                object : KeyguardManager.KeyguardDismissCallback() {
                    override fun onDismissSucceeded() {
                        if (!isFinishing) onUnlocked()
                    }
                },
            )
        }.onFailure {
            Log.w(TAG, "requestDismissKeyguard failed: ${it.message}")
        }
    }

    private fun clipProductIcon() {
        val icon = findViewById<View>(R.id.in_call_app_icon) ?: return
        icon.outlineProvider = object : android.view.ViewOutlineProvider() {
            override fun getOutline(view: View, outline: android.graphics.Outline) {
                val size = minOf(view.width, view.height)
                if (size <= 0) return
                val left = (view.width - size) / 2
                val top = (view.height - size) / 2
                outline.setOval(left, top, left + size, top + size)
            }
        }
        icon.clipToOutline = true
        icon.post { icon.invalidateOutline() }
    }

    override fun onNewIntent(intent: Intent) {
        super.onNewIntent(intent)
        setIntent(intent)
        render(intent)
    }

    /** Sync the audio route with the button once per screen (default: earpiece). */
    private var routeSynced = false

    override fun onResume() {
        super.onResume()
        resumedNow = true
        BeamioCallTiming.mark("screen-onResume")
        window.decorView.post { BeamioCallTiming.mark("screen-first-frame") }
        if (!routeSynced && InCallScreenModel.isLive()) {
            routeSynced = true
            restoreSpeakerRoute(InCallScreenModel.isSpeakerOn())
        }
        InCallScreenModel.presentIfLive()
        MainActivity.hideInCallReturnPill()
        refreshMuteUi()
        refreshSpeakerUi()
        startTimer()
        ensureMicForVoiceUplink()
        // Answered in the background (Android 14+): the call service lacks the
        // microphone type; add it while this screen is in front.
        BeamioCallForegroundService.upgradeMicrophoneIfNeeded("InCallActivity.onResume")
    }

    /** Prompt RECORD_AUDIO so Accept-path PCM uplink can start (no WebView getUserMedia). */
    private fun ensureMicForVoiceUplink() {
        if (!InCallScreenModel.isLive() && callId.isBlank()) return
        if (BeamioVoiceMicPermission.has(this)) {
            BeamioNativeVoiceChannel.retryCaptureAfterMicPermission()
            return
        }
        // The permission dialog cannot show over the keyguard.
        unlockThen("mic-permission") {
            BeamioVoiceMicPermission.requestIfNeeded(this, recordAudioLauncher) {
                BeamioNativeVoiceChannel.retryCaptureAfterMicPermission()
            }
        }
    }

    override fun onPause() {
        resumedNow = false
        stopTimer()
        super.onPause()
    }

    /** Between onResume and onPause: on top of its task and visible. */
    private var resumedNow = false

    override fun onDestroy() {
        stopTimer()
        // The camera is bound to this activity; minimizing or ending turns it off.
        stopLocalVideo(sendControl = true)
        if (instance?.get() === this) instance = null
        // Minimizing finishes this activity while the call stays live. Any other
        // way out of a live call (e.g. a task change) counts as minimized too,
        // so the return pill and the notification can bring it back.
        when (
            BeamioActiveCallRoute.onDestroyed(
                callLive = InCallScreenModel.isLive(),
                presented = InCallScreenModel.isPresented(),
                changingConfigurations = isChangingConfigurations,
            )
        ) {
            BeamioActiveCallRoute.Destroyed.RESTORE_ROUTE -> restoreSpeakerRoute(false)
            BeamioActiveCallRoute.Destroyed.MARK_MINIMIZED -> {
                InCallScreenModel.minimize()
                Log.i(TAG, "InCall screen gone while the call is live; marked minimized")
            }
            BeamioActiveCallRoute.Destroyed.KEEP -> Unit
        }
        super.onDestroy()
    }

    private fun applySafeTopInset() {
        val topRow = findViewById<View>(R.id.in_call_top_row) ?: return
        ViewCompat.setOnApplyWindowInsetsListener(topRow) { view, insets ->
            val top = insets.getInsets(WindowInsetsCompat.Type.systemBars()).top
            view.setPadding(view.paddingLeft, top + dp(4f), view.paddingRight, view.paddingBottom)
            insets
        }
        ViewCompat.requestApplyInsets(topRow)
        // Keep End clear of the navigation bar.
        val tools = findViewById<View>(R.id.in_call_tools_expanded) ?: return
        val baseBottom = tools.paddingBottom
        ViewCompat.setOnApplyWindowInsetsListener(tools) { view, insets ->
            val bottom = insets.getInsets(WindowInsetsCompat.Type.systemBars()).bottom
            view.setPadding(view.paddingLeft, view.paddingTop, view.paddingRight, baseBottom + bottom)
            insets
        }
        ViewCompat.requestApplyInsets(tools)
    }

    private fun bindControls() {
        findViewById<View>(R.id.in_call_minimize).setOnClickListener { minimizeCall() }
        findViewById<View>(R.id.in_call_end).setOnClickListener {
            it.isEnabled = false
            if (InCallScreenModel.prepareError().isNotEmpty() && InCallScreenModel.isPrepared()) {
                // The dial already failed; the PWA has nothing left to cancel.
                InCallScreenModel.cancelPrepared()
                finishFromCall()
                return@setOnClickListener
            }
            if (callId.isBlank() && sessionId.isBlank() && InCallScreenModel.cancelPrepared()) {
                // Hung up while the PWA was still preparing the dial: no call
                // exists yet. Tell the PWA to drop the dial it is building.
                Log.i(TAG, "End on prepared screen — cancel dial")
                MainActivity.dispatchSystemCallAction("callEnded", "", "", applicationContext)
                finishFromCall()
                return@setOnClickListener
            }
            // startSystemCall may have filled in the ids before this screen re-rendered.
            val snapshot = InCallScreenModel.snapshot()
            BeamioTelecomService.end(
                this,
                callId.ifBlank { snapshot.callId },
                sessionId.ifBlank { snapshot.sessionId },
            )
        }
        findViewById<View>(R.id.in_call_tools_collapsed)?.setOnClickListener {
            toolsExpanded = true
            applyToolsCollapsedState()
        }
        findViewById<View>(R.id.in_call_tools_grabber)?.setOnClickListener {
            if (!peerVideoActive) return@setOnClickListener
            toolsExpanded = false
            applyToolsCollapsedState()
        }
        bindControl(
            includeId = R.id.in_call_mute,
            label = getString(R.string.in_call_mute),
            icon = R.drawable.ic_in_call_mic,
            enabled = true,
        ) {
            InCallScreenModel.toggleMute()
            refreshMuteUi()
        }
        bindControl(
            includeId = R.id.in_call_video,
            label = getString(R.string.in_call_video),
            icon = R.drawable.ic_in_call_video_off,
            enabled = true,
        ) {
            toggleVideo()
        }
        bindControl(
            includeId = R.id.in_call_speaker,
            label = getString(R.string.in_call_speaker),
            icon = R.drawable.ic_in_call_speaker,
            enabled = true,
        ) {
            val on = InCallScreenModel.toggleSpeaker()
            restoreSpeakerRoute(on)
            refreshSpeakerUi()
        }
        applyToolsCollapsedState()
    }

    /**
     * Peer JPEG as full-screen background (no inset panel). When active, tools
     * from the @tag row down can collapse to a bottom strip.
     */
    fun applyPeerVideoFrame(bitmap: android.graphics.Bitmap?) {
        val peer = findViewById<ImageView>(R.id.in_call_peer_video) ?: return
        val scrim = findViewById<View>(R.id.in_call_peer_video_scrim)
        if (bitmap == null) {
            peer.setImageDrawable(null)
            peer.visibility = View.GONE
            scrim?.visibility = View.GONE
            if (peerVideoActive) {
                peerVideoActive = false
                toolsExpanded = true
                applyToolsCollapsedState()
            }
            return
        }
        peer.setImageBitmap(bitmap)
        peer.visibility = View.VISIBLE
        scrim?.visibility = View.VISIBLE
        if (!peerVideoActive) {
            peerVideoActive = true
            toolsExpanded = false
            applyToolsCollapsedState()
        }
    }

    private fun applyToolsCollapsedState() {
        val expanded = findViewById<View>(R.id.in_call_tools_expanded)
        val collapsed = findViewById<View>(R.id.in_call_tools_collapsed)
        val grabber = findViewById<View>(R.id.in_call_tools_grabber)
        val showCollapsed = peerVideoActive && !toolsExpanded
        expanded?.visibility = if (showCollapsed) View.GONE else View.VISIBLE
        collapsed?.visibility = if (showCollapsed) View.VISIBLE else View.GONE
        grabber?.visibility = if (peerVideoActive && toolsExpanded) View.VISIBLE else View.GONE
        collapsed?.contentDescription = getString(R.string.in_call_show_controls)
        grabber?.contentDescription = getString(R.string.in_call_hide_controls)
    }

    private fun bindControl(
        includeId: Int,
        label: String,
        icon: Int,
        enabled: Boolean,
        onClick: (() -> Unit)? = null,
    ) {
        val root = findViewById<View>(includeId) ?: return
        root.alpha = if (enabled) 1f else 0.35f
        root.isEnabled = enabled
        root.findViewById<TextView>(R.id.in_call_control_label)?.text = label
        root.findViewById<ImageView>(R.id.in_call_control_icon)?.setImageResource(icon)
        if (enabled && onClick != null) {
            root.setOnClickListener { onClick() }
            root.findViewById<View>(R.id.in_call_control_disc)?.setOnClickListener { onClick() }
        } else {
            root.setOnClickListener(null)
            root.findViewById<View>(R.id.in_call_control_disc)?.setOnClickListener(null)
        }
    }

    private fun render(source: Intent?) {
        callId = source?.getStringExtra(BeamioTelecomService.EXTRA_CALL_ID).orEmpty().trim()
            .ifBlank { InCallScreenModel.snapshot().callId }
        sessionId = source?.getStringExtra(BeamioTelecomService.EXTRA_SESSION_ID).orEmpty().trim()
            .ifBlank { InCallScreenModel.snapshot().sessionId }
        val state = InCallScreenModel.snapshot()
        val title = InCallScreenModel.titleLine(getString(R.string.in_call_fallback_title))
        findViewById<TextView>(R.id.in_call_title)?.text = title
        findViewById<TextView>(R.id.in_call_collapsed_title)?.text = title
        val address = state.address.trim()
        val capsule = findViewById<View>(R.id.in_call_address_capsule)
        val addressView = findViewById<TextView>(R.id.in_call_address)
        if (address.isBlank()) {
            capsule?.visibility = View.GONE
        } else {
            capsule?.visibility = View.VISIBLE
            addressView?.text = BeamioVoiceOfferIdentity.shortAddress(address)
        }
        bindCallerAvatar(state.tag)
        bindTimer()
        refreshMuteUi()
        refreshSpeakerUi()
        refreshVideoUi()
        applyToolsCollapsedState()
    }

    /** Prefer fun-emoji from verified @BeamioTag; hide when tag not ready. */
    private fun bindCallerAvatar(tag: String) {
        val avatar = findViewById<ImageView>(R.id.in_call_avatar)
        val collapsed = findViewById<ImageView>(R.id.in_call_collapsed_avatar)
        val bitmap = if (tag.isNotBlank()) {
            BeamioTelecomService.cachedCallerAvatar(tag)
        } else {
            null
        }
        if (bitmap != null) {
            avatar?.setImageBitmap(bitmap)
            avatar?.visibility = View.VISIBLE
            collapsed?.setImageBitmap(bitmap)
            collapsed?.visibility = View.VISIBLE
        } else {
            avatar?.setImageDrawable(null)
            avatar?.visibility = View.GONE
            collapsed?.setImageDrawable(null)
            collapsed?.visibility = View.GONE
        }
    }

    private fun refreshMuteUi() {
        val muted = InCallScreenModel.isMuted()
        val root = findViewById<View>(R.id.in_call_mute) ?: return
        root.findViewById<TextView>(R.id.in_call_control_label)?.text =
            getString(if (muted) R.string.in_call_unmute else R.string.in_call_mute)
        root.findViewById<ImageView>(R.id.in_call_control_icon)?.setImageResource(
            if (muted) R.drawable.ic_in_call_mic_off else R.drawable.ic_in_call_mic,
        )
        root.findViewById<View>(R.id.in_call_control_disc)?.setBackgroundResource(
            if (muted) R.drawable.bg_in_call_control_disc_active else R.drawable.bg_in_call_control_disc,
        )
        root.findViewById<ImageView>(R.id.in_call_control_icon)?.imageTintList =
            if (muted) {
                android.content.res.ColorStateList.valueOf(0xFF1C1C1E.toInt())
            } else {
                android.content.res.ColorStateList.valueOf(0xFFFFFFFF.toInt())
            }
    }

    // MARK: - Video

    private fun toggleVideo() {
        if (videoBusy) return
        // No peer media session until the callee accepts.
        if (!InCallScreenModel.isConnected()) return
        if (localVideoOn) {
            stopLocalVideo(sendControl = true)
            return
        }
        if (!InCallScreenModel.isLive() && callId.isBlank()) return
        videoBusy = true
        refreshVideoUi()
        if (androidx.core.content.ContextCompat.checkSelfPermission(
                this,
                android.Manifest.permission.CAMERA,
            ) == android.content.pm.PackageManager.PERMISSION_GRANTED
        ) {
            startLocalVideo()
            return
        }
        // The permission dialog cannot show over the keyguard.
        unlockThen("camera-permission") {
            cameraLauncher.launch(android.Manifest.permission.CAMERA)
        }
    }

    private fun startLocalVideo() {
        val preview = findViewById<androidx.camera.view.PreviewView>(R.id.in_call_local_preview)
        preview?.clipToOutline = true
        BeamioInCallVideoCapture.start(
            activity = this,
            preview = preview,
            frameSink = { jpeg, w, h -> BeamioNativeVoiceChannel.sendVideoJpegFrame(jpeg, w, h) },
        ) { result ->
            videoBusy = false
            if (isFinishing) {
                BeamioInCallVideoCapture.stop()
                return@start
            }
            if (result.isSuccess) {
                localVideoOn = true
                preview?.visibility = View.VISIBLE
                BeamioNativeVoiceChannel.sendVideoEnableControl(true)
                Log.i(TAG, "local video ON callId=${callId.take(12)}")
            } else {
                localVideoOn = false
                preview?.visibility = View.GONE
                showCallNotice(getString(R.string.in_call_camera_failed))
            }
            refreshVideoUi()
        }
    }

    /** Turn the camera off. The call (audio) keeps running. */
    private fun stopLocalVideo(sendControl: Boolean) {
        val wasOn = localVideoOn
        localVideoOn = false
        videoBusy = false
        if (BeamioInCallVideoCapture.isRunning || wasOn) BeamioInCallVideoCapture.stop()
        findViewById<View>(R.id.in_call_local_preview)?.visibility = View.GONE
        if (wasOn && sendControl) {
            BeamioNativeVoiceChannel.sendVideoEnableControl(false)
            Log.i(TAG, "local video OFF callId=${callId.take(12)}")
        }
        if (!isFinishing) refreshVideoUi()
    }

    private fun refreshVideoUi() {
        val root = findViewById<View>(R.id.in_call_video) ?: return
        root.alpha = when {
            !InCallScreenModel.isConnected() -> 0.35f
            videoBusy -> 0.6f
            else -> 1f
        }
        root.findViewById<ImageView>(R.id.in_call_control_icon)?.setImageResource(
            if (localVideoOn) R.drawable.ic_in_call_video else R.drawable.ic_in_call_video_off,
        )
        root.findViewById<View>(R.id.in_call_control_disc)?.setBackgroundResource(
            if (localVideoOn) R.drawable.bg_in_call_control_disc_active else R.drawable.bg_in_call_control_disc,
        )
        root.findViewById<ImageView>(R.id.in_call_control_icon)?.imageTintList =
            android.content.res.ColorStateList.valueOf(
                if (localVideoOn) 0xFF1C1C1E.toInt() else 0xFFFFFFFF.toInt(),
            )
    }

    private fun showCallNotice(text: String) {
        android.widget.Toast.makeText(this, text, android.widget.Toast.LENGTH_LONG).show()
    }

    private fun refreshSpeakerUi() {
        val on = InCallScreenModel.isSpeakerOn()
        val root = findViewById<View>(R.id.in_call_speaker) ?: return
        root.findViewById<TextView>(R.id.in_call_control_label)?.text =
            getString(if (on) R.string.in_call_audio else R.string.in_call_speaker)
        root.findViewById<View>(R.id.in_call_control_disc)?.setBackgroundResource(
            if (on) R.drawable.bg_in_call_control_disc_active else R.drawable.bg_in_call_control_disc,
        )
        root.findViewById<ImageView>(R.id.in_call_control_icon)?.imageTintList =
            if (on) {
                android.content.res.ColorStateList.valueOf(0xFF1C1C1E.toInt())
            } else {
                android.content.res.ColorStateList.valueOf(0xFFFFFFFF.toInt())
            }
    }

    /**
     * Speaker on/off. The call is a self-managed Telecom call, so the route
     * belongs to Telecom (AudioManager.setSpeakerphoneOn alone is overridden).
     * Without a live Telecom connection fall back to the communication device.
     */
    private fun restoreSpeakerRoute(on: Boolean) {
        if (BeamioTelecomService.setSpeaker(on)) return
        Log.i(TAG, "speaker=$on via AudioManager (no live Telecom connection)")
        val am = getSystemService(AudioManager::class.java) ?: return
        runCatching {
            am.mode = AudioManager.MODE_IN_COMMUNICATION
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.S) {
                if (on) {
                    am.availableCommunicationDevices
                        .firstOrNull { it.type == android.media.AudioDeviceInfo.TYPE_BUILTIN_SPEAKER }
                        ?.let { am.setCommunicationDevice(it) }
                } else {
                    am.clearCommunicationDevice()
                }
            } else {
                @Suppress("DEPRECATION")
                am.isSpeakerphoneOn = on
            }
        }
    }

    private fun bindTimer() {
        val override = when {
            InCallScreenModel.isConnectionLost() -> getString(R.string.in_call_connection_lost)
            InCallScreenModel.isBusy() -> getString(R.string.in_call_busy)
            InCallScreenModel.isUnreachable() -> getString(R.string.in_call_unreachable)
            InCallScreenModel.isReconnecting() && InCallScreenModel.isConnected() ->
                getString(R.string.in_call_reconnecting)
            else -> null
        }
        if (override != null) {
            findViewById<TextView>(R.id.in_call_timer)?.text = override
            findViewById<TextView>(R.id.in_call_collapsed_timer)?.text = override
            return
        }
        if (!InCallScreenModel.isConnected()) {
            val prepared = InCallScreenModel.isPrepared()
            val wake = if (prepared) InCallScreenModel.PeerWake.WAITING else InCallScreenModel.peerWake()
            val calling = InCallScreenModel.prepareError().ifEmpty {
                getString(
                    when {
                        prepared -> R.string.in_call_connecting
                        wake == InCallScreenModel.PeerWake.RINGING -> R.string.in_call_ringing
                        wake == InCallScreenModel.PeerWake.RESTRICTED -> R.string.in_call_peer_unreachable
                        else -> R.string.in_call_calling
                    },
                )
            }
            // The collapsed bar has one short line: keep "Calling…" there.
            val collapsed = if (wake == InCallScreenModel.PeerWake.RESTRICTED &&
                InCallScreenModel.prepareError().isEmpty()
            ) getString(R.string.in_call_calling) else calling
            findViewById<TextView>(R.id.in_call_timer)?.text = calling
            findViewById<TextView>(R.id.in_call_collapsed_timer)?.text = collapsed
            return
        }
        val answeredAt = InCallScreenModel.snapshot().answeredAtMs
        val elapsed = if (answeredAt <= 0L) {
            0L
        } else {
            ((System.currentTimeMillis() - answeredAt) / 1000L).coerceAtLeast(0L)
        }
        val minutes = elapsed / 60L
        val seconds = elapsed % 60L
        val clock = String.format("%02d:%02d", minutes, seconds)
        findViewById<TextView>(R.id.in_call_timer)?.text = clock
        findViewById<TextView>(R.id.in_call_collapsed_timer)?.text = clock
    }

    private fun startTimer() {
        if (timerRunning) return
        timerRunning = true
        bindTimer()
        mainHandler.postDelayed(timerTick, 1_000L)
    }

    private fun stopTimer() {
        timerRunning = false
        mainHandler.removeCallbacks(timerTick)
    }

    private fun minimizeCall() {
        // Leaving the call screen opens the app, so unlock first.
        unlockThen("minimize") {
            InCallScreenModel.minimize()
            MainActivity.bringForwardWithInCallReturnPill(this)
            finish()
        }
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

    private fun dp(value: Float): Int =
        (value * resources.displayMetrics.density + 0.5f).toInt()

    companion object {
        private const val TAG = "BeamioInCall"
        private var instance: WeakReference<InCallActivity>? = null

        fun isShowing(): Boolean {
            val activity = instance?.get() ?: return false
            return !activity.isFinishing
        }

        /** Re-render after a model change (e.g. dialer connected). */
        fun refreshStateIfShowing() {
            val activity = instance?.get() ?: return
            if (activity.isFinishing) return
            activity.runOnUiThread { activity.render(null) }
        }

        /** Called from [BeamioNativeVoiceChannel] when capture hits missing mic permission. */
        fun requestMicForVoiceUplinkIfShowing() {
            val activity = instance?.get() ?: return
            if (activity.isFinishing) return
            activity.runOnUiThread { activity.ensureMicForVoiceUplink() }
        }

        /** Peer FaceTime JPEG → full-screen background on the live in-call activity. */
        fun applyPeerVideoFrameIfShowing(bitmap: android.graphics.Bitmap?) {
            val activity = instance?.get() ?: return
            if (activity.isFinishing) return
            activity.runOnUiThread { activity.applyPeerVideoFrame(bitmap) }
        }

        fun present(
            context: Context,
            callId: String,
            sessionId: String,
            tag: String = "",
            address: String = "",
        ) {
            val run = Runnable {
                presentOnMain(
                    context.applicationContext,
                    callId,
                    sessionId,
                    tag,
                    address,
                )
            }
            if (Looper.myLooper() == Looper.getMainLooper()) run.run()
            else Handler(Looper.getMainLooper()).post(run)
        }

        /**
         * Refresh title + avatar after async BeamioTag / DiceBear resolve while
         * the answered InCall page is already showing (Answer raced ahead of lookup).
         */
        fun refreshIdentityIfShowing(
            callId: String,
            sessionId: String,
            tag: String,
            address: String = "",
        ) {
            val run = Runnable {
                if (!InCallScreenModel.isLive()) return@Runnable
                if (!InCallScreenModel.matches(callId, sessionId)) return@Runnable
                val changed = InCallScreenModel.updateVerifiedIdentity(
                    callId,
                    sessionId,
                    tag,
                    address,
                )
                val activity = instance?.get()
                if (activity == null || activity.isFinishing) return@Runnable
                if (!changed && tag.isBlank()) return@Runnable
                activity.render(null)
                Log.i(
                    TAG,
                    "InCall identity refresh tag=${InCallScreenModel.snapshot().tag.ifBlank { "-" }} " +
                        "avatar=${BeamioTelecomService.cachedCallerAvatar(InCallScreenModel.snapshot().tag) != null}",
                )
            }
            if (Looper.myLooper() == Looper.getMainLooper()) run.run()
            else Handler(Looper.getMainLooper()).post(run)
        }

        private fun presentOnMain(
            app: Context,
            callId: String,
            sessionId: String,
            tag: String,
            address: String,
        ) {
            // Always begin so Answer can refresh tag/address on a live session.
            // A prepared dial screen has no ids yet; begin() would treat it as
            // a new connected call and start the timer.
            if (callId.isNotBlank() || sessionId.isNotBlank() || !InCallScreenModel.isPrepared()) {
                InCallScreenModel.begin(callId, sessionId, tag, address, presentImmediately = true)
            }
            val showing = instance?.get()?.takeIf { !it.isFinishing }
            val step = BeamioActiveCallRoute.present(
                instanceAlive = showing != null,
                instanceResumed = showing?.resumedNow == true,
            )
            if (showing != null && step == BeamioActiveCallRoute.Present.RENDER_IN_PLACE) {
                showing.render(
                    Intent().apply {
                        putExtra(BeamioTelecomService.EXTRA_CALL_ID, callId)
                        putExtra(BeamioTelecomService.EXTRA_SESSION_ID, sessionId)
                        putExtra(BeamioTelecomService.EXTRA_CLAIMED_TAG, tag)
                        putExtra(BeamioTelecomService.EXTRA_PEER_ADDRESS, address)
                    },
                )
                showing.raiseTask()
                return
            }
            val opening = Intent(app, InCallActivity::class.java).apply {
                addFlags(
                    Intent.FLAG_ACTIVITY_NEW_TASK or
                        Intent.FLAG_ACTIVITY_SINGLE_TOP or
                        Intent.FLAG_ACTIVITY_REORDER_TO_FRONT or
                        Intent.FLAG_ACTIVITY_NO_USER_ACTION,
                )
                putExtra(BeamioTelecomService.EXTRA_CALL_ID, callId)
                putExtra(BeamioTelecomService.EXTRA_SESSION_ID, sessionId)
                putExtra(BeamioTelecomService.EXTRA_CLAIMED_TAG, tag)
                putExtra(BeamioTelecomService.EXTRA_PEER_ADDRESS, address)
            }
            runCatching { app.startActivity(opening) }
                .onSuccess { Log.i(TAG, "InCall present dispatched") }
                .onFailure { Log.w(TAG, "InCall present failed", it) }
            // CallStyle / Telecom Answer often runs from BroadcastReceiver under lock;
            // plain startActivity is BAL-blocked — always dual-dispatch via PendingIntent.
            IncomingCallActivity.forceBringActivityViaPendingIntent(
                app,
                opening,
                inCallPendingRequestCode(callId, sessionId),
            )
        }

        private fun inCallPendingRequestCode(callId: String, sessionId: String): Int {
            val key = callId.ifBlank { sessionId }.ifBlank { "incall" }
            return (key.hashCode() and 0x7fffffff) % 100_000 + 200_000
        }

        fun finishIfMatching(callId: String, sessionId: String) {
            val activity = instance?.get() ?: return
            if (!activity.matches(callId, sessionId) &&
                !InCallScreenModel.matches(callId, sessionId)
            ) {
                return
            }
            activity.finishFromCall()
        }

        fun finishIfShowing() {
            instance?.get()?.finishFromCall()
        }
    }

    private fun raiseTask() {
        runCatching {
            val am = getSystemService(android.app.ActivityManager::class.java) ?: return
            @Suppress("DEPRECATION")
            am.moveTaskToFront(taskId, android.app.ActivityManager.MOVE_TASK_WITH_HOME)
        }
    }
}
