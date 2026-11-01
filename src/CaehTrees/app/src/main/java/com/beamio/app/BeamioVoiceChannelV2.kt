package com.beamio.app

import java.nio.ByteBuffer
import java.nio.ByteOrder
import java.security.SecureRandom
import javax.crypto.Cipher
import javax.crypto.Mac
import javax.crypto.spec.GCMParameterSpec
import javax.crypto.spec.SecretKeySpec

/**
 * Voice channel v2 (CoNET Chat rules 22/23). Same wire as iOS
 * `BeamioVoiceChannelV2.swift` and the PWA SDK `voice-channel-v2.ts`.
 *
 * Setup once per direction: `voice_listen` with `v: 2` and a random 32-byte write
 * key `wk` on the 32-hex session (the channel locator); the node answers `v: 2`;
 * the peer learns `wk` from the AES caps frame (`chan: 2`, `wk`).
 *
 * Each chunk is a binary OpenPGP literal to the peer route key:
 * `CVC2 ‖ locator(16) ‖ HMAC-SHA256(wk, locator ‖ blob)[0..16) ‖ blob`.
 * `blob` = AES-GCM (session key, AAD = `CVC2 ‖ locator`) over a 28-byte LE header
 * `ver=2 | kind | flags | rsv | seq u32 | captureMs u64 | frameId u32 | fragIdx u16 |
 * fragCnt u16 | dataLen u32` + data + zero padding (blob → multiple of 256, max 9000).
 */
object BeamioVoiceChannelV2 {
    val MAGIC = "CVC2".toByteArray(Charsets.US_ASCII)
    const val HEADER = 28
    const val PAD_BUCKET = 256
    const val MAX_BLOB = 9_000
    const val KIND_AUDIO = 0
    const val KIND_VIDEO = 1
    const val KIND_CONTROL = 2
    private val random = SecureRandom()

    class Peer(val locator: ByteArray, val writeKey: ByteArray)
    class Opened(val kind: Int, val seq: Int, val captureMs: Long, val frameId: Int, val data: ByteArray)

    fun randomWriteKey(): ByteArray = ByteArray(32).also { random.nextBytes(it) }

    /** 32 lowercase hex chars → 16 bytes; null for any other session id. */
    fun locator(sessionId: String): ByteArray? {
        val hex = sessionId.trim()
        if (hex.length != 32 || hex != hex.lowercase() || !hex.all { it in '0'..'9' || it in 'a'..'f' }) return null
        return ByteArray(16) { i -> hex.substring(i * 2, i * 2 + 2).toInt(16).toByte() }
    }

    private fun keyBytes(sessionKeyB64: String): ByteArray =
        android.util.Base64.decode(sessionKeyB64.trim(), android.util.Base64.DEFAULT)

    private fun aad(locator: ByteArray) = MAGIC + locator

    fun sealChunk(
        sessionKeyB64: String,
        peer: Peer,
        kind: Int,
        seq: Int,
        captureMs: Long,
        frameId: Int,
        data: ByteArray,
    ): ByteArray = sealChunk(keyBytes(sessionKeyB64), peer, kind, seq, captureMs, frameId, data)

    fun openChunk(sessionKeyB64: String, ownLocator: ByteArray, blob: ByteArray): Opened =
        openChunk(keyBytes(sessionKeyB64), ownLocator, blob)

    fun sealChunk(
        sessionKey: ByteArray,
        peer: Peer,
        kind: Int,
        seq: Int,
        captureMs: Long,
        frameId: Int,
        data: ByteArray,
    ): ByteArray {
        require(sessionKey.size == 32) { "invalid sessionKey" }
        val bare = 12 + HEADER + data.size + 16
        require(bare <= MAX_BLOB) { "chunk too large" }
        val padded = minOf(MAX_BLOB, (bare + PAD_BUCKET - 1) / PAD_BUCKET * PAD_BUCKET)
        val plain = ByteBuffer.allocate(padded - 28).order(ByteOrder.LITTLE_ENDIAN)
        plain.put(2).put(kind.toByte()).put(0).put(0)
        plain.putInt(seq).putLong(captureMs).putInt(frameId)
        plain.putShort(0).putShort(1).putInt(data.size)
        plain.put(data)
        val nonce = ByteArray(12).also { random.nextBytes(it) }
        val cipher = Cipher.getInstance("AES/GCM/NoPadding")
        cipher.init(Cipher.ENCRYPT_MODE, SecretKeySpec(sessionKey, "AES"), GCMParameterSpec(128, nonce))
        cipher.updateAAD(aad(peer.locator))
        val blob = nonce + cipher.doFinal(plain.array())
        val mac = Mac.getInstance("HmacSHA256")
        mac.init(SecretKeySpec(peer.writeKey, "HmacSHA256"))
        mac.update(peer.locator)
        val tag = mac.doFinal(blob).copyOf(16)
        return MAGIC + peer.locator + tag + blob
    }

    fun openChunk(sessionKey: ByteArray, ownLocator: ByteArray, blob: ByteArray): Opened {
        require(sessionKey.size == 32 && blob.size > 28) { "bad key or chunk" }
        val cipher = Cipher.getInstance("AES/GCM/NoPadding")
        cipher.init(Cipher.DECRYPT_MODE, SecretKeySpec(sessionKey, "AES"), GCMParameterSpec(128, blob, 0, 12))
        cipher.updateAAD(aad(ownLocator))
        val plain = cipher.doFinal(blob, 12, blob.size - 12)
        require(plain.size >= HEADER && plain[0].toInt() == 2) { "bad chunk header" }
        val b = ByteBuffer.wrap(plain).order(ByteOrder.LITTLE_ENDIAN)
        val kind = plain[1].toInt() and 0xff
        val seq = b.getInt(4)
        val captureMs = b.getLong(8)
        val frameId = b.getInt(16)
        val dataLen = b.getInt(24)
        require(dataLen >= 0 && HEADER + dataLen <= plain.size) { "bad chunk length" }
        return Opened(kind, seq, captureMs, frameId, plain.copyOfRange(HEADER, HEADER + dataLen))
    }
}
