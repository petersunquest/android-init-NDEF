package com.beamio.app

import android.app.Notification
import android.app.Service
import android.content.Context
import android.content.Intent
import android.content.pm.ServiceInfo
import android.os.Build
import android.os.Handler
import android.os.IBinder
import android.os.Looper
import android.util.Log
import androidx.core.app.NotificationManagerCompat
import androidx.core.app.ServiceCompat
import java.util.concurrent.atomic.AtomicInteger

/**
 * Keeps a phoneCall / shortService foreground notification alive while a call
 * is ringing or active.
 *
 * Ringing starts as CallStyle + CATEGORY_CALL so Android 14+ can auto-fire the
 * full-screen intent while the screen is on. Once [IncomingCallActivity] is
 * visible, [demoteIncomingAfterGlass] swaps that shade for a silent
 * CATEGORY_SERVICE keep-alive so Samsung does not leave a second Answer/Decline
 * heads-up over the glass. After Answer, the notification becomes a quiet
 * ongoing status entry.
 */
class BeamioCallForegroundService : Service() {
    override fun onBind(intent: Intent?): IBinder? = null

    override fun onCreate() {
        super.onCreate()
        instance = this
    }

    /** Start id of the last command delivered; stopping with it never drops a start still queued. */
    private var lastStartId = 0

    /**
     * True while handling a startForegroundService command that has not yet
     * called startForeground. Android kills the app if such a start ends (or the
     * service stops) without one, so any stop in that window posts a quiet
     * foreground first.
     */
    private var foregroundOwed = false

    override fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int {
        lastStartId = startId
        val foregroundRequired = intent?.getBooleanExtra(EXTRA_FOREGROUND_REQUIRED, false) == true
        if (foregroundRequired) {
            pendingForegroundStarts.updateAndGet { if (it > 0) it - 1 else 0 }
            foregroundOwed = true
        }
        try {
            return handleCommand(intent)
        } finally {
            if (foregroundOwed) {
                // The handler neither showed anything nor stopped (e.g. a muted
                // hold that was denied). Satisfy the start, then stop if idle.
                if (activeForegroundNotificationId == 0) {
                    Log.i(TAG, "FGS start left nothing to show; posting a quiet foreground, then stopping")
                    removeCallForeground()
                }
                foregroundOwed = false
            }
        }
    }

