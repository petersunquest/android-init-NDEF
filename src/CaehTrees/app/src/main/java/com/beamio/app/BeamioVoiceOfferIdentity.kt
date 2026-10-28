package com.beamio.app
import network.conet.chat.BeamioOpenPgpHost
import network.conet.chat.BeamioSiCipherPost
import network.conet.chat.BeamioChatPgpStore

import android.content.Context
import android.os.Handler
import android.os.Looper
import android.util.Log
import org.json.JSONObject
import kotlin.math.max
import java.io.BufferedReader
import java.io.InputStreamReader
import java.net.HttpURLConnection
import java.net.URL
import java.util.concurrent.CopyOnWriteArrayList
import java.util.concurrent.Executors
import java.util.concurrent.atomic.AtomicBoolean

/**
 * Killed-app path: encrypt `voice_offer_fetch` to mailbox route PGP →
 * `POST http://{entryIp}/post` (shell picks an IP ≠ mailbox B) → decrypt
 * `offerArmor` with stored user PGP → EIP-191 recover caller →
 * exact-address BeamioTag → update Incoming UI.
 *
 * Concurrent callers (FCM resolve + Decline `resolveBlocking`) **join** the same
 * in-flight fetch — iOS allows concurrent resolve; Android must not drop the
 * second waiter (that left Decline with a null offer while dialer kept ringing).
 */
object BeamioVoiceOfferIdentity {
    private const val TAG = "BeamioVoiceOfferId"
    private val io = Executors.newSingleThreadExecutor()
    private val main = Handler(Looper.getMainLooper())
    private val resolveRunning = AtomicBoolean(false)
    private val waiters = CopyOnWriteArrayList<(ResolvedIdentity) -> Unit>()

    data class ResolvedIdentity(
        val callerEoa: String,
        val beamioTag: String?,
        val shortAddress: String,
        val callId: String,
        val sessionId: String,
        /** Offer AES-GCM key (base64 32 bytes) — required for native Decline uplink. */
        val sessionKey: String = "",
        /** Offer `to` (local callee EOA when present). */
        val to: String = "",
    )

