package com.beamio.app

import android.content.Context
import android.util.Base64
import android.util.Log
import network.conet.chat.BeamioChatPgpStore
import network.conet.chat.BeamioChatWalletKeyStore
import network.conet.chat.BeamioConetChatSignBroker
import network.conet.chat.BeamioOpenPgpHost
import network.conet.chat.BeamioSiCipherPost
import org.json.JSONArray
import org.json.JSONObject
import java.io.File
import java.security.SecureRandom
import java.util.concurrent.CompletableFuture
import java.util.concurrent.TimeUnit

/**
 * Voice protocol v3: paid temporary channels (wire spec: CoNET-SI `voiceForward.ts`,
 * PWA `vendor/conet-chat-sdk/src/voice-v3.ts`, iOS `BeamioVoiceV3.swift`).
 *
 * The callee creates four channels when it answers: caller voice / video
 * (`cv`, `cV`) and callee voice / video (`ev`, `eV`). Each has its own
 * temporary wallet T, AES key, write key and locator. The payer wallet signs T;
 * T signs every `voice_listen`, bound to the relay's route key ID. Each side
 * picks the relays for its own two channels. Nothing here is logged.
 */
object BeamioVoiceV3 {
    private const val TAG = "BeamioVoiceV3"
    private const val PAY_VALID_SEC = 12 * 60 * 60L
    private val rng = SecureRandom()

    /** Relay node: route key ID (= Guardian domain), IP, armored route key. */
    data class Relay(val domain: String, val ip: String, val armor: String)

    /** One channel: locator id, AES key and HMAC write key (base64). */
    data class Channel(val sid: String, val keyB64: String, val wkB64: String) {
        val locator: ByteArray? get() = BeamioVoiceChannelV2.locator(sid)
        val wk: ByteArray get() = Base64.decode(wkB64, Base64.NO_WRAP)
    }

    /** A channel this side listens on. [tkHex] = T private key (memory only). */
    data class Own(
        val channel: Channel,
        val tkHex: String,
        val tempAddress: String,
        val payJson: String,
        val relay: Relay? = null,
    )

    data class Peer(val channel: Channel, val relay: Relay? = null)

    data class Call(
        val callId: String,
        val ownVoice: Own,
        val ownVideo: Own,
        val peerVoice: Peer,
        val peerVideo: Peer,
    )

    // MARK: - Wire text (must match CoNET-SI)

    fun payText(temp: String, notAfter: Long, maxBytes: Long = 0, maxSeconds: Long = 0): String =
        listOf(
            "conet.voice.sse.pay.v3",
            "temp=${temp.lowercase()}",
            "notAfter=$notAfter",
            "maxBytes=$maxBytes",
            "maxSeconds=$maxSeconds",
        ).joinToString("\n")

    fun listenText(sid: String, wk: String, relayKeyId: String, timestamp: Long): String =
        listOf("conet.voice.sse.listen.v3", sid, wk, relayKeyId.uppercase(), timestamp.toString()).joinToString("|")

    private fun randomBytes(n: Int) = ByteArray(n).also { rng.nextBytes(it) }
    private fun hex(b: ByteArray) = b.joinToString("") { "%02x".format(it) }
    private fun b64(b: ByteArray) = Base64.encodeToString(b, Base64.NO_WRAP)

    fun newChannel() = Channel(hex(randomBytes(16)), b64(randomBytes(32)), b64(randomBytes(32)))

    // MARK: - Signing (BeamioOpenPgpHost; never on the main thread)

    @Volatile private var lastSignPath = ""

    /**
     * v3 channel signing: native secp256k1 first (same bytes as ethers), the SDK's
     * crypto WebView only if that fails. Logs the path when it changes.
     */
    private fun nativeOrWebView(what: String, native: () -> String?, webView: (BeamioOpenPgpHost) -> String?): String? {
        val n = runCatching { native() }.getOrNull()
        if (n != null) {
            if (lastSignPath != "native") { lastSignPath = "native"; Log.i(TAG, "v3 sign path=native ($what)") }
            return n
        }
        Log.w(TAG, "v3 sign path=webview ($what): native failed")
        lastSignPath = "webview"
        val ctx = appContext ?: return null
        return webView(BeamioOpenPgpHost.shared(ctx))
    }

    private fun waitResult(seconds: Long = 10, run: ((Result<String>) -> Unit) -> Unit): String? {
        val f = CompletableFuture<String?>()
        run { f.complete(it.getOrNull()) }
        return runCatching { f.get(seconds, TimeUnit.SECONDS) }.getOrNull()
    }

