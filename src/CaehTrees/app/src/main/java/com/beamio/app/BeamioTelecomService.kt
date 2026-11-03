package com.beamio.app

import android.app.Notification
import android.app.PendingIntent
import android.content.ComponentName
import android.content.Context
import android.content.Intent
import android.graphics.Bitmap
import android.graphics.BitmapFactory
import android.graphics.Canvas
import android.graphics.Color
import android.graphics.Paint
import android.graphics.PorterDuff
import android.graphics.PorterDuffXfermode
import android.graphics.Rect
import android.net.Uri
import android.os.Build
import android.os.Bundle
import android.os.Handler
import android.os.Looper
import android.os.SystemClock
import android.telecom.Connection
import android.telecom.ConnectionRequest
import android.telecom.ConnectionService
import android.telecom.DisconnectCause
import android.telecom.PhoneAccount
import android.telecom.PhoneAccountHandle
import android.telecom.TelecomManager
import android.util.Log
import androidx.core.app.NotificationCompat
import androidx.core.app.NotificationManagerCompat
import androidx.core.app.Person
import androidx.core.graphics.drawable.IconCompat
import org.json.JSONObject
import java.net.HttpURLConnection
import java.net.URL
import java.net.URLEncoder
import java.util.concurrent.ConcurrentHashMap

class BeamioTelecomService : ConnectionService() {
    override fun onCreateIncomingConnection(
        connectionManagerPhoneAccount: PhoneAccountHandle?,
        request: ConnectionRequest,
    ): Connection {
        val callId = request.extras?.getString(EXTRA_CALL_ID).orEmpty()
        val originalCallId = request.extras?.getString(EXTRA_ORIGINAL_CALL_ID).orEmpty()
        val sessionId = request.extras?.getString(EXTRA_SESSION_ID).orEmpty()
        restoreSettledIncoming(this)
        val requestedCaller = ShownCaller(
            peerAddress = request.extras?.getString(EXTRA_PEER_ADDRESS).orEmpty(),
            displayName = request.extras?.getString(EXTRA_DISPLAY_NAME).orEmpty(),
            claimedTag = request.extras?.getString(EXTRA_CLAIMED_TAG).orEmpty(),
            claimedAddress = request.extras?.getString(EXTRA_CLAIMED_ADDRESS).orEmpty(),
            identityWarning = request.extras?.getString(EXTRA_IDENTITY_WARNING).orEmpty(),
        )
        // reportIncoming() can arrive before Telecom creates this connection.
        // The caller pool keeps the verified PWA identity until Telecom asks
        // for the connection; there is no generic native/FCM caller fallback.
        val lookupKeys = callerLookupKeys(callId, originalCallId, sessionId, request.address)
        // One Telecom call per offer. A second addNewIncomingCall for the same
        // offer used to replace the first in activeConnections; the replaced
        // one was never disconnected and stayed RINGING, which then failed the
        // next outgoing placeCall (createConnectionFailed, no ringback).
        val existing = listOf(callId, originalCallId, sessionId)
            .filter { it.isNotBlank() }
            .firstNotNullOfOrNull { activeConnections[it] }
        if (existing != null && existing.isLiveIncoming()) {
            Log.i(TAG, "createConnection duplicate for a ringing call; returning a failed connection")
            return Connection.createFailedConnection(DisconnectCause(DisconnectCause.CANCELED))
        }
        // Caller cancelled / declined / timed out before Telecom got here: no
        // ringing row (answering it would open a call with no peer).
        if (isIncomingCancelled(callId, originalCallId, sessionId)) {
            Log.i(TAG, "createConnection for an incoming call that already ended; returning a failed connection")
            return Connection.createFailedConnection(DisconnectCause(DisconnectCause.CANCELED))
        }
        val answeredBeforeTelecom = isIncomingAnsweredAny(callId, originalCallId, sessionId)
        val caller = resolvePendingCaller(this, lookupKeys, requestedCaller)
        Log.i(
            TAG,
            "createConnection callIdPresent=${callId.isNotBlank()} " +
                "originalCallIdPresent=${originalCallId.isNotBlank()} " +
                "sessionIdPresent=${sessionId.isNotBlank()} " +
                "shownCallerHit=${lookupKeys.any { shownCallers.containsKey(it) }} " +
                "displayNamePresent=${caller.displayName.isNotBlank()}",
        )
        val displayName = caller.displayName
        val peerAddress = caller.peerAddress
        val claimedTag = caller.claimedTag
        val claimedAddress = caller.claimedAddress
        val identityWarning = caller.identityWarning
        val connection = BeamioConnection(
            this, callId, displayName, peerAddress, sessionId,
            claimedTag, claimedAddress, identityWarning,
            originalCallId = originalCallId,
            incoming = true,
        )
        if (answeredBeforeTelecom) {
            // Answer won the race with Telecom. Promote right after Telecom takes
            // the connection; onShowIncomingCallUi will not show a banner for it.
            Log.i(TAG, "createConnection for an already answered call; setActive")
            Handler(Looper.getMainLooper()).post {
                if (connection.state == Connection.STATE_RINGING) {
                    runCatching { connection.setActive() }
                        .onFailure { Log.w(TAG, "setActive after early answer: ${it.message}") }
                }
            }
        }
        return connection
    }

    /**
     * Telecom rejected the incoming Connection (OEM WAITING_CALL zombies, too many
     * self-managed RINGING, etc.). Without this override the offer stays silent:
     * reportIncoming armed the ring clock and deferred glass to onShowIncomingCallUi,
     * which never runs — CallStyle/FSI and IncomingCallActivity never arm.
     */
    override fun onCreateIncomingConnectionFailed(
        connectionManagerPhoneAccount: PhoneAccountHandle?,
        request: ConnectionRequest,
    ) {
        val callId = request.extras?.getString(EXTRA_CALL_ID).orEmpty()
        val originalCallId = request.extras?.getString(EXTRA_ORIGINAL_CALL_ID).orEmpty()
        val sessionId = request.extras?.getString(EXTRA_SESSION_ID).orEmpty()
        Log.w(
            TAG,
            "createConnectionFailed → CallStyle/glass fallback " +
                "callIdPresent=${callId.isNotBlank()} " +
                "originalCallIdPresent=${originalCallId.isNotBlank()} " +
                "sessionIdPresent=${sessionId.isNotBlank()}",
        )
        fallBackIncomingWithoutTelecom(
            this,
            telecomCallId = callId,
            originalCallId = originalCallId,
            sessionId = sessionId,
            requestExtras = request.extras,
        )
    }

    override fun onCreateOutgoingConnection(
        connectionManagerPhoneAccount: PhoneAccountHandle?,
        request: ConnectionRequest,
    ): Connection {
        val callId = request.address?.schemeSpecificPart.orEmpty()
        BeamioCallTiming.mark("telecom-onCreateOutgoingConnection")
        // The status-bar call chip only appears for a CallStyle ongoing notification.
        BeamioCallForegroundService.showOngoingCall(this, callId, "")
        return BeamioConnection(this, callId, "", "", "", incoming = false)
    }

    private class BeamioConnection(
        private val context: Context,
        private val callId: String,
        private val displayName: String,
        private val peerAddress: String,
        private val sessionId: String,
        private val claimedTag: String = "",
        private val claimedAddress: String = "",
        private val identityWarning: String = "",
        private val originalCallId: String = "",
        private val incoming: Boolean,
    ) : Connection() {
        private var disconnectAcknowledged = false

        /** An incoming call Telecom still holds (ringing or answered). */
        fun isLiveIncoming(): Boolean = incoming && state != STATE_DISCONNECTED

        init {
            connectionProperties = PROPERTY_SELF_MANAGED
            audioModeIsVoip = true
            if (callId.isNotBlank()) activeConnections[callId] = this
            if (incoming) {
                setCallerDisplayName(
                    displayName.ifBlank { peerAddress.ifBlank { "Beamio contact" } },
                    TelecomManager.PRESENTATION_ALLOWED,
                )
            }
            if (incoming) {
                setRinging()
            } else {
                setDialing()
                BeamioCallTonePlayer.onOutgoingConnectionDialing()
            }
        }

        override fun onStateChanged(state: Int) {
            super.onStateChanged(state)
            if (!incoming && (state == STATE_ACTIVE || state == STATE_HOLDING || state == STATE_DISCONNECTED)) {
                BeamioCallTonePlayer.stopRingback("telecom-state-$state")
            }
        }

        fun isIncomingCall(): Boolean = incoming

        fun occupiesVoiceChrome(): Boolean {
            return state == STATE_RINGING ||
                state == STATE_DIALING ||
                state == STATE_ACTIVE ||
                state == STATE_HOLDING
        }

        fun identityKeys(): Set<String> {
            return listOf(callId, sessionId, originalCallId)
                .map { it.trim() }
                .filter { it.isNotEmpty() }
                .toSet()
        }

        fun setActiveKeepingWebViewMic(handler: Handler) {
            setActive()
            Log.i(
                "BeamioVoiceCall",
                "setActive callId=$callId handler=${handler.hashCode()}",
            )
        }

            override fun onShowIncomingCallUi() {
            // Ringing still uses the incoming card. Once the call is up, the
            // status-bar chip must return to the in-app call page.
            val stillRinging = incoming && state == STATE_RINGING
            if (!stillRinging) {
                openActiveCallScreen(context, callId, sessionId)
                return
            }
            Log.i(TAG, "onShowIncomingCallUi RINGING callIdPresent=${callId.isNotBlank()}")
            // Connection is RINGING — BAL exemption is live only on this binder
            // call stack. Present glass *first* (sync), then arm CallStyle shade.
            // Do not Handler.post — posting loses REASON_SELF_MANAGED_CONNECTION_SERVICE.
            showIncomingCallNotification(
                context, callId, peerAddress, displayName, sessionId,
                claimedTag, claimedAddress, identityWarning,
            )
        }

        fun updateCallerDisplayName(name: String) {
            if (!incoming || name.isBlank()) return
            setCallerDisplayName(name, TelecomManager.PRESENTATION_ALLOWED)
        }

        /** Endpoints Telecom offers for this call (Android 14+). */
        @Volatile private var availableEndpoints: List<android.telecom.CallEndpoint> = emptyList()

        override fun onAvailableCallEndpointsChanged(endpoints: MutableList<android.telecom.CallEndpoint>) {
            availableEndpoints = endpoints.toList()
        }

        /**
         * Speaker on/off for a self-managed call. Telecom owns the audio route,
         * so AudioManager.setSpeakerphoneOn is ignored; ask Telecom instead.
         */
        fun setSpeaker(on: Boolean): Boolean {
            if (Build.VERSION.SDK_INT >= 34) {
                val wantType = if (on) {
                    android.telecom.CallEndpoint.TYPE_SPEAKER
                } else {
                    android.telecom.CallEndpoint.TYPE_EARPIECE
                }
                val endpoint = availableEndpoints.firstOrNull { it.endpointType == wantType }
                    ?: if (!on) {
                        // No earpiece (e.g. headset only): take any non-speaker route.
                        availableEndpoints.firstOrNull {
                            it.endpointType != android.telecom.CallEndpoint.TYPE_SPEAKER
                        }
                    } else {
                        null
                    }
                if (endpoint != null) {
                    requestCallEndpointChange(
                        endpoint,
                        java.util.concurrent.Executors.newSingleThreadExecutor(),
                        object : android.os.OutcomeReceiver<Void, android.telecom.CallEndpointException> {
                            override fun onResult(result: Void?) {
                                Log.i(TAG, "speaker=$on endpoint changed")
                            }

                            override fun onError(error: android.telecom.CallEndpointException) {
                                Log.w(TAG, "speaker=$on endpoint change failed: ${error.message}")
                            }
                        },
                    )
                    return true
                }
                Log.w(TAG, "speaker=$on no matching endpoint (available=${availableEndpoints.size})")
            }
            Log.i(TAG, "speaker=$on via setAudioRoute")
            @Suppress("DEPRECATION")
            setAudioRoute(
                if (on) android.telecom.CallAudioState.ROUTE_SPEAKER
                else android.telecom.CallAudioState.ROUTE_WIRED_OR_EARPIECE,
            )
            return true
        }

        /** Mark disconnect as already handled so onDisconnect will not emit callEnded. */
        fun acknowledgeQuietDisconnect() {
            disconnectAcknowledged = true
        }

        override fun onAnswer() {
            completeIncomingUserAction(context, "callAnswered", callId, sessionId, fromTelecom = true)
        }

        override fun onReject() {
            completeIncomingUserAction(context, "callRejected", callId, sessionId, fromTelecom = true)
        }

        override fun onDisconnect() {
            if (disconnectAcknowledged) return
            disconnectAcknowledged = true
            if (!incoming) {
                completeIncomingUserAction(context, "callEnded", callId, sessionId, fromTelecom = true)
                return
            }
            if (incomingActionAlreadySettled(callId, sessionId)) return
            // Telecom drops an unanswered self-managed call at about 120s.
            // Keep the banner up until the 180s app clock, then tell the caller.
            if (incomingRingShouldRearm(callId, sessionId)) {
                activeConnections.remove(callId, this)
                setDisconnected(DisconnectCause(DisconnectCause.MISSED))
                destroy()
                Handler(Looper.getMainLooper()).post {
                    rearmIncomingRing(context, callId, originalCallId, sessionId)
                }
                return
            }
            val action = if (incomingRingClock(callId, sessionId) != null) "callTimedOut" else "callEnded"
            completeIncomingUserAction(context, action, callId, sessionId, fromTelecom = true)
        }
    }