    fun scheduleResolve(
        context: Context,
        callId: String,
        sessionId: String = "",
        onResolved: (ResolvedIdentity) -> Unit,
    ) {
        val app = context.applicationContext
        val cid = callId.trim()
        if (cid.isEmpty()) return
        // Cache hit — no network.
        BeamioNativeVoiceSignaling.cachedOffer(cid, sessionId)
            ?.takeIf { it.sessionKey.isNotEmpty() }
            ?.let { hit ->
                main.post { onResolved(hit) }
                return
            }

        waiters.add(onResolved)
        if (!resolveRunning.compareAndSet(false, true)) {
            Log.i(TAG, "resolve already in-flight; join waiters callId=${cid.take(12)}")
            return
        }
        io.execute {
            var identity: ResolvedIdentity? = null
            try {
                val secrets = BeamioChatPgpStore.load(app)
                if (secrets == null || !secrets.hasUserPrivate) {
                    Log.w(TAG, "no stored user PGP; skip resolve")
                    return@execute
                }
                if (!secrets.hasRoutePublic) {
                    Log.w(TAG, "no mailbox route public; skip resolve")
                    return@execute
                }
                val roster = rosterOf(secrets)
                if (roster.isEmpty()) {
                    Log.w(TAG, "no SI IP roster; skip resolve")
                    return@execute
                }
                val command = JSONObject()
                    .put("command", "voice_offer_fetch")
                    .put("callId", cid)
                    .put("sessionId", sessionId.trim())
                    .put("timestamp", System.currentTimeMillis() / 1000L)
                val encryptWait = Object()
                var armor: String? = null
                var encryptError: String? = null
                BeamioOpenPgpHost.shared(app).encryptToRoute(
                    secrets.routePublicKeyArmor,
                    command.toString(),
                ) { result ->
                    result.onSuccess { armor = it }
                        .onFailure { encryptError = it.message }
                    synchronized(encryptWait) { encryptWait.notifyAll() }
                }
                synchronized(encryptWait) {
                    if (armor == null && encryptError == null) {
                        encryptWait.wait(15_000L)
                    }
                }
                val encrypted = armor
                if (encrypted.isNullOrBlank()) {
                    Log.w(TAG, "encrypt failed: ${encryptError ?: "timeout"}")
                    return@execute
                }
                val exclude = buildSet {
                    BeamioSiCipherPost.normalizeIp(secrets.mailboxIp)?.let { add(it) }
                }
                val posted = BeamioSiCipherPost.post(encrypted, roster, exclude)
                val offerArmor = extractOfferArmor(posted.body)
                if (offerArmor.isNullOrBlank()) {
                    Log.w(TAG, "voice_offer_fetch empty status=${posted.status} err=${posted.error}")
                    return@execute
                }
                val decryptWait = Object()
                var payload: JSONObject? = null
                var decryptError: String? = null
                BeamioOpenPgpHost.shared(app).decryptAndVerifyOffer(
                    secrets.privateKeyArmor,
                    offerArmor,
                ) { result ->
                    result.onSuccess { payload = it }
                        .onFailure { decryptError = it.message }
                    synchronized(decryptWait) { decryptWait.notifyAll() }
                }
                synchronized(decryptWait) {
                    if (payload == null && decryptError == null) {
                        decryptWait.wait(20_000L)
                    }
                }
                val verified = payload
                if (verified == null) {
                    Log.w(TAG, "decrypt/verify failed: ${decryptError ?: "timeout"}")
                    return@execute
                }
                val caller = verified.optString("callerEoa", "").trim().lowercase()
                if (!caller.matches(Regex("^0x[0-9a-f]{40}$"))) {
                    Log.w(TAG, "invalid recovered caller")
                    return@execute
                }
                val sessionKey = verified.optString("sessionKey", "").trim()
                val to = verified.optString("to", "").trim().lowercase()
                val tag = fetchExactTag(caller)
                val short = shortAddress(caller)
                val resolved = ResolvedIdentity(
                    callerEoa = caller,
                    beamioTag = tag,
                    shortAddress = short,
                    callId = verified.optString("callId", cid).ifBlank { cid },
                    sessionId = verified.optString("sessionId", sessionId).ifBlank { sessionId },
                    sessionKey = sessionKey,
                    to = to,
                )
                identity = resolved
                if (sessionKey.isNotEmpty()) {
                    BeamioNativeVoiceSignaling.rememberOffer(resolved)
                }
                Log.i(
                    TAG,
                    "resolved callId=${resolved.callId.take(12)} tag=${tag ?: "-"} eoa=$short " +
                        "sessionKey=${if (sessionKey.isEmpty()) "no" else "yes"}",
                )
            } catch (error: Exception) {
                Log.w(TAG, "resolve failed: ${error.message}")
            } finally {
                val done = identity?.takeIf { it.sessionKey.isNotEmpty() }
                    ?: BeamioNativeVoiceSignaling.cachedOffer(cid, sessionId)
                        ?.takeIf { it.sessionKey.isNotEmpty() }
                val callbacks = waiters.toList()
                waiters.clear()
                resolveRunning.set(false)
                if (done != null) {
                    main.post {
                        callbacks.forEach { cb ->
                            try {
                                cb(done)
                            } catch (e: Exception) {
                                Log.w(TAG, "waiter failed: ${e.message}")
                            }
                        }
                        // Waiters that joined after clear / before unlock.
                        val extra = waiters.toList()
                        waiters.clear()
                        extra.forEach { cb ->
                            try {
                                cb(done)
                            } catch (_: Exception) {
                            }
                        }
                    }
                } else {
                    Log.w(TAG, "resolve finished without sessionKey; ${callbacks.size} waiter(s) not notified")
                }
            }
        }
    }

    private fun rosterOf(secrets: BeamioChatPgpStore.Secrets): List<BeamioChatPgpStore.SiNode> {
        if (secrets.siNodes.isNotEmpty()) return secrets.siNodes
        return secrets.entryDomains.mapNotNull { raw ->
            val ip = BeamioSiCipherPost.normalizeIp(raw) ?: return@mapNotNull null
            BeamioChatPgpStore.SiNode(ip)
        }
    }

