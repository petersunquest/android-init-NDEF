package com.beamio.app

import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Test
import java.util.Base64

/**
 * Native signer vs ethers.js. Vectors (resources/eth-sign-vectors.tsv) were made
 * with ethers v6 `Wallet.signMessage`, `Wallet.address` and `keccak256`;
 * messages are base64 (UTF-8), including the v3 pay / listen texts.
 */
class BeamioNativeEthSignerTest {
    private val rows = javaClass.classLoader!!.getResource("eth-sign-vectors.tsv").readText()
        .lines().filter { it.isNotBlank() }.map { it.split('\t') }
    private fun b64(s: String) = String(Base64.getDecoder().decode(s), Charsets.UTF_8)

    @Test
    fun keccakMatchesEthers() {
        val ks = rows.filter { it[0] == "K" }
        assertTrue(ks.isNotEmpty())
        for (k in ks) {
            val got = "0x" + BeamioNativeEthSigner.keccak256(b64(k[1]).toByteArray()).joinToString("") { "%02x".format(it) }
            assertEquals(k[2], got)
        }
    }

    @Test
    fun signaturesAndAddressesMatchEthersByteForByte() {
        val ss = rows.filter { it[0] == "S" }
        assertEquals(15, ss.size)
        for ((i, v) in ss.withIndex()) {
            assertEquals(v[2], BeamioNativeEthSigner.address(v[1]))
            assertEquals("vector $i", v[3], BeamioNativeEthSigner.signEip191(v[1], b64(v[4])))
        }
    }
}
