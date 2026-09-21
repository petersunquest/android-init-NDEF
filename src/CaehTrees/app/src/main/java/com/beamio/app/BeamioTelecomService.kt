package com.beamio.app

import android.content.ComponentName
import android.content.Context
import android.net.Uri
import android.os.Bundle
import android.telecom.Connection
import android.telecom.ConnectionRequest
import android.telecom.ConnectionService
import android.telecom.DisconnectCause
import android.telecom.PhoneAccount
import android.telecom.PhoneAccountHandle
import android.telecom.TelecomManager
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
            // PhoneAccount requires READ_PHONE_NUMBERS. Telecom is optional
            // for the app shell, so never let this capability crash startup.
            try {
                if (telecom.getPhoneAccount(handle) != null) return
            } catch (_: SecurityException) {
                return
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
            val telecom = context.getSystemService(TelecomManager::class.java) ?: return
            val extras = Bundle().apply {
                putString(EXTRA_CALL_ID, callId)
                putParcelable(TelecomManager.EXTRA_INCOMING_CALL_ADDRESS, Uri.parse("$PHONE_SCHEME:$handle"))
            }
            try {
                telecom.addNewIncomingCall(phoneAccountHandle(context), extras)
            } catch (_: SecurityException) {
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
            val connection = activeConnections[callId]
            if (connection != null) {
                connection.setDisconnected(DisconnectCause(DisconnectCause.LOCAL))
                connection.destroy()
            } else {
                // Keep the PWA state consistent if Telecom already released it.
                MainActivity.dispatchSystemCallAction("callEnded", callId)
            }
        }
    }
}
