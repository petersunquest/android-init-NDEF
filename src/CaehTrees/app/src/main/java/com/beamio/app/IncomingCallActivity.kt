package com.beamio.app

import android.app.Activity
import android.app.ActivityManager
import android.app.ActivityOptions
import android.app.AlarmManager
import android.app.PendingIntent
import android.content.Context
import android.content.Intent
import android.graphics.Outline
import android.os.Build
import android.os.Bundle
import android.os.Handler
import android.os.Looper
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
 *
 * Visual chrome matches the iOS CallKit compact banner: product line + @tag
 * on the left, red Decline (X) and blue Answer (✓) on the right.
 */
class IncomingCallActivity : Activity() {
    private var callId: String = ""
    private var sessionId: String = ""
    private var claimedTag: String = ""
    /** Full-screen Slide-to-answer layout (keyguard up) vs. the top banner. */
    private var lockedLayout: Boolean = false

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        showOverLockScreen()
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.TIRAMISU) {
            onBackInvokedDispatcher.registerOnBackInvokedCallback(
                OnBackInvokedDispatcher.PRIORITY_DEFAULT,
            ) { }
        }
        // Same flow as iOS: full screen with Slide to answer on the lock screen,
        // compact banner when the device is in use.
        lockedLayout = BeamioTelecomService.isDeviceKeyguardLocked(this)
        if (lockedLayout) {
            window.setBackgroundDrawableResource(R.drawable.bg_in_call_gradient)
            setContentView(R.layout.activity_incoming_call_locked)
        } else {
            setContentView(R.layout.activity_incoming_call)
            applyBannerEdgeInsets()
        }
        clipAppIcon()
        bindActions()
        instance = WeakReference(this)
        clearPresentInFlight()
        val openCall = intent.getStringExtra(BeamioTelecomService.EXTRA_CALL_ID).orEmpty()
        val openSession = intent.getStringExtra(BeamioTelecomService.EXTRA_SESSION_ID).orEmpty()
        if (BeamioTelecomService.isIncomingClosed(openCall, openSession) ||
            matchesPendingFinish(openCall, openSession) ||
            consumeDeferredFinish(openCall, openSession)
        ) {
            Log.i(TAG, "Incoming window skipped; end arrived before onCreate")
            finish()
            return
        }
        render(intent)
        raiseIncomingTask()
        BeamioTelecomService.demoteIncomingChromeAfterGlass(
            this,
            openCall,
            openSession,
            title = intent.getStringExtra(BeamioTelecomService.EXTRA_INCOMING_TITLE).orEmpty(),
            body = intent.getStringExtra(BeamioTelecomService.EXTRA_INCOMING_BODY).orEmpty(),
        )
        Log.i(TAG, "Incoming window showing titlePresent=${titlePresent(intent)} taskId=$taskId")
    }

    override fun onResume() {
        super.onResume()
        raiseIncomingTask()
    }

    /**
     * Keep this activity's dedicated task above the launcher. Debounced so
     * moveToFront does not re-enter onResume in a tight loop.
     */
    private var lastRaiseElapsedMs: Long = 0L

    private fun raiseIncomingTask() {
        val now = android.os.SystemClock.elapsedRealtime()
        if (now - lastRaiseElapsedMs < 400L) return
        lastRaiseElapsedMs = now
        bringOwnAppTasksToFront(this, preferIncomingOnTop = true)
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
        if (BeamioTelecomService.isIncomingClosed(nextCall, nextSession)) {
            Log.i(TAG, "Incoming window intent ignored; call already answered or ended")
            if (matches(nextCall, nextSession)) finishFromCall()
            return
        }
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

    @Deprecated("Incoming calls stay up until Decline or Answer.")
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
        // No setBackgroundBlurRadius: full-window blur darkens a black slab
        // behind the glass. Overlay path is transparent; Activity keeps an
        // opaque theme only for Samsung BAL (see IncomingCallWindow).
    }

    private fun clipAppIcon() {
        // Circular silhouette (iOS CallKit). Flat product mark fills the square;
        // oval clip removes square corners without AdaptiveIcon / soft-radius crop.
        val icon = findViewById<View>(R.id.incoming_call_app_icon) ?: return
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
        icon.scaleX = 1f
        icon.scaleY = 1f
        // Outline needs measured size; onCreate often still has 0×0.
        icon.post { icon.invalidateOutline() }
    }

    private fun bindActions() {
        findViewById<View>(R.id.incoming_call_decline)?.setOnClickListener {
            it.isEnabled = false
            BeamioTelecomService.finishIncomingCall(this, "callRejected", callId, sessionId)
        }
        findViewById<View>(R.id.incoming_call_answer)?.setOnClickListener {
            it.isEnabled = false
            BeamioTelecomService.finishIncomingCall(this, "callAnswered", callId, sessionId)
        }
        findViewById<BeamioSlideToAnswerView>(R.id.incoming_call_slide)?.onAnswer = {
            BeamioTelecomService.finishIncomingCall(this, "callAnswered", callId, sessionId)
        }
    }

    /** Wallet capsule on the full-screen layout (verified peer, else claimed). */
    private fun bindAddress(source: Intent?) {
        val capsule = findViewById<View>(R.id.incoming_call_address_capsule) ?: return
        val address = source?.getStringExtra(BeamioTelecomService.EXTRA_PEER_ADDRESS).orEmpty().trim()
            .ifBlank { source?.getStringExtra(BeamioTelecomService.EXTRA_CLAIMED_ADDRESS).orEmpty().trim() }
        if (address.isBlank()) {
            capsule.visibility = View.GONE
            return
        }
        findViewById<TextView>(R.id.incoming_call_address)?.text =
            BeamioVoiceOfferIdentity.shortAddress(address)
        capsule.visibility = View.VISIBLE
    }

    private fun render(source: Intent?) {
        callId = source?.getStringExtra(BeamioTelecomService.EXTRA_CALL_ID).orEmpty().trim()
        sessionId = source?.getStringExtra(BeamioTelecomService.EXTRA_SESSION_ID).orEmpty().trim()
        claimedTag = source?.getStringExtra(BeamioTelecomService.EXTRA_CLAIMED_TAG).orEmpty().trim()
        val title = source?.getStringExtra(BeamioTelecomService.EXTRA_INCOMING_TITLE).orEmpty()
            .ifBlank { getString(R.string.incoming_call_body) }
        findViewById<TextView>(R.id.incoming_call_title).text = title
        findViewById<TextView>(R.id.incoming_call_product_line).text =
            getString(R.string.incoming_call_glass_subtitle)
        bindWarning(
            source?.getStringExtra(BeamioTelecomService.EXTRA_INCOMING_BODY).orEmpty(),
        )
        bindAddress(source)
        bindAvatar(title)
    }

    /** Avatar of the verified @tag on the main line; hidden while the caller is unknown. */
    private fun bindAvatar(mainLine: String) {
        val view = findViewById<ImageView>(R.id.incoming_call_avatar) ?: return
        val tag = mainLine.trim().takeIf { it.startsWith("@") && it.length in 2..33 }
        val bitmap = tag?.let {
            BeamioTelecomService.cachedCallerAvatar(it) ?: BeamioCallerAvatarStore.avatar(this, it)
        }
        if (bitmap == null) {
            view.setImageDrawable(null)
            view.visibility = View.GONE
        } else {
            view.setImageBitmap(bitmap)
            view.visibility = View.VISIBLE
        }
    }

    private fun bindWarning(raw: String) {
        val warning = findViewById<TextView>(R.id.incoming_call_body) ?: return
        val product = getString(R.string.incoming_call_glass_subtitle)
        val text = raw.trim()
        // Keep product line fixed; only show a real identity warning under the @tag.
        if (text.isEmpty() || text.equals(product, ignoreCase = true)) {
            warning.visibility = View.GONE
            warning.text = ""
            return
        }
        warning.text = text
        warning.visibility = View.VISIBLE
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
            val overlayKeys = IncomingCallOverlay.shownCallKeys()
            if (overlayKeys.isNotEmpty()) return overlayKeys
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
            if (BeamioTelecomService.isIncomingClosed(callId, sessionId)) {
                Log.i(TAG, "Incoming present skipped; call already answered or ended")
                return
            }
            // A finish that arrived while glass was still launching must not
            // permanently block post-FGS present (browser→Android BAL race).
            if (matchesPendingFinish(callId, sessionId) && !isPresentInFlight()) {
                Log.i(TAG, "Incoming present skipped; pending finish for this call")
                return
            }
            if (BeamioTelecomService.anotherCallOwnsChrome(callId, sessionId)) {
                BeamioTelecomService.rejectSecondaryWhileBusy(context, callId, sessionId)
                return
            }
            val run = Runnable { presentOnMain(context.applicationContext, launch) }
            if (android.os.Looper.myLooper() == android.os.Looper.getMainLooper()) run.run()
            else android.os.Handler(android.os.Looper.getMainLooper()).post(run)
        }

        private fun matchesPendingFinish(callId: String, sessionId: String): Boolean {
            val pending = pendingFinishKeys
            if (pending.isEmpty()) return false
            val hit = listOf(callId, sessionId)
                .map { it.trim() }
                .any { it.isNotEmpty() && pending.contains(it) }
            if (hit) pendingFinishKeys = emptySet()
            return hit
        }

        private fun clearPendingFinishFor(callId: String, sessionId: String) {
            val pending = pendingFinishKeys
            if (pending.isEmpty()) return
            val keys = listOf(callId, sessionId).map { it.trim() }.filter { it.isNotEmpty() }
            if (keys.any { pending.contains(it) }) {
                pendingFinishKeys = emptySet()
                Log.i(TAG, "Cleared pending finish so live RINGING can present glass")
            }
        }

        private fun launchIsClosed(launch: Intent): Boolean {
            val closed = BeamioTelecomService.isIncomingClosed(
                launch.getStringExtra(BeamioTelecomService.EXTRA_CALL_ID).orEmpty(),
                launch.getStringExtra(BeamioTelecomService.EXTRA_SESSION_ID).orEmpty(),
            )
            if (closed) Log.i(TAG, "Incoming present skipped; call already answered or ended")
            return closed
        }

        private fun presentOnMain(app: Context, launch: Intent) {
            if (launchIsClosed(launch)) return
            val nextCall = launch.getStringExtra(BeamioTelecomService.EXTRA_CALL_ID).orEmpty()
            val nextSession = launch.getStringExtra(BeamioTelecomService.EXTRA_SESSION_ID).orEmpty()
            val showing = instance?.get()
            if (showing != null && !showing.isFinishing) {
                val shown = shownCallKeys()
                val sameWindow = listOf(nextCall, nextSession).any { it.isNotBlank() && shown.contains(it) }
                if (!sameWindow) return
                showing.render(launch)
                bringOwnAppTasksToFront(app, preferIncomingOnTop = true)
                return
            }
            // Fresh dial after phoneCall FGS: do not inherit a stale
            // pendingFinish latch from a BAL-aborted pre-FGS attempt.
            clearPendingFinishFor(nextCall, nextSession)
            // Under launcher: Telecom onShowIncomingCallUi + phoneCall FGS hold a
            // temporary BAL exemption. Prefer startActivity + NMS-allowlisted FSI
            // send. AlarmClock uses a *different* PendingIntent and still hits
            // BAL_BLOCK 102 on Samsung API 37 — keep it as last resort only.
            // Do not wakeScreen first (interactive device → heads-up, no auto-FSI).
            if (!hasVisibleAppUi()) {
                presentFromPhoneCallFgs(app, launch)
                return
            }
            wakeScreen(app)
            // Hold MainActivity.onResume stale-dismiss until glass shows or fails.
            markPresentInFlight(PRESENT_IN_FLIGHT_HOLD_MS)
            val opening = buildLaunchIntent(app, launch)
            fun tryPresentGlass(reason: String) {
                runCatching {
                    if (Build.VERSION.SDK_INT >= 34) {
                        val opts = ActivityOptions.makeBasic()
                        runCatching {
                            ActivityOptions::class.java.getMethod(
                                "setPendingIntentBackgroundActivityStartMode",
                                Int::class.javaPrimitiveType,
                            ).invoke(opts, modeBackgroundActivityStartPreferred())
                        }
                        app.startActivity(opening, opts.toBundle())
                    } else {
                        app.startActivity(opening)
                    }
                }
                    .onSuccess {
                        Log.i(TAG, "Incoming window startActivity dispatched reason=$reason")
                    }
                    .onFailure {
                        Log.i(TAG, "Incoming window start deferred to PendingIntent reason=$reason")
                    }
                forceLaunchViaPendingIntent(app, opening)
                Handler(Looper.getMainLooper()).postDelayed({
                    bringOwnAppTasksToFront(app, preferIncomingOnTop = true)
                }, 80L)
            }
            tryPresentGlass("immediate-foreground")
            val retryDelaysMs = longArrayOf(300L, 900L, 1800L)
            val lastRetryMs = retryDelaysMs.last()
            for (delayMs in retryDelaysMs) {
                Handler(Looper.getMainLooper()).postDelayed({
                    if (launchIsClosed(opening)) {
                        clearPresentInFlight()
                        return@postDelayed
                    }
                    if (isShowing()) {
                        bringOwnAppTasksToFront(app, preferIncomingOnTop = true)
                        clearPresentInFlight()
                        return@postDelayed
                    }
                    if (!hasVisibleAppUi()) {
                        Log.i(TAG, "Stop present retries; app no longer visible — rely on FSI")
                        clearPresentInFlight()
                        return@postDelayed
                    }
                    bringOwnAppTasksToFront(app, preferIncomingOnTop = true)
                    if (!isShowing()) {
                        Log.i(TAG, "Incoming window retry delay=${delayMs}ms")
                        tryPresentGlass("retry-$delayMs")
                    }
                    if (delayMs >= lastRetryMs && !isShowing()) {
                        clearPresentInFlight()
                        clearDeferredFinish()
                        val callId = opening.getStringExtra(BeamioTelecomService.EXTRA_CALL_ID).orEmpty()
                        val sessionId = opening.getStringExtra(BeamioTelecomService.EXTRA_SESSION_ID).orEmpty()
                        BeamioTelecomService.onIncomingGlassPresentFailed(app, callId, sessionId)
                    }
                }, delayMs)
            }
        }

        private fun buildLaunchIntent(app: Context, launch: Intent): Intent =
            Intent(launch).apply {
                setClass(app, IncomingCallActivity::class.java)
                // NEW_TASK + CLEAR_TASK: recreate the Incoming singleInstance
                // task. CLEAR_TOP alone only brings an existing background
                // stack to front — Samsung then BAL_BLOCKs with
                // balDontBringExistingBackgroundTaskStackToFg even when the
                // CallStyle FSI PendingIntent is NMS-allowlisted.
                addFlags(
                    Intent.FLAG_ACTIVITY_NEW_TASK or
                        Intent.FLAG_ACTIVITY_CLEAR_TASK or
                        Intent.FLAG_ACTIVITY_NO_USER_ACTION,
                )
            }

        /**
         * Drop any leftover IncomingCall AppTask so the next start is a
         * fresh activity, not "bring existing background stack to FG".
         */
        fun finishStaleIncomingCallTasks(context: Context) {
            val app = context.applicationContext
            val am = app.getSystemService(ActivityManager::class.java) ?: return
            val tasks = runCatching { am.appTasks.toList() }.getOrElse { emptyList() }
            for (task in tasks) {
                val info = runCatching { task.taskInfo }.getOrNull() ?: continue
                val top = info.topActivity?.className.orEmpty()
                val base = info.baseActivity?.className.orEmpty()
                if (!top.contains("IncomingCallActivity") && !base.contains("IncomingCallActivity")) {
                    continue
                }
                runCatching {
                    task.finishAndRemoveTask()
                    Log.i(TAG, "Finished stale Incoming AppTask id=${info.taskId}")
                }.onFailure {
                    Log.w(TAG, "finishAndRemoveTask failed: ${it.message}")
                }
            }
        }

        /**
         * Request code shared by CallStyle [NotificationCompat.Builder.setFullScreenIntent]
         * and [sendAllowlistedFullScreenIntent]. Must match so NMS's +30s FSI
         * allowlist applies to the same PendingIntent token.
         */
        fun fullScreenIntentRequestCode(launch: Intent): Int =
            pendingIntentRequestCode(launch) + 3

        /**
         * Send the CallStyle full-screen PendingIntent after NM.notify has
         * allowlisted it. Do not substitute AlarmClock's different requestCode.
         */
        fun sendAllowlistedFullScreenIntent(
            context: Context,
            fullScreen: PendingIntent,
            attempt: Int,
        ) {
            if (isShowing()) return
            finishStaleIncomingCallTasks(context)
            val app = context.applicationContext
            val senderOpts = pendingIntentSenderBackgroundActivityStartOptions()
            runCatching {
                if (Build.VERSION.SDK_INT >= 34 && senderOpts != null) {
                    fullScreen.send(app, 0, null, null, null, null, senderOpts)
                } else {
                    fullScreen.send()
                }
                Log.i(TAG, "Allowlisted FSI PendingIntent.send attempt=$attempt")
            }.onFailure {
                Log.w(TAG, "Allowlisted FSI send failed attempt=$attempt: ${it.message}")
            }
        }

        /**
         * Open glass while Telecom's ConnectionService binder BAL exemption is
         * still on this call stack ([Connection.onShowIncomingCallUi]).
         *
         * targetSdk 36: do **not** use ActivityOptions ALLOW_ALWAYS (denied for
         * non-system apps) and do **not** PendingIntent.send from our uid
         * (Samsung logs `autoOptInReason: sameUid` → BAL_BLOCK). Plain
         * [Context.startActivity] on this binder thread is the grant path.
         * Leave CLEAR_TASK off — finishing/recreating a background stack is
         * treated as balDontBringExistingBackgroundTaskStackToFg.
         */
        fun presentFromTelecomShowIncomingUi(context: Context, launch: Intent) {
            if (isShowing()) return
            if (launchIsClosed(launch)) return
            if (BeamioTelecomService.wasBusyRejected(
                    launch.getStringExtra(BeamioTelecomService.EXTRA_CALL_ID).orEmpty(),
                    launch.getStringExtra(BeamioTelecomService.EXTRA_SESSION_ID).orEmpty(),
                )
            ) {
                return
            }
            markPresentInFlight(8_000L)
            val app = context.applicationContext
            // Lock screen: overlay cannot appear above the keyguard. Leave
            // CallStyle FSI (USE_FULL_SCREEN_INTENT) as the lock UI owner —
            // do not attach an invisible TYPE_APPLICATION_OVERLAY that would
            // demote CallStyle to quiet keep-alive.
            if (BeamioTelecomService.isDeviceKeyguardLocked(app)) {
                Log.i(
                    TAG,
                    "Telecom binder under keyguard → skip overlay; CallStyle FSI owns lock UI",
                )
                clearPresentInFlight()
                return
            }
            // targetSdk 36 BAL blocks binder startActivity under launcher; overlay
            // is the reliable glass path when SYSTEM_ALERT_WINDOW is granted.
            if (IncomingCallOverlay.show(app, launch)) {
                Log.i(TAG, "Telecom binder → overlay glass (skip BAL startActivity)")
                clearPresentInFlight()
                return
            }
            val opening = Intent(launch).apply {
                setClass(app, IncomingCallActivity::class.java)
                addFlags(
                    Intent.FLAG_ACTIVITY_NEW_TASK or
                        Intent.FLAG_ACTIVITY_SINGLE_TOP or
                        Intent.FLAG_ACTIVITY_NO_USER_ACTION,
                )
            }
            runCatching { app.startActivity(opening) }
                .onSuccess {
                    Log.i(TAG, "Telecom binder startActivity dispatched (no CLEAR_TASK / no sameUid FSI)")
                }
                .onFailure {
                    Log.w(TAG, "Telecom binder startActivity failed: ${it.message}")
                }
        }

        private fun tryStartActivityAllowAlways(app: Context, opening: Intent, reason: String) {
            runCatching {
                if (Build.VERSION.SDK_INT >= 34) {
                    val opts = ActivityOptions.makeBasic()
                    runCatching {
                        ActivityOptions::class.java.getMethod(
                            "setPendingIntentBackgroundActivityStartMode",
                            Int::class.javaPrimitiveType,
                        ).invoke(opts, modeBackgroundActivityStartPreferred())
                    }
                    // Also set creator-style mode used by Context.startActivity bundles.
                    runCatching {
                        val mode = modeBackgroundActivityStartPreferred()
                        val m = ActivityOptions::class.java.methods.firstOrNull {
                            it.name == "setPendingIntentCreatorBackgroundActivityStartMode" &&
                                it.parameterTypes.size == 1
                        }
                        m?.invoke(opts, mode)
                    }
                    app.startActivity(opening, opts.toBundle())
                } else {
                    app.startActivity(opening)
                }
            }
                .onSuccess { Log.i(TAG, "Incoming startActivity dispatched reason=$reason") }
                .onFailure {
                    Log.w(TAG, "Incoming startActivity failed reason=$reason: ${it.message}")
                }
        }

        /**
         * Last-resort BAL path: [AlarmManager.setAlarmClock]. On Samsung API 37
         * this still often BAL_BLOCKs (different PI from CallStyle FSI). Prefer
         * [presentFromTelecomShowIncomingUi] / [presentFromPhoneCallFgs] first.
         */
        fun scheduleAlarmClockGlassPresent(context: Context, launch: Intent) {
            if (isShowing()) return
            if (launchIsClosed(launch)) return
            finishStaleIncomingCallTasks(context)
            markPresentInFlight(10_000L)
            val app = context.applicationContext
            val opening = buildLaunchIntent(app, launch)
            val requestCode = alarmClockRequestCode(opening)
            val operation = buildActivityPendingIntent(app, opening, requestCode)
            val show = buildActivityPendingIntent(app, opening, requestCode + 1)
            val am = app.getSystemService(AlarmManager::class.java)
            if (am == null) {
                Log.w(TAG, "AlarmManager missing; falling back to FSI send")
                sendAllowlistedFullScreenIntent(app, operation, 0)
                return
            }
            val canExact =
                Build.VERSION.SDK_INT < Build.VERSION_CODES.S ||
                    runCatching { am.canScheduleExactAlarms() }.getOrDefault(false)
            if (!canExact) {
                Log.w(
                    TAG,
                    "SCHEDULE_EXACT_ALARM not granted; AlarmClock blocked — FSI fallback",
                )
                sendAllowlistedFullScreenIntent(app, operation, 0)
                Handler(Looper.getMainLooper()).postDelayed({
                    if (isShowing()) {
                        bringOwnAppTasksToFront(app, preferIncomingOnTop = true)
                        clearPresentInFlight()
                    } else {
                        clearPresentInFlight()
                        Log.w(TAG, "FSI fallback glass did not open; CallStyle shade remains tappable")
                    }
                }, 1_200L)
                return
            }
            fun arm(delayMs: Long, attempt: Int): Boolean {
                if (isShowing()) return true
                val triggerAt = System.currentTimeMillis() + delayMs.coerceAtLeast(50L)
                return runCatching {
                    am.setAlarmClock(AlarmManager.AlarmClockInfo(triggerAt, show), operation)
                    Log.i(
                        TAG,
                        "AlarmClock glass armed attempt=$attempt delayMs=$delayMs " +
                            "requestCode=$requestCode",
                    )
                    true
                }.getOrElse {
                    Log.w(TAG, "AlarmClock arm failed attempt=$attempt: ${it.message}")
                    false
                }
            }
            if (!arm(350L, 1)) {
                sendAllowlistedFullScreenIntent(app, operation, 1)
            }
            Handler(Looper.getMainLooper()).postDelayed({
                if (isShowing()) {
                    clearPresentInFlight()
                    return@postDelayed
                }
                if (!arm(80L, 2)) {
                    sendAllowlistedFullScreenIntent(app, operation, 2)
                }
            }, 1_100L)
            Handler(Looper.getMainLooper()).postDelayed({
                if (isShowing()) {
                    bringOwnAppTasksToFront(app, preferIncomingOnTop = true)
                    clearPresentInFlight()
                } else {
                    clearPresentInFlight()
                    Log.w(TAG, "AlarmClock glass did not open; CallStyle shade remains tappable")
                }
            }, 2_800L)
        }

        fun cancelAlarmClockGlassPresent(context: Context, callId: String, sessionId: String) {
            val app = context.applicationContext
            val am = app.getSystemService(AlarmManager::class.java) ?: return
            val launch = Intent(app, IncomingCallActivity::class.java).apply {
                putExtra(BeamioTelecomService.EXTRA_CALL_ID, callId)
                putExtra(BeamioTelecomService.EXTRA_SESSION_ID, sessionId)
            }
            val opening = buildLaunchIntent(app, launch)
            val requestCode = alarmClockRequestCode(opening)
            runCatching {
                am.cancel(buildActivityPendingIntent(app, opening, requestCode))
                am.cancel(buildActivityPendingIntent(app, opening, requestCode + 1))
                Log.i(TAG, "AlarmClock glass cancelled requestCode=$requestCode")
            }.onFailure {
                Log.w(TAG, "AlarmClock cancel failed: ${it.message}")
            }
        }

        private fun alarmClockRequestCode(opening: Intent): Int =
            pendingIntentRequestCode(opening) + 50_000

        /**
         * phoneCall FGS is BAL-exempt for [Context.startActivity] on API 34+.
         * Try that first with the NMS-allowlisted CallStyle FSI PendingIntent,
         * then AlarmClock only if glass still missing.
         */
        fun presentFromPhoneCallFgs(context: Context, launch: Intent) {
            if (isShowing()) return
            if (launchIsClosed(launch)) return
            finishStaleIncomingCallTasks(context)
            markPresentInFlight(8_000L)
            val app = context.applicationContext
            // phoneCall FGS can add TYPE_APPLICATION_OVERLAY without BAL.
            if (IncomingCallOverlay.show(app, launch)) {
                Log.i(TAG, "phoneCall FGS → overlay glass")
                clearPresentInFlight()
                return
            }
            val opening = buildLaunchIntent(app, launch)
            tryStartActivityAllowAlways(app, opening, "phoneCall-fgs")
            val fsi = buildFullScreenPendingIntent(app, launch, fullScreenIntentRequestCode(launch))
            sendAllowlistedFullScreenIntent(app, fsi, 2)
            Log.i(TAG, "phoneCall FGS → startActivity + allowlisted FSI (no overlay permission)")
            Handler(Looper.getMainLooper()).postDelayed({
                if (isShowing()) {
                    bringOwnAppTasksToFront(app, preferIncomingOnTop = true)
                    clearPresentInFlight()
                    return@postDelayed
                }
                // Late overlay grant / retry once more before AlarmClock.
                if (IncomingCallOverlay.show(app, launch)) {
                    Log.i(TAG, "phoneCall FGS → overlay glass (retry)")
                    clearPresentInFlight()
                    return@postDelayed
                }
                Log.w(TAG, "phoneCall FGS glass missing; AlarmClock last resort")
                scheduleAlarmClockGlassPresent(app, launch)
            }, 450L)
        }

        /**
         * Raise only the IncomingCall [ActivityManager.AppTask] above the
         * launcher. Never move Main while glass is presenting — Samsung
         * otherwise resumes opaque Main first, covers glass, then
         * onResume→raise loops (Main ↔ Incoming fight).
         */
        fun bringOwnAppTasksToFront(context: Context, preferIncomingOnTop: Boolean = true) {
            val app = context.applicationContext
            val am = app.getSystemService(ActivityManager::class.java) ?: return
            val tasks = runCatching { am.appTasks.toList() }.getOrElse { emptyList() }
            if (tasks.isEmpty()) return
            fun isIncoming(task: ActivityManager.AppTask): Boolean {
                val info = runCatching { task.taskInfo }.getOrNull() ?: return false
                val top = info.topActivity?.className.orEmpty()
                val base = info.baseActivity?.className.orEmpty()
                return top.contains("IncomingCallActivity") || base.contains("IncomingCallActivity")
            }
            val incoming = tasks.filter { isIncoming(it) }
            if (incoming.isEmpty()) return
            // preferIncomingOnTop (always for glass): ONLY Incoming. Moving Main
            // first was the browser/launcher "no window" bug — glass opened then
            // was immediately buried by opaque Main.
            val order =
                if (preferIncomingOnTop) {
                    incoming
                } else {
                    tasks.filterNot { isIncoming(it) } + incoming
                }
            for (task in order) {
                runCatching {
                    task.moveToFront()
                    val info = task.taskInfo
                    Log.i(
                        TAG,
                        "AppTask.moveToFront id=${info.taskId} top=${info.topActivity?.shortClassName}",
                    )
                }.onFailure {
                    Log.w(TAG, "AppTask.moveToFront failed: ${it.message}")
                }
            }
            for (task in incoming) {
                val id = runCatching { task.taskInfo.taskId }.getOrNull() ?: continue
                @Suppress("DEPRECATION")
                runCatching {
                    am.moveTaskToFront(id, ActivityManager.MOVE_TASK_WITH_HOME)
                }
            }
        }

        /**
         * Samsung One UI often aborts Context.startActivity from FCM/FGS with
         * "Abort background activity starts" while still allowing a PendingIntent
         * that carries FLAG_ALLOW_BACKGROUND_ACTIVITY_START (same trick as NFC FD).
         *
         * API 34 BAL options are split:
         * - Creator mode → [PendingIntent.getActivity] options Bundle
         * - Sender mode → [PendingIntent.send] options Bundle
         * Passing creator mode into send() throws
         * "pendingIntentCreatorBackgroundActivityStartMode must not be set when sending".
         */
        fun forceLaunchViaPendingIntent(context: Context, launch: Intent) {
            val app = context.applicationContext
            val opening = buildLaunchIntent(app, launch)
            forceBringActivityViaPendingIntent(app, opening, pendingIntentRequestCode(opening))
        }

        /**
         * BAL-safe PendingIntent.send for any activity Intent (opaque MainActivity
         * raise, or translucent IncomingCallActivity glass).
         */
        fun forceBringActivityViaPendingIntent(
            context: Context,
            activityIntent: Intent,
            requestCode: Int,
        ) {
            val app = context.applicationContext
            val pi = buildActivityPendingIntent(app, activityIntent, requestCode)
            val senderOpts = pendingIntentSenderBackgroundActivityStartOptions()
            val target = activityIntent.component?.shortClassName ?: activityIntent.action.orEmpty()
            runCatching {
                if (Build.VERSION.SDK_INT >= 34 && senderOpts != null) {
                    pi.send(app, 0, null, null, null, null, senderOpts)
                } else {
                    pi.send()
                }
                Log.i(
                    TAG,
                    "PendingIntent.send dispatched requestCode=$requestCode target=$target",
                )
            }.onFailure {
                Log.w(TAG, "PendingIntent.send failed target=$target: ${it.message}")
            }
        }

        fun buildFullScreenPendingIntent(context: Context, launch: Intent, requestCode: Int): PendingIntent {
            val app = context.applicationContext
            val opening = buildLaunchIntent(app, launch)
            return buildActivityPendingIntent(app, opening, requestCode)
        }

        private fun buildActivityPendingIntent(
            app: Context,
            opening: Intent,
            requestCode: Int,
        ): PendingIntent {
            var flags = PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE
            flags = flags or pendingIntentAllowBackgroundActivityStartFlag()
            val creatorOpts = pendingIntentCreatorBackgroundActivityStartOptions()
            return if (Build.VERSION.SDK_INT >= 34 && creatorOpts != null) {
                PendingIntent.getActivity(app, requestCode, opening, flags, creatorOpts)
            } else {
                PendingIntent.getActivity(app, requestCode, opening, flags)
            }
        }

        private fun pendingIntentRequestCode(launch: Intent): Int {
            val callId = launch.getStringExtra(BeamioTelecomService.EXTRA_CALL_ID).orEmpty()
            val sessionId = launch.getStringExtra(BeamioTelecomService.EXTRA_SESSION_ID).orEmpty()
            val key = callId.ifBlank { sessionId }.ifBlank { "incoming" }
            return (key.hashCode() and 0x7fffffff) % 100_000 + 3
        }

        private fun pendingIntentAllowBackgroundActivityStartFlag(): Int {
            if (Build.VERSION.SDK_INT < 34) return 0
            return try {
                PendingIntent::class.java.getField("FLAG_ALLOW_BACKGROUND_ACTIVITY_START").getInt(null)
            } catch (_: Throwable) {
                0
            }
        }

        private fun modeBackgroundActivityStartAllowed(): Int {
            return try {
                ActivityOptions::class.java
                    .getField("MODE_BACKGROUND_ACTIVITY_START_ALLOWED")
                    .getInt(null)
            } catch (_: Throwable) {
                1
            }
        }

        /**
         * Prefer ALLOW_ALWAYS (API 35+) so Samsung/BAL does not silently drop
         * PendingIntent.send while the launcher is top. Fall back to ALLOWED.
         */
        private fun modeBackgroundActivityStartPreferred(): Int {
            if (Build.VERSION.SDK_INT >= 35) {
                try {
                    return ActivityOptions::class.java
                        .getField("MODE_BACKGROUND_ACTIVITY_START_ALLOW_ALWAYS")
                        .getInt(null)
                } catch (_: Throwable) {
                    // Fall through to ALLOWED.
                }
            }
            return modeBackgroundActivityStartAllowed()
        }

        /** Bundle for PendingIntent.getActivity (creator). */
        private fun pendingIntentCreatorBackgroundActivityStartOptions(): Bundle? {
            if (Build.VERSION.SDK_INT < 34) return null
            return try {
                val options = ActivityOptions.makeBasic()
                ActivityOptions::class.java.getMethod(
                    "setPendingIntentCreatorBackgroundActivityStartMode",
                    Int::class.javaPrimitiveType,
                ).invoke(options, modeBackgroundActivityStartPreferred())
                options.toBundle()
            } catch (_: Throwable) {
                null
            }
        }

        /** Bundle for PendingIntent.send (sender). Must not set creator mode. */
        private fun pendingIntentSenderBackgroundActivityStartOptions(): Bundle? {
            if (Build.VERSION.SDK_INT < 34) return null
            return try {
                val options = ActivityOptions.makeBasic()
                ActivityOptions::class.java.getMethod(
                    "setPendingIntentBackgroundActivityStartMode",
                    Int::class.javaPrimitiveType,
                ).invoke(options, modeBackgroundActivityStartPreferred())
                options.toBundle()
            } catch (_: Throwable) {
                null
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
            if (IncomingCallOverlay.isShowing()) return true
            return isWindowShowing()
        }

        /** This Activity only (not the overlay glass). */
        fun isWindowShowing(): Boolean {
            val activity = instance?.get() ?: return false
            return !activity.isFinishing
        }

        /**
         * True when Main is resumed or IncomingCall is showing. Background
         * MainActivity (alive but paused under launcher) is NOT visible — app
         * present() will BAL_BLOCK; rely on CallStyle FSI instead.
         */
        fun hasVisibleAppUi(): Boolean {
            if (isShowing()) return true
            return MainActivity.isUiResumed()
        }

        /**
         * True while [presentOnMain] is retrying BAL starts. MainActivity.onResume
         * must not dismiss RINGING/FGS during this window or glass never appears.
         */
        @Volatile
        private var presentInFlightUntilElapsedMs: Long = 0L

        private const val PRESENT_IN_FLIGHT_HOLD_MS = 12_000L

        fun isPresentInFlight(): Boolean {
            if (isShowing()) return true
            return android.os.SystemClock.elapsedRealtime() < presentInFlightUntilElapsedMs
        }

        fun markPresentInFlight(holdMs: Long = PRESENT_IN_FLIGHT_HOLD_MS) {
            presentInFlightUntilElapsedMs =
                android.os.SystemClock.elapsedRealtime() + holdMs.coerceAtLeast(1_000L)
            Log.i(TAG, "Glass present in-flight holdMs=$holdMs")
        }

        fun clearPresentInFlight() {
            presentInFlightUntilElapsedMs = 0L
        }

        fun bringToFront(context: Context) {
            val activity = instance?.get() ?: return
            present(context, activity.intent ?: return)
        }

        fun refreshAvatarIfShowing() {
            val activity = instance?.get() ?: return
            if (activity.isFinishing) return
            activity.runOnUiThread {
                val title = activity.findViewById<TextView>(R.id.incoming_call_title)?.text?.toString().orEmpty()
                activity.bindAvatar(title)
            }
        }

        /** Quiet title/body update after BeamioTag resolve — no second CallStyle notify. */
        fun refreshCallerChrome(title: String, body: String) {
            if (IncomingCallOverlay.isShowing()) {
                IncomingCallOverlay.refreshCallerChrome(title, body)
                return
            }
            val activity = instance?.get() ?: return
            if (activity.isFinishing) return
            val run = Runnable {
                val nextTitle = title.trim().ifBlank { activity.getString(R.string.incoming_call_body) }
                // Persist verified @BeamioTag so soft-reassert / FSI relaunch
                // does not wipe the main line back to "Incoming call".
                if (nextTitle.startsWith("@") && nextTitle.length in 2..33) {
                    activity.claimedTag = nextTitle
                    activity.intent?.putExtra(BeamioTelecomService.EXTRA_CLAIMED_TAG, nextTitle)
                }
                activity.findViewById<TextView>(R.id.incoming_call_title)?.text = nextTitle
                activity.bindAvatar(nextTitle)
                activity.bindWarning(body)
                activity.intent?.putExtra(BeamioTelecomService.EXTRA_INCOMING_TITLE, nextTitle)
                activity.intent?.putExtra(BeamioTelecomService.EXTRA_INCOMING_BODY, body)
            }
            if (Looper.myLooper() == Looper.getMainLooper()) run.run()
            else Handler(Looper.getMainLooper()).post(run)
        }

        /**
         * When a matching end arrives before [onCreate], remember the ids so
         * [present] / [onCreate] do not open a glass for an already-ended call.
         */
        @Volatile
        private var pendingFinishKeys: Set<String> = emptySet()

        fun finishIfMatching(callId: String, sessionId: String) {
            if (IncomingCallOverlay.isShowing()) {
                if (!IncomingCallOverlay.matches(callId, sessionId)) return
                BeamioIncomingRingtone.stopFor(listOf(callId, sessionId), "incoming window closed")
                IncomingCallOverlay.dismiss(callId, sessionId)
                pendingFinishKeys = emptySet()
                deferredFinishKeys = emptySet()
                return
            }
            val activity = instance?.get()
            if (activity != null && !activity.matches(callId, sessionId)) return
            // By id: with no window up, another call's end must not stop this ring.
            BeamioIncomingRingtone.stopFor(listOf(callId, sessionId), "incoming window closed")
            if (activity == null) {
                val keys = listOf(callId, sessionId)
                    .map { it.trim() }
                    .filter { it.isNotEmpty() }
                    .toSet()
                if (keys.isEmpty()) return
                // While BAL retries are in flight, latching pendingFinish would
                // skip the post-FGS present and leave RINGING with no glass.
                if (isPresentInFlight()) {
                    deferredFinishKeys = keys
                    Log.i(TAG, "Incoming finish deferred until glass shows or present fails")
                    return
                }
                pendingFinishKeys = keys
                Log.i(TAG, "Incoming finish pending; glass not yet created")
                return
            }
            pendingFinishKeys = emptySet()
            deferredFinishKeys = emptySet()
            activity.finishFromCall()
        }

        /** Applied in onCreate when end arrived during present-in-flight. */
        @Volatile
        private var deferredFinishKeys: Set<String> = emptySet()

        fun consumeDeferredFinish(callId: String, sessionId: String): Boolean {
            val deferred = deferredFinishKeys
            if (deferred.isEmpty()) return false
            val hit = listOf(callId, sessionId)
                .map { it.trim() }
                .any { it.isNotEmpty() && deferred.contains(it) }
            if (hit) deferredFinishKeys = emptySet()
            return hit
        }

        fun clearDeferredFinish() {
            deferredFinishKeys = emptySet()
        }

        fun finishIfShowing() {
            BeamioIncomingRingtone.stop()
            if (IncomingCallOverlay.isShowing()) {
                IncomingCallOverlay.dismissIfShowing()
            }
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
            if (IncomingCallOverlay.isShowing() && IncomingCallOverlay.matches(callId, sessionId)) {
                IncomingCallOverlay.updateShownCaller(
                    callId,
                    sessionId,
                    displayName,
                    peerAddress,
                    claimedTag,
                    identityWarning,
                )
                return
            }
            val activity = instance?.get() ?: return
            if (!activity.matches(callId, sessionId)) return
            val title = displayName.trim().ifBlank {
                claimedTag.trim().ifBlank { peerAddress.trim() }
            }.ifBlank { activity.getString(R.string.incoming_call_body) }
            activity.claimedTag = claimedTag.trim().ifBlank { activity.claimedTag }
            activity.findViewById<TextView>(R.id.incoming_call_title)?.text = title
            activity.findViewById<TextView>(R.id.incoming_call_product_line)?.text =
                activity.getString(R.string.incoming_call_glass_subtitle)
            activity.bindWarning(identityWarning)
            if (claimedAddress.isNotBlank()) {
                activity.intent?.putExtra(BeamioTelecomService.EXTRA_CLAIMED_ADDRESS, claimedAddress)
            }
            if (peerAddress.isNotBlank()) {
                activity.intent?.putExtra(BeamioTelecomService.EXTRA_PEER_ADDRESS, peerAddress)
            }
            activity.bindAddress(activity.intent)
        }

        private fun titlePresent(source: Intent?): Boolean {
            return !source?.getStringExtra(BeamioTelecomService.EXTRA_INCOMING_TITLE).isNullOrBlank()
        }
    }
}
