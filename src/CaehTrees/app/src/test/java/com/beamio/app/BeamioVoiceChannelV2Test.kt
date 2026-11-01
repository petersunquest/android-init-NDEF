package com.beamio.app

import org.junit.Assert.assertArrayEquals
import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Test
import java.io.File
import javax.crypto.Mac
import javax.crypto.spec.SecretKeySpec

class BeamioVoiceChannelV2Test {
    private fun unhex(s: String) = if (s == "-") ByteArray(0) else ByteArray(s.length / 2) { s.substring(it * 2, it * 2 + 2).toInt(16).toByte() }
    private fun hex(b: ByteArray) = b.joinToString("") { "%02x".format(it) }
    private fun mac(wk: ByteArray, loc: ByteArray, blob: ByteArray): ByteArray =
        Mac.getInstance("HmacSHA256").apply { init(SecretKeySpec(wk, "HmacSHA256")); update(loc) }.doFinal(blob).copyOf(16)

    @Test
    fun roundTripPadsAndAuthenticates() {
        val key = ByteArray(32) { it.toByte() }
        val wk = ByteArray(32) { (it * 3).toByte() }
        val loc = BeamioVoiceChannelV2.locator("00112233445566778899aabbccddeeff")!!
        val data = ByteArray(5120) { (it % 251).toByte() }
        val lit = BeamioVoiceChannelV2.sealChunk(key, BeamioVoiceChannelV2.Peer(loc, wk), 0, 7, 1234L, 0, data)
        val blob = lit.copyOfRange(36, lit.size)
        assertEquals(0, blob.size % 256)
        assertArrayEquals(mac(wk, loc, blob), lit.copyOfRange(20, 36))
        val o = BeamioVoiceChannelV2.openChunk(key, loc, blob)
        assertEquals(7, o.seq)
        assertEquals(1234L, o.captureMs)
        assertArrayEquals(data, o.data)
    }

    /** Cross-check with vectors from the PWA SDK: `BEAMIO_V2_VECTORS=<dir>` (skipped otherwise). */
    @Test
    fun interopWithSdkVectors() {
        val dir = System.getenv("BEAMIO_V2_VECTORS") ?: return
        val lines = File(dir, "vectors.txt").readLines().filter { it.isNotBlank() }
        val (k, w, l) = lines[0].split(" ")
        val key = unhex(k); val wk = unhex(w); val loc = unhex(l)
        var opened = 0
        val mine = mutableListOf<String>()
        for (line in lines.drop(1)) {
            val (kind, seq, ts, data, literal) = line.split(" ")
            val lit = unhex(literal)
            val blob = lit.copyOfRange(36, lit.size)
            assertArrayEquals(mac(wk, loc, blob), lit.copyOfRange(20, 36))
            val o = BeamioVoiceChannelV2.openChunk(key, loc, blob)
            assertEquals(kind.toInt(), o.kind)
            assertEquals(seq.toLong().toInt(), o.seq)
            assertEquals(ts.toLong(), o.captureMs)
            assertArrayEquals(unhex(data), o.data)
            opened++
            val sealed = BeamioVoiceChannelV2.sealChunk(key, BeamioVoiceChannelV2.Peer(loc, wk), kind.toInt(), seq.toLong().toInt(), ts.toLong(), 0, unhex(data))
            mine.add("{\"literal\":\"${hex(sealed)}\"}")
        }
        assertTrue(opened > 0)
        File(dir, "out-kotlin.json").writeText("{\"opened\":$opened,\"cases\":[${mine.joinToString(",")}]}")
    }
}

class BeamioVoiceChannelV2PgpTest {
    /** BouncyCastle binary literal must decrypt byte-exact in the SI (openpgp.js). Needs `BEAMIO_V2_VECTORS/node.pub`. */
    @Test
    fun binaryLiteralForSi() {
        val dir = System.getenv("BEAMIO_V2_VECTORS") ?: return
        val pub = File(dir, "node.pub").readText()
        val lit = "CVC2".toByteArray() + ByteArray(16) { 1 } + ByteArray(16) { 2 } + ByteArray(3000) { (it % 256).toByte() }
        File(dir, "bc-chunk.asc").writeText(BeamioNativeRoutePgp.encryptBinaryToRoute(pub, lit))
        File(dir, "bc-chunk.hex").writeText(lit.joinToString("") { "%02x".format(it) })
    }
}