    companion object {
        const val EXTRA_CALL_ID = "beamio.call_id"
        const val EXTRA_ORIGINAL_CALL_ID = "beamio.original_call_id"
        const val EXTRA_SESSION_ID = "beamio.session_id"
        const val EXTRA_DISPLAY_NAME = "beamio.display_name"
        const val EXTRA_PEER_ADDRESS = "beamio.peer_address"
        const val EXTRA_CLAIMED_TAG = "beamio.claimed_tag"
        const val EXTRA_CLAIMED_ADDRESS = "beamio.claimed_address"
        const val EXTRA_IDENTITY_WARNING = "beamio.identity_warning"
        const val EXTRA_INCOMING_TITLE = "beamio.incoming_title"
        const val EXTRA_INCOMING_BODY = "beamio.incoming_body"
        const val EXTRA_WAKE_FOR_CALL = "beamio.wake_for_call"
        const val EXTRA_SHOW_ACTIVE_CALL = "beamio.show_active_call"
        // Self-managed VoIP account. Stock dialer UI is default-dialer only;
        // Glass IncomingCallActivity is the only visible incoming-call card.
        private const val ACCOUNT_ID = "beamio_system_phone_v3"
        private const val PHONE_SCHEME = "beamio-call"
        private const val ACTION_PREFS = "beamio_telecom_pending_action"
        private const val ACTION_KEY = "action"
        private const val CALL_ID_KEY = "call_id"
        private const val SESSION_ID_KEY = "session_id"
        private const val CALLER_POOL_PREFS = "beamio_pending_caller_pool_v1"
        private const val CALLER_POOL_TTL_MS = 2 * 60 * 1000L
        private val activeConnections = ConcurrentHashMap<String, BeamioConnection>()

        /**
         * Route the live call to the speaker (or back). Returns false when no
         * Telecom connection is live, so the caller can fall back to AudioManager.
         */
        fun setSpeaker(on: Boolean): Boolean {
            val all = activeConnections.values.distinct()
            val live = all.filter { it.occupiesVoiceChrome() }
            Log.i(
                TAG,
                "setSpeaker on=$on connections=${all.size} live=${live.size} " +
                    "states=${all.joinToString(",") { it.state.toString() }}",
            )
            if (live.isEmpty()) return false
            live.forEach { runCatching { it.setSpeaker(on) } }
            return true
        }
        // FCM may create the Telecom call before the PWA has verified the
        // caller. Keep a process-local submission set so the later verified
        // report only updates the existing call instead of submitting a
        // second self-managed call (which OEM Telecom rejects as a duplicate
        // ringing call).
        private val submittedIncomingCalls = ConcurrentHashMap.newKeySet<String>()
        /** Ids that already own the glass window or the live call. Claimed before the Activity exists. */
        private val claimedChromeKeys = ConcurrentHashMap.newKeySet<String>()
        private val busyRejectKeys = ConcurrentHashMap.newKeySet<String>()
        private val chromeGate = Any()
        // Answer → setActive must wait until the PWA has opened getUserMedia.
        // Fixed 3.5s was too short when route/PGP/acceptIncoming exceeded that
        // window: MODE_IN_COMMUNICATION then made WebView report NotFound.
        private const val SET_ACTIVE_FALLBACK_MS = 12_000L
        private val setActiveHandler = Handler(Looper.getMainLooper())
        private val pendingSetActive = ConcurrentHashMap<String, Runnable>()

        private fun setActiveLookupKeys(callId: String, sessionId: String): List<String> =
            listOf(callId, sessionId).map { it.trim() }.filter { it.isNotEmpty() }.distinct()

        private fun cancelPendingSetActive(callId: String, sessionId: String) {
            for (key in setActiveLookupKeys(callId, sessionId)) {
                pendingSetActive.remove(key)?.let { setActiveHandler.removeCallbacks(it) }
            }
        }

        private fun scheduleDeferredSetActive(
            callId: String,
            sessionId: String,
            connection: BeamioConnection,
        ) {
            cancelPendingSetActive(callId, sessionId)
            val keys = setActiveLookupKeys(callId, sessionId)
            if (keys.isEmpty()) return
            val runnable = Runnable {
                for (key in keys) pendingSetActive.remove(key)
                try {
                    val state = connection.state
                    if (state == Connection.STATE_DISCONNECTED || state == Connection.STATE_ACTIVE) {
                        return@Runnable
                    }
                    connection.setActiveKeepingWebViewMic(setActiveHandler)
                    Log.i(
                        TAG,
                        "callAnswered setActive fallback after ${SET_ACTIVE_FALLBACK_MS}ms callId=$callId",
                    )
                } catch (error: Exception) {
                    Log.w(TAG, "Deferred setActive fallback failed: ${error.message}")
                }
            }
            for (key in keys) pendingSetActive[key] = runnable
            setActiveHandler.postDelayed(runnable, SET_ACTIVE_FALLBACK_MS)
        }

        /**
         * PWA opened the mic successfully — promote Telecom to ACTIVE now
         * (MODE_IN_COMMUNICATION) and cancel the fallback timer.
         */
        fun notifyVoiceMicReady(callId: String, sessionId: String) {
            cancelPendingSetActive(callId, sessionId)
            val connection =
                setActiveLookupKeys(callId, sessionId)
                    .firstNotNullOfOrNull { activeConnections[it] }
            if (connection == null) {
                Log.w(TAG, "notifyVoiceMicReady: no connection callId=$callId sessionId=$sessionId")
                return
            }
            try {
                val state = connection.state
                if (state == Connection.STATE_DISCONNECTED || state == Connection.STATE_ACTIVE) {
                    Log.i(TAG, "notifyVoiceMicReady: already state=$state callId=$callId")
                    return
                }
                connection.setActiveKeepingWebViewMic(setActiveHandler)
                Log.i(TAG, "notifyVoiceMicReady setActive callId=$callId sessionId=$sessionId")
            } catch (error: Exception) {
                Log.w(TAG, "notifyVoiceMicReady setActive failed: ${error.message}")
            }
        }

        fun savePendingSystemCallAction(context: Context, action: String, callId: String, sessionId: String) {
            context.getSharedPreferences(ACTION_PREFS, Context.MODE_PRIVATE).edit()
                .putString(ACTION_KEY, action)
                .putString(CALL_ID_KEY, callId)
                .putString(SESSION_ID_KEY, sessionId)
                .apply()
        }

        fun peekPendingSystemCallAction(context: Context): Bundle? {
            val prefs = context.getSharedPreferences(ACTION_PREFS, Context.MODE_PRIVATE)
            val action = prefs.getString(ACTION_KEY, null) ?: return null
            return Bundle().apply {
                putString("action", action)
                putString("callId", prefs.getString(CALL_ID_KEY, "").orEmpty())
                putString("sessionId", prefs.getString(SESSION_ID_KEY, "").orEmpty())
            }
        }

        fun takePendingSystemCallAction(context: Context): Bundle? {
            val result = peekPendingSystemCallAction(context) ?: return null
            clearPendingSystemCallAction(context)
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
            try {
                val existing = telecom.getPhoneAccount(handle)
                // Self-managed VoIP (not CAPABILITY_CALL_PROVIDER / default dialer).
                if (existing != null &&
                    existing.capabilities and PhoneAccount.CAPABILITY_SELF_MANAGED != 0
                ) {
                    return
                }
                if (existing != null) telecom.unregisterPhoneAccount(handle)
            } catch (_: SecurityException) {
                // Register below; registerPhoneAccount is idempotent.
            }
            registerSelfManagedPhoneAccount(telecom, handle)
        }

        /**
         * Unregister + re-register so Telecom drops orphan RINGING / WAITING_CALL
         * rows that no longer map to a live [Connection] in this process (common
         * after forceClear / install-over when Samsung kept zombies).
         */
        fun resetSelfManagedPhoneAccount(context: Context) {
            val telecom = context.getSystemService(TelecomManager::class.java) ?: return
            val handle = phoneAccountHandle(context)
            runCatching {
                telecom.unregisterPhoneAccount(handle)
                Log.i(TAG, "PhoneAccount unregistered to clear Telecom RINGING orphans")
            }.onFailure {
                Log.w(TAG, "PhoneAccount unregister failed: ${it.message}")
            }
            registerSelfManagedPhoneAccount(telecom, handle)
        }

        private fun registerSelfManagedPhoneAccount(
            telecom: TelecomManager,
            handle: PhoneAccountHandle,
        ) {
            val account = PhoneAccount.builder(handle, "Beamio Phone")
                .setCapabilities(PhoneAccount.CAPABILITY_SELF_MANAGED)
                .setSupportedUriSchemes(listOf(PHONE_SCHEME))
                .build()
            try {
                telecom.registerPhoneAccount(account)
                Log.i(TAG, "PhoneAccount registered self-managed")
            } catch (error: SecurityException) {
                Log.w(TAG, "PhoneAccount registration denied by Telecom", error)
            } catch (error: IllegalArgumentException) {
                Log.w(TAG, "PhoneAccount registration rejected by OEM Telecom", error)
            }
        }

        internal data class ShownCaller(
            val peerAddress: String,
            val displayName: String,
            val claimedTag: String,
            val claimedAddress: String,
            val identityWarning: String,
        )

        private val shownCallers = java.util.concurrent.ConcurrentHashMap<String, ShownCaller>()

        private fun keepShownCaller(
            context: Context,
            callKey: String,
            peerAddress: String,
            displayName: String,
            claimedTag: String,
            claimedAddress: String,
            identityWarning: String,
        ): ShownCaller {
            val previous = shownCallers[callKey]
            val generic = isGenericCallerName(displayName) || isWalletAddress(displayName)
            val previousTag = previous?.displayName?.takeIf(::isBeamioTag)
                ?: previous?.claimedTag?.takeIf(::isBeamioTag)
            val mergedDisplay = when {
                isBeamioTag(displayName) -> displayName.trim()
                previousTag != null && generic -> previousTag
                generic -> previous?.displayName?.takeUnless(::isGenericCallerName) ?: displayName
                else -> displayName
            }
            val mergedClaimed = when {
                isBeamioTag(claimedTag) -> claimedTag.trim()
                isBeamioTag(mergedDisplay) -> mergedDisplay.trim()
                else -> claimedTag.ifBlank { previous?.claimedTag.orEmpty() }
            }
            val merged = ShownCaller(
                peerAddress = peerAddress.ifBlank { previous?.peerAddress.orEmpty() },
                displayName = mergedDisplay,
                claimedTag = mergedClaimed,
                claimedAddress = claimedAddress.ifBlank { previous?.claimedAddress.orEmpty() },
                identityWarning = identityWarning.ifBlank { previous?.identityWarning.orEmpty() },
            )
            shownCallers[callKey] = merged
            if (callKey.isNotBlank()) {
                context.getSharedPreferences(CALLER_POOL_PREFS, Context.MODE_PRIVATE)
                    .edit()
                    .putString(
                        callKey,
                        JSONObject()
                            .put("peerAddress", merged.peerAddress)
                            .put("displayName", merged.displayName)
                            .put("claimedTag", merged.claimedTag)
                            .put("claimedAddress", merged.claimedAddress)
                            .put("identityWarning", merged.identityWarning)
                            .put("expiresAt", System.currentTimeMillis() + CALLER_POOL_TTL_MS)
                            .toString(),
                    )
                    .apply()
            }
            return merged
        }

        private fun callerLookupKeys(
            callId: String,
            originalCallId: String,
            sessionId: String,
            address: Uri?,
        ): List<String> {
            val uriKey = address?.schemeSpecificPart.orEmpty()
            return listOf(callId, originalCallId, sessionId, uriKey)
                .map(String::trim)
                .filter(String::isNotBlank)
                .distinct()
        }

        internal fun resolvePendingCaller(
            context: Context,
            keys: List<String>,
            fallback: ShownCaller = ShownCaller("", "", "", "", ""),
        ): ShownCaller {
            val cached = keys.asSequence()
                .mapNotNull { shownCallers[it] }
                .firstOrNull()
            val persisted = if (cached == null) {
                val prefs = context.getSharedPreferences(CALLER_POOL_PREFS, Context.MODE_PRIVATE)
                keys.asSequence().mapNotNull { key ->
                    val raw = prefs.getString(key, null) ?: return@mapNotNull null
                    val json = runCatching { JSONObject(raw) }.getOrNull() ?: return@mapNotNull null
                    if (json.optLong("expiresAt", 0L) < System.currentTimeMillis()) {
                        prefs.edit().remove(key).apply()
                        return@mapNotNull null
                    }
                    ShownCaller(
                        peerAddress = json.optString("peerAddress"),
                        displayName = json.optString("displayName"),
                        claimedTag = json.optString("claimedTag"),
                        claimedAddress = json.optString("claimedAddress"),
                        identityWarning = json.optString("identityWarning"),
                    )
                }.firstOrNull()
            } else null
            val stored = cached ?: persisted ?: return fallback
            val fallbackGeneric = isGenericCallerName(fallback.displayName) || isWalletAddress(fallback.displayName)
            val cachedGeneric = isGenericCallerName(stored.displayName) || isWalletAddress(stored.displayName)
            val displayName = when {
                isBeamioTag(fallback.displayName) -> fallback.displayName.trim()
                isBeamioTag(stored.displayName) -> stored.displayName.trim()
                !cachedGeneric || fallbackGeneric -> stored.displayName.ifBlank { fallback.displayName }
                else -> fallback.displayName
            }
            val claimed = when {
                isBeamioTag(fallback.claimedTag) -> fallback.claimedTag.trim()
                isBeamioTag(stored.claimedTag) -> stored.claimedTag.trim()
                isBeamioTag(displayName) -> displayName.trim()
                isBeamioTag(fallback.displayName) -> fallback.displayName.trim()
                else -> stored.claimedTag.ifBlank { fallback.claimedTag }
            }
            return ShownCaller(
                peerAddress = stored.peerAddress.ifBlank { fallback.peerAddress },
                displayName = displayName,
                claimedTag = claimed,
                claimedAddress = stored.claimedAddress.ifBlank { fallback.claimedAddress },
                identityWarning = stored.identityWarning.ifBlank { fallback.identityWarning },
            )
        }

        fun pendingCallerKeys(
            callId: String,
            originalCallId: String,
            sessionId: String,
            address: Uri? = null,
        ): List<String> = callerLookupKeys(callId, originalCallId, sessionId, address)

        /**
         * Store a verified PWA caller even when the full-screen activity has
         * not been created yet. The next activity render resolves this pool.
         */
        internal fun rememberShownCaller(
            context: Context,
            callKey: String,
            peerAddress: String,
            displayName: String,
            claimedTag: String = "",
            claimedAddress: String = "",
            identityWarning: String = "",
        ): ShownCaller = keepShownCaller(
            context,
            callKey,
            peerAddress,
            displayName,
            claimedTag,
            claimedAddress,
            identityWarning,
        )

        fun wasBusyRejected(callId: String, sessionId: String): Boolean {
            val key = busyKey(callId, sessionId)
            return key.isNotEmpty() && busyRejectKeys.contains(key)
        }

        /**
         * Live chrome the user can see or hear — not leftover claim keys alone.
         * Orphan [claimedChromeKeys] without this must not busy-reject the next dial.
         */
        private fun hasLiveVoiceChrome(): Boolean {
            // claimedChromeKeys alone is NOT live chrome — BAL Abort can leave
            // ownership claimed with no glass, which then busy-rejects later dials.
            if (IncomingCallActivity.isShowing()) return true
            if (BeamioNativeVoiceSignaling.currentActiveCall() != null) return true
            // RINGING / DIALING without glass is orphan sticky chrome (BAL Abort
            // after rememberChromeOwner). Do not treat it as busy for the next dial.
            return activeConnections.values.any { it.hasVisibleOrConnectedChrome() }
        }

        /**
         * True when a connection should block a second dial: active/holding always,
         * ringing/dialing only while the glass window is actually showing.
         */
        private fun BeamioConnection.hasVisibleOrConnectedChrome(): Boolean {
            return when (state) {
                Connection.STATE_ACTIVE, Connection.STATE_HOLDING -> true
                Connection.STATE_RINGING, Connection.STATE_DIALING -> IncomingCallActivity.isShowing()
                else -> false
            }
        }

        /** Glass window, answered call, or a claim made before either exists. */
        fun hasStickyVoiceChrome(): Boolean {
            if (hasLiveVoiceChrome()) return true
            return claimedChromeKeys.isNotEmpty()
        }

        /** A call rings, dials or is up: the chat mailbox listen stays connected meanwhile. */
        fun isCallInProgress(): Boolean =
            activeConnections.isNotEmpty() || hasStickyVoiceChrome() ||
                InCallScreenModel.isLive() || BeamioNativeVoiceSignaling.currentActiveCall() != null

        /** This device still has a Telecom call, call chrome or a native call for one of [ids]. */
        fun isLiveCall(vararg ids: String): Boolean {
            val keys = ids.map { it.trim() }.filter { it.isNotEmpty() }
            if (keys.isEmpty()) return false
            if (keys.any {
                    activeConnections.containsKey(it) || claimedChromeKeys.contains(it) ||
                        submittedIncomingCalls.contains(it)
                }
            ) return true
            if (InCallScreenModel.isLive()) {
                val st = InCallScreenModel.snapshot()
                if (keys.any { it == st.callId || it == st.sessionId }) return true
            }
            val cur = BeamioNativeVoiceSignaling.currentActiveCall() ?: return false
            return keys.any { it == cur.offer.callId || it == cur.offer.sessionId || it == cur.listenSessionId }
        }

        /**
         * Keyguard / lock / screen-off: overlay cannot appear above it; CallStyle
         * FSI (USE_FULL_SCREEN_INTENT) must own the lock UI.
         *
         * Screen-off race: after KEYCODE_SLEEP, [KeyguardManager.isKeyguardLocked]
         * can still be false briefly while the panel is non-interactive. Treat
         * !isInteractive as lock UI so we never demote CallStyle to quiet keep-alive
         * before the keyguard fully engages (Samsung lock = no Beamio incoming).
         */
        fun isDeviceKeyguardLocked(context: Context): Boolean {
            val app = context.applicationContext
            val pm = app.getSystemService(android.os.PowerManager::class.java)
            val interactive = runCatching { pm?.isInteractive }.getOrNull()
            if (interactive == false) return true
            val km = app.getSystemService(android.app.KeyguardManager::class.java)
                ?: return false
            return runCatching {
                if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.LOLLIPOP_MR1) {
                    km.isDeviceLocked || km.isKeyguardLocked
                } else {
                    @Suppress("DEPRECATION")
                    km.inKeyguardRestrictedInputMode()
                }
            }.getOrDefault(false)
        }

        /**
         * Product glass is actually on-screen (Activity or attached overlay).
         * [IncomingCallOverlay.canPresent] is only SYSTEM_ALERT_WINDOW permission —
         * using it as "chrome up" skips CallStyle under the keyguard and leaves a
         * quiet keep-alive with no Answer button (lock-screen answer dead).
         * Overlay [IncomingCallOverlay.isShowing] under keyguard is a lie — the
         * window attaches but is invisible; never treat it as chrome then.
         *
         * Under keyguard / screen-off: always false. [IncomingCallActivity] may
         * report isShowing while occluded behind Samsung keyguard; demoting
         * CallStyle then leaves the lock screen with no Beamio incoming UI.
         */
        private fun productIncomingChromeVisible(context: Context? = null): Boolean {
            val app = context?.applicationContext
            if (app != null && isDeviceKeyguardLocked(app)) return false
            if (IncomingCallActivity.isShowing()) return true
            return IncomingCallOverlay.isShowing()
        }

        /**
         * Debug / smoke only: wipe sticky chrome so the next dial is not
         * busy-rejected by orphan claimed keys, ACTIVE connections, or keep-alive
         * notifications left after a failed BAL / lock-screen arm.
         */
        fun forceClearStickyVoiceStateForSmoke(context: Context) {
            val app = context.applicationContext
            Log.i(TAG, "forceClearStickyVoiceStateForSmoke begin")
            runCatching {
                activeConnections.values.toList().forEach { conn ->
                    runCatching {
                        conn.setDisconnected(DisconnectCause(DisconnectCause.LOCAL))
                        conn.destroy()
                    }
                }
                activeConnections.clear()
            }
            claimedChromeKeys.clear()
            busyRejectKeys.clear()
            submittedIncomingCalls.clear()
            settledCallActions.clear()
            runCatching {
                app.getSharedPreferences(SETTLED_PREFS, Context.MODE_PRIVATE).edit().clear().apply()
            }
            armedCallStyleKeys.clear()
            lastArmedCallStyleTitle.clear()
            mutedIncomingKeys.clear()
            incomingRingClocks.keys.toList().forEach { key ->
                incomingRingClocks.remove(key)?.runnable?.let { incomingRingHandler.removeCallbacks(it) }
            }
            BeamioNativeVoiceSignaling.clearActiveCall()
            InCallScreenModel.end()
            runCatching { IncomingCallActivity.finishIfShowing() }
            runCatching { IncomingCallOverlay.dismiss() }
            runCatching { InCallActivity.finishIfShowing() }
            BeamioCallForegroundService.stop(app)
            runCatching {
                val nm = NotificationManagerCompat.from(app)
                nm.cancelAll()
            }
            // Drop Telecom-framework RINGING / WAITING_CALL orphans that are not
            // in our process map — otherwise the next addNewIncomingCall fails
            // with createConnectionFailed and lock-screen glass never arms.
            resetSelfManagedPhoneAccount(app)
            Log.i(TAG, "forceClearStickyVoiceStateForSmoke done")
        }

        /** Drop busy-reject marks that mention any of [ids] (callId / sessionId aliases). */
        private fun clearBusyRejectForIds(ids: Collection<String>) {
            val needles = ids.map { it.trim() }.filter { it.isNotEmpty() }.toSet()
            if (needles.isEmpty()) return
            busyRejectKeys.removeIf { key ->
                needles.any { id ->
                    key == id || key.startsWith("$id|") || key.endsWith("|$id") || key.contains("|$id|")
                }
            }
        }

        /**
         * True when [callId]/[sessionId] are a different call from the one that
         * already owns the window. The same id is a tag refresh and must update
         * the first window.
         */
        fun anotherCallOwnsChrome(callId: String, sessionId: String, extra: String = ""): Boolean {
            if (!hasStickyVoiceChrome()) return false
            val incoming = listOf(callId, sessionId, extra)
                .map { it.trim() }
                .filter { it.isNotEmpty() }
                .toSet()
            val primary = primaryVoiceCallKeys()
            if (incoming.isEmpty() || primary.isEmpty()) return true
            return incoming.none { primary.contains(it) }
        }

        /**
         * Second incoming while the first window or an active call is up.
         * Does not present, ring, arm a timeout, or open the encryption WebView.
         */
        fun rejectSecondaryWhileBusy(context: Context, callId: String, sessionId: String) {
            val key = busyKey(callId, sessionId)
            if (key.isEmpty()) return
            if (!busyRejectKeys.add(key)) return
            Log.i(TAG, "secondary incoming busy-rejected; primary chrome left alone")
            BeamioNativeVoiceSignaling.sendDecline(
                context.applicationContext,
                callId,
                sessionId,
                reason = "busy",
                protectStickyChrome = true,
            )
            MainActivity.dispatchSystemCallAction(
                "callRejected",
                callId,
                sessionId,
                context.applicationContext,
            )
        }

