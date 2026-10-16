package com.beamio.app

import android.util.Log
import org.json.JSONObject
import java.io.BufferedReader
import java.io.InputStreamReader
import java.io.OutputStreamWriter
import java.net.HttpURLConnection
import java.net.URL

/**
 * One-shot OpenPGP ciphertext POST. Target is `http://{Guardian ip}/post`
 * with body `{ "data": armor }` only. The shell picks the entry IP.
 */
object BeamioSiCipherPost {
    private const val TAG = "BeamioSiPost"

    data class Result(
        val ok: Boolean,
        val status: Int,
        val body: String,
        val error: String,
    )

    fun normalizeIp(raw: String?): String? {
        var trimmed = raw?.trim().orEmpty()
        if (trimmed.isEmpty() || trimmed.contains("/") || trimmed.contains(" ")) return null
        if (trimmed.startsWith("[") && trimmed.endsWith("]")) {
            trimmed = trimmed.substring(1, trimmed.length - 1)
        }
        if (trimmed.contains(":")) {
            if (trimmed.count { it == ':' } < 2 || trimmed.contains(".")) return null
            return trimmed
        }
        val parts = trimmed.split(".")
        if (parts.size != 4) return null
        for (part in parts) {
            if (part.isEmpty() || part.length > 3) return null
            if (part.length > 1 && part.startsWith("0")) return null
            val n = part.toIntOrNull() ?: return null
            if (n !in 0..255) return null
        }
        return trimmed
    }

    fun postUrl(ip: String): String? {
        val norm = normalizeIp(ip) ?: return null
        return if (norm.contains(":")) "http://[$norm]/post" else "http://$norm/post"
    }

    fun post(
        armor: String,
        nodes: List<BeamioChatPgpStore.SiNode>,
        excludeIps: Set<String>,
        maxAttempts: Int = 4,
    ): Result {
        val trimmed = armor.trim()
        if (!trimmed.contains("BEGIN PGP MESSAGE")) {
            return Result(false, 0, "", "not_pgp")
        }
        val blocked = excludeIps.mapNotNull { normalizeIp(it) }.toSet()
        val ips = nodes.mapNotNull { normalizeIp(it.ip) }
            .filter { it !in blocked }
            .distinct()
            .shuffled()
        if (ips.isEmpty()) return Result(false, 0, "", "no_si_roster")
        val body = JSONObject().put("data", trimmed).toString()
        var lastStatus = 0
        for (ip in ips.take(maxAttempts.coerceAtLeast(1))) {
            val url = postUrl(ip) ?: continue
            val (status, text) = httpPost(url, body)
            lastStatus = status
            if (status in 200..299) {
                Log.i(TAG, "http ip ok status=$status")
                val capped = if (text.length > 48_000) text.substring(0, 48_000) else text
                return Result(true, status, capped, "")
            }
        }
        Log.i(TAG, "http ip failed status=$lastStatus")
        return Result(false, lastStatus, "", "post_failed")
    }

    private fun httpPost(url: String, body: String): Pair<Int, String> {
        var conn: HttpURLConnection? = null
        return try {
            conn = (URL(url).openConnection() as HttpURLConnection).apply {
                requestMethod = "POST"
                connectTimeout = 10_000
                readTimeout = 12_000
                doOutput = true
                setRequestProperty("Content-Type", "application/json")
            }
            OutputStreamWriter(conn.outputStream, Charsets.UTF_8).use { it.write(body) }
            val code = conn.responseCode
            val stream = if (code in 200..299) conn.inputStream else conn.errorStream
            val text = stream?.let {
                BufferedReader(InputStreamReader(it, Charsets.UTF_8)).use { r -> r.readText() }
            }.orEmpty()
            code to text
        } catch (error: Exception) {
            Log.i(TAG, "POST fail: ${error.message}")
            0 to ""
        } finally {
            conn?.disconnect()
        }
    }
}
