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
        return BeamioConnection(
            this, callId, displayName, peerAddress, sessionId,
            claimedTag, claimedAddress, identityWarning,
            originalCallId = originalCallId,
            incoming = true,
        )
    }

    override fun onCreateOutgoingConnection(
        connectionManagerPhoneAccount: PhoneAccountHandle?,
        request: ConnectionRequest,
    ): Connection {
        val callId = request.address?.schemeSpecificPart.orEmpty()
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
            if (incoming) setRinging() else setDialing()
        }

        fun isIncomingCall(): Boolean = incoming

        override fun onShowIncomingCallUi() {
            // Ringing still uses the incoming card. Once the call is up, the
            // status-bar chip must return to the in-app call page.
            val stillRinging = incoming && state == STATE_RINGING
            if (!stillRinging) {
                openActiveCallScreen(context, callId, sessionId)
                return
            }
            showIncomingCallNotification(
                context, callId, peerAddress, displayName, sessionId,
                claimedTag, claimedAddress, identityWarning,
            )
        }

        fun updateCallerDisplayName(name: String) {
            if (!incoming || name.isBlank()) return
            setCallerDisplayName(name, TelecomManager.PRESENTATION_ALLOWED)
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
        const val EXTRA_WAKE_FOR_CALL = "beamio.wake_for_call"
        const val EXTRA_SHOW_ACTIVE_CALL = "beamio.show_active_call"
        // Self-managed VoIP account. Stock dialer UI is default-dialer only;
        // CallStyle heads-up is the third-party incoming-call card.
        private const val ACCOUNT_ID = "beamio_system_phone_v3"
        private const val PHONE_SCHEME = "beamio-call"
        private const val ACTION_PREFS = "beamio_telecom_pending_action"
        private const val ACTION_KEY = "action"
        private const val CALL_ID_KEY = "call_id"
        private const val SESSION_ID_KEY = "session_id"
        private const val CALLER_POOL_PREFS = "beamio_pending_caller_pool_v1"
        private const val CALLER_POOL_TTL_MS = 2 * 60 * 1000L
        private val activeConnections = ConcurrentHashMap<String, BeamioConnection>()
        // FCM may create the Telecom call before the PWA has verified the
        // caller. Keep a process-local submission set so the later verified
        // report only updates the existing call instead of submitting a
        // second self-managed call (which OEM Telecom rejects as a duplicate
        // ringing call).
        private val submittedIncomingCalls = ConcurrentHashMap.newKeySet<String>()

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
            val merged = ShownCaller(
                peerAddress = peerAddress.ifBlank { previous?.peerAddress.orEmpty() },
                displayName = when {
                    isBeamioTag(displayName) -> displayName.trim()
                    previousTag != null && generic -> previousTag
                    generic -> previous?.displayName?.takeUnless(::isGenericCallerName) ?: displayName
                    else -> displayName
                },
                claimedTag = claimedTag.ifBlank { previous?.claimedTag.orEmpty() },
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
            return ShownCaller(
                peerAddress = stored.peerAddress.ifBlank { fallback.peerAddress },
                displayName = displayName,
                claimedTag = stored.claimedTag.ifBlank { fallback.claimedTag },
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
            settledCallActions.remove(settleKey("callAnswered", nativeCallId))
            settledCallActions.remove(settleKey("callRejected", nativeCallId))
            settledCallActions.remove(settleKey("callEnded", nativeCallId))
            ensurePhoneAccount(context)
            // Post CallStyle before Telecom so the shade card is Decline/Answer
            // even when addNewIncomingCall is rejected. Same id for callId and sessionId.
            showIncomingCallNotification(
                context, nativeCallId, shown.peerAddress, shown.displayName, sessionId,
                shown.claimedTag, shown.claimedAddress, shown.identityWarning,
                aliasCallId = callId,
            )
            val telecom = context.getSystemService(TelecomManager::class.java) ?: return
            val handle = phoneAccountHandle(context)
            activeConnections[nativeCallId]?.updateCallerDisplayName(shown.displayName)
            if (callId.isNotBlank()) activeConnections[callId]?.updateCallerDisplayName(shown.displayName)
            if (sessionId.isNotBlank()) activeConnections[sessionId]?.updateCallerDisplayName(shown.displayName)
            val callKeys = callerLookupKeys(callId, nativeCallId, sessionId, null)
            val alreadySubmitted = callKeys.any { submittedIncomingCalls.contains(it) }
            if (alreadySubmitted) {
                Log.i(
                    TAG,
                    "Telecom incoming call already submitted; updated caller only " +
                        "callIdPresent=${callId.isNotBlank()} " +
                        "sessionIdPresent=${sessionId.isNotBlank()}",
                )
                return
            }
            callKeys.forEach { submittedIncomingCalls.add(it) }
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
                Log.i(TAG, "Telecom addNewIncomingCall submitted")
            } catch (error: Exception) {
                callKeys.forEach { submittedIncomingCalls.remove(it) }
                Log.w(TAG, "Telecom addNewIncomingCall failed; CallStyle notification remains", error)
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

        fun startOutgoing(context: Context, callId: String, handle: String) {
            if (activeConnections.values.any { it.isIncomingCall() }) {
                Log.i(TAG, "placeCall skipped; answered incoming call stays in the app")
                return
            }
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

        fun end(context: Context, callId: String, sessionId: String = "") {
            val id = callId.ifBlank { sessionId }
            completeIncomingUserAction(context, "callEnded", id, sessionId, fromTelecom = false)
        }

        /**
         * Hide the incoming card and stop the ringtone. The call stays unanswered:
         * the ring clock keeps running, and the PWA still sends timeout to the caller.
         */
        fun silenceIncomingWindow(context: Context, callId: String, sessionId: String) {
            incomingRingKeys(callId, sessionId).forEach { mutedIncomingKeys.add(it) }
            Log.i(TAG, "Incoming window muted callIdPresent=${callId.isNotBlank()} sessionIdPresent=${sessionId.isNotBlank()}")
            IncomingCallActivity.stopRinging()
            IncomingCallActivity.finishIfMatching(callId, sessionId)
            if (callId.isNotBlank() || sessionId.isNotBlank()) {
                BeamioCallForegroundService.holdMutedIncoming(context, callId, sessionId)
            }
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

        private const val INCOMING_CALL_CHANNEL_ID = "beamio_incoming_calls_v7"
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
        private const val INCOMING_RING_REARM_SLACK_MS = 3_000L

        private class IncomingRingClock(
            val startedAt: Long,
            val runnable: Runnable,
        )

        private val incomingRingClocks = ConcurrentHashMap<String, IncomingRingClock>()
        private val incomingRingHandler = Handler(Looper.getMainLooper())
        private val callerAvatarBitmaps = ConcurrentHashMap<String, Bitmap>()
        private val callerAvatarLoads = ConcurrentHashMap.newKeySet<String>()
        private val beamioTagLookups = ConcurrentHashMap.newKeySet<String>()
        private val mutedIncomingKeys = ConcurrentHashMap.newKeySet<String>()

        private fun settleKey(action: String, callId: String): String = "$action|$callId"

        private fun incomingRingKeys(callId: String, sessionId: String): List<String> =
            listOf(callId, sessionId).map { it.trim() }.filter { it.isNotEmpty() }.distinct()

        private fun incomingRingClock(callId: String, sessionId: String): IncomingRingClock? =
            incomingRingKeys(callId, sessionId).firstNotNullOfOrNull { incomingRingClocks[it] }

        private fun incomingActionAlreadySettled(callId: String, sessionId: String): Boolean {
            val actions = listOf("callAnswered", "callRejected", "callEnded", "callTimedOut")
            return incomingRingKeys(callId, sessionId).any { id ->
                actions.any { action -> settledCallActions.contains(settleKey(action, id)) }
            }
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
            val clock = IncomingRingClock(startedAt, runnable)
            keys.forEach { incomingRingClocks[it] = clock }
            incomingRingHandler.postDelayed(runnable, INCOMING_RING_TIMEOUT_MS)
        }

        private fun cancelIncomingRingTimeout(callId: String, sessionId: String) {
            val clock = incomingRingClock(callId, sessionId) ?: return
            incomingRingHandler.removeCallbacks(clock.runnable)
            incomingRingClocks.entries.removeIf { it.value === clock }
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
            clearIncomingMute(endedId, sessionId)
            if (!settledCallActions.add(settleKey(action, endedId))) return
            cancelIncomingRingTimeout(endedId, sessionId)
            shownCallers.remove(endedId)
            if (sessionId.isNotBlank()) shownCallers.remove(sessionId)
            context.getSharedPreferences(CALLER_POOL_PREFS, Context.MODE_PRIVATE).edit()
                .remove(endedId)
                .remove(sessionId)
                .apply()
            submittedIncomingCalls.remove(endedId)
            if (sessionId.isNotBlank()) submittedIncomingCalls.remove(sessionId)
            IncomingCallActivity.finishIfMatching(endedId, sessionId)
            val connection = activeConnections[endedId] ?: activeConnections[sessionId]
            when (action) {
                "callAnswered" -> {
                    connection?.setActive()
                    BeamioCallForegroundService.handoffAnsweredCall(context, callId, sessionId)
                    bringMainActivityToFront(context)
                }
                "callRejected" -> {
                    connection?.let {
                        it.setDisconnected(DisconnectCause(DisconnectCause.REJECTED))
                        it.destroy()
                        activeConnections.remove(callId, it)
                    }
                    BeamioCallForegroundService.stop(context)
                    cancelIncomingNotifications(context, endedId, sessionId)
                }
                "callEnded", "callTimedOut" -> {
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
                    if (!IncomingCallActivity.isShowing()) {
                        BeamioCallForegroundService.stop(context)
                    }
                    cancelIncomingNotifications(context, endedId, sessionId)
                }
            }
            savePendingSystemCallAction(context, action, endedId, sessionId)
            MainActivity.dispatchSystemCallAction(action, callId, sessionId, context)
            if (fromTelecom || action == "callTimedOut") {
                Log.i(TAG, "Telecom action=$action callIdPresent=${callId.isNotBlank()}")
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
            val tag = resolved.displayName.trim().takeIf(::isBeamioTag).orEmpty()
            val walletLine = shortWallet(resolved.peerAddress).ifBlank {
                shortWallet(resolved.displayName)
            }
            // Line 1 is the caller identity only: BeamioTag then the short address.
            // With no tag, the address stands alone. Do not put "Incoming voice call"
            // here — CallStyle verification text renders on this same row.
            val name = when {
                tag.isNotBlank() && walletLine.isNotBlank() -> "$tag  $walletLine"
                tag.isNotBlank() -> tag
                walletLine.isNotBlank() -> walletLine
                else -> "Incoming call"
            }
            val body = resolved.identityWarning.ifBlank { "Incoming voice call" }
            val avatar = callerAvatarBitmap(tag)
            val postedId = notificationId(primary)
            // The glass IncomingCallActivity is the only incoming UI. This
            // notification stays in the shade for the phone-call foreground
            // service and must not draw a second heads-up card.
            val fullScreenIntent = Intent(context, IncomingCallActivity::class.java).apply {
                flags = Intent.FLAG_ACTIVITY_NEW_TASK or Intent.FLAG_ACTIVITY_SINGLE_TOP
                putExtra(EXTRA_CALL_ID, callId.ifBlank { primary })
                putExtra(EXTRA_SESSION_ID, sessionId)
                putExtra(EXTRA_DISPLAY_NAME, name)
                putExtra(EXTRA_PEER_ADDRESS, resolved.peerAddress)
                putExtra(EXTRA_CLAIMED_TAG, tag.ifBlank { resolved.claimedTag })
                putExtra(EXTRA_CLAIMED_ADDRESS, resolved.claimedAddress)
                putExtra(EXTRA_IDENTITY_WARNING, body)
            }
            val builder = NotificationCompat.Builder(context, INCOMING_CALL_CHANNEL_ID)
                .setSmallIcon(R.drawable.ic_incoming_call_status)
                .setContentTitle(name)
                .setContentText(body)
                .setPriority(NotificationCompat.PRIORITY_MIN)
                .setVisibility(NotificationCompat.VISIBILITY_SECRET)
                .setOngoing(true)
                .setAutoCancel(false)
                .setSilent(true)
                .setOnlyAlertOnce(true)
                .setForegroundServiceBehavior(NotificationCompat.FOREGROUND_SERVICE_IMMEDIATE)
            if (IncomingCallActivity.isShowing()) {
                IncomingCallActivity.updateShownCaller(
                    callId.ifBlank { primary },
                    sessionId,
                    name,
                    resolved.peerAddress,
                    tag.ifBlank { resolved.claimedTag },
                    resolved.claimedAddress,
                    body,
                )
            } else {
                runCatching { context.startActivity(fullScreenIntent) }
            }
            val manager = NotificationManagerCompat.from(context)
            listOf(callId, sessionId, aliasCallId)
                .map { it.trim() }
                .filter { it.isNotBlank() && notificationId(it) != postedId }
                .forEach { alias -> manager.cancel(notificationId(alias)) }
            BeamioCallForegroundService.startIncoming(context, postedId, builder.build())
            Log.i(
                TAG,
                "CallStyle incoming notification requested nameIsTag=${tag.isNotBlank()} " +
                    "walletLinePresent=${walletLine.isNotBlank()} bodyIsWarning=${resolved.identityWarning.isNotBlank()} " +
                    "avatarReady=${avatar != null}",
            )
            if (tag.isBlank()) {
                scheduleBeamioTagLookup(
                    context,
                    resolved.peerAddress,
                    callId,
                    sessionId,
                    claimedTag,
                    claimedAddress,
                    identityWarning,
                    aliasCallId,
                )
            }
            if (avatar == null) {
                scheduleCallerAvatar(
                    context,
                    tag,
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
                    if (incomingActionAlreadySettled(callId, sessionId)) return@post
                    IncomingCallActivity.refreshAvatarIfShowing()
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
         * The decrypted offer first reports the caller's wallet. The glass card
         * needs the BeamioTag for both the title and the fun-emoji avatar.
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
                    if (incomingActionAlreadySettled(callId, sessionId)) return@post
                    Log.i(TAG, "Caller BeamioTag resolved")
                    listOf(callId, sessionId, aliasCallId)
                        .map { it.trim() }
                        .filter { it.isNotBlank() }
                        .distinct()
                        .forEach { key ->
                            rememberShownCaller(
                                app,
                                key,
                                address,
                                lookedUp,
                                claimedTag,
                                claimedAddress,
                                identityWarning,
                            )
                        }
                    showIncomingCallNotification(
                        app,
                        callId,
                        address,
                        lookedUp,
                        sessionId,
                        claimedTag,
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
         * Mailbox/FCM wake path. Posts the system CallStyle card immediately
         * (Decline / Answer). Caller identity is filled in when the PWA later
         * reports the decrypted offer on the same notification id.
         */
        fun showIncomingCallWakeNotification(
            context: Context,
            callId: String,
            sessionId: String,
        ) {
            if (callId.isBlank() && sessionId.isBlank()) return
            reportIncoming(
                context,
                callId = callId.ifBlank { sessionId },
                peerAddress = "",
                displayName = "",
                sessionId = sessionId,
            )
            wakeConsumerShell(context)
        }

        private fun wakeConsumerShell(context: Context) {
            if (MainActivity.isRunning()) {
                MainActivity.requestMailboxWake()
                Log.i(TAG, "Mailbox wake kept the incoming window in front")
                return
            }
            // The process was started by the push. Opening MainActivity here
            // puts its opaque black shell on screen before the translucent
            // call window can cover it. IncomingCallActivity starts the shell
            // only after it is already showing, and that shell stays behind.
            Log.i(TAG, "Shell start waits until the incoming window is showing")
        }

        fun ensureIncomingCallChannel(context: Context) {
            if (Build.VERSION.SDK_INT < Build.VERSION_CODES.O) return
            val manager = context.getSystemService(android.app.NotificationManager::class.java) ?: return
            val channel = android.app.NotificationChannel(
                INCOMING_CALL_CHANNEL_ID,
                "Incoming calls",
                android.app.NotificationManager.IMPORTANCE_LOW,
            ).apply {
                description = "Incoming voice calls"
                lockscreenVisibility = Notification.VISIBILITY_SECRET
                setSound(null, null)
                enableVibration(false)
            }
            manager.createNotificationChannel(channel)
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
            val manager = NotificationManagerCompat.from(context)
            val aliases = listOf(callId, sessionId).map { it.trim() }.filter { it.isNotBlank() }.distinct()
            val prefs = context.getSharedPreferences(NOTIFICATION_ALIAS_PREFS, Context.MODE_PRIVATE)
            val primary = aliases.firstNotNullOfOrNull { prefs.getString("alias:$it", null) }.orEmpty()
            val keepForegroundId = BeamioCallForegroundService.activeForegroundNotificationId
            (aliases + listOf(primary)).filter { it.isNotBlank() }.distinct().forEach { key ->
                val id = notificationId(key)
                if (id != keepForegroundId) manager.cancel(id)
            }
            val editor = prefs.edit()
            aliases.forEach { editor.remove("alias:$it") }
            editor.apply()
        }

        private const val TAG = "BeamioVoiceCall"
    }
}
