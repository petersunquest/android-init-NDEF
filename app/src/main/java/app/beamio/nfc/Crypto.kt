package app.beamio.nfc

import java.security.SecureRandom
import javax.crypto.Cipher
import javax.crypto.spec.IvParameterSpec
import javax.crypto.spec.SecretKeySpec

object Crypto {
    private val random = SecureRandom()

    fun randomBytes(n: Int): ByteArray = ByteArray(n).also { random.nextBytes(it) }

    /** AES/CBC/NoPadding only. EV2 steps use different IVs; caller must pass correct IV per step. */
    fun aesCbcEncrypt(plaintext: ByteArray, key: ByteArray, iv: ByteArray): ByteArray {
        val cipher = Cipher.getInstance("AES/CBC/NoPadding")
        cipher.init(Cipher.ENCRYPT_MODE, SecretKeySpec(key, "AES"), IvParameterSpec(iv))
        return cipher.doFinal(plaintext)
    }

    /** AES/CBC/NoPadding only. Step1: IV=ByteArray(16) (zero). Step2: IV=encAB[16..32]. */
    fun aesCbcDecrypt(ciphertext: ByteArray, key: ByteArray, iv: ByteArray): ByteArray {
        val cipher = Cipher.getInstance("AES/CBC/NoPadding")
        cipher.init(Cipher.DECRYPT_MODE, SecretKeySpec(key, "AES"), IvParameterSpec(iv))
        return cipher.doFinal(ciphertext)
    }

    fun aesEcbEncrypt(block16: ByteArray, key: ByteArray): ByteArray {
        val cipher = Cipher.getInstance("AES/ECB/NoPadding")
        cipher.init(Cipher.ENCRYPT_MODE, SecretKeySpec(key, "AES"))
        return cipher.doFinal(block16)
    }

    /** CMAC(msg, key) - data first, key second, matches aesCbcEncrypt/aesEcbEncrypt style. */
    fun aesCmac(msg: ByteArray, key: ByteArray): ByteArray {
        require(key.size == 16) { "bad cmac key length" }
        val l = aesEcbEncrypt(ByteArray(16), key)
        val (k1, k2) = cmacSubkeys(l)
        val n = maxOf(1, kotlin.math.ceil(msg.size / 16.0).toInt())
        val lastComplete = (msg.size % 16 == 0) && msg.isNotEmpty()
        val mLast = if (lastComplete) {
            xor16(msg.copyOfRange((n - 1) * 16, n * 16), k1)
        } else {
            val start = (n - 1) * 16
            val last = if (start < msg.size) msg.copyOfRange(start, msg.size) else byteArrayOf()
            val pad = ByteArray(16)
            last.copyInto(pad)
            pad[last.size] = 0x80.toByte()
            xor16(pad, k2)
        }
        var x = ByteArray(16)
        for (i in 0 until (n - 1)) {
            val block = msg.copyOfRange(i * 16, (i + 1) * 16)
            x = aesEcbEncrypt(xor16(x, block), key)
        }
        return aesEcbEncrypt(xor16(x, mLast), key)
    }

    private fun cmacSubkeys(l: ByteArray): Pair<ByteArray, ByteArray> {
        val rb: Byte = 0x87.toByte()
        fun leftShift(input: ByteArray): ByteArray {
            val out = ByteArray(16)
            var carry = 0
            for (i in 15 downTo 0) {
                val b = input[i].toInt() and 0xFF
                out[i] = ((b shl 1) or carry).toByte()
                carry = if ((b and 0x80) != 0) 1 else 0
            }
            return out
        }
        var k1 = leftShift(l)
        if ((l[0].toInt() and 0x80) != 0) k1[15] = (k1[15].toInt() xor rb.toInt()).toByte()
        var k2 = leftShift(k1)
        if ((k1[0].toInt() and 0x80) != 0) k2[15] = (k2[15].toInt() xor rb.toInt()).toByte()
        return Pair(k1, k2)
    }

    private fun xor16(a: ByteArray, b: ByteArray): ByteArray {
        val out = ByteArray(16)
        for (i in 0 until 16) out[i] = (a[i].toInt() xor b[i].toInt()).toByte()
        return out
    }
}