    /** New temporary wallet T and the payer's signature over it. Blocking. */
    fun newPaidChannel(context: Context, payerKeyHex: String, payerEoa: String): Own? {
        if (appContext == null) appContext = context.applicationContext
        val tk = hex(randomBytes(32))
        val temp = nativeOrWebView("address", { BeamioNativeEthSigner.address(tk) }) { host -> waitResult { host.walletAddress(tk, it) } }
            ?: return null
        val notAfter = System.currentTimeMillis() / 1000L + PAY_VALID_SEC
        val text = payText(temp, notAfter)
        val sig = nativeOrWebView("pay", { BeamioNativeEthSigner.signEip191(payerKeyHex, text) }) { host -> waitResult { host.signEip191(payerKeyHex, text, it) } }
            ?: return null
        val pay = JSONObject()
            .put("payer", payerEoa.lowercase())
            .put("notAfter", notAfter)
            .put("maxBytes", 0)
            .put("maxSeconds", 0)
            .put("sig", sig)
        return Own(newChannel(), tk, temp.lowercase(), pay.toString())
    }

    /** `voice_listen` v3 for one own channel on its relay. Blocking. */
    fun listenCommand(context: Context, own: Own, relay: Relay): JSONObject? {
        if (appContext == null) appContext = context.applicationContext
        val ts = System.currentTimeMillis() / 1000L
        val text = listenText(own.channel.sid, own.channel.wkB64, relay.domain, ts)
        val tempSig = nativeOrWebView("listen", { BeamioNativeEthSigner.signEip191(own.tkHex, text) }) { host -> waitResult { host.signEip191(own.tkHex, text, it) } }
            ?: return null
        val pay = runCatching { JSONObject(own.payJson) }.getOrNull() ?: return null
        return JSONObject()
            .put("command", "voice_listen")
            .put("v", 3)
            .put("sessionId", own.channel.sid)
            .put("wk", own.channel.wkB64)
            .put("timestamp", ts)
            .put("temp", own.tempAddress)
            .put("tempSig", tempSig)
            .put("pay", pay)
    }

    // MARK: - Accept wire

    private fun channelOf(o: JSONObject?): Channel? {
        o ?: return null
        val sid = o.optString("sid").lowercase()
        if (BeamioVoiceChannelV2.locator(sid) == null) return null
        val key = runCatching { Base64.decode(o.optString("key"), Base64.DEFAULT) }.getOrNull()
        val wk = runCatching { Base64.decode(o.optString("wk"), Base64.DEFAULT) }.getOrNull()
        if (key?.size != 32 || wk?.size != 32) return null
        return Channel(sid, b64(key), b64(wk))
    }

    private fun relayOf(domain: String, ip: String, keyB64: String): Relay? {
        val d = domain.trim().uppercase()
        if (d.isEmpty()) return null
        RelayNodes.node(d)?.let { return it }
        val armor = runCatching { String(Base64.decode(keyB64, Base64.DEFAULT), Charsets.UTF_8) }.getOrNull()
        if (armor == null || !armor.contains("BEGIN PGP PUBLIC KEY")) return null
        return Relay(d, BeamioSiCipherPost.normalizeIp(ip).orEmpty(), armor)
    }

    private fun ownOf(context: Context, o: JSONObject?): Own? {
        val c = channelOf(o) ?: return null
        val tk = BeamioChatWalletKeyStore.normalizeKey(o?.optString("tk"))
        val pay = o?.optJSONObject("pay") ?: return null
        if (tk.isEmpty()) return null
        val host = BeamioOpenPgpHost.shared(context.applicationContext)
        val temp = waitResult { host.walletAddress(tk, it) } ?: return null
        return Own(c, tk, temp.lowercase(), pay.toString())
    }

    private fun peerOf(o: JSONObject?): Peer? {
        val c = channelOf(o) ?: return null
        val r = relayOf(o?.optString("relay").orEmpty(), o?.optString("relayIp").orEmpty(), o?.optString("relayKey").orEmpty())
            ?: return null
        return Peer(c, r)
    }

    /** Caller side: `accept.ch` → our two channels (with T) and the callee's two. Blocking. */
    fun callFromAccept(context: Context, callId: String, ch: JSONObject): Call? {
        val cv = ownOf(context, ch.optJSONObject("cv")) ?: return null
        val cV = ownOf(context, ch.optJSONObject("cV")) ?: return null
        val ev = peerOf(ch.optJSONObject("ev")) ?: return null
        val eV = peerOf(ch.optJSONObject("eV")) ?: return null
        return Call(callId, cv, cV, ev, eV)
    }

    private fun wire(c: Channel) = JSONObject().put("sid", c.sid).put("key", c.keyB64).put("wk", c.wkB64)

