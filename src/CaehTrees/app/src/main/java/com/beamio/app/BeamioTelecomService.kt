package com.beamio.app

import android.content.ComponentName
import android.content.Context
import android.content.Intent
import android.app.PendingIntent
import android.net.Uri
import android.os.Bundle
import android.telecom.Connection
import android.telecom.ConnectionRequest
import android.telecom.ConnectionService
import android.telecom.DisconnectCause
import android.telecom.PhoneAccount
import android.telecom.PhoneAccountHandle
import android.telecom.TelecomManager
import androidx.core.app.NotificationCompat
import androidx.core.app.NotificationManagerCompat
import java.util.concurrent.atomic.AtomicInteger
import java.util.concurrent.ConcurrentHashMap

class BeamioTelecomService : ConnectionService() {
    override fun onCreateIncomingConnection(
        connectionManagerPhoneAccount: PhoneAccountHandle?,
        request: ConnectionRequest,
    ): Connection {
        val callId = request.extras?.getString(EXTRA_CALL_ID).orEmpty()
        val displayName = request.extras?.getString(EXTRA_DISPLAY_NAME).orEmpty()
        val peerAddress = request.extras?.getString(EXTRA_PEER_ADDRESS).orEmpty()
        return BeamioConnection(this, callId, displayName, peerAddress, incoming = true)
    }

    override fun onCreateOutgoingConnection(
        connectionManagerPhoneAccount: PhoneAccountHandle?,
        request: ConnectionRequest,
    ): Connection {
        val callId = request.address?.schemeSpecificPart.orEmpty()
        return BeamioConnection(this, callId, "", "", incoming = false)
    }

    private class BeamioConnection(
        private val context: Context,
        private val callId: String,
        private val displayName: String,
        private val peerAddress: String,
        private val incoming: Boolean,
    ) : Connection() {
        init {
            if (callId.isNotBlank()) activeConnections[callId] = this
            if (incoming) {
                setCallerDisplayName(
                    displayName.ifBlank { peerAddress.ifBlank { "Beamio contact" } },
                    1, // Telecom PRESENTATION_ALLOWED
                )
            }
            if (incoming) setRinging() else setDialing()
        }

        override fun onAnswer() {
            setActive()
            MainActivity.dispatchSystemCallAction("callAnswered", callId, context = context)
        }

        override fun onReject() {
            setDisconnected(DisconnectCause(DisconnectCause.REJECTED))
            destroy()
            removeFromActiveConnections()
            MainActivity.dispatchSystemCallAction("callRejected", callId, context = context)
        }

        override fun onDisconnect() {
            setDisconnected(DisconnectCause(DisconnectCause.LOCAL))
            destroy()
            removeFromActiveConnections()
            MainActivity.dispatchSystemCallAction("callEnded", callId, context = context)
        }

        private fun removeFromActiveConnections() {
            if (callId.isNotBlank()) activeConnections.remove(callId, this)
        }
    }

