package app.beamio.nfc

import android.nfc.Tag
import java.nio.charset.StandardCharsets
import javax.crypto.Cipher
import javax.crypto.spec.IvParameterSpec
import javax.crypto.spec.SecretKeySpec

object BeamioLocalSunDecoder {

    data class LocalDecodedCard(
        val uidHex: String,
        val counterHex: String,
        val counterLsbHex: String,
        val eHex: String,
        val mHex: String?,
        val tagIdHex: String,
        val version: Int,
        val padHex: String,
        val plainHex: String
    )

    /**
     * 本地解码：
     * - UID：优先来自 URL uid=，否则回退 Tag.id
     * - Counter：来自 URL c=（ASCII hex, MSB first）
     * - e：64 hex => 32 bytes, 作为 SDMENCFileData 解密
     * - Key2：全局 SDMFileReadKey
     *
     * 输出：
     * - uid
     * - ctr
     * - tagId / version / pad
     */
    fun decodeFromTagAndUrl(
        tag: Tag,
        url: String,
        globalKey2Hex: String
    ): LocalDecodedCard {
        val urlUidHex = getQueryParam(url, "uid")?.uppercase()
        val uid = when {
            urlUidHex != null -> hexToBytes(urlUidHex)
            else -> tag.id ?: error("Tag UID missing")
        }
        return decodeFromUidAndUrl(
            uid = uid,
            url = url,
            globalKey2Hex = globalKey2Hex
        )
    }

    fun decodeFromUrl(
        url: String,
        globalKey2Hex: String
    ): LocalDecodedCard {
        val urlUidHex = getQueryParam(url, "uid")?.uppercase() ?: error("Missing uid")
        val uid = hexToBytes(urlUidHex)
        return decodeFromUidAndUrl(
            uid = uid,
            url = url,
            globalKey2Hex = globalKey2Hex
        )
    }

    private fun decodeFromUidAndUrl(
        uid: ByteArray,
        url: String,
        globalKey2Hex: String
    ): LocalDecodedCard {
        val key2 = hexToBytes(globalKey2Hex)
        require(key2.size == 16) { "Key2 must be 16 bytes" }

        val eHex = getQueryParam(url, "e") ?: error("Missing e")
        val cHex = getQueryParam(url, "c") ?: error("Missing c")
        val mHex = getQueryParam(url, "m")

        require(uid.size == 7) { "Expected 7-byte UID, got ${uid.size}" }

        require(eHex.length == 64) { "e must be 64 hex chars" }
        require(cHex.length == 6) { "c must be 6 hex chars" }

        val encFileData = hexToBytes(eHex)
        val ctrMsb = hexToBytes(cHex)

        // 文档里说明：读出来的 counter 在 NDEF 中是 ASCII / MSB first，
        // 但密码学计算里 counter 需要用 LSB first。:contentReference[oaicite:4]{index=4}
        val ctrLsb = ctrMsb.reversedArray()

        val sessionEncKey = deriveSesSdmFileReadEncKey(
            sdmFileReadKey = key2,
            uid = uid,
            ctrLsb = ctrLsb
        )

        val iv = deriveSdmEncIv(
            sessionEncKey = sessionEncKey,
            ctrLsb = ctrLsb
        )

        val plain = aesCbcDecryptNoPadding(
            ciphertext = encFileData,
            key = sessionEncKey,
            iv = iv
        )

        require(plain.size == 32) { "Decrypted SDMENCFileData must be 32 bytes" }

        val embeddedUid = plain.copyOfRange(0, 7)
        val embeddedCtrMsb = plain.copyOfRange(7, 10).reversedArray()
        val isUidCtrTagIdLayout = embeddedUid.contentEquals(uid) && embeddedCtrMsb.contentEquals(ctrMsb)

        val tagId = if (isUidCtrTagIdLayout) {
            plain.copyOfRange(10, 18)
        } else {
            plain.copyOfRange(0, 8)
        }
        val ver = if (isUidCtrTagIdLayout) {
            plain[18].toInt() and 0xFF
        } else {
            plain[8].toInt() and 0xFF
        }
        val pad = if (isUidCtrTagIdLayout) {
            plain.copyOfRange(19, 32)
        } else {
            plain.copyOfRange(9, 32)
        }

        return LocalDecodedCard(
            uidHex = bytesToHex(uid),
            counterHex = bytesToHex(ctrMsb),
            counterLsbHex = bytesToHex(ctrLsb),
            eHex = eHex.uppercase(),
            mHex = mHex?.uppercase(),
            tagIdHex = bytesToHex(tagId),
            version = ver,
            padHex = bytesToHex(pad),
            plainHex = bytesToHex(plain)
        )
    }

    /**
     * KSesSDMFileReadENC = CMAC(KSDMFileRead; SV1)
     *
     * SV1 = C3 3C 00 01 00 80 || UID(7) || CTR(3)
     *
     * NXP 在 SDM Session Key Generation 示例中给出了这个构造：
     * SV1 = C33C 0001 0080 [UID] [SDMReadCtr]，
     * 其中在加密文件数据场景下，UID 和 SDMReadCtr 都要参与。:contentReference[oaicite:5]{index=5}
     */
    fun deriveSesSdmFileReadEncKey(
        sdmFileReadKey: ByteArray,
        uid: ByteArray,
        ctrLsb: ByteArray
    ): ByteArray {
        require(sdmFileReadKey.size == 16) { "sdmFileReadKey must be 16 bytes" }
        require(uid.size == 7) { "uid must be 7 bytes" }
        require(ctrLsb.size == 3) { "ctr must be 3 bytes" }

        val sv1 = byteArrayOf(
            0xC3.toByte(), 0x3C.toByte(),
            0x00, 0x01, 0x00, 0x80.toByte()
        ) + uid + ctrLsb

        require(sv1.size == 16) { "SV1 must be 16 bytes" }

        return aesCmac(sdmFileReadKey, sv1)
    }

