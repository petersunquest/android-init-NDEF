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
        return BeamioConnection(callId, incoming = true)
    }

    override fun onCreateOutgoingConnection(
        connectionManagerPhoneAccount: PhoneAccountHandle?,
        request: ConnectionRequest,
    ): Connection {
        val callId = request.address?.schemeSpecificPart.orEmpty()
        return BeamioConnection(callId, incoming = false)
    }

    private class BeamioConnection(
        private val callId: String,
        private val incoming: Boolean,
    ) : Connection() {
        init {
            if (callId.isNotBlank()) activeConnections[callId] = this
            connectionProperties = PROPERTY_SELF_MANAGED
            if (incoming) setRinging() else setDialing()
        }

        override fun onAnswer() {
            setActive()
            MainActivity.dispatchSystemCallAction("callAnswered", callId)
        }

        override fun onReject() {
            setDisconnected(DisconnectCause(DisconnectCause.REJECTED))
            destroy()
            removeFromActiveConnections()
            MainActivity.dispatchSystemCallAction("callRejected", callId)
        }

        override fun onDisconnect() {
            setDisconnected(DisconnectCause(DisconnectCause.LOCAL))
            destroy()
            removeFromActiveConnections()
            MainActivity.dispatchSystemCallAction("callEnded", callId)
        }

        private fun removeFromActiveConnections() {
            if (callId.isNotBlank()) activeConnections.remove(callId, this)
        }
    }

    companion object {
        const val EXTRA_CALL_ID = "beamio.call_id"
        private const val ACCOUNT_ID = "beamio_system_phone"
        private const val PHONE_SCHEME = "beamio-call"
        private val activeConnections = ConcurrentHashMap<String, BeamioConnection>()

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
                if (telecom.getPhoneAccount(handle) != null) return
            } catch (_: SecurityException) {
                // Register below; registerPhoneAccount is idempotent.
            }
            val account = PhoneAccount.builder(handle, "Beamio Phone")
                .setCapabilities(PhoneAccount.CAPABILITY_SELF_MANAGED)
                .setSupportedUriSchemes(listOf(PHONE_SCHEME))
                .build()
            try {
                telecom.registerPhoneAccount(account)
            } catch (_: SecurityException) {
            }
        }

        fun reportIncoming(context: Context, callId: String, handle: String) {
            ensurePhoneAccount(context)
            showIncomingCallFallback(context, callId, handle)
            val telecom = context.getSystemService(TelecomManager::class.java) ?: return
            val extras = Bundle().apply {
                putString(EXTRA_CALL_ID, callId)
                putParcelable(TelecomManager.EXTRA_INCOMING_CALL_ADDRESS, Uri.parse("$PHONE_SCHEME:$handle"))
            }
            try {
                telecom.addNewIncomingCall(phoneAccountHandle(context), extras)
            } catch (_: Exception) {
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

        /**
         * Self-managed Telecom accounts do not provide a vendor-independent
         * incoming-call window. Keep the PWA offer and add a full-screen call
         * notification so an incoming offer cannot degrade into a chat JSON
         * bubble when Telecom UI is unavailable or the account is disabled.
         */
        private fun showIncomingCallFallback(context: Context, callId: String, handle: String) {
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
            val openIntent = Intent(context, MainActivity::class.java).apply {
                action = "com.beamio.app.INCOMING_CALL"
                flags = Intent.FLAG_ACTIVITY_SINGLE_TOP or Intent.FLAG_ACTIVITY_CLEAR_TOP
                putExtra(EXTRA_CALL_ID, callId)
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
                .setContentText(handle.ifBlank { "Beamio contact" })
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

        private fun notificationId(callId: String): Int =
            notificationIdByCall.getOrPut(callId) { notificationIds.incrementAndGet() }
    }
}
