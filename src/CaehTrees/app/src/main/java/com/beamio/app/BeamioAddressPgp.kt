package com.beamio.app
import network.conet.chat.BeamioSiCipherPost
import network.conet.chat.BeamioChatPgpStore

import android.util.Base64
import android.util.Log
import org.json.JSONArray
import org.json.JSONObject
import java.io.BufferedReader
import java.io.InputStreamReader
import java.io.OutputStreamWriter
import java.net.HttpURLConnection
import java.net.URL
import java.nio.charset.StandardCharsets

/**
 * Read-only AddressPGP `searchKey(address)` over CoNET RPC.
 * Mirrors iOS `BeamioAddressPgp`.
 */
object BeamioAddressPgp {
    private const val TAG = "BeamioAddressPgp"
    private const val CONTRACT = "0x684b0ac760cEE9c9b85de36d69746420648Cf9e2"
    /** bytes4(keccak256("searchKey(address)")) */
    private const val SELECTOR = "052f2778"
    private val RPCS = listOf(
        "https://rpc1.conet.network",
        "https://publicrpc.conet.network",
    )

    data class Keys(
        val userPgpKeyID: String,
        val userPublicKeyArmored: String,
        val routePgpKeyID: String,
        val routePublicKeyArmored: String,
        val routeOnline: Boolean,
    )

    fun searchKey(address: String): Keys? {
        val eoa = address.trim().lowercase()
        if (!eoa.matches(Regex("^0x[0-9a-f]{40}$"))) return null
        val addrWord = eoa.removePrefix("0x")
        val data = "0x${SELECTOR}000000000000000000000000$addrWord"
        val hex = ethCall(data) ?: return null
        val bytes = hexToBytes(hex.removePrefix("0x")) ?: return null
        if (bytes.size < 32 * 5) return null
        val userId = readString(bytes, 0, 0) ?: return null
        val userPub = readString(bytes, 0, 1) ?: return null
        val routeId = readString(bytes, 0, 2) ?: return null
        val routePub = readString(bytes, 0, 3) ?: return null
        val online = (u256(bytes, 32 * 4) ?: 0) != 0
        val routeArmor = decodeMaybeBase64Armor(routePub)
        if (!routeArmor.contains("BEGIN PGP PUBLIC KEY")) return null
        return Keys(
            userPgpKeyID = userId,
            userPublicKeyArmored = decodeMaybeBase64Armor(userPub),
            routePgpKeyID = routeId.trim(),
            routePublicKeyArmored = routeArmor,
            routeOnline = online,
        )
    }

    fun mailboxIp(routePgpKeyID: String, nodes: List<BeamioChatPgpStore.SiNode>): String? {
        val want = routePgpKeyID.trim().lowercase()
        if (want.isEmpty()) return null
        for (node in nodes) {
            val domain = node.domain.trim().lowercase()
            if (domain.isNotEmpty() &&
                (domain == want || domain.startsWith(want) || want.startsWith(domain))
            ) {
                return BeamioSiCipherPost.normalizeIp(node.ip)
            }
        }
        return null
    }

    private fun ethCall(data: String): String? {
        val body = JSONObject()
            .put("jsonrpc", "2.0")
            .put("id", 1)
            .put("method", "eth_call")
            .put(
                "params",
                JSONArray()
                    .put(JSONObject().put("to", CONTRACT).put("data", data))
                    .put("latest"),
            )
            .toString()
        for (rpc in RPCS) {
            var conn: HttpURLConnection? = null
            try {
                conn = (URL(rpc).openConnection() as HttpURLConnection).apply {
                    requestMethod = "POST"
                    connectTimeout = 12_000
                    readTimeout = 14_000
                    doOutput = true
                    setRequestProperty("Content-Type", "application/json")
                }
                OutputStreamWriter(conn.outputStream, StandardCharsets.UTF_8).use { it.write(body) }
                if (conn.responseCode !in 200..299) continue
                val text = BufferedReader(InputStreamReader(conn.inputStream, Charsets.UTF_8)).use { it.readText() }
                val hex = JSONObject(text).optString("result", "")
                if (hex.startsWith("0x") && hex.length > 2) return hex
            } catch (e: Exception) {
                Log.w(TAG, "eth_call failed rpc=$rpc: ${e.message}")
            } finally {
                conn?.disconnect()
            }
        }
        return null
    }

    private fun decodeMaybeBase64Armor(raw: String): String {
        val trimmed = raw.trim()
        if (trimmed.contains("BEGIN PGP PUBLIC KEY")) return trimmed
        val compact = trimmed.filter { !it.isWhitespace() }
        return try {
            val decoded = String(Base64.decode(compact, Base64.DEFAULT), Charsets.UTF_8)
            if (decoded.contains("BEGIN PGP PUBLIC KEY")) decoded else trimmed
        } catch (_: Exception) {
            trimmed
        }
    }

    private fun u256(bytes: ByteArray, off: Int): Int? {
        if (off < 0 || off + 32 > bytes.size) return null
        for (i in 0 until 24) if (bytes[off + i].toInt() != 0) return null
        var v = 0L
        for (i in 24 until 32) {
            v = (v shl 8) or (bytes[off + i].toInt() and 0xff).toLong()
        }
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

    private fun hexToBytes(hex: String): ByteArray? {
        if (hex.length % 2 != 0) return null
        return try {
            ByteArray(hex.length / 2) { i ->
                hex.substring(i * 2, i * 2 + 2).toInt(16).toByte()
            }
        } catch (_: Exception) {
            null
        }
    }
}
