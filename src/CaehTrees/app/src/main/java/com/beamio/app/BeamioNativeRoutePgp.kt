package com.beamio.app

import android.util.Base64
import org.bouncycastle.bcpg.ArmoredOutputStream
import org.bouncycastle.bcpg.CompressionAlgorithmTags
import org.bouncycastle.bcpg.SymmetricKeyAlgorithmTags
import org.bouncycastle.openpgp.PGPCompressedDataGenerator
import org.bouncycastle.openpgp.PGPEncryptedDataGenerator
import org.bouncycastle.openpgp.PGPLiteralData
import org.bouncycastle.openpgp.PGPLiteralDataGenerator
import org.bouncycastle.openpgp.PGPPublicKey
import org.bouncycastle.openpgp.PGPPublicKeyRing
import org.bouncycastle.openpgp.PGPUtil
import org.bouncycastle.openpgp.operator.bc.BcKeyFingerprintCalculator
import org.bouncycastle.openpgp.operator.bc.BcPGPDataEncryptorBuilder
import org.bouncycastle.openpgp.operator.bc.BcPublicKeyKeyEncryptionMethodGenerator
import java.io.ByteArrayOutputStream
import java.security.SecureRandom
import java.util.Date
import java.util.concurrent.ConcurrentHashMap
import java.util.concurrent.Executors
import java.util.concurrent.atomic.AtomicInteger
import android.content.Context
import android.util.Log
import network.conet.chat.BeamioOpenPgpHost

/**
 * Route-key OpenPGP encryption on the calling thread, without the WebView.
 *
 * Same output as the chat SDK's `encryptToRoute` (openpgp.js): the literal text
 * is base64 of the UTF-8 JSON command, zlib compressed, encrypted to the route
 * key's encryption subkey only, armored. The SI decrypts it and base64-decodes
 * the literal. The WebView path stalled for 1–2 s whenever the main thread was
 * busy, which left multi-second gaps in call audio.
 *
 * Uses the BouncyCastle lightweight (`Bc*`) API so no JCA provider is involved
 * (Android ships its own reduced "BC" provider).
 */
object BeamioNativeRoutePgp {
    private const val TAG = "BeamioRoutePgp"
    private val keyCache = ConcurrentHashMap<String, PGPPublicKey>()
    private val random = SecureRandom()
    private val threadNo = AtomicInteger(0)

    /**
     * Background pool for encryption: never the main thread. Low priority so
     * the UI and audio threads always win the CPU.
     */
    private val pool = Executors.newFixedThreadPool(2) { r ->
        Thread({
            android.os.Process.setThreadPriority(android.os.Process.THREAD_PRIORITY_BACKGROUND)
            r.run()
        }, "BeamioRoutePgp-${threadNo.incrementAndGet()}").apply { isDaemon = true }
    }

    /**
     * Drop-in for `BeamioOpenPgpHost.encryptToRoute`: same callback, but the
     * work runs on [pool]. Falls back to the WebView host only if native fails.
     * [done] runs on a pool thread (or the WebView callback thread on fallback).
     */
    fun encryptToRouteAsync(
        context: Context,
        routePublicArmor: String,
        plaintextJson: String,
        done: (Result<String>) -> Unit,
    ) {
        val app = context.applicationContext
        pool.execute {
            val native = runCatching { encryptToRoute(routePublicArmor, plaintextJson) }
            if (native.isSuccess) {
                done(native)
                return@execute
            }
            Log.w(TAG, "native encrypt failed: ${native.exceptionOrNull()?.message}; WebView fallback")
            BeamioOpenPgpHost.shared(app).encryptToRoute(routePublicArmor, plaintextJson, done)
        }
    }

    /** Armored PGP message for [plaintextJson], or throws on a bad key. */
    fun encryptToRoute(routePublicArmor: String, plaintextJson: String): String {
        val key = encryptionKey(routePublicArmor)
        val literalText = Base64.encodeToString(
            plaintextJson.toByteArray(Charsets.UTF_8),
            Base64.NO_WRAP,
        ).toByteArray(Charsets.UTF_8)

        // Literal → compressed (zlib, as openpgp.js prefers) → encrypted → armored.
        val compressedBytes = ByteArrayOutputStream().use { compressedOut ->
            val compressor = PGPCompressedDataGenerator(CompressionAlgorithmTags.ZLIB)
            compressor.open(compressedOut).use { cOut ->
                PGPLiteralDataGenerator().open(
                    cOut,
                    PGPLiteralData.UTF8,
                    "",
                    literalText.size.toLong(),
                    Date(),
                ).use { it.write(literalText) }
            }
            compressor.close()
            compressedOut.toByteArray()
        }

        val armored = ByteArrayOutputStream()
        ArmoredOutputStream.builder().clearHeaders().build(armored).use { armorOut ->
            val encryptor = PGPEncryptedDataGenerator(
                BcPGPDataEncryptorBuilder(SymmetricKeyAlgorithmTags.AES_256)
                    .setWithIntegrityPacket(true)
                    .setSecureRandom(random),
            )
            encryptor.addMethod(BcPublicKeyKeyEncryptionMethodGenerator(key).setSecureRandom(random))
            encryptor.open(armorOut, compressedBytes.size.toLong()).use { it.write(compressedBytes) }
        }
        return armored.toString(Charsets.UTF_8.name())
    }

    /**
     * Voice channel v2 chunk: armored OpenPGP message whose literal is [bytes]
     * (binary, uncompressed: the chunk is AES output). No WebView fallback; the
     * caller sends that frame on the v1 path instead. [done] runs on [pool].
     */
    fun encryptBinaryAsync(routePublicArmor: String, bytes: ByteArray, done: (Result<String>) -> Unit) {
        pool.execute { done(runCatching { encryptBinaryToRoute(routePublicArmor, bytes) }) }
    }

    fun encryptBinaryToRoute(routePublicArmor: String, bytes: ByteArray): String {
        val key = encryptionKey(routePublicArmor)
        val literal = ByteArrayOutputStream().use { out ->
            PGPLiteralDataGenerator().open(out, PGPLiteralData.BINARY, "", bytes.size.toLong(), Date())
                .use { it.write(bytes) }
            out.toByteArray()
        }
        val armored = ByteArrayOutputStream()
        ArmoredOutputStream.builder().clearHeaders().build(armored).use { armorOut ->
            val encryptor = PGPEncryptedDataGenerator(
                BcPGPDataEncryptorBuilder(SymmetricKeyAlgorithmTags.AES_256)
                    .setWithIntegrityPacket(true)
                    .setSecureRandom(random),
            )
            encryptor.addMethod(BcPublicKeyKeyEncryptionMethodGenerator(key).setSecureRandom(random))
            encryptor.open(armorOut, literal.size.toLong()).use { it.write(literal) }
        }
        return armored.toString(Charsets.UTF_8.name())
    }

    /** The key's encryption subkey (one recipient only), cached per armor. */
    private fun encryptionKey(armor: String): PGPPublicKey {
        keyCache[armor]?.let { return it }
        val ring = PGPUtil.getDecoderStream(armor.toByteArray(Charsets.UTF_8).inputStream()).use { input ->
            PGPPublicKeyRing(input, BcKeyFingerprintCalculator())
        }
        val keys = ring.publicKeys.asSequence().toList()
        val key = keys.firstOrNull { !it.isMasterKey && it.isEncryptionKey }
            ?: keys.firstOrNull { it.isEncryptionKey }
            ?: throw IllegalArgumentException("route key has no encryption subkey")
        keyCache[armor] = key
        return key
    }
}