    private fun handleCommand(intent: Intent?): Int {
        when (intent?.action) {
            ACTION_STOP -> {
                removeCallForeground()
                return START_NOT_STICKY
            }
            ACTION_MUTE -> {
                val callId = intent?.getStringExtra(BeamioTelecomService.EXTRA_CALL_ID).orEmpty()
                val sessionId = intent?.getStringExtra(BeamioTelecomService.EXTRA_SESSION_ID).orEmpty()
                holdMutedIncoming(callId, sessionId)
                // Mute hold is short-lived; do not resurrect after process death.
                return START_NOT_STICKY
            }
            ACTION_INCOMING -> {
                val id = intent.getIntExtra(EXTRA_NOTIFICATION_ID, 0)
                val notification = readNotification(intent)
                if (id == 0 || notification == null) {
                    Log.e(TAG, "Incoming FGS missing notification")
                    if (activeForegroundNotificationId == 0) removeCallForeground()
                    return START_NOT_STICKY
                }
                val glass = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.TIRAMISU) {
                    intent.getParcelableExtra(EXTRA_GLASS_LAUNCH, Intent::class.java)
                } else {
                    @Suppress("DEPRECATION")
                    intent.getParcelableExtra(EXTRA_GLASS_LAUNCH)
                }
                postIncoming(id, notification, glass)
                // Incoming must not START_STICKY: after force-stop / kill the OS
                // would resurrect a ghost RINGING FGS + glass with no live offer,
                // and sticky chrome then busy-rejects the next real dial.
                return START_NOT_STICKY
            }
            ACTION_ONGOING -> {
                val callId = intent.getStringExtra(BeamioTelecomService.EXTRA_CALL_ID).orEmpty()
                val sessionId = intent.getStringExtra(BeamioTelecomService.EXTRA_SESSION_ID).orEmpty()
                postOngoingCall(callId, sessionId)
            }
            else -> {
                val callId = intent?.getStringExtra(BeamioTelecomService.EXTRA_CALL_ID).orEmpty()
                val sessionId = intent?.getStringExtra(BeamioTelecomService.EXTRA_SESSION_ID).orEmpty()
                postOngoingCall(callId, sessionId)
            }
        }
        // Active call may be restarted after a brief process death; incoming
        // already returned START_NOT_STICKY above.
        return START_STICKY
    }

    override fun onDestroy() {
        if (instance === this) instance = null
        activeForegroundNotificationId = 0
        runCatching { stopForeground(STOP_FOREGROUND_REMOVE) }
        super.onDestroy()
    }

    /**
     * Caller hung up. Drop the incoming foreground notification from this
     * process. An exported Decline broadcast is not required.
     */
    fun removeCallForeground() {
        settleOwedForeground()
        val previous = activeForegroundNotificationId
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.N) {
            runCatching { stopForeground(STOP_FOREGROUND_REMOVE) }
        } else {
            @Suppress("DEPRECATION")
            runCatching { stopForeground(true) }
        }
        activeForegroundNotificationId = 0
        if (previous != 0) {
            NotificationManagerCompat.from(this).cancel(previous)
        }
        Log.i(TAG, "Incoming window removed")
        stopIfNoStartQueued()
    }

    /**
     * Inside a startForegroundService command that has not posted yet: post a
     * quiet foreground now, so a stop right after it does not crash the app
     * (ForegroundServiceDidNotStartInTimeException).
     */
    private fun settleOwedForeground() {
        if (!foregroundOwed) return
        if (postQuietForeground(FOREGROUND_ID, BeamioTelecomService.buildMutedIncomingNotification(this))) {
            activeForegroundNotificationId = FOREGROUND_ID
        }
    }

    /**
     * stopSelf() would also drop a startForegroundService that is queued but not
     * delivered yet, and Android then kills the app. Stopping with the last
     * delivered start id leaves the service running when a newer start is queued;
     * that start then decides what to show (or stops itself).
     */
    private fun stopIfNoStartQueued() {
        val stopped = stopSelfResult(lastStartId)
        if (!stopped) {
            Log.i(TAG, "FGS stop deferred; a newer start is queued")
        }
    }

    /** Drop the ringing card. Keep this process alive so the ring timeout can still fire. */
    fun holdMutedIncoming(callId: String, sessionId: String) {
        val previous = activeForegroundNotificationId
        val quiet = BeamioTelecomService.buildMutedIncomingNotification(this)
        if (!postQuietForeground(FOREGROUND_ID, quiet)) {
            Log.e(TAG, "Muted incoming hold denied")
            return
        }
        activeForegroundNotificationId = FOREGROUND_ID
        if (previous != 0 && previous != FOREGROUND_ID) {
            NotificationManagerCompat.from(this).cancel(previous)
        }
        BeamioTelecomService.cancelIncomingNotifications(this, callId, sessionId)
        Log.i(TAG, "Incoming window muted")
    }

    /**
     * The ringing FGS notification cannot be dismissed with NotificationManager
     * .cancel() alone. Remove that foreground entry, then post a silent ongoing
     * notification that has no Answer / Decline actions.
     */
    fun replaceIncomingWithQuiet(callId: String, sessionId: String) {
        val previous = activeForegroundNotificationId
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.N) {
            runCatching { stopForeground(STOP_FOREGROUND_REMOVE) }
        } else {
            @Suppress("DEPRECATION")
            runCatching { stopForeground(true) }
        }
        activeForegroundNotificationId = 0
        if (previous != 0) {
            NotificationManagerCompat.from(this).cancel(previous)
        }
        postOngoingCall(callId, sessionId)
        BeamioTelecomService.cancelIncomingNotifications(this, callId, sessionId)
    }

    fun postOngoingCall(callId: String, sessionId: String) {
        val notification = BeamioTelecomService.buildOngoingCallNotification(this, callId, sessionId)
        if (!postQuietForeground(FOREGROUND_ID, notification)) {
            Log.e(TAG, "Ongoing call status bar denied")
            return
        }
        activeForegroundNotificationId = FOREGROUND_ID
        Log.i(TAG, "Ongoing call status bar posted")
    }

    private fun postIncoming(id: Int, notification: Notification, glassLaunch: Intent?) {
        val previous = activeForegroundNotificationId
        val callId = glassLaunch
            ?.getStringExtra(BeamioTelecomService.EXTRA_CALL_ID)
            .orEmpty()
        val sessionId = glassLaunch
            ?.getStringExtra(BeamioTelecomService.EXTRA_SESSION_ID)
            .orEmpty()
        val title = glassLaunch
            ?.getStringExtra(BeamioTelecomService.EXTRA_INCOMING_TITLE)
            .orEmpty()
            .ifBlank { "Incoming call" }
        val body = glassLaunch
            ?.getStringExtra(BeamioTelecomService.EXTRA_INCOMING_BODY)
            .orEmpty()
        BeamioTelecomService.restoreSettledIncoming(this)
        // A start queued before Answer / Decline / caller cancel / timeout is
        // delivered after it: do not bring back the CallStyle card or banner.
        // startForegroundService still needs a startForeground, so post a quiet one.
        if ((callId.isNotBlank() || sessionId.isNotBlank()) &&
            BeamioTelecomService.isIncomingClosed(callId, sessionId)
        ) {
            if (BeamioTelecomService.isIncomingAnsweredAny(callId, sessionId) &&
                InCallScreenModel.isLive() && InCallScreenModel.matches(callId, sessionId)
            ) {
                Log.i(TAG, "Late incoming FGS start after answer; keeping the ongoing call notification")
                postOngoingCall(callId, sessionId)
                BeamioTelecomService.cancelIncomingNotifications(this, callId, sessionId)
            } else if (previous != 0) {
                Log.i(TAG, "Late incoming FGS start for an ended call; ignored")
            } else {
                Log.i(TAG, "Late incoming FGS start for an ended call; stopping")
                if (postQuietForeground(FOREGROUND_ID, BeamioTelecomService.buildMutedIncomingNotification(this))) {
                    activeForegroundNotificationId = FOREGROUND_ID
                }
                removeCallForeground()
                BeamioTelecomService.cancelIncomingNotifications(this, callId, sessionId)
            }
            return
        }
        // Critical race: Activity/overlay may already have demoted CallStyle to
        // quiet via NM.notify. If we startForeground with the original CallStyle
        // parcel, Samsung re-posts Decline/Answer HUN *over* Beamio glass.
        // Prefer quiet only when glass/overlay is *actually* showing — not merely
        // when SYSTEM_ALERT_WINDOW is granted (that killed lock-screen Answer).
        // Lock / screen-off: never preferQuiet — CallStyle FSI owns lock UI even
        // when IncomingCallActivity reports isShowing behind an occluded keyguard.
        val keyguardLocked = BeamioTelecomService.isDeviceKeyguardLocked(this)
        // On screen, not merely added: Settings / permission pages hide overlays.
        val preferQuiet =
            !keyguardLocked && BeamioTelecomService.incomingGlassOnScreen()
        // Never startForeground with CallStyle when glass/overlay is the product
        // UI — that resurrects Decline/Answer HUN over TYPE_APPLICATION_OVERLAY.
        val forFgs = if (preferQuiet) {
            BeamioTelecomService.buildGlassKeepAliveNotification(
                this,
                callId = callId,
                sessionId = sessionId,
                title = title,
                body = body,
            )
        } else {
            notification
        }
        try {
            // Do NOT NotificationManager.notify again here when CallStyle is
            // intentional. startForeground alone keeps / replaces the shade.
            startIncomingForeground(id, forFgs)
            activeForegroundNotificationId = id
            if (previous != 0 && previous != id) {
                NotificationManagerCompat.from(this).cancel(previous)
            }
            Log.i(
                TAG,
                "Incoming FGS posted id=$id preferQuiet=$preferQuiet " +
                    "keyguardLocked=$keyguardLocked " +
                    "glassUp=${IncomingCallActivity.isShowing()}",
            )
            // Visible shell: normal present(). Under launcher: phoneCall FGS
            // may startActivity when the Intent uses CLEAR_TASK (recreate),
            // which avoids Samsung balDontBringExistingBackgroundTaskStackToFg.
            // Allowlisted FSI send runs in parallel from showIncomingCallNotification.
            // Under keyguard skip overlay-first present — CallStyle FSI owns lock UI.
            if (glassLaunch != null && !IncomingCallActivity.isShowing() && !keyguardLocked) {
                if (IncomingCallActivity.hasVisibleAppUi()) {
                    IncomingCallActivity.present(this, glassLaunch)
                    Log.i(TAG, "Incoming window present after FGS (app UI already visible)")
                } else {
                    IncomingCallActivity.presentFromPhoneCallFgs(this, glassLaunch)
                    Log.i(TAG, "Incoming window presentFromPhoneCallFgs under launcher")
                }
            }
            // After glass attach (or overlay-capable path), demote any leftover
            // CallStyle — including delayed retries for async Activity onCreate.
            // Never demote under keyguard unless IncomingCallActivity is up.
            if (preferQuiet || IncomingCallActivity.isShowing()) {
                demoteIncomingAfterGlass(
                    this,
                    callId = callId,
                    sessionId = sessionId,
                    title = title,
                    body = body,
                    notificationId = id,
                )
                val main = Handler(Looper.getMainLooper())
                for (delayMs in longArrayOf(400L, 1_200L)) {
                    main.postDelayed(
                        {
                            // demoteIncomingAfterGlass itself no-ops under keyguard;
                            // still gate here so we do not spam NM under lock.
                            if (BeamioTelecomService.isDeviceKeyguardLocked(
                                    this@BeamioCallForegroundService,
                                )
                            ) {
                                return@postDelayed
                            }
                            // Overlay hidden by the system: keep the banner.
                            if (BeamioTelecomService.incomingGlassOnScreen()) {
                                demoteIncomingAfterGlass(
                                    this@BeamioCallForegroundService,
                                    callId = callId,
                                    sessionId = sessionId,
                                    title = title,
                                    body = body,
                                    notificationId = id,
                                )
                            }
                        },
                        delayMs,
                    )
                }
            }
        } catch (error: Exception) {
            Log.e(TAG, "Incoming FGS denied", error)
            if (activeForegroundNotificationId == 0) removeCallForeground()
        }
    }

    /**
     * phoneCall is the right type once Telecom has a connection. Before that,
     * Android 15+ rejects it. shortService can still start from an FCM wake and
     * is enough for a CATEGORY_CALL FGS notification.
     */
    private fun startIncomingForeground(id: Int, notification: Notification) {
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.UPSIDE_DOWN_CAKE) {
            startForeground(id, notification)
            foregroundOwed = false
            return
        }
        try {
            ServiceCompat.startForeground(
                this,
                id,
                notification,
                ServiceInfo.FOREGROUND_SERVICE_TYPE_PHONE_CALL,
            )
        } catch (phoneCallDenied: Exception) {
            Log.w(TAG, "phoneCall FGS denied; using shortService for incoming", phoneCallDenied)
            ServiceCompat.startForeground(
                this,
                id,
                notification,
                ServiceInfo.FOREGROUND_SERVICE_TYPE_SHORT_SERVICE,
            )
        }
        foregroundOwed = false
    }

    /** phoneCall after Telecom setActive(); shortService if that type is denied. */
    private fun postQuietForeground(id: Int, notification: Notification): Boolean {
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.UPSIDE_DOWN_CAKE) {
            val ok = runCatching { startForeground(id, notification) }.isSuccess
            if (ok) foregroundOwed = false
            return ok
        }
        val types = intArrayOf(
            ServiceInfo.FOREGROUND_SERVICE_TYPE_PHONE_CALL,
            ServiceInfo.FOREGROUND_SERVICE_TYPE_SHORT_SERVICE,
        )
        for (type in types) {
            try {
                ServiceCompat.startForeground(this, id, notification, type)
                foregroundOwed = false
                return true
            } catch (error: Exception) {
                Log.w(TAG, "Quiet FGS denied type=$type", error)
            }
        }
        return false
    }

    fun postQuietForegroundPublic(id: Int, notification: Notification): Boolean =
        postQuietForeground(id, notification)

    private fun readNotification(intent: Intent): Notification? {
        return if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.TIRAMISU) {
            intent.getParcelableExtra(EXTRA_NOTIFICATION, Notification::class.java)
        } else {
            @Suppress("DEPRECATION")
            intent.getParcelableExtra(EXTRA_NOTIFICATION)
        }
    }

    companion object {
        private const val TAG = "BeamioVoiceCall"
        private const val FOREGROUND_ID = 41_001
        private const val ACTION_START = "com.beamio.app.action.START_CALL_FGS"
        private const val ACTION_ONGOING = "com.beamio.app.action.ONGOING_CALL_FGS"
        private const val ACTION_INCOMING = "com.beamio.app.action.INCOMING_CALL_FGS"
        private const val ACTION_STOP = "com.beamio.app.action.STOP_CALL_FGS"
        private const val ACTION_MUTE = "com.beamio.app.action.MUTE_INCOMING_FGS"
        private const val EXTRA_NOTIFICATION_ID = "notificationId"
        private const val EXTRA_NOTIFICATION = "notification"
        private const val EXTRA_GLASS_LAUNCH = "glassLaunch"
        private const val EXTRA_FOREGROUND_REQUIRED = "foregroundRequired"

        /**
         * startForegroundService calls not yet delivered to onStartCommand. While
         * one is queued the service must not be stopped from outside: Android
         * then throws ForegroundServiceDidNotStartInTimeException and kills the app.
         */
        private val pendingForegroundStarts = AtomicInteger(0)

        /** Every foreground start goes through here, so the queued count stays right. */
        private fun startForegroundRequired(context: Context, intent: Intent, failure: String) {
            if (Build.VERSION.SDK_INT < Build.VERSION_CODES.O) {
                try {
                    context.startService(intent)
                } catch (error: Exception) {
                    Log.e(TAG, failure, error)
                }
                return
            }
            intent.putExtra(EXTRA_FOREGROUND_REQUIRED, true)
            pendingForegroundStarts.incrementAndGet()
            try {
                context.startForegroundService(intent)
            } catch (error: Exception) {
                pendingForegroundStarts.updateAndGet { if (it > 0) it - 1 else 0 }
                Log.e(TAG, failure, error)
            }
        }

        @Volatile
        var activeForegroundNotificationId: Int = 0

        @Volatile
        private var instance: BeamioCallForegroundService? = null

        /**
         * Hide the Decline / Answer card on the same turn as Answer. The live
         * service can do that immediately; a new start only covers a cold process.
         */
        fun handoffAnsweredCall(context: Context, callId: String, sessionId: String) {
            val live = instance
            if (live != null) {
                live.replaceIncomingWithQuiet(callId, sessionId)
                return
            }
            start(context, callId, sessionId)
        }

        /**
         * Replace CallStyle Answer/Decline shade with a silent keep-alive after
         * glass is showing. Keeps phoneCall/shortService FGS alive for ring timeout.
         *
         * Must work even when FGS [instance] is not yet onCreated (glass often
         * demotes before startForegroundService runs) — otherwise CallStyle HUN
         * stays and covers TYPE_APPLICATION_OVERLAY.
         */
        fun demoteIncomingAfterGlass(
            context: Context,
            callId: String,
            sessionId: String,
            title: String,
            body: String,
            notificationId: Int,
            aliasKeys: List<String> = emptyList(),
        ) {
            // Lock / screen-off: never demote CallStyle FSI. Activity may report
            // isShowing while occluded — quiet keep-alive then = no Beamio UI.
            if (BeamioTelecomService.isDeviceKeyguardLocked(context)) {
                Log.i(
                    TAG,
                    "Skip demoteIncomingAfterGlass; keyguard/screen-off — keep CallStyle FSI " +
                        "activityUp=${IncomingCallActivity.isShowing()}",
                )
                return
            }
            val quiet = BeamioTelecomService.buildGlassKeepAliveNotification(
                context,
                callId = callId,
                sessionId = sessionId,
                title = title,
                body = body,
            )
            // Prefer the live FGS id (same shade that held CallStyle). Fall back
            // to the CallStyle posted id, then a stable FOREGROUND_ID — never
            // leave CallStyle orphaned on a different hash id.
            val id = when {
                activeForegroundNotificationId != 0 -> activeForegroundNotificationId
                notificationId != 0 -> notificationId
                else -> FOREGROUND_ID
            }
            val live = instance
            if (live != null) {
                if (!live.postQuietForegroundPublic(id, quiet)) {
                    NotificationManagerCompat.from(context).notify(id, quiet)
                }
                activeForegroundNotificationId = id
            } else {
                NotificationManagerCompat.from(context).notify(id, quiet)
            }
            val cancelIds = linkedSetOf<Int>()
            if (notificationId != 0) cancelIds.add(notificationId)
            (aliasKeys + listOf(callId, sessionId))
                .map { it.trim() }
                .filter { it.isNotBlank() }
                .forEach { key -> cancelIds.add(BeamioTelecomService.notificationId(key)) }
            cancelIds
                .filter { it != id }
                .forEach { aliasId ->
                    NotificationManagerCompat.from(context).cancel(aliasId)
                    NotificationManagerCompat.from(context).cancel(null, aliasId)
                }
            // Nuclear: any leftover CATEGORY_CALL HUN on the incoming channel
            // (wrong alias hash) still covers TYPE_APPLICATION_OVERLAY glass.
            BeamioTelecomService.cancelActiveCallStyleNotifications(context, keepId = id)
            Log.i(
                TAG,
                "Incoming CallStyle demoted after glass keepId=$id " +
                    "cancelledAliases=${cancelIds.filter { it != id }} fgsLive=${live != null}",
            )
        }

        fun startIncoming(
            context: Context,
            notificationId: Int,
            notification: Notification,
            glassLaunch: Intent? = null,
        ) {
            val intent = Intent(context, BeamioCallForegroundService::class.java).apply {
                action = ACTION_INCOMING
                putExtra(EXTRA_NOTIFICATION_ID, notificationId)
                putExtra(EXTRA_NOTIFICATION, notification)
                if (glassLaunch != null) {
                    putExtra(EXTRA_GLASS_LAUNCH, glassLaunch)
                }
            }
            startForegroundRequired(context, intent, "startForegroundService failed for incoming call")
        }

        /**
         * Replace CallStyle Person/title on the live FGS shade after BeamioTag
         * resolve (lock-screen identity refresh). Does not re-present glass.
         */
        fun refreshIncomingCallStyle(
            context: Context,
            notificationId: Int,
            notification: Notification,
        ) {
            val live = instance
            if (live != null && notificationId != 0) {
                runCatching {
                    live.startIncomingForeground(notificationId, notification)
                    activeForegroundNotificationId = notificationId
                    Log.i(TAG, "Incoming CallStyle FGS identity refresh id=$notificationId")
                }.onFailure {
                    Log.w(TAG, "Incoming CallStyle FGS identity refresh failed", it)
                    NotificationManagerCompat.from(context).notify(notificationId, notification)
                }
                return
            }
            if (notificationId != 0) {
                NotificationManagerCompat.from(context).notify(notificationId, notification)
            }
        }

        fun showOngoingCall(context: Context, callId: String, sessionId: String) {
            val live = instance
            if (live != null) {
                live.postOngoingCall(callId, sessionId)
                return
            }
            val intent = Intent(context, BeamioCallForegroundService::class.java).apply {
                action = ACTION_ONGOING
                putExtra(BeamioTelecomService.EXTRA_CALL_ID, callId)
                putExtra(BeamioTelecomService.EXTRA_SESSION_ID, sessionId)
            }
            startForegroundRequired(context, intent, "Ongoing call status bar failed to start")
        }

        fun start(context: Context, callId: String, sessionId: String) {
            val intent = Intent(context, BeamioCallForegroundService::class.java).apply {
                action = ACTION_START
                putExtra(BeamioTelecomService.EXTRA_CALL_ID, callId)
                putExtra(BeamioTelecomService.EXTRA_SESSION_ID, sessionId)
            }
            startForegroundRequired(context, intent, "startForegroundService failed")
        }

        fun stop(context: Context) {
            // Call over: the chat listen may take its owed background pause now.
            network.conet.chat.BeamioConetChatModule.release("callEnded")
            network.conet.chat.BeamioEntryPool.release("incomingCall")
            val live = instance
            if (live != null) {
                live.removeCallForeground()
                return
            }
            val intent = Intent(context, BeamioCallForegroundService::class.java).apply {
                action = ACTION_STOP
            }
            runCatching { context.startService(intent) }
            // A foreground start still queued (the service is not created yet):
            // stopService now would crash the app. The STOP above is delivered
            // after that start and stops the service once it has posted.
            if (pendingForegroundStarts.get() > 0) {
                Log.i(TAG, "FGS stop queued behind a pending foreground start")
                return
            }
            runCatching { context.stopService(Intent(context, BeamioCallForegroundService::class.java)) }
        }

        /** Replace the ringing card with a silent foreground hold. Does not end the call. */
        fun holdMutedIncoming(context: Context, callId: String, sessionId: String) {
            val live = instance
            if (live != null) {
                live.holdMutedIncoming(callId, sessionId)
                return
            }
            val intent = Intent(context, BeamioCallForegroundService::class.java).apply {
                action = ACTION_MUTE
                putExtra(BeamioTelecomService.EXTRA_CALL_ID, callId)
                putExtra(BeamioTelecomService.EXTRA_SESSION_ID, sessionId)
            }
            startForegroundRequired(context, intent, "Muted incoming hold failed to start")
        }
    }
}