        private fun rememberChromeOwner(callId: String, sessionId: String, extra: String = "") {
            listOf(callId, sessionId, extra)
                .map { it.trim() }
                .filter { it.isNotEmpty() }
                .forEach { claimedChromeKeys.add(it) }
        }

        /**
         * True when sticky chrome already belongs to a *different* call than
         * [callId]/[sessionId]. A stale mid-ring `callEnded` (old voice_end /
         * silent bridge end) must not tear down the ringing call's chrome.
         */
        private fun shouldIgnoreStaleTerminalAction(callId: String, sessionId: String): Boolean {
            if (!hasStickyVoiceChrome()) return false
            val ending = listOf(callId, sessionId)
                .map { it.trim() }
                .filter { it.isNotEmpty() }
                .toSet()
            if (ending.isEmpty()) return false
            val owned = primaryVoiceCallKeys()
            if (owned.isEmpty()) return false
            val foreign = ending.none { owned.contains(it) }
            if (foreign) {
                Log.i(
                    TAG,
                    "ignore stale terminal; sticky chrome preserved " +
                        "endingCount=${ending.size} ownedCount=${owned.size}",
                )
            }
            return foreign
        }

        /**
         * Only one call owns the incoming glass. [reportIncoming] claims the WebView
         * `callId` plus `sessionId` / nativeCallId; the glass Intent only carries
         * nativeCallId (= sessionId). Decline used to [Set.remove] just those two and
         * left the original callId in [claimedChromeKeys], so [hasStickyVoiceChrome]
         * stayed true for minutes and the next offer was busy-rejected with no window.
         *
         * Empty [callId]/[sessionId] force-clears (orphan teardown). Non-empty
         * ending ids that do not intersect claimed/submitted are skipped so a
         * foreign mid-ring `callEnded` cannot nuclear-wipe the current ring.
         */
        private fun releaseChromeOwner(callId: String, sessionId: String) {
            val ending = listOf(callId, sessionId)
                .map { it.trim() }
                .filter { it.isNotEmpty() }
            if (ending.isEmpty()) {
                val cleared = claimedChromeKeys.size
                val aliases = claimedChromeKeys.toList()
                val busyCleared = busyRejectKeys.size
                claimedChromeKeys.clear()
                aliases.forEach { submittedIncomingCalls.remove(it) }
                // busyRejectKeys used to stick until process death — a false
                // secondary reject then blocked every retry of that offer.
                busyRejectKeys.clear()
                if (cleared > 0 || busyCleared > 0) {
                    Log.i(
                        TAG,
                        "chrome ownership force-cleared claimedWas=$cleared " +
                            "busyRejectWas=$busyCleared",
                    )
                }
                return
            }
            val intersects = ending.any { claimedChromeKeys.contains(it) } ||
                ending.any { submittedIncomingCalls.contains(it) }
            if (!intersects) {
                // Still drop busy-reject marks for this offer so a later idle
                // retry is not permanently poisoned.
                clearBusyRejectForIds(ending)
                Log.i(
                    TAG,
                    "releaseChromeOwner skipped; ending ids not in claimed/submitted",
                )
                return
            }
            val aliases = linkedSetOf<String>()
            aliases.addAll(ending)
            aliases.addAll(claimedChromeKeys)
            val cleared = claimedChromeKeys.size
            claimedChromeKeys.clear()
            aliases.forEach { submittedIncomingCalls.remove(it) }
            clearBusyRejectForIds(aliases)
            if (cleared > 0 || aliases.isNotEmpty()) {
                Log.i(
                    TAG,
                    "chrome ownership cleared claimedWas=$cleared aliasCount=${aliases.size}",
                )
            }
        }

        private fun busyKey(callId: String, sessionId: String): String {
            return listOf(callId, sessionId)
                .map { it.trim() }
                .filter { it.isNotEmpty() }
                .joinToString("|")
        }

        private fun primaryVoiceCallKeys(): Set<String> {
            val keys = linkedSetOf<String>()
            keys.addAll(claimedChromeKeys)
            keys.addAll(IncomingCallActivity.shownCallKeys())
            BeamioNativeVoiceSignaling.currentActiveCall()?.let { active ->
                listOf(
                    active.offer.callId,
                    active.offer.sessionId,
                    active.listenSessionId,
                    active.peerMediaSessionId,
                ).forEach { raw ->
                    val id = raw.trim()
                    if (id.isNotEmpty()) keys.add(id)
                }
            }
            // Same glass gate as hasLiveVoiceChrome: RINGING without a window
            // must not poison anotherCallOwnsChrome for the next browser dial.
            activeConnections.values.forEach { connection ->
                if (connection.hasVisibleOrConnectedChrome()) {
                    keys.addAll(connection.identityKeys())
                }
            }
            return keys
        }

        /**
         * Tear Telecom RINGING/DIALING rows that never got a glass window so the
         * next dial is not stuck behind an invisible primary connection.
         * [keepKeys] protects the offer we are about to present.
         */
        private fun tearDownInvisibleRingingConnections(
            context: Context,
            keepKeys: Set<String> = emptySet(),
        ) {
            if (IncomingCallActivity.isShowing()) return
            val orphans = activeConnections.entries.filter { (_, connection) ->
                val ringingOrDialing =
                    connection.state == Connection.STATE_RINGING ||
                        connection.state == Connection.STATE_DIALING
                if (!ringingOrDialing) return@filter false
                connection.identityKeys().none { keepKeys.contains(it) }
            }.toList()
            if (orphans.isEmpty()) return
            orphans.forEach { (key, connection) ->
                Log.i(
                    TAG,
                    "tearDownInvisibleRinging key=$key state=${connection.state}",
                )
                val ids = connection.identityKeys()
                val idList = ids.toList()
                cancelIncomingRingTimeout(
                    idList.getOrElse(0) { "" },
                    idList.getOrElse(1) { "" },
                )
                runCatching {
                    connection.setDisconnected(
                        android.telecom.DisconnectCause(
                            android.telecom.DisconnectCause.CANCELED,
                            "Invisible ringing chrome cleared",
                        ),
                    )
                    connection.destroy()
                }
                activeConnections.remove(key)
                cancelIncomingNotifications(context, key, key)
                ids.forEach { id -> cancelIncomingNotifications(context, id, id) }
            }
            if (BeamioNativeVoiceSignaling.currentActiveCall() == null &&
                activeConnections.values.none { it.occupiesVoiceChrome() }
            ) {
                releaseChromeOwner("", "")
            }
        }

        /**
         * Glass retries exhausted while launcher stayed top. Do not leave this
         * RINGING connection as "busy" for later dials — tear it if still invisible.
         */
        fun onIncomingGlassPresentFailed(
            context: Context,
            callId: String,
            sessionId: String,
        ) {
            if (IncomingCallActivity.isShowing()) return
            Log.w(
                TAG,
                "incoming glass never showed after BAL retries; " +
                    "clearing invisible RINGING so next dial can present",
            )
            val keep = callerLookupKeys(callId, sessionId.ifBlank { callId }, sessionId, null).toSet()
            // Keep the current offer's connection until the ring timeout / user
            // answers from the heads-up notification; only clear *other* orphans.
            tearDownInvisibleRingingConnections(context, keepKeys = keep)
            // Current offer RINGING alone must not block a later dial either.
            synchronized(chromeGate) {
                if (!hasLiveVoiceChrome() && claimedChromeKeys.isNotEmpty()) {
                    val claimedWas = claimedChromeKeys.size
                    claimedChromeKeys.clear()
                    submittedIncomingCalls.clear()
                    Log.i(TAG, "released claimed chrome after glass fail claimedWas=$claimedWas")
                }
            }
        }

        fun reportIncoming(
            context: Context,
            callId: String,
            peerAddress: String,
            displayName: String,
            sessionId: String = "",
            claimedTag: String = "",
            claimedAddress: String = "",
            identityWarning: String = "",
        ) {
            val nativeCallId = sessionId.ifBlank { callId }
            restoreSettledIncoming(context)
            // A late report (PWA tag refresh, repeat delivery, push) for an offer
            // that was already answered, declined, cancelled or timed out must
            // not re-open the banner, re-arm the ring clock or submit a new
            // Telecom call (that was the "ghost call" with no peer).
            if (isIncomingClosed(callId, sessionId, nativeCallId)) {
                val answered = isIncomingAnsweredAny(callId, sessionId, nativeCallId)
                Log.i(TAG, "reportIncoming skipped; call already " + if (answered) "answered" else "ended")
                // Answer can beat the PWA's caller fields. Give the call page the
                // caller now (title only; no incoming window).
                if (answered && InCallScreenModel.isLive() && InCallScreenModel.matches(nativeCallId, sessionId)) {
                    val tag = claimedTag.trim().takeIf(::isBeamioTag)
                        ?: displayName.trim().takeIf(::isBeamioTag).orEmpty()
                    val address = peerAddress.trim()
                    if (tag.isNotBlank() || address.isNotBlank()) {
                        InCallActivity.refreshIdentityIfShowing(nativeCallId, sessionId, tag = tag, address = address)
                    }
                    if (tag.isBlank() && address.isNotBlank()) {
                        scheduleBeamioTagLookup(
                            context, address, nativeCallId, sessionId,
                            claimedTag = "", claimedAddress = claimedAddress,
                            identityWarning = identityWarning,
                            aliasCallId = callId.trim().takeIf { it != nativeCallId }.orEmpty(),
                        )
                    }
                }
                IncomingCallActivity.finishIfMatching(callId, sessionId)
                IncomingCallActivity.finishIfMatching(nativeCallId, sessionId)
                return
            }
            // PWA may fire reportIncomingSystemCall twice on the same bridge
            // thread pool (offer + tag refresh). Claim Telecom submit under the
            // same chromeGate lock so we never open TC@N and TC@N+1 for one call.
            val callKeys = callerLookupKeys(callId, nativeCallId, sessionId, null)
            // BAL Abort can leave Telecom RINGING with no glass. Tear those
            // before chromeGate so the new offer is not busy-rejected and does
            // not stack a second invisible primary connection.
            tearDownInvisibleRingingConnections(context, keepKeys = callKeys.toSet())
            val submitTelecom: Boolean
            synchronized(chromeGate) {
                // A repeat report of the offer being set up right now (its glass
                // and Connection do not exist yet) is not an orphan: clearing its
                // claims here re-submitted it to Telecom on every repeat.
                val sameCallInFlight = callKeys.any {
                    submittedIncomingCalls.contains(it) || claimedChromeKeys.contains(it)
                }
                // Claim keys alone (no glass / visible RINGING / active signaling)
                // are orphans from a prior race. Treating them as "busy" made the
                // next browser dial busy-reject with no window, then stuck that
                // offer in busyRejectKeys forever.
                if (claimedChromeKeys.isNotEmpty() && !hasLiveVoiceChrome() && !sameCallInFlight) {
                    val orphanClaims = claimedChromeKeys.size
                    val orphanBusy = busyRejectKeys.size
                    claimedChromeKeys.clear()
                    submittedIncomingCalls.clear()
                    busyRejectKeys.clear()
                    Log.i(
                        TAG,
                        "reclaim orphan chrome before primary " +
                            "claimedWas=$orphanClaims busyRejectWas=$orphanBusy",
                    )
                } else if (wasBusyRejected(callId, sessionId) && !hasLiveVoiceChrome()) {
                    // Offer was false-busy-rejected while chrome was sticky; idle
                    // now — allow this dial to present glass.
                    clearBusyRejectForIds(listOf(callId, sessionId, nativeCallId))
                    Log.i(TAG, "cleared idle busy-reject so offer can present glass")
                }
                if (wasBusyRejected(callId, sessionId)) {
                    Log.i(TAG, "ignore late push for a call already busy-rejected")
                    return
                }
                if (anotherCallOwnsChrome(callId, sessionId, nativeCallId)) {
                    handleSecondaryWhileBusy(context, callId, sessionId, peerAddress) {
                        reportIncoming(
                            context, callId, peerAddress, displayName, sessionId,
                            claimedTag, claimedAddress, identityWarning,
                        )
                    }
                    return
                }
                rememberChromeOwner(callId, sessionId, nativeCallId)
                // Primary claim wins over any prior busy-reject mark for this offer.
                clearBusyRejectForIds(listOf(callId, sessionId, nativeCallId))
                submitTelecom = callKeys.none { submittedIncomingCalls.contains(it) }
                if (submitTelecom) {
                    callKeys.forEach { submittedIncomingCalls.add(it) }
                }
            }
            val shown = keepShownCaller(
                context,
                nativeCallId, peerAddress, displayName,
                claimedTag, claimedAddress, identityWarning,
            )
            // FCM normally uses callId while Telecom and the PWA may use
            // sessionId. Keep both aliases so an OEM/Telecom callback cannot
            // lose the verified caller between those lifecycle stages.
            if (callId.isNotBlank() && callId != nativeCallId) {
                keepShownCaller(
                    context,
                    callId, shown.peerAddress, shown.displayName,
                    shown.claimedTag, shown.claimedAddress, shown.identityWarning,
                )
            }
            if (sessionId.isNotBlank() && sessionId != nativeCallId) {
                keepShownCaller(
                    context,
                    sessionId, shown.peerAddress, shown.displayName,
                    shown.claimedTag, shown.claimedAddress, shown.identityWarning,
                )
            }
            armIncomingRingTimeout(context, callId, sessionId)
            Log.i(
                TAG,
                "reportIncoming called callIdPresent=${callId.isNotBlank()} " +
                    "sessionIdPresent=${sessionId.isNotBlank()} " +
                    "displayNamePresent=${shown.displayName.isNotBlank()} " +
                    "displayNameIsTag=${shown.displayName.trim().startsWith("@")} " +
                    "peerAddressPresent=${shown.peerAddress.isNotBlank()}",
            )
            // A later PWA tag lookup reports the same offer again. That must
            // refresh a still-ringing card, not clear Answer and open a second
            // window over the in-app call page.
            if (incomingAnswered(callId, sessionId) || incomingAnswered(nativeCallId, sessionId)) {
                Log.i(TAG, "reportIncoming skipped; call already answered")
                IncomingCallActivity.finishIfMatching(callId, sessionId)
                IncomingCallActivity.finishIfMatching(nativeCallId, sessionId)
                return
            }
            // Empty local map still allows Telecom orphans (Samsung WAITING_CALL)
            // that make createConnectionFailed — wipe PhoneAccount first. Only
            // for a new submit: a repeat report must not unregister the account
            // while its own addNewIncomingCall is still pending.
            if (submitTelecom && activeConnections.isEmpty()) {
                resetSelfManagedPhoneAccount(context)
            } else {
                ensurePhoneAccount(context)
            }
            // Telecom RINGING first. phoneCall FGS is denied until a live
            // Connection exists; posting CallStyle + present() before that
            // leaves shortService only, and targetSdk 36 BAL still blocks
            // PendingIntent.send — glass never tops the launcher.
            if (submitTelecom) {
                val telecom = context.getSystemService(TelecomManager::class.java)
                if (telecom == null) {
                    synchronized(chromeGate) {
                        callKeys.forEach { submittedIncomingCalls.remove(it) }
                    }
                } else {
                    val handle = phoneAccountHandle(context)
                    val extras = Bundle().apply {
                        putString(EXTRA_CALL_ID, nativeCallId)
                        putString(EXTRA_ORIGINAL_CALL_ID, callId)
                        putString(EXTRA_SESSION_ID, sessionId)
                        putString(EXTRA_DISPLAY_NAME, shown.displayName)
                        putString(EXTRA_PEER_ADDRESS, shown.peerAddress)
                        putString(EXTRA_CLAIMED_TAG, shown.claimedTag)
                        putString(EXTRA_CLAIMED_ADDRESS, shown.claimedAddress)
                        putString(EXTRA_IDENTITY_WARNING, shown.identityWarning)
                        putParcelable(
                            TelecomManager.EXTRA_INCOMING_CALL_ADDRESS,
                            Uri.parse("$PHONE_SCHEME:$nativeCallId"),
                        )
                    }
                    try {
                        telecom.addNewIncomingCall(handle, extras)
                        Log.i(
                            TAG,
                            "Telecom addNewIncomingCall; glass deferred to onShowIncomingCallUi",
                        )
                        // Prefer onShowIncomingCallUi for first glass (Telecom BAL).
                        // If OEM never creates the Connection (createConnectionFailed
                        // or silent drop), watchdog arms CallStyle/FSI so lock screen
                        // still shows Beamio Answer.
                        scheduleTelecomIncomingWatchdog(
                            context,
                            nativeCallId = nativeCallId,
                            originalCallId = callId,
                            sessionId = sessionId,
                            shown = shown,
                        )
                        activeConnections[nativeCallId]?.updateCallerDisplayName(shown.displayName)
                        if (callId.isNotBlank()) {
                            activeConnections[callId]?.updateCallerDisplayName(shown.displayName)
                        }
                        if (sessionId.isNotBlank()) {
                            activeConnections[sessionId]?.updateCallerDisplayName(shown.displayName)
                        }
                        return
                    } catch (error: Exception) {
                        synchronized(chromeGate) {
                            callKeys.forEach { submittedIncomingCalls.remove(it) }
                        }
                        Log.w(TAG, "Telecom addNewIncomingCall failed; posting glass without Telecom BAL", error)
                    }
                }
            } else {
                Log.i(
                    TAG,
                    "Telecom incoming call already submitted; refresh glass " +
                        "callIdPresent=${callId.isNotBlank()} " +
                        "sessionIdPresent=${sessionId.isNotBlank()}",
                )
            }
            // Fallback / refresh path (Telecom unavailable or already submitted).
            showIncomingCallNotification(
                context, nativeCallId, shown.peerAddress, shown.displayName, sessionId,
                shown.claimedTag, shown.claimedAddress, shown.identityWarning,
                aliasCallId = callId,
            )
            activeConnections[nativeCallId]?.updateCallerDisplayName(shown.displayName)
            if (callId.isNotBlank()) activeConnections[callId]?.updateCallerDisplayName(shown.displayName)
            if (sessionId.isNotBlank()) activeConnections[sessionId]?.updateCallerDisplayName(shown.displayName)
        }

