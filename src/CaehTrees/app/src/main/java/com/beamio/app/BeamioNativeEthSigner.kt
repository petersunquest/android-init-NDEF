package com.beamio.app

import org.bouncycastle.asn1.x9.X9IntegerConverter
import org.bouncycastle.crypto.digests.KeccakDigest
import org.bouncycastle.crypto.digests.SHA256Digest
import org.bouncycastle.crypto.ec.CustomNamedCurves
import org.bouncycastle.crypto.params.ECDomainParameters
import org.bouncycastle.crypto.params.ECPrivateKeyParameters
import org.bouncycastle.crypto.signers.ECDSASigner
import org.bouncycastle.crypto.signers.HMacDSAKCalculator
import org.bouncycastle.math.ec.ECAlgorithms
import org.bouncycastle.math.ec.ECPoint
import java.math.BigInteger

/**
 * Native Ethereum signing for the voice v3 channel texts (EIP-191 personal_sign
 * and wallet addresses), byte-for-byte what ethers.js `Wallet.signMessage` /
 * `Wallet.address` give: RFC 6979 nonce, low-s, `v` = 27/28, EIP-55 address.
 * BouncyCastle is already a dependency of this app; no new library.
 * Keys stay where they are: callers pass the hex they already hold.
 */
object BeamioNativeEthSigner {
    private val curve = CustomNamedCurves.getByName("secp256k1")
    private val domain = ECDomainParameters(curve.curve, curve.g, curve.n, curve.h)
    private val halfN: BigInteger = curve.n.shiftRight(1)

    fun keccak256(data: ByteArray): ByteArray {
        val d = KeccakDigest(256)
        d.update(data, 0, data.size)
        return ByteArray(32).also { d.doFinal(it, 0) }
    }

    /** EIP-55 checksummed address of a 32-byte private key (hex, optional 0x). */
    fun address(privateKeyHex: String): String? {
        val d = parseKey(privateKeyHex) ?: return null
        return addressOf(domain.g.multiply(d).normalize())
    }

    /** `0x` + r ‖ s ‖ v (65 bytes, v = 27/28) over EIP-191 of [message] (UTF-8). */
    fun signEip191(privateKeyHex: String, message: String): String? {
        val d = parseKey(privateKeyHex) ?: return null
        val bytes = message.toByteArray(Charsets.UTF_8)
        val prefix = "\u0019Ethereum Signed Message:\n${bytes.size}".toByteArray(Charsets.UTF_8)
        val hash = keccak256(prefix + bytes)
        val signer = ECDSASigner(HMacDSAKCalculator(SHA256Digest()))
        signer.init(true, ECPrivateKeyParameters(d, domain))
        val rs = signer.generateSignature(hash)
        val r = rs[0]
        var s = rs[1]
        if (s > halfN) s = curve.n.subtract(s)
        val pub = domain.g.multiply(d).normalize()
        val recId = (0..3).firstOrNull { recover(it, r, s, hash)?.equals(pub) == true } ?: return null
        val out = to32(r) + to32(s) + byteArrayOf((27 + recId).toByte())
        return "0x" + out.joinToString("") { "%02x".format(it) }
    }

    private fun parseKey(hex: String): BigInteger? {
        val h = hex.removePrefix("0x").removePrefix("0X")
        if (h.length != 64 || !h.all { it.isDigit() || it.lowercaseChar() in 'a'..'f' }) return null
        val d = BigInteger(h, 16)
        return if (d.signum() > 0 && d < curve.n) d else null
    }

    private fun addressOf(pub: ECPoint): String {
        val enc = pub.getEncoded(false) // 0x04 ‖ X ‖ Y
        val raw = keccak256(enc.copyOfRange(1, enc.size)).copyOfRange(12, 32)
        val lower = raw.joinToString("") { "%02x".format(it) }
        val h = keccak256(lower.toByteArray(Charsets.US_ASCII)).joinToString("") { "%02x".format(it) }
        val sb = StringBuilder("0x")
        for (i in lower.indices) {
            val c = lower[i]
            sb.append(if (c in 'a'..'f' && h[i].digitToInt(16) >= 8) c.uppercaseChar() else c)
        }
        return sb.toString()
    }

    /** SEC 1 v2 §4.1.6 public key recovery for recovery id [recId]. */
    private fun recover(recId: Int, r: BigInteger, s: BigInteger, hash: ByteArray): ECPoint? {
        val n = curve.n
        val x = r.add(BigInteger.valueOf((recId / 2).toLong()).multiply(n))
        val p = curve.curve.field.characteristic
        if (x >= p) return null
        val conv = X9IntegerConverter()
        val enc = conv.integerToBytes(x, 1 + conv.getByteLength(curve.curve))
        enc[0] = (if (recId and 1 == 1) 0x03 else 0x02).toByte()
        val bigR = runCatching { curve.curve.decodePoint(enc) }.getOrNull() ?: return null
        if (!bigR.multiply(n).isInfinity) return null
        val e = BigInteger(1, hash)
        val rInv = r.modInverse(n)
        val srInv = rInv.multiply(s).mod(n)
        val eInvrInv = rInv.multiply(n.subtract(e).mod(n)).mod(n)
        return ECAlgorithms.sumOfTwoMultiplies(domain.g, eInvrInv, bigR, srInv).normalize()
    }

    private fun to32(v: BigInteger): ByteArray {
        val b = v.toByteArray()
        return when {
            b.size == 32 -> b
            b.size > 32 -> b.copyOfRange(b.size - 32, b.size)
            else -> ByteArray(32 - b.size) + b
        }
    }
}
