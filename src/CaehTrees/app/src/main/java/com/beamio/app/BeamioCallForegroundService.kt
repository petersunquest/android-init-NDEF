package com.beamio.app

import android.app.Notification
import android.app.Service
import android.content.Context
import android.content.Intent
import android.content.pm.ServiceInfo
import android.os.Build
import android.os.IBinder
import android.util.Log
import androidx.core.app.NotificationManagerCompat
import androidx.core.app.ServiceCompat

/**
 * Posts the system CallStyle incoming card as a phoneCall foreground-service
 * notification. Android 14+ rejects CallStyle from NotificationManager.notify()
 * unless it belongs to a foreground service or carries a fullScreenIntent.
 * After Answer, that card is removed and a silent status entry keeps the
 * service alive. The PWA call page is the call UI.
 */
class BeamioCallForegroundService : Service() {
    override fun onBind(intent: Intent?): IBinder? = null

    override fun onCreate() {
        super.onCreate()
        instance = this
    }

    override fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int {
        when (intent?.action) {
            ACTION_STOP -> {
                removeCallForeground()
                return START_NOT_STICKY
            }
            ACTION_MUTE -> {
                val callId = intent?.getStringExtra(BeamioTelecomService.EXTRA_CALL_ID).orEmpty()
                val sessionId = intent?.getStringExtra(BeamioTelecomService.EXTRA_SESSION_ID).orEmpty()
                holdMutedIncoming(callId, sessionId)
                return START_STICKY
            }
            ACTION_INCOMING -> {
                val id = intent.getIntExtra(EXTRA_NOTIFICATION_ID, 0)
                val notification = readNotification(intent)
                if (id == 0 || notification == null) {
                    Log.e(TAG, "Incoming FGS missing CallStyle notification")
                    if (activeForegroundNotificationId == 0) stopSelf()
                    return START_NOT_STICKY
                }
                postIncoming(id, notification)
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
        return START_STICKY
    }

    override fun onDestroy() {
        if (instance === this) instance = null
        activeForegroundNotificationId = 0
        runCatching { stopForeground(STOP_FOREGROUND_REMOVE) }
        super.onDestroy()
    }

    /**
     * Caller hung up. Drop the CallStyle foreground notification from this
     * process. An exported Decline broadcast is not required.
     */
    fun removeCallForeground() {
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
        stopSelf()
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
     * The CallStyle card is the foreground notification, so NotificationManager
     * .cancel() leaves the heads-up up. Remove that foreground entry, then post
     * a silent ongoing notification that has no Answer / Decline actions.
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

    private fun postIncoming(id: Int, notification: Notification) {
        val previous = activeForegroundNotificationId
        try {
            startIncomingForeground(id, notification)
            activeForegroundNotificationId = id
            if (previous != 0 && previous != id) {
                NotificationManagerCompat.from(this).cancel(previous)
            }
            Log.i(TAG, "CallStyle incoming FGS posted id=$id")
        } catch (error: Exception) {
            Log.e(TAG, "Incoming CallStyle FGS denied", error)
            if (activeForegroundNotificationId == 0) stopSelf()
        }
    }

    /**
     * phoneCall is the right type once Telecom has a connection. Before that,
     * Android 15+ rejects it. shortService can still start from an FCM wake and
     * is enough for CallStyle to be accepted as a foreground-service notification.
     */
    private fun startIncomingForeground(id: Int, notification: Notification) {
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.UPSIDE_DOWN_CAKE) {
            startForeground(id, notification)
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
            Log.w(TAG, "phoneCall FGS denied; using shortService for CallStyle", phoneCallDenied)
            ServiceCompat.startForeground(
                this,
                id,
                notification,
                ServiceInfo.FOREGROUND_SERVICE_TYPE_SHORT_SERVICE,
            )
        }
    }

    /** phoneCall after Telecom setActive(); shortService if that type is denied. */
    private fun postQuietForeground(id: Int, notification: Notification): Boolean {
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.UPSIDE_DOWN_CAKE) {
            return runCatching { startForeground(id, notification) }.isSuccess
        }
        val types = intArrayOf(
            ServiceInfo.FOREGROUND_SERVICE_TYPE_PHONE_CALL,
            ServiceInfo.FOREGROUND_SERVICE_TYPE_SHORT_SERVICE,
        )
        for (type in types) {
            try {
                ServiceCompat.startForeground(this, id, notification, type)
                return true
            } catch (error: Exception) {
                Log.w(TAG, "Quiet FGS denied type=$type", error)
            }
        }
        return false
    }

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

        fun startIncoming(context: Context, notificationId: Int, notification: Notification) {
            val intent = Intent(context, BeamioCallForegroundService::class.java).apply {
                action = ACTION_INCOMING
                putExtra(EXTRA_NOTIFICATION_ID, notificationId)
                putExtra(EXTRA_NOTIFICATION, notification)
            }
            try {
                if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
                    context.startForegroundService(intent)
                } else {
                    context.startService(intent)
                }
            } catch (error: Exception) {
                Log.e(TAG, "startForegroundService failed for incoming call", error)
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
            try {
                if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
                    context.startForegroundService(intent)
                } else {
                    context.startService(intent)
                }
            } catch (error: Exception) {
                Log.e(TAG, "Ongoing call status bar failed to start", error)
            }
        }

        fun start(context: Context, callId: String, sessionId: String) {
            val intent = Intent(context, BeamioCallForegroundService::class.java).apply {
                action = ACTION_START
                putExtra(BeamioTelecomService.EXTRA_CALL_ID, callId)
                putExtra(BeamioTelecomService.EXTRA_SESSION_ID, sessionId)
            }
            try {
                if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
                    context.startForegroundService(intent)
                } else {
                    context.startService(intent)
                }
            } catch (error: Exception) {
                Log.e(TAG, "startForegroundService failed", error)
            }
        }

        fun stop(context: Context) {
            val live = instance
            if (live != null) {
                live.removeCallForeground()
                return
            }
            val intent = Intent(context, BeamioCallForegroundService::class.java).apply {
                action = ACTION_STOP
            }
            runCatching { context.startService(intent) }
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
            try {
                if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
                    context.startForegroundService(intent)
                } else {
                    context.startService(intent)
                }
            } catch (error: Exception) {
                Log.e(TAG, "Muted incoming hold failed to start", error)
            }
        }
    }
}