    /** Accept `ch` (callee side): the caller's two channels with T, our two with relays. */
    fun acceptChannels(cv: Own, cV: Own, ev: Own, eV: Own): JSONObject? {
        fun ownWire(o: Own): JSONObject? {
            val pay = runCatching { JSONObject(o.payJson) }.getOrNull() ?: return null
            return wire(o.channel).put("tk", "0x" + o.tkHex).put("pay", pay)
        }
        fun relayWire(o: Own): JSONObject? {
            val r = o.relay ?: return null
            return wire(o.channel)
                .put("relay", r.domain)
                .put("relayIp", r.ip)
                .put("relayKey", b64(r.armor.toByteArray(Charsets.UTF_8)))
        }
        return JSONObject()
            .put("cv", ownWire(cv) ?: return null)
            .put("cV", ownWire(cV) ?: return null)
            .put("ev", relayWire(ev) ?: return null)
            .put("eV", relayWire(eV) ?: return null)
    }

    /** `voice_channel_ready_v3` body for our two relays. */
    fun channelReadyBody(callId: String, voice: Relay, video: Relay): JSONObject = JSONObject()
        .put("type", "voice_channel_ready_v3")
        .put("callId", callId)
        .put("voice", voice.domain)
        .put("voiceIp", voice.ip)
        .put("voiceKey", b64(voice.armor.toByteArray(Charsets.UTF_8)))
        .put("video", video.domain)
        .put("videoIp", video.ip)
        .put("videoKey", b64(video.armor.toByteArray(Charsets.UTF_8)))

    /** The peer's relays from `voice_channel_ready_v3`. */
    fun relaysFromReady(json: JSONObject): Pair<Relay?, Relay?> = Pair(
        relayOf(json.optString("voice"), json.optString("voiceIp"), json.optString("voiceKey")),
        relayOf(json.optString("video"), json.optString("videoIp"), json.optString("videoKey")),
    )

    // MARK: - Relay node cache

    /**
     * Route keys of all nodes, handed over by the page (`setNativeVoiceRelayNodes`)
     * and cached for a cold start that answers without the page. Public data.
     */
    /** App context from [RelayNodes.attach] (callers without a context). */
    @Volatile var appContext: Context? = null

    /**
     * First `voice_listen` of a channel, signed with T and encrypted to its relay
     * ahead of time (callee, while it rings). Nothing is sent before Answer, so the
     * relay learns nothing and nothing is paid until the listen opens. Memory only;
     * used once, within 5 min (the relay accepts a listen timestamp ±10 min).
     */
    object PreparedListens {
        private val lock = Any()
        private val bySid = HashMap<String, Triple<String, String, Long>>()

        fun prepare(context: Context, own: Own) {
            val relay = own.relay ?: return
            val command = listenCommand(context, own, relay) ?: return
            val f = CompletableFuture<String?>()
            BeamioNativeRoutePgp.encryptToRouteAsync(context, relay.armor, command.toString()) { f.complete(it.getOrNull()) }
            val armor = runCatching { f.get(12, TimeUnit.SECONDS) }.getOrNull()
            if (armor.isNullOrBlank() || !armor.contains("BEGIN PGP MESSAGE")) return
            synchronized(lock) { bySid[own.channel.sid] = Triple(relay.domain, armor, System.currentTimeMillis()) }
        }

        fun take(sid: String, relayDomain: String): String? = synchronized(lock) {
            val now = System.currentTimeMillis()
            bySid.entries.removeAll { now - it.value.third > 300_000L }
            val hit = bySid.remove(sid) ?: return null
            if (hit.first == relayDomain) hit.second else null
        }

        fun drop(sids: List<String>) = synchronized(lock) { sids.forEach { bySid.remove(it) } }
    }

    object RelayNodes {
        private val lock = Any()
        @Volatile private var cache: List<Relay>? = null
        @Volatile private var dir: File? = null

        @Volatile private var qaDebuggable = false

        fun attach(context: Context) {
            val app = context.applicationContext
            appContext = app
            dir = app.filesDir
            qaDebuggable = (app.applicationInfo.flags and android.content.pm.ApplicationInfo.FLAG_DEBUGGABLE) != 0
        }

        private fun file(): File? = dir?.let { File(it, "beamio-voice-relays.json") }

        fun saveFromBridge(context: Context, json: String) {
            attach(context)
            val rows = runCatching { JSONObject(json).optJSONArray("nodes") }.getOrNull() ?: return
            val out = mutableListOf<Relay>()
            for (i in 0 until rows.length()) {
                val n = rows.optJSONObject(i) ?: continue
                val ip = BeamioSiCipherPost.normalizeIp(n.optString("ip")) ?: continue
                val domain = n.optString("domain").trim().uppercase()
                val armor = n.optString("armor")
                if (domain.isEmpty() || !armor.contains("BEGIN PGP PUBLIC KEY")) continue
                out.add(Relay(domain, ip, armor))
            }
            if (out.isEmpty()) return
            synchronized(lock) { cache = out }
            val arr = JSONArray()
            out.forEach { arr.put(JSONObject().put("ip", it.ip).put("domain", it.domain).put("armor", it.armor)) }
            runCatching { file()?.writeText(arr.toString()) }
            Log.i(TAG, "relay nodes cached n=${out.size}")
        }