        /**
         * After [TelecomManager.addNewIncomingCall], wait briefly for a live
         * [Connection]. If OEM never delivers [onCreateIncomingConnection] /
         * [onShowIncomingCallUi] (createConnectionFailed or silent drop), arm
         * CallStyle + FSI so lock-screen glass still appears.
         */
        private fun scheduleTelecomIncomingWatchdog(
            context: Context,
            nativeCallId: String,
            originalCallId: String,
            sessionId: String,
            shown: ShownCaller,
        ) {
            val app = context.applicationContext
            val keys = listOf(nativeCallId, originalCallId, sessionId)
                .map { it.trim() }
                .filter { it.isNotEmpty() }
                .distinct()
            incomingRingHandler.postDelayed({
                val hasConn = keys.any { activeConnections.containsKey(it) }
                if (hasConn) return@postDelayed
                if (isIncomingClosed(originalCallId, nativeCallId, sessionId)) {
                    return@postDelayed
                }
                if (productIncomingChromeVisible(app)) return@postDelayed
                Log.w(
                    TAG,
                    "Telecom incoming watchdog: no Connection after addNewIncomingCall — " +
                        "CallStyle/FSI fallback (lock-screen glass)",
                )
                fallBackIncomingWithoutTelecom(
                    app,
                    telecomCallId = nativeCallId,
                    originalCallId = originalCallId,
                    sessionId = sessionId,
                    requestExtras = null,
                    shownOverride = shown,
                )
            }, 1_200L)
        }

        /**
         * Telecom create failed or never created a Connection — clear submit
         * gates and post CallStyle / present glass so Answer is visible under
         * the keyguard (USE_FULL_SCREEN_INTENT).
         */
        internal fun fallBackIncomingWithoutTelecom(
            context: Context,
            telecomCallId: String,
            originalCallId: String,
            sessionId: String,
            requestExtras: Bundle?,
            shownOverride: ShownCaller? = null,
        ) {
            val app = context.applicationContext
            val callId = originalCallId.ifBlank {
                requestExtras?.getString(EXTRA_ORIGINAL_CALL_ID).orEmpty()
            }.ifBlank { telecomCallId }
            val sid = sessionId.ifBlank {
                requestExtras?.getString(EXTRA_SESSION_ID).orEmpty()
            }
            val nativeId = telecomCallId.ifBlank { sid.ifBlank { callId } }
            val keys = callerLookupKeys(callId, nativeId, sid, null)
            synchronized(chromeGate) {
                keys.forEach { submittedIncomingCalls.remove(it) }
            }
            if (isIncomingClosed(callId, nativeId, sid)) {
                Log.i(TAG, "fallBackIncomingWithoutTelecom skipped; call already answered or ended")
                return
            }
            if (productIncomingChromeVisible(app)) {
                Log.i(TAG, "fallBackIncomingWithoutTelecom skipped; glass already up")
                return
            }
            val extrasFallback = ShownCaller(
                peerAddress = requestExtras?.getString(EXTRA_PEER_ADDRESS).orEmpty(),
                displayName = requestExtras?.getString(EXTRA_DISPLAY_NAME).orEmpty()
                    .ifBlank { "Beamio" },
                claimedTag = requestExtras?.getString(EXTRA_CLAIMED_TAG).orEmpty(),
                claimedAddress = requestExtras?.getString(EXTRA_CLAIMED_ADDRESS).orEmpty(),
                identityWarning = requestExtras?.getString(EXTRA_IDENTITY_WARNING).orEmpty(),
            )
            val shown = shownOverride ?: resolvePendingCaller(
                app,
                callerLookupKeys(callId, nativeId, sid, null),
                fallback = extrasFallback,
            )
            Log.i(
                TAG,
                "fallBackIncomingWithoutTelecom CallStyle/FSI " +
                    "callIdPresent=${callId.isNotBlank()} " +
                    "sessionIdPresent=${sid.isNotBlank()}",
            )
            showIncomingCallNotification(
                app, nativeId, shown.peerAddress, shown.displayName, sid,
                shown.claimedTag, shown.claimedAddress, shown.identityWarning,
                aliasCallId = callId,
            )
        }

        fun isPhoneAccountEnabled(context: Context): Boolean {
            val telecom = context.getSystemService(TelecomManager::class.java) ?: return false
            return try {
                telecom.getPhoneAccount(phoneAccountHandle(context))?.isEnabled == true
            } catch (_: SecurityException) {
                false
            }
        }

        fun openIncomingCallSettings(context: Context) {
            val intent = Intent(android.provider.Settings.ACTION_APP_NOTIFICATION_SETTINGS).apply {
                putExtra(android.provider.Settings.EXTRA_APP_PACKAGE, context.packageName)
                if (context !is android.app.Activity) addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
            }
            try {
                context.startActivity(intent)
            } catch (_: Exception) {
                val fallback = Intent(android.provider.Settings.ACTION_APPLICATION_DETAILS_SETTINGS).apply {
                    data = Uri.parse("package:${context.packageName}")
                    if (context !is android.app.Activity) addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
                }
                runCatching { context.startActivity(fallback) }
            }
        }

        @Deprecated("Use openIncomingCallSettings")
        fun openPhoneAccountSettings(context: Context) = openIncomingCallSettings(context)

        fun startOutgoing(
            context: Context,
            callId: String,
            handle: String,
            sessionId: String = "",
        ) {
            if (activeConnections.values.any { it.isIncomingCall() }) {
                Log.i(TAG, "placeCall skipped; answered incoming call stays in the app")
                return
            }
            ensurePhoneAccount(context)
            val telecom = context.getSystemService(TelecomManager::class.java) ?: return
            val extras = Bundle().apply {
                putParcelable(TelecomManager.EXTRA_PHONE_ACCOUNT_HANDLE, phoneAccountHandle(context))
                putString(EXTRA_CALL_ID, callId)
                if (sessionId.isNotBlank()) putString(EXTRA_SESSION_ID, sessionId)
            }
            try {
                BeamioCallTiming.mark("telecom-placeCall")
                telecom.placeCall(Uri.parse("$PHONE_SCHEME:$callId"), extras)
                BeamioCallTiming.mark("telecom-placeCall-returned")
            } catch (_: SecurityException) {
                MainActivity.dispatchSystemCallAction("callFailed", callId)
            }
        }

        /** Dialer: remote accept — mark Telecom active (in-call UI). */
        fun markOutgoingConnected(context: Context, callId: String, sessionId: String) {
            val endedId = callId.ifBlank { sessionId }
            if (endedId.isBlank()) return
            val connection = activeConnections[endedId] ?: activeConnections[sessionId] ?: return
            try {
                connection.setActive()
                Log.i(TAG, "markOutgoingConnected callId=${endedId.take(12)}")
            } catch (e: Exception) {
                Log.w(TAG, "markOutgoingConnected setActive: ${e.message}")
            }
        }

        /** Dialer remote reject — drop Connection without another PWA bridge emit. */
        fun disconnectOutgoingQuiet(context: Context, callId: String, sessionId: String) {
            val endedId = callId.ifBlank { sessionId }
            if (endedId.isBlank()) return
            cancelPendingSetActive(endedId, sessionId)
            val connection = activeConnections[endedId] ?: activeConnections[sessionId]
            connection?.let {
                // Acknowledge before setDisconnected so onDisconnect does not fire callEnded
                // after callRejected (that race left the chat bubble stuck on Calling…).
                it.acknowledgeQuietDisconnect()
                try {
                    it.setDisconnected(DisconnectCause(DisconnectCause.REJECTED))
                    it.destroy()
                } catch (e: Exception) {
                    Log.w(TAG, "disconnectOutgoingQuiet: ${e.message}")
                }
                activeConnections.remove(endedId, it)
                if (sessionId.isNotBlank()) activeConnections.remove(sessionId, it)
            }
            BeamioCallForegroundService.stop(context)
            cancelIncomingNotifications(context, endedId, sessionId)
        }

        fun end(context: Context, callId: String, sessionId: String = "") {
            val id = callId.ifBlank { sessionId }
            Log.i(
                TAG,
                "end() bridge callEnded callIdPresent=${callId.isNotBlank()} " +
                    "sessionIdPresent=${sessionId.isNotBlank()} " +
                    "endedIdPresent=${id.isNotBlank()} stickyChrome=${hasStickyVoiceChrome()}",
            )
            completeIncomingUserAction(context, "callEnded", id, sessionId, fromTelecom = false)
        }

        /**
         * Hide the incoming card and stop the ringtone. The call stays unanswered:
         * the ring clock keeps running, and the PWA still sends timeout to the caller.
         */
        fun silenceIncomingWindow(context: Context, callId: String, sessionId: String) {
            incomingRingKeys(callId, sessionId).forEach { mutedIncomingKeys.add(it) }
            Log.i(TAG, "Incoming window muted callIdPresent=${callId.isNotBlank()} sessionIdPresent=${sessionId.isNotBlank()}")
            if (callId.isNotBlank() || sessionId.isNotBlank()) {
                BeamioCallForegroundService.holdMutedIncoming(context, callId, sessionId)
            }
            IncomingCallActivity.finishIfMatching(callId, sessionId)
        }

        /**
         * Mute only hides the call that was silenced. A different incoming call
         * has its own id and must still open the window. Caller cancel clears
         * the latch so a later ring of this same call can show again.
         */
        fun isIncomingMuted(callId: String, sessionId: String, aliasCallId: String = ""): Boolean {
            val keys = listOf(callId, sessionId, aliasCallId)
                .map { it.trim() }
                .filter { it.isNotEmpty() }
                .distinct()
            if (keys.isEmpty() || mutedIncomingKeys.isEmpty()) return false
            return keys.all { mutedIncomingKeys.contains(it) }
        }

        private fun clearIncomingMute(callId: String, sessionId: String) {
            val keys = incomingRingKeys(callId, sessionId)
            if (keys.none { mutedIncomingKeys.contains(it) }) return
            mutedIncomingKeys.clear()
            Log.i(TAG, "Incoming mute cleared")
        }

        /** Same entry as IncomingCallActivity Accept / Decline. */
        fun finishIncomingCall(context: Context, action: String, callId: String, sessionId: String) {
            completeIncomingUserAction(context, action, callId, sessionId, fromTelecom = false)
        }

        /**
         * v14: HIGH + CATEGORY_CALL + CallStyle.
         *
         * Android 14+ (targetSdk 34+) only auto-fires fullScreenIntent for
         * CallStyle / CATEGORY_CALL (and alarms). v13 used silent
         * CATEGORY_SERVICE so Samsung skipped FSI while the screen was on /
         * launcher was top — BAL then dropped startActivity and no glass
         * appeared for browser→Android dials.
         *
         * v14 kept HIGH + CallStyle but muted the channel (sound/vib off);
         * Samsung then skipped interrupt / FSI while only startForeground
         * posted the notif. v15 keeps CallStyle and restores ringtone +
         * vibration so NotificationManager can fire fullScreenIntent.
         *
         * CallStyle heads-up is the system entry when glass BAL-fails; once
         * [IncomingCallActivity] is visible, demote to a quiet FGS keep-alive
         * so Samsung does not leave a second Decline/Answer card over glass.
         */
        private const val INCOMING_CALL_CHANNEL_ID = "beamio_incoming_calls_v15"
        /** Silent FGS keep-alive while glass / overlay is the product UI. Never HUN. */
        private const val GLASS_KEEPALIVE_CHANNEL_ID = "beamio_glass_keepalive_v1"
        private const val NOTIFICATION_ALIAS_PREFS = "beamio_call_notification_keys"
        private const val ONGOING_CALL_CHANNEL_ID = "beamio_ongoing_calls_v2"
        private const val QUIET_ANSWERED_CHANNEL_ID = "beamio_answered_call_quiet_v1"
        private const val MUTED_INCOMING_CHANNEL_ID = "beamio_muted_incoming_v1"
        const val ACTION_ANSWER = "com.beamio.app.action.ANSWER_CALL"
        const val ACTION_DECLINE = "com.beamio.app.action.DECLINE_CALL"
        const val ACTION_MUTE = "com.beamio.app.action.MUTE_CALL"
        const val ACTION_HANGUP = "com.beamio.app.action.HANGUP_CALL"
        private val settledCallActions = ConcurrentHashMap.newKeySet<String>()
        private const val INCOMING_RING_TIMEOUT_MS = 180_000L

        /**
         * Settled actions also go to disk. The page can re-report an offer after
         * the process that saw it end was killed (cold start replays the native
         * inbox); without this the new process opens a Telecom call for it.
         */
        private const val SETTLED_PREFS = "beamio_settled_incoming_v1"
        /** Longer than the PWA's ring window (3 min + 15 s), after which it stops reporting an offer. */
        private const val SETTLED_KEEP_MS = 15 * 60_000L
        private val settledRestored = java.util.concurrent.atomic.AtomicBoolean(false)

        /** Load the settled actions of earlier processes once per process. */
        fun restoreSettledIncoming(context: Context) {
            if (!settledRestored.compareAndSet(false, true)) return
            runCatching {
                val prefs = context.applicationContext.getSharedPreferences(SETTLED_PREFS, Context.MODE_PRIVATE)
                val cutoff = System.currentTimeMillis() - SETTLED_KEEP_MS
                val stale = ArrayList<String>()
                var restored = 0
                for ((key, value) in prefs.all) {
                    val at = (value as? Long) ?: 0L
                    if (at < cutoff) {
                        stale.add(key)
                    } else if (settledCallActions.add(key)) {
                        restored++
                    }
                }
                if (stale.isNotEmpty()) {
                    prefs.edit().apply { stale.forEach { remove(it) } }.apply()
                }
                Log.i(TAG, "settled incoming restored=$restored pruned=${stale.size}")
            }.onFailure { Log.w(TAG, "settled incoming restore failed", it) }
        }

        private fun persistSettled(context: Context, keys: Collection<String>) {
            if (keys.isEmpty()) return
            runCatching {
                val now = System.currentTimeMillis()
                context.applicationContext.getSharedPreferences(SETTLED_PREFS, Context.MODE_PRIVATE)
                    .edit()
                    .apply { keys.forEach { putLong(it, now) } }
                    .apply()
            }
        }
        private const val INCOMING_RING_REARM_SLACK_MS = 3_000L

        private class IncomingRingClock(
            val startedAt: Long,
            val runnable: Runnable,
            val callId: String = "",
            val sessionId: String = "",
        )

        private val incomingRingClocks = ConcurrentHashMap<String, IncomingRingClock>()
        private val incomingRingHandler = Handler(Looper.getMainLooper())
        private val callerAvatarBitmaps = ConcurrentHashMap<String, Bitmap>()
        private val callerAvatarLoads = ConcurrentHashMap.newKeySet<String>()
        private val beamioTagLookups = ConcurrentHashMap.newKeySet<String>()
        private val mutedIncomingKeys = ConcurrentHashMap.newKeySet<String>()
        /** CallStyle NM.notify + FSI already armed for these ring keys. */
        private val armedCallStyleKeys = ConcurrentHashMap.newKeySet<String>()
        /**
         * Last CallStyle / keep-alive title posted per primary notification key.
         * Used so a later verified `@BeamioTag` can quietly refresh Person/title
         * under lock without re-arming ringtone (onlyAlertOnce).
         */
        private val lastArmedCallStyleTitle = ConcurrentHashMap<String, String>()

        private fun settleKey(action: String, callId: String): String = "$action|$callId"

        private fun incomingRingKeys(callId: String, sessionId: String): List<String> =
            listOf(callId, sessionId).map { it.trim() }.filter { it.isNotEmpty() }.distinct()

        private fun incomingRingClock(callId: String, sessionId: String): IncomingRingClock? =
            incomingRingKeys(callId, sessionId).firstNotNullOfOrNull { incomingRingClocks[it] }

        /** True while an incoming ring timeout clock is live (CallStyle / FSI path). */
        fun hasActiveIncomingRing(): Boolean = incomingRingClocks.isNotEmpty()

        private fun incomingAnswered(callId: String, sessionId: String): Boolean =
            incomingRingKeys(callId, sessionId).any { id ->
                settledCallActions.contains(settleKey("callAnswered", id))
            }

        private fun incomingActionAlreadySettled(callId: String, sessionId: String): Boolean {
            val actions = listOf("callAnswered", "callRejected", "callEnded", "callTimedOut")
            return incomingRingKeys(callId, sessionId).any { id ->
                actions.any { action -> settledCallActions.contains(settleKey(action, id)) }
            }
        }

        private fun settledAny(actions: List<String>, ids: Array<out String>): Boolean =
            ids.map { it.trim() }.filter { it.isNotEmpty() }.distinct().any { id ->
                actions.any { action -> settledCallActions.contains(settleKey(action, id)) }
            }

        /**
         * Answered, declined, cancelled by the caller or timed out. Once true, no
         * incoming banner, Activity, CallStyle card or Telecom ringing call may be
         * shown for this offer again, however late the present request arrives.
         */
        fun isIncomingClosed(vararg ids: String): Boolean =
            settledAny(listOf("callAnswered", "callRejected", "callEnded", "callTimedOut"), ids)

        /** Declined, cancelled or timed out before an answer: it cannot be answered any more. */
        fun isIncomingCancelled(vararg ids: String): Boolean =
            !settledAny(listOf("callAnswered"), ids) &&
                settledAny(listOf("callRejected", "callEnded", "callTimedOut"), ids)

        fun isIncomingAnsweredAny(vararg ids: String): Boolean =
            settledAny(listOf("callAnswered"), ids)

        /**
         * Answer tapped on a banner for an offer that already ended (caller
         * cancelled, timed out, declined). Do not accept or open a call: remove
         * every incoming surface and any Telecom row left for it.
         */
        private fun dropAnswerForClosedCall(context: Context, callId: String, sessionId: String) {
            val ids = listOf(callId, sessionId).map { it.trim() }.filter { it.isNotEmpty() }.distinct()
            Log.i(TAG, "Answer ignored; this incoming call already ended — no call is opened")
            BeamioIncomingRingtone.stop()
            ids.forEach { IncomingCallActivity.finishIfMatching(it, sessionId) }
            IncomingCallOverlay.dismissIfShowing()
            disconnectIncomingFor(ids, DisconnectCause.LOCAL)
            // A ghost connection someone else already set ACTIVE for this offer.
            ids.forEach { key ->
                val conn = activeConnections[key] ?: return@forEach
                if (!conn.isIncomingCall()) return@forEach
                runCatching {
                    conn.setDisconnected(DisconnectCause(DisconnectCause.LOCAL))
                    conn.destroy()
                }
                activeConnections.entries.filter { it.value === conn }.toList()
                    .forEach { activeConnections.remove(it.key, it.value) }
            }
            ids.forEach { cancelIncomingNotifications(context, it, sessionId) }
            val otherCallOnScreen = InCallScreenModel.isLive() && !InCallScreenModel.matches(callId, sessionId)
            if (!otherCallOnScreen) {
                BeamioCallForegroundService.stop(context)
                InCallActivity.finishIfMatching(callId, sessionId)
            }
            releaseChromeOwner(callId, sessionId)
        }

