package com.beamio.app
import network.conet.chat.BeamioSiCipherPost
import network.conet.chat.BeamioChatPgpStore

import android.content.Context
import android.os.Handler
import android.os.Looper
import android.util.Base64
import android.util.Log
import org.json.JSONObject
import java.net.HttpURLConnection
import java.net.URL
import java.util.concurrent.atomic.AtomicBoolean

/**
 * Shell-owned Guardian `ip_addr` roster. Reads `GuardianNodesInfoV6.getAllNodes`
 * over CoNET RPC and persists ip + domain (`PGPKey`) + region. The PWA does not
 * supply this list. RPC failure or a decoded empty list keeps the previous roster.
 */
object BeamioGuardianRoster {
    private const val TAG = "BeamioGuardian"
    private const val CONTRACT = "0xBC6b53065b5647261396d002bDBA0d3396E0722f"
    private const val SELECTOR = "4272c81e"
    private val RPCS = arrayOf(
        "https://rpc1.conet.network",
        "https://publicrpc.conet.network",
    )
    private const val PAGE = 200
    private const val MAX_PAGES = 6
    private const val RETRY_EMPTY_MS = 60_000L
    private const val RETRY_HAVE_MS = 300_000L

    private data class Row(val node: BeamioChatPgpStore.SiNode, val armor: String)

    private val handler = Handler(Looper.getMainLooper())
    private val inFlight = AtomicBoolean(false)
    private val gate = Any()
    @Volatile private var app: Context? = null
    @Volatile private var lastSuccessMs = 0L
    private var pending: Runnable? = null

    fun kick(context: Context) {
        app = context.applicationContext
        Thread { refresh() }.start()
    }

    private fun refresh() {
        val ctx = app ?: return
        val have = BeamioChatPgpStore.loadSiNodes(ctx).isNotEmpty()
        val age = System.currentTimeMillis() - lastSuccessMs
        if (have && lastSuccessMs > 0L && age < RETRY_HAVE_MS) {
            val queued = synchronized(gate) { pending != null }
            if (!queued) scheduleNext((RETRY_HAVE_MS - age).coerceAtLeast(5_000L))
            return
        }
        if (!inFlight.compareAndSet(false, true)) return
        try {
            val rows = fetchAll()
            if (rows.isNullOrEmpty()) {
                Log.i(TAG, "refresh untrusted — kept previous count=${BeamioChatPgpStore.loadSiNodes(ctx).size}")
                return
            }
            val mailbox = matchMailbox(ctx, rows)
            val nodes = rows.map { it.node }
            val ok = BeamioChatPgpStore.storeChainRoster(ctx, nodes, mailbox)
            if (ok) {
                lastSuccessMs = System.currentTimeMillis()
                Log.i(TAG, "roster count=${nodes.size} mailbox=${if (mailbox == null) "unchanged" else "matched"}")
            }
        } finally {
            inFlight.set(false)
            val empty = BeamioChatPgpStore.loadSiNodes(ctx).isEmpty()
            scheduleNext(if (empty) RETRY_EMPTY_MS else RETRY_HAVE_MS)
        }
    }

    private fun scheduleNext(delayMs: Long) {
        synchronized(gate) {
            pending?.let { handler.removeCallbacks(it) }
            val run = Runnable { Thread { refresh() }.start() }
            pending = run
            handler.postDelayed(run, delayMs)
        }
    }

    private fun fetchAll(): List<Row>? {
        val all = ArrayList<Row>()
        var start = 0
        repeat(MAX_PAGES) {
            val page = fetchPage(start, PAGE) ?: return null
            if (page.isEmpty()) return all
            all.addAll(page)
            if (page.size < PAGE) return all
            start += PAGE
        }
        return all
    }

    private fun fetchPage(start: Int, length: Int): List<Row>? {
        val data = "0x$SELECTOR${start.toString(16).padStart(64, '0')}${length.toString(16).padStart(64, '0')}"
        for (rpc in RPCS) {
            val body = ethCall(rpc, data) ?: continue
            val rows = decode(body) ?: continue
            return rows
        }
        return null
    }