        fun all(): List<Relay> {
            cache?.let { return it }
            synchronized(lock) {
                cache?.let { return it }
                val text = runCatching { file()?.readText() }.getOrNull() ?: return emptyList()
                val arr = runCatching { JSONArray(text) }.getOrNull() ?: return emptyList()
                val loaded = (0 until arr.length()).mapNotNull { i ->
                    val o = arr.optJSONObject(i) ?: return@mapNotNull null
                    Relay(o.optString("domain"), o.optString("ip"), o.optString("armor"))
                }
                cache = loaded
                return loaded
            }
        }

        fun node(domain: String): Relay? {
            val want = domain.uppercase()
            return all().firstOrNull { it.domain == want }
        }

        private fun norm(s: String) = s.replace("\r", "").trim()

        /** A random relay that is none of [excludeIps] and serves none of [excludeArmors]. */
        fun pick(excludeIps: Set<String>, excludeArmors: List<String>): Relay? {
            val avoid = excludeArmors.map { norm(it) }.filter { it.isNotEmpty() }.toSet()
            var pool = all().filter { it.ip !in excludeIps && norm(it.armor) !in avoid }
            // Debuggable (QA) builds only: pin relays to canary nodes listed in
            // files/beamio-qa-voice-relays (comma-separated route key IDs).
            if (qaDebuggable) {
                val allow = runCatching { dir?.let { File(it, "beamio-qa-voice-relays").readText() } }.getOrNull()
                    ?.split(',', '\n')?.map { it.trim().uppercase() }?.filter { it.isNotEmpty() }?.toSet()
                if (!allow.isNullOrEmpty()) pool = pool.filter { it.domain in allow }
            }
            // Prefer a relay the SDK pool saw alive lately (answers at once); still random.
            val warm = network.conet.chat.BeamioEntryPool.warmIps()
            return pool.filter { it.ip in warm }.randomOrNull() ?: pool.randomOrNull()
        }

        /** IPs of the nodes serving [routeArmor] (a mailbox). */
        fun ipsOf(routeArmor: String): Set<String> {
            val want = norm(routeArmor)
            if (want.isEmpty()) return emptySet()
            return all().filter { norm(it.armor) == want }.map { it.ip }.toSet()
        }
    }

    // MARK: - Chat message to the peer's mailbox

    /**
     * Sign (our wallet), encrypt to the peer's user PGP, wrap to the peer's
     * mailbox route key, post through an entry that is neither mailbox: the
     * same path as every chat message. Blocking.
     */
    fun postChatMessage(
        context: Context,
        text: String,
        localEoa: String,
        peerUserPgp: String,
        peerRoute: String,
        noPush: Boolean,
    ): Boolean {
        if (!peerUserPgp.contains("BEGIN PGP PUBLIC KEY") || !peerRoute.contains("BEGIN PGP PUBLIC KEY")) return false
        val app = context.applicationContext
        val host = BeamioOpenPgpHost.shared(app)
        val sig = waitResult { done -> BeamioConetChatSignBroker.requestEip191(text, 10_000L) { done(it) } } ?: return false
        val envelope = JSONObject()
            .put("timestamp", System.currentTimeMillis())
            .put("text", text)
            .put("from", localEoa)
            .put("signMessage", sig)
            .toString()
        val userArmor = waitResult { host.encryptUtf8JsonBase64(envelope, peerUserPgp, it) }
        if (userArmor == null || !userArmor.contains("BEGIN PGP MESSAGE")) return false
        val armor = waitResult { host.wrapArmorToMailboxWork(userArmor, peerRoute, noPush, it) }
        if (armor == null || !armor.contains("BEGIN PGP MESSAGE")) return false
        val secrets = BeamioChatPgpStore.load(app) ?: return false
        val exclude = buildSet {
            addAll(RelayNodes.ipsOf(peerRoute))
            BeamioSiCipherPost.normalizeIp(secrets.mailboxIp)?.let { add(it) }
        }
        return BeamioSiCipherPost.post(armor, BeamioNativeVoiceSignaling.rosterOf(secrets), exclude, 4, null, 8_000L).ok
    }

    /** Stored wallet key of [eoa], or null. */
    fun payerKey(context: Context, eoa: String): String? =
        BeamioChatWalletKeyStore.load(context.applicationContext)
            ?.takeIf { it.eoa.trim().lowercase() == eoa.lowercase() }
            ?.privateKeyHex
}