    /**
     * IV = Enc(KSesSDMFileReadEncKey; SDMReadCounter || 13 bytes 0x00)
     *
     * NXP 的 SDMENCFileData 说明里给出：
     * IV = Enc(SesSDMFileReadEncKey; SDMReadCounter || 0x00...00) 。:contentReference[oaicite:6]{index=6}
     */
    fun deriveSdmEncIv(
        sessionEncKey: ByteArray,
        ctrLsb: ByteArray
    ): ByteArray {
        require(sessionEncKey.size == 16) { "sessionEncKey must be 16 bytes" }
        require(ctrLsb.size == 3) { "ctr must be 3 bytes" }

        val ivInput = ByteArray(16)
        System.arraycopy(ctrLsb, 0, ivInput, 0, 3)

        return aesEcbEncrypt(sessionEncKey, ivInput)
    }

    // ---------------- Crypto helpers ----------------

    fun aesCbcDecryptNoPadding(ciphertext: ByteArray, key: ByteArray, iv: ByteArray): ByteArray {
        val cipher = Cipher.getInstance("AES/CBC/NoPadding")
        val sk = SecretKeySpec(key, "AES")
        cipher.init(Cipher.DECRYPT_MODE, sk, IvParameterSpec(iv))
        return cipher.doFinal(ciphertext)
    }

    fun aesEcbEncrypt(key: ByteArray, block16: ByteArray): ByteArray {
        require(key.size == 16) { "AES key must be 16 bytes" }
        require(block16.size == 16) { "ECB block must be 16 bytes" }

        val cipher = Cipher.getInstance("AES/ECB/NoPadding")
        val sk = SecretKeySpec(key, "AES")
        cipher.init(Cipher.ENCRYPT_MODE, sk)
        return cipher.doFinal(block16)
    }

    /**
     * NIST SP800-38B AES-CMAC
     */
    fun aesCmac(key: ByteArray, message: ByteArray): ByteArray {
        require(key.size == 16) { "CMAC key must be 16 bytes" }

        val zero = ByteArray(16)
        val l = aesEcbEncrypt(key, zero)
        val (k1, k2) = cmacSubkeys(l)

        val blockCount = if (message.isEmpty()) 1 else ((message.size + 15) / 16)
        val lastComplete = message.isNotEmpty() && (message.size % 16 == 0)

        val mLast = ByteArray(16)

        if (lastComplete) {
            val last = message.copyOfRange((blockCount - 1) * 16, blockCount * 16)
            xorInto(mLast, last, k1)
        } else {
            val start = (blockCount - 1) * 16
            val last = ByteArray(16)
            val remain = if (start < message.size) message.copyOfRange(start, message.size) else ByteArray(0)
            System.arraycopy(remain, 0, last, 0, remain.size)
            last[remain.size] = 0x80.toByte()
            xorInto(mLast, last, k2)
        }

        var x = ByteArray(16)
        for (i in 0 until blockCount - 1) {
            val block = message.copyOfRange(i * 16, (i + 1) * 16)
            x = aesEcbEncrypt(key, xor16(x, block))
        }

        return aesEcbEncrypt(key, xor16(x, mLast))
    }

    private fun cmacSubkeys(l: ByteArray): Pair<ByteArray, ByteArray> {
        val k1 = leftShiftOneBit(l)
        if ((l[0].toInt() and 0x80) != 0) {
            k1[15] = (k1[15].toInt() xor 0x87).toByte()
        }

        val k2 = leftShiftOneBit(k1)
        if ((k1[0].toInt() and 0x80) != 0) {
            k2[15] = (k2[15].toInt() xor 0x87).toByte()
        }

        return k1 to k2
    }

    private fun leftShiftOneBit(input: ByteArray): ByteArray {
        val out = ByteArray(16)
        var carry = 0
        for (i in 15 downTo 0) {
            val b = input[i].toInt() and 0xFF
            out[i] = ((b shl 1) and 0xFF or carry).toByte()
            carry = if ((b and 0x80) != 0) 1 else 0
        }
        return out
    }

    private fun xorInto(out: ByteArray, a: ByteArray, b: ByteArray) {
        require(out.size == 16 && a.size == 16 && b.size == 16)
        for (i in 0 until 16) {
            out[i] = ((a[i].toInt() xor b[i].toInt()) and 0xFF).toByte()
        }
    }

    private fun xor16(a: ByteArray, b: ByteArray): ByteArray {
        val out = ByteArray(16)
        xorInto(out, a, b)
        return out
    }

    // ---------------- URL / HEX helpers ----------------

    fun getQueryParam(url: String, key: String): String? {
        val marker = "$key="
        val idx = url.indexOf(marker)
        if (idx < 0) return null
        val start = idx + marker.length
        val end = url.indexOf('&', start).let { if (it < 0) url.length else it }
        return url.substring(start, end)
    }

    fun hexToBytes(hex: String): ByteArray {
        val s = hex.trim().replace(" ", "")
        require(s.length % 2 == 0) { "hex length must be even" }
        return ByteArray(s.length / 2) { i ->
            s.substring(i * 2, i * 2 + 2).toInt(16).toByte()
        }
    }

    fun bytesToHex(data: ByteArray): String =
        buildString(data.size * 2) {
            data.forEach { append("%02X".format(it)) }
        }
}