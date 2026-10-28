package com.beamio.app

import android.util.Base64
import org.json.JSONObject
import java.security.SecureRandom
import javax.crypto.Cipher
import javax.crypto.spec.GCMParameterSpec
import javax.crypto.spec.SecretKeySpec

/**
 * AES-256-GCM matching PWA `encryptVoiceFrame`: nonce(12) ‖ ciphertext‖tag → base64. No AAD.
 */
object BeamioVoiceAesGcm {
    private const val NONCE_LEN = 12
    private const val TAG_BITS = 128

    fun encryptUtf8Json(keyBase64: String, json: JSONObject): String {
        return encryptBytes(keyBase64, json.toString().toByteArray(Charsets.UTF_8))
    }

    fun encryptBytes(keyBase64: String, plain: ByteArray): String {
        val keyBytes = Base64.decode(keyBase64.trim(), Base64.DEFAULT)
        require(keyBytes.size == 32) { "invalid sessionKey length=${keyBytes.size}" }
        val nonce = ByteArray(NONCE_LEN).also { SecureRandom().nextBytes(it) }
        val cipher = Cipher.getInstance("AES/GCM/NoPadding")
        cipher.init(
            Cipher.ENCRYPT_MODE,
            SecretKeySpec(keyBytes, "AES"),
            GCMParameterSpec(TAG_BITS, nonce),
        )
        val cipherAndTag = cipher.doFinal(plain)
        val packed = ByteArray(nonce.size + cipherAndTag.size)
        System.arraycopy(nonce, 0, packed, 0, nonce.size)
        System.arraycopy(cipherAndTag, 0, packed, nonce.size, cipherAndTag.size)
        return Base64.encodeToString(packed, Base64.NO_WRAP)
    }

    fun decryptBytes(keyBase64: String, payloadBase64: String): ByteArray {
        val keyBytes = Base64.decode(keyBase64.trim(), Base64.DEFAULT)
        require(keyBytes.size == 32) { "invalid sessionKey length=${keyBytes.size}" }
        val packed = Base64.decode(payloadBase64.trim(), Base64.DEFAULT)
        require(packed.size > NONCE_LEN) { "payload too short" }
        val nonce = packed.copyOfRange(0, NONCE_LEN)
        val cipherAndTag = packed.copyOfRange(NONCE_LEN, packed.size)
        val cipher = Cipher.getInstance("AES/GCM/NoPadding")
        cipher.init(
            Cipher.DECRYPT_MODE,
            SecretKeySpec(keyBytes, "AES"),
            GCMParameterSpec(TAG_BITS, nonce),
        )
        return cipher.doFinal(cipherAndTag)
    }
}