        private fun armIncomingRingTimeout(context: Context, callId: String, sessionId: String) {
            val keys = incomingRingKeys(callId, sessionId)
            if (keys.isEmpty() || incomingRingClock(callId, sessionId) != null) return
            val nativeCallId = sessionId.ifBlank { callId }
            val startedAt = SystemClock.elapsedRealtime()
            val runnable = Runnable {
                keys.forEach { incomingRingClocks.remove(it) }
                completeIncomingUserAction(
                    context,
                    "callTimedOut",
                    nativeCallId,
                    sessionId.ifBlank { callId },
                    fromTelecom = false,
                )
            }
            val clock = IncomingRingClock(startedAt, runnable, callId, sessionId)
            keys.forEach { incomingRingClocks[it] = clock }
            incomingRingHandler.postDelayed(runnable, INCOMING_RING_TIMEOUT_MS)
            // The caller's cancel may have missed the current mailbox listen.
            BeamioNativeChatHooks.startIncomingRingCatchUp(context, callId, sessionId)
        }

        /** This incoming call still rings: its ring clock runs and it was not answered, declined or ended. */
        fun isIncomingRinging(callId: String, sessionId: String): Boolean =
            incomingRingClock(callId, sessionId) != null && !isIncomingClosed(callId, sessionId)

        private class PrimaryRing(val callId: String, val sessionId: String, val caller: String)

        /**
         * The call that owns the chrome is an incoming call still ringing, not
         * answered: its ids and its verified caller (lowercase). Null otherwise,
         * or when the caller is not known.
         */
        private fun unansweredPrimaryRing(context: Context): PrimaryRing? {
            if (BeamioNativeVoiceSignaling.currentActiveCall() != null) return null
            if (InCallScreenModel.isLive()) return null
            val keys = primaryVoiceCallKeys()
            val clock = keys.firstNotNullOfOrNull { incomingRingClocks[it] } ?: return null
            val callId = clock.callId
            val sessionId = clock.sessionId
            if (isIncomingClosed(callId, sessionId)) return null
            val ids = incomingRingKeys(callId, sessionId)
            val caller = BeamioNativeVoiceSignaling.cachedOffer(callId, sessionId)?.callerEoa
                ?.takeIf { it.isNotBlank() }
                ?: resolvePendingCaller(context, ids).peerAddress
            val normalized = caller.trim().lowercase()
            if (!isWalletAddress(normalized)) return null
            return PrimaryRing(callId, sessionId, normalized)
        }

        /** Second offers whose busy choice waits for their verified caller (key → since). */
        private val secondaryAwaitingCaller = ConcurrentHashMap<String, Long>()
        private const val SECONDARY_CALLER_WAIT_MS = 8_000L

        fun isAwaitingSecondaryCaller(callId: String, sessionId: String): Boolean {
            val key = busyKey(callId, sessionId)
            return key.isNotEmpty() && secondaryAwaitingCaller.containsKey(key)
        }

        /**
         * A second offer while another call owns the chrome. Busy, unless the
         * earlier call is an unanswered ring from the same caller: one caller
         * cannot ring us twice at once, so the earlier call is over even though
         * its cancel has not reached us. Then the earlier ring ends as cancelled
         * by the caller and [present] shows the new call. A push carries no
         * caller, so the choice waits (at most [SECONDARY_CALLER_WAIT_MS]) for
         * the offer's verified caller; without it the call is busy.
         */
        private fun handleSecondaryWhileBusy(
            context: Context,
            callId: String,
            sessionId: String,
            caller: String,
            present: () -> Unit,
        ) {
            val key = busyKey(callId, sessionId)
            if (key.isEmpty()) return
            val primary = unansweredPrimaryRing(context)
            if (primary == null) {
                secondaryAwaitingCaller.remove(key)
                rejectSecondaryWhileBusy(context, callId, sessionId)
                return
            }
            val newCaller = caller.trim().lowercase()
            if (!isWalletAddress(newCaller)) {
                if (secondaryAwaitingCaller.putIfAbsent(key, SystemClock.elapsedRealtime()) != null) return
                Log.i(TAG, "second incoming while an earlier call rings; busy choice waits for its caller")
                val app = context.applicationContext
                incomingRingHandler.postDelayed({
                    if (secondaryAwaitingCaller.remove(key) != null) {
                        Log.i(TAG, "second incoming caller not known in time; busy")
                        synchronized(chromeGate) { rejectSecondaryWhileBusy(app, callId, sessionId) }
                    }
                }, SECONDARY_CALLER_WAIT_MS)
                return
            }
            secondaryAwaitingCaller.remove(key)
            if (newCaller != primary.caller) {
                rejectSecondaryWhileBusy(context, callId, sessionId)
                return
            }
            Log.i(
                TAG,
                "same caller rang again while the earlier call rings; earlier call ended as cancelled " +
                    "earlier=${primary.callId.take(12)} new=${callId.take(12)}",
            )
            val app = context.applicationContext
            incomingRingHandler.post {
                BeamioNativeVoiceSignaling.peerDidEnd(app, primary.callId, primary.sessionId)
                // peerDidEnd posts the end to the main thread; this runs after it.
                incomingRingHandler.post(present)
            }
        }

        private fun cancelIncomingRingTimeout(callId: String, sessionId: String) {
            val clock = incomingRingClock(callId, sessionId) ?: return
            incomingRingHandler.removeCallbacks(clock.runnable)
            incomingRingClocks.entries.removeIf { it.value === clock }
            incomingRingKeys(callId, sessionId).forEach { key ->
                armedCallStyleKeys.remove(key)
                lastArmedCallStyleTitle.remove(key)
            }
        }

        private fun incomingRingShouldRearm(callId: String, sessionId: String): Boolean {
            if (incomingActionAlreadySettled(callId, sessionId)) return false
            val clock = incomingRingClock(callId, sessionId) ?: return false
            val elapsed = SystemClock.elapsedRealtime() - clock.startedAt
            return elapsed + INCOMING_RING_REARM_SLACK_MS < INCOMING_RING_TIMEOUT_MS
        }

        private fun rearmIncomingRing(
            context: Context,
            telecomCallId: String,
            originalCallId: String,
            sessionId: String,
        ) {
            if (!incomingRingShouldRearm(telecomCallId, sessionId)) return
            val keys = callerLookupKeys(originalCallId, telecomCallId, sessionId, null)
            keys.forEach { submittedIncomingCalls.remove(it) }
            val shown = resolvePendingCaller(context, keys)
            reportIncoming(
                context,
                callId = originalCallId.ifBlank { telecomCallId },
                peerAddress = shown.peerAddress,
                displayName = shown.displayName,
                sessionId = sessionId.ifBlank { telecomCallId },
                claimedTag = shown.claimedTag,
                claimedAddress = shown.claimedAddress,
                identityWarning = shown.identityWarning,
            )
        }

        fun completeIncomingUserAction(
            context: Context,
            action: String,
            callId: String,
            sessionId: String,
            fromTelecom: Boolean,
        ) {
            val endedId = callId.ifBlank { sessionId }
            if (endedId.isBlank()) return
            restoreSettledIncoming(context)
            // The caller cancelled (or the ring timed out / was declined) before
            // this Answer: never accept or start a call with no peer.
            if (action == "callAnswered" && isIncomingCancelled(callId, sessionId, endedId)) {
                dropAnswerForClosedCall(context, endedId, sessionId)
                return
            }
            // Peer signaling BEFORE settle short-circuit (iOS parity).
            // Telecom REJECTED + glass Decline can race: first attempt may lack
            // v3 offer; a second completeIncomingUserAction must still send.
            // callEnded must uplink voice_end_v1 before forgetOffer so the browser
            // dialer leaves the in-call UI (AES temporary relay).
            when (action) {
                "callAnswered" -> BeamioNativeVoiceSignaling.sendAccept(context, callId, sessionId)
                "callRejected" -> BeamioNativeVoiceSignaling.sendDecline(context, callId, sessionId)
                "callEnded" -> {
                    // Our outgoing call still ringing: the prebuilt cancel goes out
                    // now, before the page hears callEnded (it then sends none).
                    BeamioNativeVoiceSignaling.postDialerCancelIfRinging(context, callId, sessionId)
                    BeamioNativeVoiceSignaling.sendHangup(context, callId, sessionId)
                }
            }
            clearIncomingMute(endedId, sessionId)
            val firstSettle = settledCallActions.add(settleKey(action, endedId))
            if (sessionId.isNotBlank() && sessionId != endedId) {
                settledCallActions.add(settleKey(action, sessionId))
            }
            if (callId.isNotBlank() && callId != endedId) {
                settledCallActions.add(settleKey(action, callId))
            }
            if (firstSettle) {
                persistSettled(
                    context,
                    listOf(endedId, sessionId, callId)
                        .map { it.trim() }
                        .filter { it.isNotEmpty() }
                        .distinct()
                        .map { settleKey(action, it) },
                )
            }
            if (!firstSettle) {
                // A repeat terminal action must still leave no Telecom call behind:
                // the first settle can run before the Connection exists.
                if (action == "callEnded" || action == "callTimedOut" || action == "callRejected") {
                    disconnectIncomingFor(
                        listOf(callId, endedId, sessionId),
                        when (action) {
                            "callTimedOut" -> DisconnectCause.MISSED
                            "callRejected" -> DisconnectCause.REJECTED
                            else -> DisconnectCause.LOCAL
                        },
                    )
                }
                // Decline/timeout must still reach the callee PWA even when settle
                // already ran (orphan teardown, glass+Telecom race). Otherwise
                // App.tsx never gossips voice_call_reject_v1 and the caller stays
                // on Ringing…. AES was re-queued above; emit PWA here too.
                if (action == "callRejected" || action == "callTimedOut") {
                    savePendingSystemCallAction(context, action, endedId, sessionId)
                    MainActivity.dispatchSystemCallAction(action, callId, sessionId, context)
                }
                Log.i(
                    TAG,
                    "completeIncomingUserAction already settled action=$action " +
                        "id=${endedId.take(12)} fromTelecom=$fromTelecom; peer signal re-queued" +
                        if (action == "callRejected" || action == "callTimedOut") {
                            " + PWA emit"
                        } else {
                            ""
                        },
                )
                return
            }

            // Stale mid-ring callEnded (wrong/old ids) must not stop FGS, finish
            // glass, or nuclear-clear claimedChromeKeys for the ringing call.
            // Keep the settle so the same stale end cannot re-enter later.
            if ((action == "callEnded" || action == "callTimedOut") &&
                shouldIgnoreStaleTerminalAction(endedId, sessionId)
            ) {
                Log.i(
                    TAG,
                    "completeIncomingUserAction ignored stale $action " +
                        "fromTelecom=$fromTelecom (chrome left for ringing call)",
                )
                return
            }

            cancelIncomingRingTimeout(endedId, sessionId)
            val answeredCaller = if (action == "callAnswered") {
                resolvePendingCaller(
                    context,
                    listOf(endedId, sessionId, callId).filter { it.isNotBlank() }.distinct(),
                )
            } else {
                null
            }
            shownCallers.remove(endedId)
            if (sessionId.isNotBlank()) shownCallers.remove(sessionId)
            context.getSharedPreferences(CALLER_POOL_PREFS, Context.MODE_PRIVATE).edit()
                .remove(endedId)
                .remove(sessionId)
                .apply()
            submittedIncomingCalls.remove(endedId)
            if (sessionId.isNotBlank()) submittedIncomingCalls.remove(sessionId)
            if (action == "callAnswered") {
                BeamioCallForegroundService.handoffAnsweredCall(context, endedId, sessionId)
            } else {
                BeamioCallForegroundService.stop(context)
                InCallActivity.finishIfMatching(endedId, sessionId)
            }
            IncomingCallActivity.finishIfMatching(endedId, sessionId)
            // Always tear overlay chrome on settle. ID-gated dismiss can no-op
            // when Answer extras use a remapped/native callId while the overlay
            // still holds the wake id — leaving BeamioIncomingCall above InCall
            // under an occluded keyguard.
            IncomingCallOverlay.dismissIfShowing()
            val connection = activeConnections[endedId] ?: activeConnections[sessionId]
            when (action) {
                "callAnswered" -> {
                    // sendAccept already queued above — native temporary voice channel.
                    if (connection != null) {
                        try {
                            connection.setActive()
                        } catch (e: Exception) {
                            Log.w(TAG, "setActive after answer: ${e.message}")
                        }
                        scheduleDeferredSetActive(endedId, sessionId, connection)
                    }
                    // Unlocked CallKit-style page (iOS BeamioInCallScreen parity).
                    val inCallTag = when {
                        answeredCaller != null && isBeamioTag(answeredCaller.claimedTag) ->
                            answeredCaller.claimedTag.trim()
                        answeredCaller != null && isBeamioTag(answeredCaller.displayName) ->
                            answeredCaller.displayName.trim()
                        else -> ""
                    }
                    val inCallAddress = answeredCaller?.peerAddress.orEmpty().ifBlank {
                        answeredCaller?.claimedAddress.orEmpty()
                    }
                    val presentCallId = endedId.ifBlank { callId }
                    InCallActivity.present(
                        context,
                        callId = presentCallId,
                        sessionId = sessionId,
                        tag = inCallTag,
                        address = inCallAddress,
                    )
                    // Tag may still be resolving when Answer lands — kick lookup /
                    // avatar so InCall refreshes after CallStyle-settled early-return.
                    val aliasForInCall =
                        callId.trim().takeIf { it.isNotBlank() && it != presentCallId }.orEmpty()
                    if (inCallAddress.isNotBlank() && !isBeamioTag(inCallTag)) {
                        scheduleBeamioTagLookup(
                            context,
                            inCallAddress,
                            presentCallId,
                            sessionId,
                            claimedTag = inCallTag,
                            claimedAddress = answeredCaller?.claimedAddress.orEmpty(),
                            identityWarning = answeredCaller?.identityWarning.orEmpty(),
                            aliasCallId = aliasForInCall,
                        )
                    } else if (isBeamioTag(inCallTag) && callerAvatarBitmap(inCallTag) == null) {
                        scheduleCallerAvatar(
                            context,
                            inCallTag,
                            presentCallId,
                            inCallAddress,
                            inCallTag,
                            sessionId,
                            inCallTag,
                            answeredCaller?.claimedAddress.orEmpty(),
                            answeredCaller?.identityWarning.orEmpty(),
                            aliasForInCall,
                        )
                    } else if (isBeamioTag(inCallTag)) {
                        InCallActivity.refreshIdentityIfShowing(
                            presentCallId,
                            sessionId,
                            tag = inCallTag,
                            address = inCallAddress,
                        )
                    }
                    Log.i(
                        TAG,
                        "native accept UI settled callIdPresent=${callId.isNotBlank()} (InCall)",
                    )
                    return
                }
                "callRejected" -> {
                    cancelPendingSetActive(endedId, sessionId)
                    connection?.let {
                        it.setDisconnected(DisconnectCause(DisconnectCause.REJECTED))
                        it.destroy()
                        activeConnections.remove(callId, it)
                        activeConnections.remove(endedId, it)
                        if (sessionId.isNotBlank()) activeConnections.remove(sessionId, it)
                    }
                    // Tear any other RINGING orphan keyed under an alias of this call.
                    activeConnections.entries
                        .filter { (_, conn) ->
                            conn.isIncomingCall() && conn.state == Connection.STATE_RINGING
                        }
                        .toList()
                        .forEach { (key, conn) ->
                            runCatching {
                                conn.setDisconnected(DisconnectCause(DisconnectCause.REJECTED))
                                conn.destroy()
                            }
                            activeConnections.remove(key, conn)
                        }
                    BeamioCallForegroundService.stop(context)
                    cancelIncomingNotifications(context, endedId, sessionId)
                    cancelIncomingNotifications(context, callId, sessionId)
                    // AES reject uplink already queued (sendDecline). Also notify PWA so it
                    // can send user-PGP voice_call_reject_v1 — dialer listen may not be up
                    // yet (SI drops AES with target_voice_session_not_found), leaving the
                    // caller stuck on Ringing without gossip backup.
                    Log.i(
                        TAG,
                        "native decline UI settled callIdPresent=${callId.isNotBlank()}; emit PWA for gossip reject",
                    )
                    savePendingSystemCallAction(context, action, endedId, sessionId)
                    MainActivity.dispatchSystemCallAction(action, callId, sessionId, context)
                    releaseChromeOwner(callId, sessionId)
                    BeamioNativeVoiceSignaling.flushDeferredStickyDeclinesIfIdle()
                    return
                }
                "callEnded", "callTimedOut" -> {
                    cancelPendingSetActive(endedId, sessionId)
                    connection?.let {
                        val cause = if (action == "callTimedOut") {
                            DisconnectCause.MISSED
                        } else {
                            DisconnectCause.LOCAL
                        }
                        it.setDisconnected(DisconnectCause(cause))
                        it.destroy()
                        activeConnections.remove(endedId, it)
                        if (sessionId.isNotBlank()) activeConnections.remove(sessionId, it)
                    }
                    // Same sweep as callRejected: no incoming call may stay RINGING
                    // in Telecom after this offer ended (it blocks the next dial).
                    activeConnections.entries
                        .filter { (_, conn) ->
                            conn.isIncomingCall() && conn.state == Connection.STATE_RINGING
                        }
                        .toList()
                        .forEach { (key, conn) ->
                            runCatching {
                                conn.setDisconnected(
                                    DisconnectCause(
                                        if (action == "callTimedOut") DisconnectCause.MISSED
                                        else DisconnectCause.LOCAL,
                                    ),
                                )
                                conn.destroy()
                            }
                            activeConnections.remove(key, conn)
                        }
                    BeamioCallForegroundService.stop(context)
                    cancelIncomingNotifications(context, endedId, sessionId)
                    cancelIncomingNotifications(context, callId, sessionId)
                    // Stop native temporary voice channel; still notify PWA for dialer UI.
                    BeamioNativeVoiceChannel.stop()
                    releaseChromeOwner(callId, sessionId)
                    BeamioNativeVoiceSignaling.clearActiveCall()
                    BeamioNativeVoiceSignaling.forgetOffer(callId, sessionId)
                    BeamioNativeVoiceSignaling.forgetOffer(endedId, sessionId)
                    InCallScreenModel.end(endedId.ifBlank { callId })
                    MainActivity.hideInCallReturnPill()
                    InCallActivity.finishIfMatching(endedId, sessionId)
                    InCallActivity.finishIfMatching(callId, sessionId)
                    Log.i(TAG, "native voice channel stopped on $action; emit PWA UI")
                    savePendingSystemCallAction(context, action, endedId, sessionId)
                    MainActivity.dispatchSystemCallAction(action, callId, sessionId, context)
                    BeamioNativeVoiceSignaling.flushDeferredStickyDeclinesIfIdle()
                    return
                }
            }
            savePendingSystemCallAction(context, action, endedId, sessionId)
            MainActivity.dispatchSystemCallAction(action, callId, sessionId, context)
            if (fromTelecom || action == "callTimedOut") {
                Log.i(TAG, "Telecom action=$action callIdPresent=${callId.isNotBlank()}")
            }
        }