    private fun extractOfferArmor(raw: String): String? {
        val trimmed = raw.trim()
        if (trimmed.contains("BEGIN PGP MESSAGE")) {
            try {
                val obj = JSONObject(trimmed)
                val armor = obj.optString("offerArmor", "")
                    .ifBlank { obj.optString("data", "") }
                if (armor.contains("BEGIN PGP MESSAGE")) return armor
            } catch (_: Exception) {
                return trimmed
            }
        }
        return try {
            val obj = JSONObject(trimmed)
            if (!obj.optBoolean("ok", true) && obj.has("error")) return null
            val armor = obj.optString("offerArmor", "")
                .ifBlank { obj.optString("data", "") }
            armor.takeIf { it.contains("BEGIN PGP MESSAGE") }
        } catch (_: Exception) {
            null
        }
    }

    fun fetchExactTag(address: String): String? {
        val trimmed = address.trim()
        if (!trimmed.matches(Regex("^0x[0-9a-fA-F]{40}$"))) return null
        var conn: HttpURLConnection? = null
        return try {
            val url = URL(
                "https://beamio.app/api/search-users?keyward=${java.net.URLEncoder.encode(trimmed, "UTF-8")}",
            )
            conn = (url.openConnection() as HttpURLConnection).apply {
                requestMethod = "GET"
                connectTimeout = 10_000
                readTimeout = 12_000
            }
            if (conn.responseCode !in 200..299) return null
            val text = BufferedReader(InputStreamReader(conn.inputStream, Charsets.UTF_8)).use { it.readText() }
            val json = JSONObject(text)
            val results = json.optJSONArray("results") ?: return null
            val lower = trimmed.lowercase()
            for (i in 0 until results.length()) {
                val row = results.optJSONObject(i) ?: continue
                val addr = row.optString("address", "").lowercase()
                if (addr != lower) continue
                val username = row.optString("username", "")
                    .ifBlank { row.optString("accountName", "") }
                return normalizeTag(username)
            }
            null
        } catch (_: Exception) {
            null
        } finally {
            conn?.disconnect()
        }
    }

    fun shortAddress(eoa: String): String {
        val a = eoa.trim()
        if (a.length < 10) return a
        return "${a.take(6)}…${a.takeLast(4)}"
    }

    fun normalizeTag(raw: String?): String? {
        val t = raw?.trim().orEmpty()
        if (t.isEmpty()) return null
        return if (t.startsWith("@")) t else "@$t"
    }

    /** Delay helper for PushKit/FCM: resolve after notification shown. */
    fun scheduleResolveDelayed(
        context: Context,
        callId: String,
        sessionId: String = "",
        delayMs: Long = 400L,
        onResolved: (ResolvedIdentity) -> Unit,
    ) {
        val delay = max(0L, delayMs)
        main.postDelayed(
            { scheduleResolve(context, callId, sessionId, onResolved) },
            delay,
        )
    }

    /**
     * Blocking resolve for native Decline when cache miss races ahead of UI resolve.
     * Must be called off the main thread. Joins in-flight [scheduleResolve] waiters
     * (iOS parity: concurrent resolve allowed). Wall-clock covers encrypt(15s)+decrypt(20s).
     */
    fun resolveBlocking(
        context: Context,
        callId: String,
        sessionId: String,
        timeoutMs: Long = 45_000L,
    ): ResolvedIdentity? {
        BeamioNativeVoiceSignaling.cachedOffer(callId, sessionId)
            ?.takeIf { it.sessionKey.isNotEmpty() }
            ?.let { return it }

        val wait = Object()
        var out: ResolvedIdentity? = null
        var done = false
        scheduleResolve(context, callId, sessionId) { identity ->
            synchronized(wait) {
                out = identity
                done = true
                wait.notifyAll()
            }
        }
        val deadline = System.currentTimeMillis() + timeoutMs
        while (System.currentTimeMillis() < deadline) {
            BeamioNativeVoiceSignaling.cachedOffer(callId, sessionId)
                ?.takeIf { it.sessionKey.isNotEmpty() }
                ?.let { return it }
            synchronized(wait) {
                if (done) return@synchronized
                val remain = deadline - System.currentTimeMillis()
                if (remain <= 0L) return@synchronized
                wait.wait(minOf(200L, remain))
            }
            if (done) break
        }
        return out?.takeIf { it.sessionKey.isNotEmpty() }
            ?: BeamioNativeVoiceSignaling.cachedOffer(callId, sessionId)
                ?.takeIf { it.sessionKey.isNotEmpty() }
    }
}
