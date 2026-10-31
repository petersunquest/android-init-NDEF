package com.beamio.app

import android.util.Base64
import java.security.MessageDigest

/**
 * Reads OpenPGP key IDs from armored data without decrypting anything:
 * recipient key IDs of an encrypted message (PKESK packets) and the v4 key
 * IDs of a public key and its subkeys. Used only for diagnostics when an
 * incoming-call offer cannot be decrypted.
 */
object BeamioPgpKeyIds {

    /** Recipient key IDs named in a `BEGIN PGP MESSAGE` armor. */
    fun messageRecipients(armor: String): List<String> {
        val out = ArrayList<String>()
        forEachPacket(dearmor(armor) ?: return out) { tag, body ->
            // PKESK v3: version(1) + keyID(8) + algo + ...
            if (tag == 1 && body.size >= 9 && body[0].toInt() == 3) {
                out += hex(body.copyOfRange(1, 9))
            }
            // Stop once the encrypted payload starts.
            tag != 9 && tag != 18 && tag != 20
        }
        return out
    }

    /** Primary and subkey IDs of a `BEGIN PGP PUBLIC KEY BLOCK` armor (v4 keys). */
    fun publicKeyIds(armor: String): List<String> {
        val out = ArrayList<String>()
        forEachPacket(dearmor(armor) ?: return out) { tag, body ->
            if ((tag == 6 || tag == 14) && body.isNotEmpty() && body[0].toInt() == 4) {
                val sha = MessageDigest.getInstance("SHA-1")
                sha.update(0x99.toByte())
                sha.update((body.size shr 8 and 0xFF).toByte())
                sha.update((body.size and 0xFF).toByte())
                sha.update(body)
                val fp = sha.digest()
                out += hex(fp.copyOfRange(fp.size - 8, fp.size))
            }
            true
        }
        return out
    }

    /**
     * For each secret key / subkey packet in a private key armor: its key ID
     * and whether the secret part is passphrase-protected (S2K usage != 0).
     */
    fun secretKeyProtection(armor: String): List<String> {
        val out = ArrayList<String>()
        forEachPacket(dearmor(armor) ?: return out) { tag, body ->
            if ((tag == 5 || tag == 7) && body.isNotEmpty() && body[0].toInt() == 4) {
                val pubLen = v4PublicLength(body)
                if (pubLen != null && pubLen < body.size) {
                    val pub = body.copyOfRange(0, pubLen)
                    val sha = MessageDigest.getInstance("SHA-1")
                    sha.update(0x99.toByte())
                    sha.update((pub.size shr 8 and 0xFF).toByte())
                    sha.update((pub.size and 0xFF).toByte())
                    sha.update(pub)
                    val fp = sha.digest()
                    val usage = body[pubLen].toInt() and 0xFF
                    out += hex(fp.copyOfRange(fp.size - 8, fp.size)) +
                        if (usage == 0) ":plain" else ":protected($usage)"
                } else {
                    out += "unknown-algo"
                }
            }
            true
        }
        return out
    }

    /** Length of the public-key part of a v4 key packet body, or null if unsupported. */
    private fun v4PublicLength(b: ByteArray): Int? {
        if (b.size < 6) return null
        var p = 6
        fun mpi(): Boolean {
            if (p + 2 > b.size) return false
            val bits = ((b[p].toInt() and 0xFF) shl 8) or (b[p + 1].toInt() and 0xFF)
            p += 2 + (bits + 7) / 8
            return p <= b.size
        }
        fun lenPrefixed(): Boolean {
            if (p >= b.size) return false
            p += 1 + (b[p].toInt() and 0xFF)
            return p <= b.size
        }
        val ok = when (b[5].toInt() and 0xFF) {
            1, 2, 3 -> mpi() && mpi()
            16, 20 -> mpi() && mpi() && mpi()
            17 -> mpi() && mpi() && mpi() && mpi()
            18 -> lenPrefixed() && mpi() && lenPrefixed()
            19, 22 -> lenPrefixed() && mpi()
            25 -> { p += 32; p <= b.size }
            26 -> { p += 56; p <= b.size }
            27 -> { p += 32; p <= b.size }
            28 -> { p += 57; p <= b.size }
            else -> false
        }
        return if (ok) p else null
    }

    private fun dearmor(armor: String): ByteArray? {
        val lines = armor.replace("\r", "").lines()
        val start = lines.indexOfFirst { it.startsWith("-----BEGIN PGP") }
        if (start < 0) return null
        var i = start + 1
        // Skip armor headers up to the blank line.
        while (i < lines.size && lines[i].isNotBlank()) {
            if (!lines[i].contains(":")) break
            i++
        }
        val b64 = StringBuilder()
        while (i < lines.size) {
            val line = lines[i].trim()
            if (line.startsWith("-----END") || line.startsWith("=")) break
            b64.append(line)
            i++
        }
        return runCatching { Base64.decode(b64.toString(), Base64.DEFAULT) }.getOrNull()
    }

    /** Walks packets; [visit] returns false to stop. Partial lengths end the walk. */
    private fun forEachPacket(data: ByteArray, visit: (tag: Int, body: ByteArray) -> Boolean) {
        var p = 0
        while (p < data.size) {
            val h = data[p].toInt() and 0xFF
            if (h and 0x80 == 0) return
            var tag: Int
            var len: Int
            if (h and 0x40 != 0) {
                tag = h and 0x3F
                if (p + 1 >= data.size) return
                val o1 = data[p + 1].toInt() and 0xFF
                when {
                    o1 < 192 -> { len = o1; p += 2 }
                    o1 < 224 -> {
                        if (p + 2 >= data.size) return
                        len = ((o1 - 192) shl 8) + (data[p + 2].toInt() and 0xFF) + 192
                        p += 3
                    }
                    o1 == 255 -> {
                        if (p + 5 >= data.size) return
                        len = be32(data, p + 2)
                        p += 6
                    }
                    else -> return
                }
            } else {
                tag = (h shr 2) and 0x0F
                when (h and 0x03) {
                    0 -> { if (p + 1 >= data.size) return; len = data[p + 1].toInt() and 0xFF; p += 2 }
                    1 -> { if (p + 2 >= data.size) return; len = ((data[p + 1].toInt() and 0xFF) shl 8) or (data[p + 2].toInt() and 0xFF); p += 3 }
                    2 -> { if (p + 4 >= data.size) return; len = be32(data, p + 1); p += 5 }
                    else -> return
                }
            }
            if (len < 0 || p + len > data.size) return
            if (!visit(tag, data.copyOfRange(p, p + len))) return
            p += len
        }
    }

    private fun be32(b: ByteArray, at: Int): Int =
        ((b[at].toInt() and 0xFF) shl 24) or ((b[at + 1].toInt() and 0xFF) shl 16) or
            ((b[at + 2].toInt() and 0xFF) shl 8) or (b[at + 3].toInt() and 0xFF)

    private fun hex(b: ByteArray): String = b.joinToString("") { "%02X".format(it) }
}