        /** Disconnect and destroy every live incoming Connection held under [ids]. */
        private fun disconnectIncomingFor(ids: List<String>, cause: Int) {
            ids.filter { it.isNotBlank() }.distinct().forEach { key ->
                val conn = activeConnections[key] ?: return@forEach
                if (!conn.isLiveIncoming()) return@forEach
                runCatching {
                    conn.setDisconnected(DisconnectCause(cause))
                    conn.destroy()
                }
                activeConnections.entries.filter { it.value === conn }.toList()
                    .forEach { activeConnections.remove(it.key, it.value) }
                Log.i(TAG, "repeat terminal action: disconnected a live incoming call")
            }
        }

        private fun bringMainActivityToFront(context: Context) {
            openActiveCallScreen(context, "", "")
        }

        /**
         * Status-bar call chip and the ongoing-call notification both land here.
         * Bring the consumer shell forward and ask the PWA to open the live call page.
         */
        private var lastOpenActiveCallAt = 0L

        fun openActiveCallScreen(context: Context, callId: String, sessionId: String) {
            val now = SystemClock.elapsedRealtime()
            if (now - lastOpenActiveCallAt < 1500L) return
            lastOpenActiveCallAt = now
            IncomingCallActivity.finishIfMatching(callId, sessionId)
            // Prefer the unlocked CallKit-style InCall page when a shell-answered call is live.
            if (InCallScreenModel.isLive()) {
                val snap = InCallScreenModel.snapshot()
                val presentCallId = callId.ifBlank { snap.callId }
                val presentSessionId = sessionId.ifBlank { snap.sessionId }
                val shown = resolvePendingCaller(
                    context,
                    listOf(presentCallId, presentSessionId).filter { it.isNotBlank() }.distinct(),
                )
                val tag = when {
                    isBeamioTag(shown.claimedTag) -> shown.claimedTag.trim()
                    isBeamioTag(shown.displayName) -> shown.displayName.trim()
                    snap.tag.isNotBlank() -> snap.tag
                    else -> ""
                }
                val address = shown.peerAddress.ifBlank { shown.claimedAddress }.ifBlank { snap.address }
                InCallActivity.present(
                    context,
                    presentCallId,
                    presentSessionId,
                    tag = tag,
                    address = address,
                )
                if (address.isNotBlank() && !isBeamioTag(tag)) {
                    scheduleBeamioTagLookup(
                        context,
                        address,
                        presentCallId,
                        presentSessionId,
                        claimedTag = tag,
                        claimedAddress = shown.claimedAddress,
                        identityWarning = shown.identityWarning,
                        aliasCallId = "",
                    )
                } else if (isBeamioTag(tag) && callerAvatarBitmap(tag) == null) {
                    scheduleCallerAvatar(
                        context,
                        tag,
                        presentCallId,
                        address,
                        tag,
                        presentSessionId,
                        tag,
                        shown.claimedAddress,
                        shown.identityWarning,
                        "",
                    )
                } else if (isBeamioTag(tag)) {
                    InCallActivity.refreshIdentityIfShowing(
                        presentCallId,
                        presentSessionId,
                        tag = tag,
                        address = address,
                    )
                }
                Log.i(TAG, "Active InCall screen requested callIdPresent=${presentCallId.isNotBlank()}")
                return
            }
            val intent = Intent(context, MainActivity::class.java).apply {
                action = "com.beamio.app.action.SHOW_ACTIVE_CALL"
                flags = Intent.FLAG_ACTIVITY_NEW_TASK or
                    Intent.FLAG_ACTIVITY_SINGLE_TOP or
                    Intent.FLAG_ACTIVITY_REORDER_TO_FRONT or
                    Intent.FLAG_ACTIVITY_CLEAR_TOP
                putExtra(EXTRA_SHOW_ACTIVE_CALL, true)
                putExtra(EXTRA_CALL_ID, callId)
                putExtra(EXTRA_SESSION_ID, sessionId)
            }
            runCatching { context.startActivity(intent) }
                .onFailure { error -> Log.w(TAG, "Could not open the active call screen", error) }
            Log.i(TAG, "Active call screen requested callIdPresent=${callId.isNotBlank()}")
        }

        private fun incomingWindowIntent(
            context: Context,
            callId: String,
            sessionId: String,
            title: String,
            body: String,
            claimedTag: String,
        ): Intent {
            return Intent(context, IncomingCallActivity::class.java).apply {
                flags = Intent.FLAG_ACTIVITY_NEW_TASK or
                    Intent.FLAG_ACTIVITY_SINGLE_TOP or
                    Intent.FLAG_ACTIVITY_NO_USER_ACTION
                putExtra(EXTRA_CALL_ID, callId)
                putExtra(EXTRA_SESSION_ID, sessionId)
                putExtra(EXTRA_INCOMING_TITLE, title)
                putExtra(EXTRA_INCOMING_BODY, body)
                putExtra(EXTRA_CLAIMED_TAG, claimedTag)
            }
        }

