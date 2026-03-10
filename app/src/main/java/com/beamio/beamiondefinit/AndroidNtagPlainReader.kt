package app.beamio.nfc

import android.nfc.tech.IsoDep

class AndroidNtagPlainReader(
    private val isoDep: IsoDep
) {
    @Throws(Exception::class)
    private fun transceive(apdu: ByteArray): ByteArray {
        return isoDep.transceive(apdu)
    }

    @Throws(Exception::class)
    private fun splitStatus(resp: ByteArray): Pair<ByteArray, Int> {
        require(resp.size >= 2) { "Bad response length" }
        val sw1 = resp[resp.size - 2].toInt() and 0xFF
        val sw2 = resp[resp.size - 1].toInt() and 0xFF
        val sw = (sw1 shl 8) or sw2
        return resp.copyOfRange(0, resp.size - 2) to sw
    }

    @Throws(Exception::class)
    private fun selectApplicationIfSupported() {
        val apdus = listOf(
            byteArrayOf(0x90.toByte(), 0x5A.toByte(), 0x00, 0x00, 0x03, 0xDF.toByte(), 0x03.toByte(), 0x00, 0x00),
            byteArrayOf(0x00, 0xA4.toByte(), 0x04, 0x00, 0x03, 0xDF.toByte(), 0x03.toByte(), 0x00, 0x00),
            byteArrayOf(0x00, 0xA4.toByte(), 0x04, 0x00, 0x07, 0xD2.toByte(), 0x76, 0x00, 0x00, 0x85.toByte(), 0x01, 0x01, 0x00)
        )
        var lastSw = 0
        for (apdu in apdus) {
            val (_, sw) = splitStatus(transceive(apdu))
            when (sw) {
                0x9100, 0x9000 -> return
                0x911c, 0x6A82 -> {
                    lastSw = sw
                    continue
                }
                else -> throw IllegalArgumentException("SelectApplication failed: 0x${sw.toString(16)}")
            }
        }
        throw IllegalArgumentException("SelectApplication failed (last: 0x${lastSw.toString(16)})")
    }

    @Throws(Exception::class)
    private fun selectNdefApplicationStrict() {
        val apdus = listOf(
            byteArrayOf(0x90.toByte(), 0x5A.toByte(), 0x00, 0x00, 0x03, 0xDF.toByte(), 0x03.toByte(), 0x00, 0x00),
            byteArrayOf(0x00, 0xA4.toByte(), 0x04, 0x00, 0x03, 0xDF.toByte(), 0x03.toByte(), 0x00, 0x00)
        )
        var lastSw = 0
        for (apdu in apdus) {
            val (_, sw) = splitStatus(transceive(apdu))
            when (sw) {
                0x9100, 0x9000 -> return
                0x911c, 0x6A82 -> {
                    lastSw = sw
                    continue
                }
                else -> throw IllegalArgumentException("Strict SelectApplication failed: 0x${sw.toString(16)}")
            }
        }
        throw IllegalArgumentException("Strict SelectApplication failed (last: 0x${lastSw.toString(16)})")
    }

    @Throws(Exception::class)
    private fun sendPlain(cmd: Int, data: ByteArray = byteArrayOf()): ByteArray {
        val apdus = if (data.isEmpty()) {
            listOf(
                byteArrayOf(0x90.toByte(), cmd.toByte(), 0x00, 0x00, 0x00)
            )
        } else {
            listOf(
                ByteArray(5 + data.size + 1).also {
                    it[0] = 0x90.toByte()
                    it[1] = cmd.toByte()
                    it[2] = 0x00
                    it[3] = 0x00
                    it[4] = data.size.toByte()
                    System.arraycopy(data, 0, it, 5, data.size)
                    it[it.size - 1] = 0x00
                },
                ByteArray(5 + data.size).also {
                    it[0] = 0x90.toByte()
                    it[1] = cmd.toByte()
                    it[2] = 0x00
                    it[3] = 0x00
                    it[4] = data.size.toByte()
                    System.arraycopy(data, 0, it, 5, data.size)
                }
            )
        }

        var lastSw = 0
        for ((index, apdu) in apdus.withIndex()) {
            val resp = transceive(apdu)
            val (body, sw) = splitStatus(resp)
            if (sw == 0x9100) return body
            lastSw = sw
            val shouldRetryWithoutLe = sw == 0x917E && data.isNotEmpty() && index == 0
            if (!shouldRetryWithoutLe) {
                require(sw == 0x9100) { "Unexpected status 0x${sw.toString(16)} for cmd 0x${cmd.toString(16)}" }
            }
        }
        error("Unexpected status 0x${lastSw.toString(16)} for cmd 0x${cmd.toString(16)}")
    }

    @Throws(Exception::class)
    fun getFileIds(): IntArray {
        val body = try {
            sendPlain(0x6F)
        } catch (e: IllegalArgumentException) {
            if (e.message?.contains("0x911c", ignoreCase = true) != true) throw e
            selectNdefApplicationStrict()
            sendPlain(0x6F)
        }
        return body.map { it.toInt() and 0xFF }.toIntArray()
    }

    @Throws(Exception::class)
    fun getFileSettingsPlain(fileNo: Int): ByteArray {
        return try {
            sendPlain(0xF5, byteArrayOf(fileNo.toByte()))
        } catch (e: IllegalArgumentException) {
            if (e.message?.contains("0x911c", ignoreCase = true) != true) throw e
            selectNdefApplicationStrict()
            sendPlain(0xF5, byteArrayOf(fileNo.toByte()))
        }
    }

    @Throws(Exception::class)
    fun readDataPlain(fileNo: Int, offset: Int, length: Int): ByteArray {
        fun le3(v: Int) = byteArrayOf(
            (v and 0xFF).toByte(),
            ((v shr 8) and 0xFF).toByte(),
            ((v shr 16) and 0xFF).toByte()
        )

        val data = byteArrayOf(fileNo.toByte()) + le3(offset) + le3(length)
        return try {
            sendPlain(0xBD, data)
        } catch (e: IllegalArgumentException) {
            if (e.message?.contains("0x911c", ignoreCase = true) != true) throw e
            selectNdefApplicationStrict()
            sendPlain(0xBD, data)
        }
    }

    @Throws(Exception::class)
    fun autoDetectNdefFileNo(): Int {
        val fileIds = getFileIds()

        for (fileNo in fileIds) {
            runCatching {
                val head = readDataPlain(fileNo, 0, 32)
                if (head.size >= 4) {
                    val nlen = ((head[0].toInt() and 0xFF) shl 8) or (head[1].toInt() and 0xFF)
                    val hdr = head[2].toInt() and 0xFF

                    val looksLikeNdef = hdr == 0xD1 || hdr == 0xD2 || hdr == 0x91 || hdr == 0x51
                    if (looksLikeNdef && nlen in 0..8192) {
                        return fileNo
                    }
                }
            }
        }

        error("Cannot auto-detect NDEF fileNo")
    }

    fun tryParseUriFromNdefFile(fileBytes: ByteArray): String? {
        if (fileBytes.size < 8) return null

        val recordStart = 2
        val header = fileBytes[recordStart].toInt() and 0xFF
        val sr = (header and 0x10) != 0
        if (sr) {
            val typeLen = fileBytes[recordStart + 1].toInt() and 0xFF
            val payloadLen = fileBytes[recordStart + 2].toInt() and 0xFF
            if (typeLen == 1) {
                val type = fileBytes[recordStart + 3].toInt().toChar()
                if (type == 'U') {
                    val payloadStart = recordStart + 4
                    if (payloadStart + payloadLen <= fileBytes.size) {
                        val payload = fileBytes.copyOfRange(payloadStart, payloadStart + payloadLen)
                        if (payload.isNotEmpty()) {
                            val prefixCode = payload[0].toInt() and 0xFF
                            val suffix = payload.copyOfRange(1, payload.size).toString(Charsets.UTF_8)

                            val prefix = when (prefixCode) {
                                0x00 -> ""
                                0x01 -> "http://www."
                                0x02 -> "https://www."
                                0x03 -> "http://"
                                0x04 -> "https://"
                                else -> ""
                            }

                            return prefix + suffix
                        }
                    }
                }
            }
        }

        val uriRemainderNeedle = "beamio.app/api/sun".toByteArray(Charsets.UTF_8)
        for (i in 0..(fileBytes.size - uriRemainderNeedle.size)) {
            var match = true
            for (j in uriRemainderNeedle.indices) {
                if (fileBytes[i + j] != uriRemainderNeedle[j]) {
                    match = false
                    break
                }
            }
            if (!match) continue
            var end = i
            while (end < fileBytes.size && fileBytes[end] != 0.toByte()) end += 1
            val remainder = String(fileBytes.copyOfRange(i, end), Charsets.UTF_8).trim()
            if (remainder.isNotBlank()) {
                return "https://$remainder"
            }
        }

        return null
    }
}