    companion object {
        const val EXTRA_CALL_ID = "beamio.call_id"
        const val EXTRA_SESSION_ID = "beamio.session_id"
        const val EXTRA_DISPLAY_NAME = "beamio.display_name"
        const val EXTRA_PEER_ADDRESS = "beamio.peer_address"
        // PhoneAccount capability is immutable on Android/Samsung once the
        // previous self-managed account has been registered. Use a new handle
        // ID for the managed Telecom account instead of trying to mutate the
        // legacy self-managed handle during app startup.
        private const val ACCOUNT_ID = "beamio_system_phone_v2"
        private const val PHONE_SCHEME = "beamio-call"
        private const val ACTION_PREFS = "beamio_telecom_pending_action"
        private const val ACTION_KEY = "action"
        private const val CALL_ID_KEY = "call_id"
        private const val SESSION_ID_KEY = "session_id"
        private val activeConnections = ConcurrentHashMap<String, BeamioConnection>()

        fun savePendingSystemCallAction(context: Context, action: String, callId: String, sessionId: String) {
            context.getSharedPreferences(ACTION_PREFS, Context.MODE_PRIVATE).edit()
                .putString(ACTION_KEY, action)
                .putString(CALL_ID_KEY, callId)
                .putString(SESSION_ID_KEY, sessionId)
                .apply()
        }

        fun takePendingSystemCallAction(context: Context): Bundle? {
            val prefs = context.getSharedPreferences(ACTION_PREFS, Context.MODE_PRIVATE)
            val action = prefs.getString(ACTION_KEY, null) ?: return null
            val result = Bundle().apply {
                putString("action", action)
                putString("callId", prefs.getString(CALL_ID_KEY, "").orEmpty())
                putString("sessionId", prefs.getString(SESSION_ID_KEY, "").orEmpty())
            }
            prefs.edit().clear().apply()
            return result
        }

        fun clearPendingSystemCallAction(context: Context) {
            context.getSharedPreferences(ACTION_PREFS, Context.MODE_PRIVATE).edit().clear().apply()
        }

        fun phoneAccountHandle(context: Context): PhoneAccountHandle =
            PhoneAccountHandle(
                ComponentName(context, BeamioTelecomService::class.java),
                ACCOUNT_ID,
            )

        fun ensurePhoneAccount(context: Context) {
            val telecom = context.getSystemService(TelecomManager::class.java) ?: return
            val handle = phoneAccountHandle(context)
            // On some Android/Samsung builds, even reading a self-managed
            // PhoneAccount can throw even when the self-managed account is
            // usable. A failed read must not suppress registration of a new
            // incoming call account.
            try {
                val existing = telecom.getPhoneAccount(handle)
                if (existing != null &&
                    existing.capabilities and PhoneAccount.CAPABILITY_CALL_PROVIDER != 0
                ) {
                    return
                }
                // Upgrade an account created by the previous self-managed
                // implementation so Telecom can own the system call UI.
                if (existing != null) telecom.unregisterPhoneAccount(handle)
            } catch (_: SecurityException) {
                // Register below; registerPhoneAccount is idempotent.
            }
            // Use a managed Telecom account so Android's system In-Call UI owns
            // the incoming-call surface. CAPABILITY_SELF_MANAGED deliberately
            // opts out of that UI and requires the app to render its own screen.
            val account = PhoneAccount.builder(handle, "Beamio Phone")
                .setCapabilities(PhoneAccount.CAPABILITY_CALL_PROVIDER)
                .setSupportedUriSchemes(listOf(PHONE_SCHEME))
                .build()
            try {
                telecom.registerPhoneAccount(account)
            } catch (_: SecurityException) {
            } catch (_: IllegalArgumentException) {
                // Some OEM Telecom implementations reject a stale account
                // capability transition. Keep app startup alive; incoming
                // calls can use the full-screen fallback until the account is
                // enabled or repaired.
            }
        }

        fun reportIncoming(
            context: Context,
            callId: String,
            peerAddress: String,
            displayName: String,
            sessionId: String = "",
        ) {
            val nativeCallId = sessionId.ifBlank { callId }
            ensurePhoneAccount(context)
            val telecom = context.getSystemService(TelecomManager::class.java) ?: return
            val handle = phoneAccountHandle(context)
            if (!isPhoneAccountEnabled(context)) {
                showIncomingCallFallback(context, nativeCallId, peerAddress, displayName, sessionId)
                return
            }
            val extras = Bundle().apply {
                putString(EXTRA_CALL_ID, nativeCallId)
                putString(EXTRA_SESSION_ID, sessionId)
                putString(EXTRA_DISPLAY_NAME, displayName)
                putString(EXTRA_PEER_ADDRESS, peerAddress)
                putParcelable(
                    TelecomManager.EXTRA_INCOMING_CALL_ADDRESS,
                    Uri.parse("$PHONE_SCHEME:$nativeCallId"),
                )
            }
            try {
                telecom.addNewIncomingCall(handle, extras)
            } catch (_: Exception) {
                showIncomingCallFallback(context, nativeCallId, peerAddress, displayName, sessionId)
            }
        }

        fun isPhoneAccountEnabled(context: Context): Boolean {
            val telecom = context.getSystemService(TelecomManager::class.java) ?: return false
            return try {
                telecom.getPhoneAccount(phoneAccountHandle(context))?.isEnabled == true
            } catch (_: SecurityException) {
                false
            }
        }

        /**
         * Android requires the user to enable a Telecom account once; apps
         * cannot enable it programmatically.
         */
        fun openPhoneAccountSettings(context: Context) {
            val intent = Intent("android.telecom.action.CHANGE_PHONE_ACCOUNT_SETTINGS").apply {
                putExtra(
                    TelecomManager.EXTRA_PHONE_ACCOUNT_HANDLE,
                    phoneAccountHandle(context),
                )
                if (context !is android.app.Activity) {
                    addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
                }
            }
            try {
                context.startActivity(intent)
            } catch (_: Exception) {
                val fallback = Intent(android.provider.Settings.ACTION_MANAGE_DEFAULT_APPS_SETTINGS).apply {
                    if (context !is android.app.Activity) addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
                }
                runCatching { context.startActivity(fallback) }
            }
        }

        fun startOutgoing(context: Context, callId: String, handle: String) {
            ensurePhoneAccount(context)
            val telecom = context.getSystemService(TelecomManager::class.java) ?: return
            val extras = Bundle().apply {
                putParcelable(TelecomManager.EXTRA_PHONE_ACCOUNT_HANDLE, phoneAccountHandle(context))
                putString(EXTRA_CALL_ID, callId)
            }
            try {
                telecom.placeCall(Uri.parse("$PHONE_SCHEME:$callId"), extras)
            } catch (_: SecurityException) {
                MainActivity.dispatchSystemCallAction("callFailed", callId)
            }
        }

        fun end(context: Context, callId: String) {
            NotificationManagerCompat.from(context).cancel(notificationId(callId))
            val connection = activeConnections[callId]
            if (connection != null) {
                connection.setDisconnected(DisconnectCause(DisconnectCause.LOCAL))
                connection.destroy()
            } else {
                // Keep the PWA state consistent if Telecom already released it.
                MainActivity.dispatchSystemCallAction("callEnded", callId)
            }
        }

        private const val INCOMING_CALL_CHANNEL_ID = "beamio_incoming_calls"
        private val notificationIds = AtomicInteger(40_000)
        private val notificationIdByCall = ConcurrentHashMap<String, Int>()

        /** Fallback only when Telecom is unavailable or the account is disabled. */
        private fun showIncomingCallFallback(
            context: Context,
            callId: String,
            peerAddress: String,
            displayName: String,
            sessionId: String,
        ) {
            if (callId.isBlank()) return
            val manager = context.getSystemService(android.app.NotificationManager::class.java)
                ?: return
            if (android.os.Build.VERSION.SDK_INT >= android.os.Build.VERSION_CODES.O) {
                val channel = android.app.NotificationChannel(
                    INCOMING_CALL_CHANNEL_ID,
                    "Incoming calls",
                    android.app.NotificationManager.IMPORTANCE_HIGH,
                ).apply {
                    description = "Beamio voice calls"
                    lockscreenVisibility = android.app.Notification.VISIBILITY_PUBLIC
                }
                manager.createNotificationChannel(channel)
            }
            val openIntent = Intent(context, IncomingCallActivity::class.java).apply {
                action = "com.beamio.app.INCOMING_CALL"
                flags = Intent.FLAG_ACTIVITY_SINGLE_TOP or Intent.FLAG_ACTIVITY_CLEAR_TOP
                putExtra(EXTRA_CALL_ID, callId)
                putExtra(EXTRA_SESSION_ID, sessionId)
                putExtra(EXTRA_DISPLAY_NAME, displayName)
                putExtra(EXTRA_PEER_ADDRESS, peerAddress)
            }
            val pendingFlags = PendingIntent.FLAG_UPDATE_CURRENT or
                if (android.os.Build.VERSION.SDK_INT >= android.os.Build.VERSION_CODES.M) {
                    PendingIntent.FLAG_IMMUTABLE
                } else 0
            val openPendingIntent = PendingIntent.getActivity(
                context,
                notificationId(callId),
                openIntent,
                pendingFlags,
            )
            val notification = NotificationCompat.Builder(context, INCOMING_CALL_CHANNEL_ID)
                .setSmallIcon(context.applicationInfo.icon)
                .setContentTitle("Incoming Beamio voice call")
                .setContentText(displayName.ifBlank { peerAddress.ifBlank { "Beamio contact" } })
                .setCategory(NotificationCompat.CATEGORY_CALL)
                .setPriority(NotificationCompat.PRIORITY_MAX)
                .setVisibility(NotificationCompat.VISIBILITY_PUBLIC)
                .setOngoing(true)
                .setAutoCancel(false)
                .setFullScreenIntent(openPendingIntent, true)
                .setContentIntent(openPendingIntent)
                .build()
            try {
                NotificationManagerCompat.from(context).notify(notificationId(callId), notification)
            } catch (_: SecurityException) {
                // POST_NOTIFICATIONS can be denied; the in-app offer remains available.
            }
        }

        fun finishIncomingCall(context: Context, action: String, callId: String, sessionId: String) {
            NotificationManagerCompat.from(context).cancel(notificationId(callId))
            savePendingSystemCallAction(context, action, callId, sessionId)
            MainActivity.dispatchSystemCallAction(action, callId, sessionId, context)
        }

        private fun notificationId(callId: String): Int =
            notificationIdByCall.getOrPut(callId) { notificationIds.incrementAndGet() }
    }
}