        fun showIncomingCallNotification(
            context: Context,
            callId: String,
            peerAddress: String,
            displayName: String,
            sessionId: String,
            claimedTag: String = "",
            claimedAddress: String = "",
            identityWarning: String = "",
            aliasCallId: String = "",
        ) {
            if (callId.isBlank() && sessionId.isBlank() && aliasCallId.isBlank()) return
            if (isIncomingClosed(callId, sessionId, aliasCallId)) {
                Log.i(TAG, "Skip incoming window; call already answered or ended")
                if (!isIncomingAnsweredAny(callId, sessionId, aliasCallId)) {
                    cancelIncomingNotifications(context, callId, sessionId)
                }
                return
            }
            synchronized(chromeGate) {
                if (wasBusyRejected(callId, sessionId)) return
                if (anotherCallOwnsChrome(callId, sessionId, aliasCallId)) {
                    handleSecondaryWhileBusy(context, callId, sessionId, peerAddress) {
                        reportIncoming(
                            context, callId.ifBlank { aliasCallId }, peerAddress, displayName, sessionId,
                            claimedTag, claimedAddress, identityWarning,
                        )
                    }
                    return
                }
                rememberChromeOwner(callId, sessionId, aliasCallId)
            }
            if (isIncomingMuted(callId, sessionId, aliasCallId)) {
                Log.i(TAG, "Skip incoming window; call is muted")
                IncomingCallActivity.stopRinging()
                BeamioCallForegroundService.holdMutedIncoming(
                    context,
                    callId.ifBlank { sessionId.ifBlank { aliasCallId } },
                    sessionId,
                )
                return
            }
            ensureIncomingCallChannel(context)
            val primary = primaryNotificationKey(context, callId, sessionId, aliasCallId)
            if (primary.isBlank()) return
            val resolved = resolvePendingCaller(
                context,
                listOf(callId, sessionId, aliasCallId),
                ShownCaller(peerAddress, displayName, claimedTag, claimedAddress, identityWarning),
            )
            val claimed = resolved.claimedTag.trim().takeIf(::isBeamioTag)
                ?: claimedTag.trim().takeIf(::isBeamioTag).orEmpty()
            val tag = claimed.ifBlank {
                resolved.displayName.trim().takeIf(::isBeamioTag).orEmpty()
            }
            val walletLine = shortWallet(resolved.peerAddress).ifBlank {
                shortWallet(resolved.displayName)
            }
            val name = when {
                tag.isNotBlank() -> tag
                walletLine.isNotBlank() -> walletLine
                else -> "Incoming call"
            }
            val body = resolved.identityWarning.ifBlank {
                context.getString(R.string.incoming_call_glass_subtitle)
            }
            val ringKeys = listOf(primary, callId, sessionId, aliasCallId)
                .map { it.trim() }
                .filter { it.isNotBlank() }
                .distinct()
            val alreadyArmed = ringKeys.any { armedCallStyleKeys.contains(it) }
            if (alreadyArmed) {
                // Parity with iOS updateVerifiedIdentity: once a verified
                // @BeamioTag exists, main line (CallStyle under lock + Activity/
                // overlay) must show @tag — never leave "Incoming call".
                val effectiveClaimed = tag.ifBlank { claimed }
                IncomingCallActivity.updateShownCaller(
                    callId = callId,
                    sessionId = sessionId,
                    displayName = name,
                    peerAddress = resolved.peerAddress,
                    claimedTag = effectiveClaimed,
                    claimedAddress = resolved.claimedAddress.ifBlank { claimedAddress },
                    identityWarning = resolved.identityWarning.ifBlank { identityWarning },
                )
                IncomingCallOverlay.updateShownCaller(
                    callId = callId,
                    sessionId = sessionId,
                    displayName = name,
                    peerAddress = resolved.peerAddress,
                    claimedTag = effectiveClaimed,
                    identityWarning = resolved.identityWarning.ifBlank { identityWarning },
                )
                // Answer may already be on InCall — keep @tag + avatar in sync
                // with CallStyle / glass (same verified identity).
                if (InCallScreenModel.isLive() &&
                    InCallScreenModel.matches(callId, sessionId) &&
                    (tag.isNotBlank() || resolved.peerAddress.isNotBlank())
                ) {
                    InCallActivity.refreshIdentityIfShowing(
                        callId,
                        sessionId,
                        tag = tag.ifBlank { effectiveClaimed },
                        address = resolved.peerAddress.ifBlank { claimedAddress },
                    )
                    if (tag.isNotBlank() && callerAvatarBitmap(tag) == null) {
                        scheduleCallerAvatar(
                            context,
                            tag,
                            callId,
                            resolved.peerAddress,
                            name,
                            sessionId,
                            effectiveClaimed,
                            claimedAddress,
                            identityWarning,
                            aliasCallId,
                        )
                    }
                }
                if (IncomingCallActivity.isShowing() || IncomingCallOverlay.isShowing()) {
                    IncomingCallActivity.refreshCallerChrome(name, body)
                    IncomingCallOverlay.refreshCallerChrome(name, body)
                } else {
                    val window = incomingWindowIntent(
                        context,
                        callId = callId,
                        sessionId = sessionId,
                        title = name,
                        body = body,
                        claimedTag = effectiveClaimed,
                    )
                    Log.i(TAG, "CallStyle already armed but glass missing → Telecom binder present")
                    IncomingCallActivity.presentFromTelecomShowIncomingUi(context, window)
                }
                val keyguardLocked = isDeviceKeyguardLocked(context)
                val previousTitle = lastArmedCallStyleTitle[primary].orEmpty()
                val verifiedTagReady = isBeamioTag(name) || isBeamioTag(effectiveClaimed)
                val titleChanged = name.isNotBlank() && name != previousTitle
                if (verifiedTagReady && titleChanged) {
                    // Under lock CallStyle IS the product chrome — must quietly
                    // re-notify Person/title. onlyAlertOnce keeps ringtone/FSI.
                    // Unlocked + glass: demote keep-alive title only (no HUN).
                    if (keyguardLocked || !productIncomingChromeVisible(context)) {
                        quietlyRefreshArmedCallStyle(
                            context = context,
                            primary = primary,
                            callId = callId,
                            sessionId = sessionId,
                            name = name,
                            body = body,
                            claimedTag = effectiveClaimed,
                            aliasCallId = aliasCallId,
                        )
                    } else {
                        demoteIncomingChromeAfterGlass(
                            context, callId, sessionId, name, body, aliasCallId = aliasCallId,
                        )
                    }
                    lastArmedCallStyleTitle[primary] = name
                    ringKeys.forEach { key ->
                        activeConnections[key]?.updateCallerDisplayName(name)
                    }
                    Log.i(
                        TAG,
                        "Incoming identity refresh title=$name keyguard=$keyguardLocked " +
                            "glass=${productIncomingChromeVisible(context)}",
                    )
                }
                // Demote CallStyle HUN once glass owns unlocked UI. Under keyguard
                // productIncomingChromeVisible is false so CallStyle stays owner.
                if (!keyguardLocked && productIncomingChromeVisible(context)) {
                    demoteIncomingChromeAfterGlass(
                        context, callId, sessionId, name, body, aliasCallId = aliasCallId,
                    )
                    val main = android.os.Handler(android.os.Looper.getMainLooper())
                    for (delayMs in longArrayOf(400L, 1_200L)) {
                        main.postDelayed(
                            {
                                if (
                                    !isDeviceKeyguardLocked(context) &&
                                    productIncomingChromeVisible(context)
                                ) {
                                    demoteIncomingChromeAfterGlass(
                                        context,
                                        callId,
                                        sessionId,
                                        name,
                                        body,
                                        aliasCallId = aliasCallId,
                                    )
                                }
                            },
                            delayMs,
                        )
                    }
                }
                if (tag.isBlank()) {
                    scheduleBeamioTagLookup(
                        context,
                        resolved.peerAddress,
                        callId,
                        sessionId,
                        effectiveClaimed,
                        claimedAddress,
                        identityWarning,
                        aliasCallId,
                    )
                }
                if (callerAvatarBitmap(tag) == null && tag.isNotBlank()) {
                    scheduleCallerAvatar(
                        context,
                        tag,
                        callId,
                        resolved.peerAddress,
                        name,
                        sessionId,
                        tag,
                        claimedAddress,
                        identityWarning,
                        aliasCallId,
                    )
                }
                return
            }
            val avatar = callerAvatarBitmap(tag)
            val postedId = notificationId(primary)
            val firstArmClaimed = tag.ifBlank { claimed }
            val window = incomingWindowIntent(
                context,
                callId = callId,
                sessionId = sessionId,
                title = name,
                body = body,
                claimedTag = firstArmClaimed,
            )
            // Same requestCode as sendAllowlistedFullScreenIntent so NMS's
            // +30s FSI allowlist applies to the PendingIntent we send next.
            val fullScreen = IncomingCallActivity.buildFullScreenPendingIntent(
                context,
                window,
                IncomingCallActivity.fullScreenIntentRequestCode(window),
            )
            // CallStyle + CATEGORY_CALL is required for Android 14+ to auto-fire
            // FSI while the screen is on. Answer/Decline stay on IncomingCallActionReceiver.
            val answer = incomingActionPendingIntent(
                context, ACTION_ANSWER, callId, sessionId, postedId + 1,
            )
            val decline = incomingActionPendingIntent(
                context, ACTION_DECLINE, callId, sessionId, postedId + 2,
            )
            val personIcon = if (avatar != null) {
                IconCompat.createWithBitmap(avatar)
            } else {
                IconCompat.createWithResource(context, R.drawable.ic_incoming_call_status)
            }
            val person = Person.Builder()
                .setName(name)
                .setIcon(personIcon)
                .setImportant(true)
                .build()
            val builder = NotificationCompat.Builder(context, INCOMING_CALL_CHANNEL_ID)
                .setSmallIcon(R.drawable.ic_incoming_call_status)
                .setContentTitle(name)
                .setContentText(body)
                .setCategory(NotificationCompat.CATEGORY_CALL)
                .setPriority(NotificationCompat.PRIORITY_MAX)
                .setVisibility(NotificationCompat.VISIBILITY_PUBLIC)
                .setOngoing(true)
                .setAutoCancel(false)
                .setOnlyAlertOnce(true)
                .setTimeoutAfter(INCOMING_RING_TIMEOUT_MS)
                .setColor(0xFF1562F0.toInt())
                .setForegroundServiceBehavior(NotificationCompat.FOREGROUND_SERVICE_IMMEDIATE)
                .setFullScreenIntent(fullScreen, true)
                .setContentIntent(fullScreen)
                .setLargeIcon(avatar)
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.S) {
                builder.setStyle(
                    NotificationCompat.CallStyle.forIncomingCall(person, decline, answer),
                )
            } else {
                builder
                    .addAction(0, context.getString(R.string.incoming_call_decline), decline)
                    .addAction(0, context.getString(R.string.incoming_call_answer), answer)
            }
            val manager = NotificationManagerCompat.from(context)
            listOf(callId, sessionId, aliasCallId)
                .map { it.trim() }
                .filter { it.isNotBlank() && notificationId(it) != postedId }
                .forEach { alias -> manager.cancel(notificationId(alias)) }
            val fullScreenAllowed = if (Build.VERSION.SDK_INT >= 34) {
                context.getSystemService(android.app.NotificationManager::class.java)
                    ?.canUseFullScreenIntent() == true
            } else {
                true
            }
            Log.i(TAG, "fullScreenIntentAllowed=$fullScreenAllowed callStyle=true")
            // Glass FIRST while onShowIncomingCallUi binder BAL is live.
            // Notify / FGS after — those can take longer and burn the window.
            if (!IncomingCallActivity.isShowing()) {
                IncomingCallActivity.presentFromTelecomShowIncomingUi(context, window)
            }
            val glassUp = IncomingCallActivity.isShowing()
            val overlayUp = IncomingCallOverlay.isShowing()
            val keyguardLocked = isDeviceKeyguardLocked(context)
            // Lock / screen-off: always post CallStyle + FSI. Never quietOnly —
            // Activity/overlay "showing" under occluded keyguard is a lie and
            // demoting leaves the lock screen with no Beamio incoming at all.
            val quietOnly =
                !keyguardLocked && (glassUp || overlayUp)
            val notification = if (quietOnly) {
                Log.i(
                    TAG,
                    "Quiet keep-alive (skip CallStyle HUN) id=$postedId " +
                        "glassUp=$glassUp overlayUp=$overlayUp keyguardLocked=$keyguardLocked",
                )
                buildGlassKeepAliveNotification(
                    context,
                    callId = callId,
                    sessionId = sessionId,
                    title = name,
                    body = body,
                )
            } else {
                builder.build()
            }
            // Dual-post: NM.notify so system_server allowlists this same
            // fullScreen PendingIntent (+30s) when CallStyle path is used.
            // Quiet path only replaces any prior shade on this id.
            runCatching {
                manager.notify(postedId, notification)
                Log.i(
                    TAG,
                    if (quietOnly) {
                        "Quiet keep-alive NM.notify posted id=$postedId"
                    } else {
                        "CallStyle NM.notify posted id=$postedId"
                    },
                )
            }.onFailure {
                Log.w(TAG, "Incoming NM.notify failed id=$postedId", it)
            }
            if (quietOnly) {
                // Cancel any leftover CallStyle ids from a prior arm / wrong alias.
                cancelActiveCallStyleNotifications(context, keepId = postedId)
            }
            // Channel v15 plays the ringtone; avoid MediaPlayer double-ring.
            // FGS keep-alive may retry presentFromPhoneCallFgs if glass missing.
            ringKeys.forEach { armedCallStyleKeys.add(it) }
            lastArmedCallStyleTitle[primary] = name
            BeamioCallForegroundService.startIncoming(
                context,
                postedId,
                notification,
                // Always pass window: FGS skips present when glass is already up,
                // but needs callId/title extras to demote CallStyle without
                // resurrecting Decline/Answer over overlay glass.
                window,
            )
            // Demote whenever CallStyle was skipped OR glass is already up.
            // quietOnly alone (overlayOk) must demote leftovers from a prior arm.
            if (quietOnly) {
                demoteIncomingChromeAfterGlass(
                    context, callId, sessionId, name, body, aliasCallId = aliasCallId,
                )
                val main = android.os.Handler(android.os.Looper.getMainLooper())
                for (delayMs in longArrayOf(400L, 1_200L)) {
                    main.postDelayed(
                        {
                            if (productIncomingChromeVisible(context)) {
                                demoteIncomingChromeAfterGlass(
                                    context,
                                    callId,
                                    sessionId,
                                    name,
                                    body,
                                    aliasCallId = aliasCallId,
                                )
                            }
                        },
                        delayMs,
                    )
                }
            }
            Log.i(
                TAG,
                "Glass incoming FGS armed glassUp=$glassUp quietOnly=$quietOnly " +
                    "keyguardLocked=$keyguardLocked " +
                    "nameIsTag=${tag.isNotBlank()} " +
                    "walletLinePresent=${walletLine.isNotBlank()} bodyIsWarning=${resolved.identityWarning.isNotBlank()} " +
                    "avatarReady=${avatar != null}",
            )
            if (tag.isBlank()) {
                scheduleBeamioTagLookup(
                    context,
                    resolved.peerAddress,
                    callId,
                    sessionId,
                    firstArmClaimed,
                    claimedAddress,
                    identityWarning,
                    aliasCallId,
                )
            }
            if (avatar == null && tag.isNotBlank()) {
                scheduleCallerAvatar(
                    context,
                    tag,
                    callId,
                    resolved.peerAddress,
                    name,
                    sessionId,
                    firstArmClaimed,
                    claimedAddress,
                    identityWarning,
                    aliasCallId,
                )
            }
        }

        fun cachedCallerAvatar(displayName: String): Bitmap? = callerAvatarBitmap(displayName)

        /** Same seed as the PWA BeamioTag avatar (`fun-emoji` from the tag, without `@`). */
        private fun callerAvatarSeed(tag: String): String? {
            val seed = tag.trim().removePrefix("@").trim()
            if (seed.isEmpty() || seed.startsWith("0x", ignoreCase = true)) return null
            return seed
        }

        private fun callerAvatarBitmap(tag: String): Bitmap? {
            val seed = callerAvatarSeed(tag) ?: return null
            return callerAvatarBitmaps[seed.lowercase()]
        }

        private fun scheduleCallerAvatar(
            context: Context,
            tag: String,
            callId: String,
            peerAddress: String,
            displayName: String,
            sessionId: String,
            claimedTag: String,
            claimedAddress: String,
            identityWarning: String,
            aliasCallId: String,
        ) {
            val seed = callerAvatarSeed(tag) ?: return
            val key = seed.lowercase()
            if (callerAvatarBitmaps.containsKey(key) || !callerAvatarLoads.add(key)) return
            val app = context.applicationContext
            Thread {
                val bitmap = fetchCallerAvatar(seed)
                callerAvatarLoads.remove(key)
                if (bitmap == null) return@Thread
                callerAvatarBitmaps[key] = bitmap
                incomingRingHandler.post {
                    // Avatar may finish after Answer — still paint InCall.
                    if (InCallScreenModel.isLive() &&
                        InCallScreenModel.matches(callId, sessionId)
                    ) {
                        InCallActivity.refreshIdentityIfShowing(
                            callId,
                            sessionId,
                            tag = tag.ifBlank { claimedTag },
                            address = peerAddress,
                        )
                    }
                    if (incomingActionAlreadySettled(callId, sessionId)) return@post
                    if (incomingRingClock(callId, sessionId) == null &&
                        incomingRingClock(aliasCallId, sessionId) == null
                    ) {
                        return@post
                    }
                    showIncomingCallNotification(
                        app,
                        callId,
                        peerAddress,
                        displayName,
                        sessionId,
                        claimedTag,
                        claimedAddress,
                        identityWarning,
                        aliasCallId,
                    )
                }
            }.start()
        }

        /**
         * The decrypted offer first reports the caller's wallet. After lookup,
         * refresh the glass window title with BeamioTag.
         */
        private fun scheduleBeamioTagLookup(
            context: Context,
            peerAddress: String,
            callId: String,
            sessionId: String,
            claimedTag: String,
            claimedAddress: String,
            identityWarning: String,
            aliasCallId: String,
        ) {
            val address = peerAddress.trim()
            if (!address.startsWith("0x", ignoreCase = true) || address.length < 42) return
            val key = address.lowercase()
            if (!beamioTagLookups.add(key)) return
            val app = context.applicationContext
            Thread {
                val lookedUp = fetchBeamioTag(address)
                beamioTagLookups.remove(key)
                if (lookedUp.isNullOrBlank()) return@Thread
                incomingRingHandler.post {
                    Log.i(TAG, "Caller BeamioTag resolved")
                    listOf(callId, sessionId, aliasCallId)
                        .map { it.trim() }
                        .filter { it.isNotBlank() }
                        .distinct()
                        .forEach { rememberKey ->
                            rememberShownCaller(
                                app,
                                rememberKey,
                                address,
                                lookedUp,
                                lookedUp,
                                claimedAddress,
                                identityWarning,
                            )
                        }
                    // Answer may have already opened InCall without @tag —
                    // always push verified identity onto the live call page.
                    if (InCallScreenModel.isLive() &&
                        InCallScreenModel.matches(callId, sessionId)
                    ) {
                        InCallActivity.refreshIdentityIfShowing(
                            callId,
                            sessionId,
                            tag = lookedUp,
                            address = address,
                        )
                        if (callerAvatarBitmap(lookedUp) == null) {
                            scheduleCallerAvatar(
                                app,
                                lookedUp,
                                callId,
                                address,
                                lookedUp,
                                sessionId,
                                lookedUp,
                                claimedAddress,
                                identityWarning,
                                aliasCallId,
                            )
                        }
                    }
                    if (incomingActionAlreadySettled(callId, sessionId)) return@post
                    showIncomingCallNotification(
                        app,
                        callId,
                        address,
                        lookedUp,
                        sessionId,
                        // Verified lookup becomes claimedTag so CallStyle /
                        // Activity keep @tag across soft-reassert / demote.
                        lookedUp,
                        claimedAddress,
                        identityWarning,
                        aliasCallId,
                    )
                }
            }.start()
        }

        private fun fetchBeamioTag(address: String): String? {
            val encoded = URLEncoder.encode(address, Charsets.UTF_8.name())
            val connection = (URL(
                "https://beamio.app/api/search-users?keyward=$encoded",
            ).openConnection() as HttpURLConnection).apply {
                connectTimeout = 4000
                readTimeout = 4000
                instanceFollowRedirects = true
            }
            return try {
                if (connection.responseCode !in 200..299) {
                    Log.w(TAG, "Caller tag HTTP ${connection.responseCode}")
                    null
                } else {
                    val body = connection.inputStream.bufferedReader().use { it.readText() }
                    val results = JSONObject(body).optJSONArray("results") ?: return null
                    val want = address.lowercase()
                    var tag: String? = null
                    for (index in 0 until results.length()) {
                        val row = results.optJSONObject(index) ?: continue
                        val rowAddress = row.optString("address").trim().lowercase()
                        if (rowAddress != want) continue
                        val username = row.optString("username").ifBlank { row.optString("accountName") }
                        tag = formatLookedUpTag(username)
                        break
                    }
                    tag
                }
            } catch (error: Exception) {
                Log.w(TAG, "Caller tag lookup failed ${error.javaClass.simpleName}")
                null
            } finally {
                connection.disconnect()
            }
        }

        private fun formatLookedUpTag(username: String): String? {
            val raw = username.trim().removePrefix("@")
            if (!raw.matches(Regex("^[A-Za-z0-9_]{1,32}$"))) return null
            if (raw.matches(Regex("^[0-9a-fA-F]{16,32}$"))) return null
            return "@$raw"
        }

        /** BeamioTag avatar is a circle, same as the PWA fun-emoji seed. */
        private fun circleCrop(source: Bitmap): Bitmap {
            val size = minOf(source.width, source.height).coerceAtLeast(1)
            val output = Bitmap.createBitmap(size, size, Bitmap.Config.ARGB_8888)
            val canvas = Canvas(output)
            val paint = Paint(Paint.ANTI_ALIAS_FLAG)
            canvas.drawCircle(size / 2f, size / 2f, size / 2f, paint)
            paint.xfermode = PorterDuffXfermode(PorterDuff.Mode.SRC_IN)
            val left = (source.width - size) / 2
            val top = (source.height - size) / 2
            canvas.drawBitmap(
                source,
                Rect(left, top, left + size, top + size),
                Rect(0, 0, size, size),
                paint,
            )
            if (output !== source) source.recycle()
            return output
        }

        private fun fetchCallerAvatar(seed: String): Bitmap? {
            val encoded = URLEncoder.encode(seed, Charsets.UTF_8.name())
            val connection = (URL(
                "https://api.dicebear.com/8.x/fun-emoji/png?seed=$encoded&size=192",
            ).openConnection() as HttpURLConnection).apply {
                connectTimeout = 4000
                readTimeout = 4000
                instanceFollowRedirects = true
            }
            return try {
                if (connection.responseCode !in 200..299) {
                    Log.w(TAG, "Caller avatar HTTP ${connection.responseCode}")
                    null
                } else {
                    connection.inputStream.use {
                        val raw = BitmapFactory.decodeStream(it) ?: return@use null
                        circleCrop(raw)
                    }
                }
            } catch (error: Exception) {
                Log.w(TAG, "Caller avatar fetch failed ${error.javaClass.simpleName}")
                null
            } finally {
                connection.disconnect()
            }
        }

        /**
         * Mailbox/FCM wake path. Posts the glass incoming window immediately
         * (Decline / Answer). Caller identity is filled in when the PWA later
         * reports the decrypted offer on the same notification id.
         */
        fun showIncomingCallWakeNotification(
            context: Context,
            callId: String,
            sessionId: String,
        ) {
            if (callId.isBlank() && sessionId.isBlank()) return
            if (wasBusyRejected(callId, sessionId)) return
            reportIncoming(
                context,
                callId = callId.ifBlank { sessionId },
                peerAddress = "",
                displayName = "",
                sessionId = sessionId,
            )
            if (wasBusyRejected(callId, sessionId)) return
            // A second call waiting for its caller (busy or replacing the ring): no raise.
            if (isAwaitingSecondaryCaller(callId, sessionId)) return
            wakeConsumerShell(context)
        }

        private fun wakeConsumerShell(context: Context) {
            // Delegates to MainActivity.wakeConsumerShell — raises the opaque
            // app task before same-task translucent glass can become visible.
            MainActivity.wakeConsumerShell(context)
        }

        fun ensureIncomingCallChannel(context: Context) {
            if (Build.VERSION.SDK_INT < Build.VERSION_CODES.O) return
            val manager = context.getSystemService(android.app.NotificationManager::class.java) ?: return
            // v15: HIGH CallStyle + ringtone/vib so Samsung interrupts and can
            // fire FSI. Delete older channels — Android will not raise an
            // existing channel's importance / sound after creation.
            for (old in 7..14) {
                runCatching { manager.deleteNotificationChannel("beamio_incoming_calls_v$old") }
            }
            val ringtone = android.media.RingtoneManager.getDefaultUri(
                android.media.RingtoneManager.TYPE_RINGTONE,
            )
            val audioAttrs = android.media.AudioAttributes.Builder()
                .setUsage(android.media.AudioAttributes.USAGE_NOTIFICATION_RINGTONE)
                .setContentType(android.media.AudioAttributes.CONTENT_TYPE_SONIFICATION)
                .build()
            val channel = android.app.NotificationChannel(
                INCOMING_CALL_CHANNEL_ID,
                "Incoming calls",
                android.app.NotificationManager.IMPORTANCE_HIGH,
            ).apply {
                description =
                    "Incoming Beamio voice calls. Opens the full-screen incoming window."
                lockscreenVisibility = Notification.VISIBILITY_PUBLIC
                setSound(ringtone, audioAttrs)
                enableVibration(true)
                vibrationPattern = longArrayOf(0L, 500L, 500L, 500L)
                setShowBadge(false)
            }
            manager.createNotificationChannel(channel)
            ensureGlassKeepAliveChannel(context)
        }

        /** MIN + silent — FGS keep-alive must never heads-up over Beamio glass. */
        private fun ensureGlassKeepAliveChannel(context: Context) {
            if (Build.VERSION.SDK_INT < Build.VERSION_CODES.O) return
            val manager = context.getSystemService(android.app.NotificationManager::class.java) ?: return
            val channel = android.app.NotificationChannel(
                GLASS_KEEPALIVE_CHANNEL_ID,
                "Call keep-alive",
                android.app.NotificationManager.IMPORTANCE_MIN,
            ).apply {
                description =
                    "Silent status while the Beamio incoming call window is open. No alerts."
                lockscreenVisibility = Notification.VISIBILITY_SECRET
                setSound(null, null)
                enableVibration(false)
                setShowBadge(false)
            }
            manager.createNotificationChannel(channel)
        }

        /**
         * CallStyle Answer/Decline must be [PendingIntent.FLAG_MUTABLE] so the
         * system can attach extras. Used only for CallStyle action buttons.
         */
        private fun incomingActionPendingIntent(
            context: Context,
            action: String,
            callId: String,
            sessionId: String,
            requestCode: Int,
        ): PendingIntent {
            val intent = Intent(context, IncomingCallActionReceiver::class.java).apply {
                this.action = action
                putExtra(EXTRA_CALL_ID, callId)
                putExtra(EXTRA_SESSION_ID, sessionId)
            }
            val flags = PendingIntent.FLAG_UPDATE_CURRENT or
                if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.S) {
                    PendingIntent.FLAG_MUTABLE
                } else {
                    0
                }
            return PendingIntent.getBroadcast(context, requestCode, intent, flags)
        }

        /**
         * Quiet FGS keep-alive after glass is visible. Replaces CallStyle so
         * Samsung does not leave a second Answer/Decline heads-up over the glass.
         */
        fun buildGlassKeepAliveNotification(
            context: Context,
            callId: String,
            sessionId: String,
            title: String,
            body: String,
        ): Notification {
            ensureGlassKeepAliveChannel(context)
            val window = incomingWindowIntent(
                context,
                callId = callId,
                sessionId = sessionId,
                title = title,
                body = body,
                claimedTag = "",
            )
            val content = IncomingCallActivity.buildFullScreenPendingIntent(
                context,
                window,
                IncomingCallActivity.fullScreenIntentRequestCode(window),
            )
            return NotificationCompat.Builder(context, GLASS_KEEPALIVE_CHANNEL_ID)
                .setSmallIcon(R.drawable.ic_incoming_call_status)
                .setContentTitle(title.ifBlank { "Incoming call" })
                .setContentText(body.ifBlank { context.getString(R.string.incoming_call_glass_subtitle) })
                .setCategory(NotificationCompat.CATEGORY_SERVICE)
                .setPriority(NotificationCompat.PRIORITY_MIN)
                .setVisibility(NotificationCompat.VISIBILITY_SECRET)
                .setOngoing(true)
                .setAutoCancel(false)
                .setOnlyAlertOnce(true)
                .setSilent(true)
                .setTimeoutAfter(INCOMING_RING_TIMEOUT_MS)
                .setColor(0xFF1562F0.toInt())
                .setForegroundServiceBehavior(NotificationCompat.FOREGROUND_SERVICE_IMMEDIATE)
                .setContentIntent(content)
                .build()
        }

        /**
         * Quietly refresh an already-armed CallStyle Person/title under lock
         * after BeamioTag resolve. [NotificationCompat.Builder.setOnlyAlertOnce]
         * keeps ringtone/FSI; same notification id so Samsung does not treat
         * this as a second incoming call.
         */
        private fun quietlyRefreshArmedCallStyle(
            context: Context,
            primary: String,
            callId: String,
            sessionId: String,
            name: String,
            body: String,
            claimedTag: String,
            aliasCallId: String,
        ) {
            val postedId = notificationId(primary)
            if (postedId == 0 || name.isBlank()) return
            val title = name.trim()
            val text = body.ifBlank { context.getString(R.string.incoming_call_glass_subtitle) }
            val avatar = callerAvatarBitmap(claimedTag.ifBlank { title })
            val personIcon = if (avatar != null) {
                IconCompat.createWithBitmap(avatar)
            } else {
                IconCompat.createWithResource(context, R.drawable.ic_incoming_call_status)
            }
            val person = Person.Builder()
                .setName(title)
                .setIcon(personIcon)
                .setImportant(true)
                .build()
            val window = incomingWindowIntent(
                context,
                callId = callId,
                sessionId = sessionId,
                title = title,
                body = text,
                claimedTag = claimedTag.ifBlank { title.takeIf(::isBeamioTag).orEmpty() },
            )
            val fullScreen = IncomingCallActivity.buildFullScreenPendingIntent(
                context,
                window,
                IncomingCallActivity.fullScreenIntentRequestCode(window),
            )
            val answer = incomingActionPendingIntent(
                context, ACTION_ANSWER, callId, sessionId, postedId + 1,
            )
            val decline = incomingActionPendingIntent(
                context, ACTION_DECLINE, callId, sessionId, postedId + 2,
            )
            val builder = NotificationCompat.Builder(context, INCOMING_CALL_CHANNEL_ID)
                .setSmallIcon(R.drawable.ic_incoming_call_status)
                .setContentTitle(title)
                .setContentText(text)
                .setCategory(NotificationCompat.CATEGORY_CALL)
                .setPriority(NotificationCompat.PRIORITY_MAX)
                .setVisibility(NotificationCompat.VISIBILITY_PUBLIC)
                .setOngoing(true)
                .setAutoCancel(false)
                .setOnlyAlertOnce(true)
                .setTimeoutAfter(INCOMING_RING_TIMEOUT_MS)
                .setColor(0xFF1562F0.toInt())
                .setForegroundServiceBehavior(NotificationCompat.FOREGROUND_SERVICE_IMMEDIATE)
                .setFullScreenIntent(fullScreen, true)
                .setContentIntent(fullScreen)
                .setLargeIcon(avatar)
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.S) {
                builder.setStyle(
                    NotificationCompat.CallStyle.forIncomingCall(person, decline, answer),
                )
            } else {
                builder
                    .addAction(0, context.getString(R.string.incoming_call_decline), decline)
                    .addAction(0, context.getString(R.string.incoming_call_answer), answer)
            }
            val notification = builder.build()
            runCatching {
                NotificationManagerCompat.from(context).notify(postedId, notification)
                BeamioCallForegroundService.refreshIncomingCallStyle(
                    context,
                    postedId,
                    notification,
                )
                Log.i(
                    TAG,
                    "Quiet CallStyle identity refresh id=$postedId title=$title " +
                        "aliasPresent=${aliasCallId.isNotBlank()} avatarReady=${avatar != null}",
                )
            }.onFailure {
                Log.w(TAG, "Quiet CallStyle identity refresh failed id=$postedId", it)
            }
        }

        /** Demote CallStyle shade once glass (Activity or overlay) is on screen. */
        fun demoteIncomingChromeAfterGlass(
            context: Context,
            callId: String,
            sessionId: String,
            title: String = "",
            body: String = "",
            aliasCallId: String = "",
        ) {
            // Lock / screen-off: always keep CallStyle FSI. Activity may report
            // isShowing while occluded behind Samsung keyguard — demoting then
            // replaces FSI with silent keep-alive and the user sees nothing.
            if (isDeviceKeyguardLocked(context)) {
                Log.i(
                    TAG,
                    "Skip CallStyle demote; keyguard/screen-off — CallStyle FSI owns lock UI " +
                        "activityUp=${IncomingCallActivity.isShowing()}",
                )
                return
            }
            val keys = listOf(callId, sessionId, aliasCallId)
                .map { it.trim() }
                .filter { it.isNotBlank() }
                .distinct()
            // Must include aliasCallId — CallStyle was posted on
            // notificationId(primaryNotificationKey(..., aliasCallId)).
            val primary = primaryNotificationKey(context, *keys.toTypedArray())
            BeamioCallForegroundService.demoteIncomingAfterGlass(
                context,
                callId = callId,
                sessionId = sessionId,
                title = title.ifBlank { "Incoming call" },
                body = body.ifBlank { context.getString(R.string.incoming_call_glass_subtitle) },
                notificationId = notificationId(primary),
                aliasKeys = keys,
            )
        }

        /**
         * Cancel every active CATEGORY_CALL / CallStyle shade on the incoming
         * channel except [keepId] (quiet FGS keep-alive). Used when glass is up
         * so Samsung HUN cannot cover TYPE_APPLICATION_OVERLAY.
         */
        fun cancelActiveCallStyleNotifications(context: Context, keepId: Int) {
            val compat = NotificationManagerCompat.from(context)
            if (Build.VERSION.SDK_INT < Build.VERSION_CODES.M) return
            val nm = context.getSystemService(android.app.NotificationManager::class.java) ?: return
            nm.activeNotifications?.forEach { status ->
                if (status.id == keepId) return@forEach
                val n = status.notification
                val channelId = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
                    n.channelId.orEmpty()
                } else {
                    ""
                }
                val isIncomingChannel = channelId.startsWith("beamio_incoming_calls")
                val isCallCategory = n.category == Notification.CATEGORY_CALL
                if (!isIncomingChannel && !isCallCategory) return@forEach
                if (!isCallCategory && (n.flags and Notification.FLAG_FOREGROUND_SERVICE) != 0) {
                    // Quiet CATEGORY_SERVICE FGS keep-alive — leave alone.
                    return@forEach
                }
                if (!isCallCategory) return@forEach
                nm.cancel(status.id)
                nm.cancel(status.tag, status.id)
                compat.cancel(status.id)
                compat.cancel(status.tag, status.id)
                Log.i(
                    TAG,
                    "Cancelled CallStyle HUN over glass id=${status.id} channel=$channelId",
                )
            }
        }

        /**
         * Drop leftover incoming FGS / shade cards when glass is not on screen
         * (force-stop / crash / MainActivity resume ghosts on Samsung).
         *
         * If Telecom still thinks a call is RINGING but [IncomingCallActivity]
         * is gone, tear down that orphan — otherwise Samsung keeps the old
         * CATEGORY_CALL shade stacked as a second "window".
         */
        fun dismissStaleIncomingUi(context: Context) {
            val glassShowing = IncomingCallActivity.isShowing()
            // Live glass must never be torn down from MainActivity.onResume —
            // Telecom RINGING can lag a beat, and same-process multi-resume used
            // to finish the window while the user still needed it.
            if (glassShowing) return
            // bringAppTaskForward raises opaque MainActivity so same-task glass
            // can become visible. That resume used to tear down RINGING + FGS
            // before BAL retries could show IncomingCallActivity — browser dial
            // then never showed a window. Skip while present is in flight or
            // Telecom is still RINGING; onIncomingGlassPresentFailed cleans up.
            if (IncomingCallActivity.isPresentInFlight()) {
                Log.i(TAG, "Stale dismiss skipped; glass present in flight")
                return
            }
            val hasRinging = activeConnections.values.any { conn ->
                conn.isIncomingCall() && conn.state == Connection.STATE_RINGING
            }
            if (hasRinging) {
                Log.i(TAG, "Stale dismiss skipped; RINGING without glass (present pending)")
                return
            }

            BeamioCallForegroundService.stop(context)
            BeamioIncomingRingtone.stop()
            IncomingCallActivity.finishIfShowing()
            ensureIncomingCallChannel(context)
            val compat = NotificationManagerCompat.from(context)
            val prefs = context.getSharedPreferences(NOTIFICATION_ALIAS_PREFS, Context.MODE_PRIVATE)
            prefs.all.values.mapNotNull { it as? String }.filter { it.isNotBlank() }.distinct()
                .forEach { key ->
                    val id = notificationId(key)
                    compat.cancel(id)
                    compat.cancel(null, id)
                }
            prefs.edit().clear().apply()
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.M) {
                val nm = context.getSystemService(android.app.NotificationManager::class.java)
                nm?.activeNotifications?.forEach { status ->
                    val n = status.notification
                    val channelId = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
                        n.channelId.orEmpty()
                    } else {
                        ""
                    }
                    val isIncomingChannel = channelId.startsWith("beamio_incoming_calls")
                    val isCallCategory = n.category == Notification.CATEGORY_CALL
                    val isServiceCategory = n.category == Notification.CATEGORY_SERVICE
                    val isFgs = (n.flags and Notification.FLAG_FOREGROUND_SERVICE) != 0
                    if (!isIncomingChannel && !isCallCategory && !(isServiceCategory && isFgs) && !isFgs) {
                        return@forEach
                    }
                    nm.cancel(status.id)
                    nm.cancel(status.tag, status.id)
                    compat.cancel(status.id)
                    compat.cancel(status.tag, status.id)
                    Log.i(
                        TAG,
                        "Cancelled stale call notification id=${status.id} " +
                            "channel=$channelId category=${n.category} fgs=$isFgs",
                    )
                }
            }
            // Orphan teardown never called releaseChromeOwner — leftover claims made
            // the next browser→Android dial busy-reject with no glass.
            if (BeamioNativeVoiceSignaling.currentActiveCall() == null &&
                activeConnections.values.none { it.occupiesVoiceChrome() }
            ) {
                releaseChromeOwner("", "")
            }
            BeamioNativeVoiceSignaling.flushDeferredStickyDeclinesIfIdle()
            Log.i(TAG, "Stale incoming UI dismissed")
        }

        fun ensureOngoingCallChannel(context: Context) {
            if (Build.VERSION.SDK_INT < Build.VERSION_CODES.O) return
            val manager = context.getSystemService(android.app.NotificationManager::class.java) ?: return
            val channel = android.app.NotificationChannel(
                ONGOING_CALL_CHANNEL_ID,
                "Ongoing calls",
                android.app.NotificationManager.IMPORTANCE_DEFAULT,
            ).apply {
                description = "Status bar control for an active Beamio voice call"
                lockscreenVisibility = Notification.VISIBILITY_PUBLIC
                setSound(null, null)
                enableVibration(false)
                setShowBadge(false)
            }
            manager.createNotificationChannel(channel)
        }

        fun buildMutedIncomingNotification(context: Context): Notification {
            ensureMutedIncomingChannel(context)
            return NotificationCompat.Builder(context, MUTED_INCOMING_CHANNEL_ID)
                .setSmallIcon(context.applicationInfo.icon)
                .setContentTitle(context.getString(R.string.incoming_call_muted_title))
                .setContentText(context.getString(R.string.incoming_call_muted_text))
                .setCategory(NotificationCompat.CATEGORY_SERVICE)
                .setPriority(NotificationCompat.PRIORITY_MIN)
                .setSilent(true)
                .setOngoing(true)
                .setOnlyAlertOnce(true)
                .setForegroundServiceBehavior(NotificationCompat.FOREGROUND_SERVICE_IMMEDIATE)
                .build()
        }

        fun ensureMutedIncomingChannel(context: Context) {
            if (Build.VERSION.SDK_INT < Build.VERSION_CODES.O) return
            val manager = context.getSystemService(android.app.NotificationManager::class.java) ?: return
            val channel = android.app.NotificationChannel(
                MUTED_INCOMING_CHANNEL_ID,
                "Muted incoming calls",
                android.app.NotificationManager.IMPORTANCE_MIN,
            ).apply {
                description = "Keeps a muted incoming call alive until it times out"
                setSound(null, null)
                enableVibration(false)
                setShowBadge(false)
            }
            manager.createNotificationChannel(channel)
        }

        fun buildQuietOngoingCallNotification(context: Context, callId: String): Notification {
            ensureQuietAnsweredCallChannel(context)
            val openPending = activeCallPendingIntent(context, callId, "")
            return NotificationCompat.Builder(context, QUIET_ANSWERED_CHANNEL_ID)
                .setSmallIcon(context.applicationInfo.icon)
                .setContentTitle("Voice call")
                .setContentText("In the app")
                .setCategory(NotificationCompat.CATEGORY_SERVICE)
                .setPriority(NotificationCompat.PRIORITY_MIN)
                .setSilent(true)
                .setOngoing(true)
                .setOnlyAlertOnce(true)
                .setContentIntent(openPending)
                .setForegroundServiceBehavior(NotificationCompat.FOREGROUND_SERVICE_IMMEDIATE)
                .build()
        }

        fun ensureQuietAnsweredCallChannel(context: Context) {
            if (Build.VERSION.SDK_INT < Build.VERSION_CODES.O) return
            val manager = context.getSystemService(android.app.NotificationManager::class.java) ?: return
            val channel = android.app.NotificationChannel(
                QUIET_ANSWERED_CHANNEL_ID,
                "Active voice call",
                android.app.NotificationManager.IMPORTANCE_MIN,
            ).apply {
                description = "Keeps an answered Beamio call running in the app"
                setSound(null, null)
                enableVibration(false)
                setShowBadge(false)
            }
            manager.createNotificationChannel(channel)
        }

        fun buildOngoingCallNotification(context: Context, callId: String, sessionId: String = ""): Notification {
            ensureOngoingCallChannel(context)
            val openPending = activeCallPendingIntent(context, callId, sessionId)
            val hangup = PendingIntent.getBroadcast(
                context,
                notificationId(callId) + 12,
                Intent(context, IncomingCallActionReceiver::class.java).apply {
                    action = ACTION_HANGUP
                    putExtra(EXTRA_CALL_ID, callId)
                    putExtra(EXTRA_SESSION_ID, sessionId)
                },
                PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE,
            )
            val person = Person.Builder()
                .setName("Voice call")
                .setIcon(IconCompat.createWithResource(context, context.applicationInfo.icon))
                .setImportant(true)
                .build()
            val builder = NotificationCompat.Builder(context, ONGOING_CALL_CHANNEL_ID)
                .setSmallIcon(R.drawable.ic_incoming_call_status)
                .setContentTitle("Voice call")
                .setContentText("Tap to return to the call")
                .setCategory(NotificationCompat.CATEGORY_CALL)
                .setOngoing(true)
                .setOnlyAlertOnce(true)
                .setVisibility(NotificationCompat.VISIBILITY_PUBLIC)
                .setColor(0xFF1562F0.toInt())
                .setContentIntent(openPending)
                .setForegroundServiceBehavior(NotificationCompat.FOREGROUND_SERVICE_IMMEDIATE)
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.S) {
                builder.setStyle(NotificationCompat.CallStyle.forOngoingCall(person, hangup))
            }
            return builder.build()
        }

        private fun activeCallPendingIntent(context: Context, callId: String, sessionId: String): PendingIntent {
            val openIntent = Intent(context, MainActivity::class.java).apply {
                action = "com.beamio.app.action.SHOW_ACTIVE_CALL"
                flags = Intent.FLAG_ACTIVITY_SINGLE_TOP or Intent.FLAG_ACTIVITY_CLEAR_TOP or
                    Intent.FLAG_ACTIVITY_NEW_TASK or Intent.FLAG_ACTIVITY_REORDER_TO_FRONT
                putExtra(EXTRA_SHOW_ACTIVE_CALL, true)
                putExtra(EXTRA_CALL_ID, callId)
                putExtra(EXTRA_SESSION_ID, sessionId)
            }
            val flags = PendingIntent.FLAG_UPDATE_CURRENT or
                if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.M) {
                    PendingIntent.FLAG_IMMUTABLE
                } else {
                    0
                }
            return PendingIntent.getActivity(context, notificationId(callId) + 10, openIntent, flags)
        }

        fun notificationId(callId: String): Int {
            val hash = callId.hashCode() and 0x7fffffff
            return 52_000 + (hash % 8_000)
        }

        private fun isWalletAddress(name: String): Boolean {
            val trimmed = name.trim()
            return trimmed.startsWith("0x", ignoreCase = true) && trimmed.length >= 42
        }

        private fun isBeamioTag(name: String): Boolean {
            val trimmed = name.trim()
            return trimmed.startsWith("@") && !isGenericCallerName(trimmed)
        }

        /** Address capsule text that fits a CallStyle line: `0x1234…5678`. */
        private fun shortWallet(raw: String): String {
            val value = raw.trim()
            if (!value.startsWith("0x", ignoreCase = true) || value.length < 10) return ""
            return value.take(6) + "…" + value.takeLast(4)
        }

        private fun isGenericCallerName(name: String): Boolean {
            val trimmed = name.trim()
            return trimmed.isBlank() ||
                trimmed == "Incoming voice call" ||
                trimmed == "Beamio Audio.." ||
                trimmed == "Incoming call" ||
                trimmed == "Connecting to Beamio" ||
                trimmed == "Beamio contact"
        }

        /** One shade card when FCM callId and the later sessionId differ. */
        private fun primaryNotificationKey(context: Context, vararg keys: String): String {
            val aliases = keys.map { it.trim() }.filter { it.isNotBlank() }.distinct()
            if (aliases.isEmpty()) return ""
            val prefs = context.getSharedPreferences(NOTIFICATION_ALIAS_PREFS, Context.MODE_PRIVATE)
            val existing = aliases.firstNotNullOfOrNull { prefs.getString("alias:$it", null)?.takeIf { key -> key.isNotBlank() } }
            val primary = existing ?: aliases.first()
            val editor = prefs.edit()
            aliases.forEach { editor.putString("alias:$it", primary) }
            editor.apply()
            return primary
        }

        fun cancelIncomingNotifications(context: Context, callId: String, sessionId: String) {
            IncomingCallActivity.cancelAlarmClockGlassPresent(context, callId, sessionId)
            val manager = NotificationManagerCompat.from(context)
            val aliases = listOf(callId, sessionId).map { it.trim() }.filter { it.isNotBlank() }.distinct()
            val prefs = context.getSharedPreferences(NOTIFICATION_ALIAS_PREFS, Context.MODE_PRIVATE)
            val primary = aliases.firstNotNullOfOrNull { prefs.getString("alias:$it", null) }.orEmpty()
            val keepForegroundId = BeamioCallForegroundService.activeForegroundNotificationId
            (aliases + listOf(primary)).filter { it.isNotBlank() }.distinct().forEach { key ->
                val id = notificationId(key)
                if (id != keepForegroundId) manager.cancel(id)
                armedCallStyleKeys.remove(key)
                lastArmedCallStyleTitle.remove(key)
            }
            val editor = prefs.edit()
            aliases.forEach { editor.remove("alias:$it") }
            editor.apply()
        }

        private const val TAG = "BeamioVoiceCall"
    }
}
