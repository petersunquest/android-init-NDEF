package com.beamio.app

import android.content.Context
import android.content.Intent
import android.graphics.Outline
import android.graphics.PixelFormat
import android.os.Build
import android.os.Handler
import android.os.Looper
import android.provider.Settings
import android.util.Log
import android.view.Gravity
import android.view.LayoutInflater
import android.view.View
import android.view.ViewOutlineProvider
import android.view.WindowManager
import android.widget.ImageView
import android.widget.TextView
import androidx.core.view.ViewCompat
import androidx.core.view.WindowInsetsCompat

/**
 * SYSTEM_ALERT_WINDOW glass for incoming VoIP when targetSdk 36 BAL blocks
 * [IncomingCallActivity] under the launcher (Telecom binder / phoneCall FGS /
 * sameUid FSI all BAL_BLOCK 102 on Samsung).
 *
 * TYPE_APPLICATION_OVERLAY from the phoneCall FGS is not subject to the same
 * background-activity start rules. CallStyle Answer/Decline is only a fallback
 * when overlay permission is missing — never post CallStyle while this glass
 * can show (it stacks above the overlay and obscures it).
 */
object IncomingCallOverlay {
    private const val TAG = "BeamioVoiceCall"

    @Volatile
    private var attached: Boolean = false
    private var windowView: View? = null
    private var callId: String = ""
    private var sessionId: String = ""
    private var claimedTag: String = ""
    private val main = Handler(Looper.getMainLooper())

    /** Whether the attached window is really on screen ([BeamioOverlayPresence]). */
    @Volatile
    private var presence: BeamioOverlayPresence.State = BeamioOverlayPresence.State.ON_SCREEN
    private var presenceListener: java.util.function.Consumer<Boolean>? = null
    private var presenceDeadline: Runnable? = null

    /** Kept out of sight while the full-screen incoming page covers the screen. */
    @Volatile
    private var suppressed = false