    private fun ethCall(rpc: String, data: String): ByteArray? {
        return try {
            val conn = (URL(rpc).openConnection() as HttpURLConnection).apply {
                requestMethod = "POST"
                connectTimeout = 12_000
                readTimeout = 22_000
                doOutput = true
                setRequestProperty("content-type", "application/json")
            }
            val payload = JSONObject()
                .put("jsonrpc", "2.0")
                .put("id", 1)
                .put("method", "eth_call")
                .put(
                    "params",
                    org.json.JSONArray()
                        .put(JSONObject().put("to", CONTRACT).put("data", data))
                        .put("latest"),
                )
            conn.outputStream.use { it.write(payload.toString().toByteArray(Charsets.UTF_8)) }
            val code = conn.responseCode
            val text = (if (code in 200..299) conn.inputStream else conn.errorStream)
                ?.bufferedReader()?.use { it.readText() }
                .orEmpty()
            conn.disconnect()
            val obj = JSONObject(text)
            if (obj.has("error")) return null
            val hex = obj.optString("result", "")
            if (!hex.startsWith("0x") || hex.length < 4 || hex.length % 2 != 0) return null
            hex.removePrefix("0x").chunked(2).map { it.toInt(16).toByte() }.toByteArray()
        } catch (_: Exception) {
            null
        }
    }

    private fun decode(bytes: ByteArray): List<Row>? {
        val outer = u256(bytes, 0) ?: return null
        if (outer + 32 > bytes.size) return null
        val n = u256(bytes, outer) ?: return null
        if (n > 800) return null
        if (n == 0) return emptyList()
        val heads = outer + 32
        val out = ArrayList<Row>()
        for (i in 0 until n) {
            val rel = u256(bytes, heads + 32 * i) ?: return null
            val tup = heads + rel
            if (tup + 32 * 5 > bytes.size) return null
            val pgp = readString(bytes, tup, 1) ?: return null
            val pgpKey = readString(bytes, tup, 2) ?: return null
            val ipRaw = readString(bytes, tup, 3) ?: return null
            val region = readString(bytes, tup, 4) ?: return null
            val ip = BeamioSiCipherPost.normalizeIp(ipRaw) ?: continue
            out.add(
                Row(
                    node = BeamioChatPgpStore.SiNode(
                        ip = ip,
                        domain = pgpKey.trim().take(256),
                        region = region.trim().take(64),
                    ),
                    armor = armorFromBase64(pgp),
                ),
            )
        }
        if (out.isEmpty()) return null
        return out
    }

    private fun matchMailbox(context: Context, rows: List<Row>): String? {
        val route = normalizeArmor(BeamioChatPgpStore.loadRoutePublicArmor(context))
        if (!route.contains("BEGIN PGP PUBLIC KEY")) return null
        for (row in rows) {
            if (normalizeArmor(row.armor) == route) return row.node.ip
        }
        return null
    }

    private fun armorFromBase64(raw: String): String {
        val compact = raw.filter { !it.isWhitespace() }
        return try {
            val data = Base64.decode(compact, Base64.DEFAULT)
            String(data, Charsets.UTF_8)
        } catch (_: Exception) {
            ""
        }
    }

    private fun normalizeArmor(raw: String): String =
        raw.replace("\r\n", "\n").replace("\r", "\n").trim()

    private fun u256(bytes: ByteArray, off: Int): Int? {
        if (off < 0 || off + 32 > bytes.size) return null
        for (i in 0 until 24) if (bytes[off + i] != 0.toByte()) return null
        var v = 0L
        for (i in 24 until 32) v = (v shl 8) or (bytes[off + i].toLong() and 0xff)
        if (v > Int.MAX_VALUE) return null
        return v.toInt()
    }

    private fun readString(bytes: ByteArray, tup: Int, word: Int): String? {
        val rel = u256(bytes, tup + 32 * word) ?: return null
        val abs = tup + rel
        val len = u256(bytes, abs) ?: return null
        if (len >= 200_000 || abs + 32 + len > bytes.size) return null
        return String(bytes, abs + 32, len, Charsets.UTF_8)
    }
}
