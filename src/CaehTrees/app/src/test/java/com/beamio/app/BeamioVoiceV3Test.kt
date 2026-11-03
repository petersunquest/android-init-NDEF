package com.beamio.app

import org.junit.Assert.assertEquals
import org.junit.Test

/** The signed texts must match CoNET-SI `voicePayText` / `voiceListenText` byte for byte. */
class BeamioVoiceV3Test {
    @Test
    fun payTextMatchesNode() {
        assertEquals(
            "conet.voice.sse.pay.v3\ntemp=0xabcdef0000000000000000000000000000000001\nnotAfter=1767225600\nmaxBytes=0\nmaxSeconds=0",
            BeamioVoiceV3.payText("0xABCDEF0000000000000000000000000000000001", 1767225600L),
        )
    }

    @Test
    fun listenTextMatchesNode() {
        assertEquals(
            "conet.voice.sse.listen.v3|0123456789abcdef0123456789abcdef|d2s=|B3DE611572F7912E|1767225600",
            BeamioVoiceV3.listenText("0123456789abcdef0123456789abcdef", "d2s=", "b3de611572f7912e", 1767225600L),
        )
    }
}