    fun canPresent(context: Context): Boolean {
        return if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.M) {
            Settings.canDrawOverlays(context.applicationContext)
        } else {
            true
        }
    }

    /** The window is added. It may still be hidden by the system: see [isVisibleOnScreen]. */
    fun isShowing(): Boolean = attached && windowView != null

    /**
     * Added and not hidden by the system. Android hides third-party overlays
     * over Settings and permission dialogs; then the system incoming banner
     * must show instead. Unconfirmed (first [BeamioOverlayPresence.CONFIRM_MS])
     * counts as visible.
     */
    fun isVisibleOnScreen(): Boolean =
        isShowing() && !suppressed && BeamioOverlayPresence.countsAsVisible(presence)

    /**
     * Hide (and stop touches to) the attached overlay while the full-screen
     * incoming page is on screen, so the two never show together; show it
     * again when that page goes to the background (Home). It stays attached,
     * so the call keeps its card the moment the page is gone.
     */
    fun setSuppressed(suppress: Boolean) {
        main.post {
            val view = windowView ?: run { suppressed = false; return@post }
            if (suppressed == suppress) return@post
            suppressed = suppress
            view.visibility = if (suppress) View.INVISIBLE else View.VISIBLE
            val params = view.layoutParams as? WindowManager.LayoutParams
            if (params != null) {
                params.flags = if (suppress) {
                    params.flags or WindowManager.LayoutParams.FLAG_NOT_TOUCHABLE
                } else {
                    params.flags and WindowManager.LayoutParams.FLAG_NOT_TOUCHABLE.inv()
                }
                runCatching {
                    view.context.applicationContext.getSystemService(WindowManager::class.java)
                        ?.updateViewLayout(view, params)
                }
            }
            Log.i(TAG, "Overlay glass ${if (suppress) "suppressed under the full-screen page" else "shown again"}")
        }
    }

    fun shownCallKeys(): Set<String> {
        if (!isShowing()) return emptySet()
        return listOf(callId, sessionId)
            .map { it.trim() }
            .filter { it.isNotEmpty() }
            .toSet()
    }

    fun matches(callId: String, sessionId: String): Boolean {
        if (!isShowing()) return false
        val call = callId.trim()
        val session = sessionId.trim()
        if (call.isEmpty() && session.isEmpty()) {
            return this.callId.isEmpty() && this.sessionId.isEmpty()
        }
        return (call.isNotEmpty() && call == this.callId) ||
            (session.isNotEmpty() && session == this.sessionId)
    }

    /**
     * Present the compact glass banner over the launcher. Returns true only
     * when the overlay was attached (permission + WindowManager success).
     */
    fun show(context: Context, launch: Intent): Boolean {
        val app = context.applicationContext
        // TYPE_APPLICATION_OVERLAY does not draw above the keyguard on Samsung /
        // modern Android. Attaching here would still set isShowing()=true and
        // demote CallStyle FSI → lock screen shows no Beamio incoming at all.
        if (BeamioTelecomService.isDeviceKeyguardLocked(app)) {
            Log.i(TAG, "Overlay glass skipped; keyguard locked — CallStyle FSI owns lock UI")
            return false
        }
        if (!canPresent(app)) {
            Log.i(TAG, "Overlay glass skipped; SYSTEM_ALERT_WINDOW not granted")
            BeamioOverlayAccess.noteFallback(app)
            return false
        }
        if (BeamioTelecomService.wasBusyRejected(
                launch.getStringExtra(BeamioTelecomService.EXTRA_CALL_ID).orEmpty(),
                launch.getStringExtra(BeamioTelecomService.EXTRA_SESSION_ID).orEmpty(),
            )
        ) {
            return false
        }
        if (Looper.myLooper() == Looper.getMainLooper()) {
            showOnMain(app, launch)
            return attached
        }
        val latch = java.util.concurrent.CountDownLatch(1)
        var ok = false
        Handler(Looper.getMainLooper()).post {
            showOnMain(app, launch)
            ok = attached
            latch.countDown()
        }
        runCatching {
            latch.await(2, java.util.concurrent.TimeUnit.SECONDS)
        }
        return ok
    }

    private fun showOnMain(app: Context, launch: Intent) {
        val nextCall = launch.getStringExtra(BeamioTelecomService.EXTRA_CALL_ID).orEmpty().trim()
        val nextSession = launch.getStringExtra(BeamioTelecomService.EXTRA_SESSION_ID).orEmpty().trim()
        // Answer / Decline / caller cancel / timeout can land before a delayed
        // present (FGS start, Telecom binder, retry timers). Checked here on the
        // main thread, after any settle that ran first, so a late request never
        // brings the banner back over the call page.
        if (BeamioTelecomService.isIncomingClosed(nextCall, nextSession)) {
            if (isShowing() && matches(nextCall, nextSession)) dismissInternal(reason = "closed")
            Log.i(TAG, "Overlay glass skipped; call already answered or ended")
            return
        }
        if (isShowing()) {
            val same = (nextCall.isNotEmpty() && nextCall == callId) ||
                (nextSession.isNotEmpty() && nextSession == sessionId)
            if (same) {
                bindContent(windowView ?: return, launch)
                // Refresh must still demote CallStyle — a prior arm may have
                // posted Decline/Answer that FGS later resurrected. Not while the
                // system hides this overlay: then the banner is the only UI.
                if (!isVisibleOnScreen()) return
                BeamioTelecomService.demoteIncomingChromeAfterGlass(
                    app,
                    nextCall,
                    nextSession,
                    title = launch.getStringExtra(BeamioTelecomService.EXTRA_INCOMING_TITLE).orEmpty(),
                    body = launch.getStringExtra(BeamioTelecomService.EXTRA_INCOMING_BODY).orEmpty(),
                )
                return
            }
            dismissInternal(reason = "replace")
        }
        val wm = app.getSystemService(WindowManager::class.java)
        if (wm == null) {
            Log.w(TAG, "Overlay glass failed; WindowManager missing")
            return
        }
        val root = LayoutInflater.from(app).inflate(R.layout.activity_incoming_call, null)
        applyBannerEdge(root)
        clipAppIcon(root)
        bindContent(root, launch)
        bindActions(app, root)
        val params = buildLayoutParams(app)
        runCatching {
            wm.addView(root, params)
            windowView = root
            attached = true
            callId = nextCall
            sessionId = nextSession
            claimedTag = launch.getStringExtra(BeamioTelecomService.EXTRA_CLAIMED_TAG).orEmpty().trim()
            watchPresence(app, wm, root, nextCall, nextSession)
            BeamioTelecomService.demoteIncomingChromeAfterGlass(
                app,
                nextCall,
                nextSession,
                title = launch.getStringExtra(BeamioTelecomService.EXTRA_INCOMING_TITLE).orEmpty(),
                body = launch.getStringExtra(BeamioTelecomService.EXTRA_INCOMING_BODY).orEmpty(),
            )
            IncomingCallActivity.clearPresentInFlight()
            Log.i(
                TAG,
                "Overlay glass showing callId=$nextCall sessionId=$nextSession " +
                    "titlePresent=${!launch.getStringExtra(BeamioTelecomService.EXTRA_INCOMING_TITLE).isNullOrBlank()}",
            )
        }.onFailure {
            attached = false
            windowView = null
            Log.w(TAG, "Overlay addView failed: ${it.message}")
        }
    }

    fun dismiss(callId: String = "", sessionId: String = "") {
        val run = Runnable {
            if (callId.isNotBlank() || sessionId.isNotBlank()) {
                if (!matches(callId, sessionId) && isShowing()) return@Runnable
            }
            dismissInternal(reason = "dismiss")
        }
        if (Looper.myLooper() == Looper.getMainLooper()) run.run()
        else Handler(Looper.getMainLooper()).post(run)
    }

    fun dismissIfShowing() {
        dismiss()
    }

    private fun dismissInternal(reason: String) {
        val view = windowView ?: run {
            attached = false
            return
        }
        val app = view.context.applicationContext
        val wm = app.getSystemService(WindowManager::class.java)
        runCatching { wm?.removeViewImmediate(view) }
            .onFailure { runCatching { wm?.removeView(view) } }
        unwatchPresence(app)
        suppressed = false
        windowView = null
        attached = false
        callId = ""
        sessionId = ""
        claimedTag = ""
        Log.i(TAG, "Overlay glass removed reason=$reason")
    }

    /**
     * Confirm the new overlay is really on screen. Android 15+ reports it with a
     * trusted presentation listener; no report within the confirm time, or a
     * later "not presented", hands the call to the system banner.
     * Below Android 15 there is no such report: keep treating it as visible.
     */
    private fun watchPresence(app: Context, wm: WindowManager, root: View, call: String, session: String) {
        unwatchPresence(app)
        val canVerify = Build.VERSION.SDK_INT >= 35
        presence = BeamioOverlayPresence.initial(canVerify)
        if (!canVerify) return
        val deadline = Runnable {
            if (windowView !== root) return@Runnable
            applyPresence(app, BeamioOverlayPresence.onDeadline(presence), call, session, "not confirmed on screen")
        }
        presenceDeadline = deadline
        main.postDelayed(deadline, BeamioOverlayPresence.CONFIRM_MS)
        // windowToken exists once the view is attached; post runs after that.
        root.post {
            if (windowView !== root) return@post
            val token = root.windowToken ?: return@post
            if (Build.VERSION.SDK_INT >= 35) registerPresence(app, wm, root, token, call, session)
        }
    }

    @androidx.annotation.RequiresApi(35)
    private fun registerPresence(
        app: Context,
        wm: WindowManager,
        root: View,
        token: android.os.IBinder,
        call: String,
        session: String,
    ) {
        val listener = java.util.function.Consumer<Boolean> { visible ->
            if (windowView !== root) return@Consumer
            applyPresence(
                app,
                BeamioOverlayPresence.onPresentation(presence, visible),
                call,
                session,
                "presented=$visible",
            )
        }
        runCatching {
            wm.registerTrustedPresentationListener(
                token,
                android.window.TrustedPresentationThresholds(0.5f, 0.25f, 100),
                app.mainExecutor,
                listener,
            )
            presenceListener = listener
        }.onFailure {
            // Cannot verify: the confirm deadline hands the call to the banner.
            Log.w(TAG, "Overlay presence watch failed: ${it.javaClass.simpleName}")
        }
    }

    private fun applyPresence(
        app: Context,
        step: BeamioOverlayPresence.Step,
        call: String,
        session: String,
        why: String,
    ) {
        val before = presence
        presence = step.state
        if (step.state != BeamioOverlayPresence.State.PENDING) {
            presenceDeadline?.let { main.removeCallbacks(it) }
            presenceDeadline = null
        }
        if (before != step.state) {
            Log.i(TAG, "Overlay presence $before -> ${step.state} ($why) banner=${step.banner}")
        }
        when (step.banner) {
            BeamioOverlayPresence.Banner.POST ->
                BeamioTelecomService.onIncomingOverlayHidden(app, call, session)
            BeamioOverlayPresence.Banner.WITHDRAW ->
                BeamioTelecomService.onIncomingOverlayVisible(app, call, session)
            BeamioOverlayPresence.Banner.NONE -> Unit
        }
    }

    private fun unwatchPresence(app: Context) {
        presenceDeadline?.let { main.removeCallbacks(it) }
        presenceDeadline = null
        val listener = presenceListener
        presenceListener = null
        if (listener != null && Build.VERSION.SDK_INT >= 35) {
            runCatching {
                app.getSystemService(WindowManager::class.java)?.unregisterTrustedPresentationListener(listener)
            }
        }
        presence = BeamioOverlayPresence.State.ON_SCREEN
    }

    fun refreshCallerChrome(title: String, body: String) {
        val view = windowView ?: return
        if (!attached) return
        val run = Runnable {
            val nextTitle = title.trim().ifBlank {
                view.context.getString(R.string.incoming_call_body)
            }
            // Persist verified @BeamioTag across soft-reassert / sticky revive.
            if (nextTitle.startsWith("@") && nextTitle.length in 2..33) {
                claimedTag = nextTitle
            }
            view.findViewById<TextView>(R.id.incoming_call_title)?.text = nextTitle
            bindAvatar(view, nextTitle)
            bindWarning(view, body)
        }
        if (Looper.myLooper() == Looper.getMainLooper()) run.run()
        else Handler(Looper.getMainLooper()).post(run)
    }

    fun updateShownCaller(
        callId: String,
        sessionId: String,
        displayName: String,
        peerAddress: String,
        claimedTag: String,
        identityWarning: String,
    ) {
        if (!matches(callId, sessionId)) return
        val view = windowView ?: return
        val run = Runnable {
            this.claimedTag = claimedTag.trim().ifBlank { this.claimedTag }
            val title = displayName.trim().ifBlank {
                claimedTag.trim().ifBlank { peerAddress.trim() }
            }.ifBlank { view.context.getString(R.string.incoming_call_body) }
            view.findViewById<TextView>(R.id.incoming_call_title)?.text = title
            bindAvatar(view, title)
            view.findViewById<TextView>(R.id.incoming_call_product_line)?.text =
                view.context.getString(R.string.incoming_call_glass_subtitle)
            bindWarning(view, identityWarning)
        }
        if (Looper.myLooper() == Looper.getMainLooper()) run.run()
        else Handler(Looper.getMainLooper()).post(run)
    }

    private fun buildLayoutParams(app: Context): WindowManager.LayoutParams {
        val type =
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
                WindowManager.LayoutParams.TYPE_APPLICATION_OVERLAY
            } else {
                @Suppress("DEPRECATION")
                WindowManager.LayoutParams.TYPE_PHONE
            }
        // NOT_FOCUSABLE: receive touches on Answer/Decline without stealing
        // IME/focus from the launcher underneath.
        // NOT_TOUCH_MODAL: launcher receives taps outside the glass bounds once
        // the root chrome is transparent (no black slab).
        val flags =
            WindowManager.LayoutParams.FLAG_NOT_FOCUSABLE or
                WindowManager.LayoutParams.FLAG_NOT_TOUCH_MODAL or
                WindowManager.LayoutParams.FLAG_LAYOUT_IN_SCREEN or
                WindowManager.LayoutParams.FLAG_LAYOUT_NO_LIMITS or
                WindowManager.LayoutParams.FLAG_KEEP_SCREEN_ON or
                WindowManager.LayoutParams.FLAG_HARDWARE_ACCELERATED
        return WindowManager.LayoutParams(
            WindowManager.LayoutParams.MATCH_PARENT,
            WindowManager.LayoutParams.WRAP_CONTENT,
            type,
            flags,
            PixelFormat.TRANSLUCENT,
        ).apply {
            gravity = Gravity.TOP or Gravity.CENTER_HORIZONTAL
            title = "BeamioIncomingCall"
            packageName = app.packageName
            // Explicit clear — some OEMs inherit an opaque default.
            dimAmount = 0f
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.P) {
                layoutInDisplayCutoutMode =
                    WindowManager.LayoutParams.LAYOUT_IN_DISPLAY_CUTOUT_MODE_SHORT_EDGES
            }
        }
    }

    private fun applyBannerEdge(root: View) {
        val edgePx = root.resources.getDimensionPixelSize(R.dimen.incoming_call_banner_edge)
        val host = root.findViewById<View>(R.id.incoming_call_banner_inset) ?: root
        ViewCompat.setOnApplyWindowInsetsListener(root) { _, insets ->
            val bars = insets.getInsets(WindowInsetsCompat.Type.statusBars())
            host.setPadding(edgePx, edgePx + bars.top, edgePx, host.paddingBottom)
            insets
        }
        root.requestApplyInsets()
        // Fallback before first inset dispatch (some overlay hosts are late).
        host.setPadding(edgePx, edgePx, edgePx, host.paddingBottom)
    }

    private fun clipAppIcon(root: View) {
        val icon = root.findViewById<View>(R.id.incoming_call_app_icon) ?: return
        icon.outlineProvider = object : ViewOutlineProvider() {
            override fun getOutline(view: View, outline: Outline) {
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

    /** Avatar of the verified @tag on the main line; hidden while the caller is unknown. */
    private fun bindAvatar(root: View, mainLine: String) {
        val view = root.findViewById<ImageView>(R.id.incoming_call_avatar) ?: return
        val tag = mainLine.trim().takeIf { it.startsWith("@") && it.length in 2..33 }
        val bitmap = tag?.let {
            BeamioTelecomService.cachedCallerAvatar(it) ?: BeamioCallerAvatarStore.avatar(root.context, it)
        }
        if (bitmap == null) {
            view.setImageDrawable(null)
            view.visibility = View.GONE
        } else {
            view.setImageBitmap(bitmap)
            view.visibility = View.VISIBLE
        }
    }

    private fun bindContent(root: View, source: Intent) {
        callId = source.getStringExtra(BeamioTelecomService.EXTRA_CALL_ID).orEmpty().trim()
        sessionId = source.getStringExtra(BeamioTelecomService.EXTRA_SESSION_ID).orEmpty().trim()
        claimedTag = source.getStringExtra(BeamioTelecomService.EXTRA_CLAIMED_TAG).orEmpty().trim()
        val title = source.getStringExtra(BeamioTelecomService.EXTRA_INCOMING_TITLE).orEmpty()
            .ifBlank { root.context.getString(R.string.incoming_call_body) }
        root.findViewById<TextView>(R.id.incoming_call_title)?.text = title
        bindAvatar(root, title)
        root.findViewById<TextView>(R.id.incoming_call_product_line)?.text =
            root.context.getString(R.string.incoming_call_glass_subtitle)
        bindWarning(
            root,
            source.getStringExtra(BeamioTelecomService.EXTRA_INCOMING_BODY).orEmpty(),
        )
    }

    private fun bindWarning(root: View, raw: String) {
        val warning = root.findViewById<TextView>(R.id.incoming_call_body) ?: return
        val product = root.context.getString(R.string.incoming_call_glass_subtitle)
        val text = raw.trim()
        if (text.isEmpty() || text.equals(product, ignoreCase = true)) {
            warning.visibility = View.GONE
            warning.text = ""
            return
        }
        warning.text = text
        warning.visibility = View.VISIBLE
    }

    private fun bindActions(app: Context, root: View) {
        root.findViewById<View>(R.id.incoming_call_decline)?.setOnClickListener {
            it.isEnabled = false
            val id = callId
            val session = sessionId
            dismissInternal(reason = "decline")
            BeamioTelecomService.finishIncomingCall(app, "callRejected", id, session)
        }
        root.findViewById<View>(R.id.incoming_call_answer)?.setOnClickListener {
            it.isEnabled = false
            val id = callId
            val session = sessionId
            dismissInternal(reason = "answer")
            BeamioTelecomService.finishIncomingCall(app, "callAnswered", id, session)
        }
    }
}
