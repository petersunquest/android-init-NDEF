package app.beamio.nfc

import android.nfc.tech.IsoDep
import java.io.IOException

private fun ByteArray.toHex(): String = joinToString("") { "%02X".format(it) }

class AndroidNtag424Ev2(
    private val isoDep: IsoDep
) {
    data class Ev2Session(
        val ti: ByteArray,
        val sesAuthEncKey: ByteArray,
        val sesAuthMacKey: ByteArray,
        var cmdCtr: Int = 0
    )

    private var session: Ev2Session? = null

    @Throws(IOException::class)
    private fun transceive(apdu: ByteArray): ByteArray {
        return isoDep.transceive(apdu)
    }

    /** Strips SW1 SW2 (e.g. 91 AF / 91 00) from response. Decrypt only the data, not status bytes. */
    @Throws(Exception::class)
    private fun splitStatus(resp: ByteArray): Pair<ByteArray, Int> {
        require(resp.size >= 2) { "Bad response length" }
        val sw1 = resp[resp.size - 2].toInt() and 0xFF
        val sw2 = resp[resp.size - 1].toInt() and 0xFF
        val sw = (sw1 shl 8) or sw2
        val data = resp.copyOfRange(0, resp.size - 2)
        return data to sw
    }

    /**
     * GetVersion (0x60) at PICC level. Returns PICC version block (7 bytes).
     * Byte 6 = production type: 0x04 = NTAG 424 DNA / NTAG 424 DNA TagTamper.
     */
    @Throws(Exception::class)
    private fun getVersion(): ByteArray {
        // Try 5-byte format first (90 60 00 00 00). 6-byte (90 60 00 00 00 00) can cause 0x917E.
        val formats = listOf(
            byteArrayOf(0x90.toByte(), 0x60.toByte(), 0x00, 0x00, 0x00),
            byteArrayOf(0x90.toByte(), 0x60.toByte(), 0x00, 0x00, 0x07)
        )
        var lastSw = 0
        for (apdu in formats) {
            val (body, sw) = splitStatus(transceive(apdu))
            if (sw == 0x9100) return body
            lastSw = sw
        }
        throw IllegalArgumentException("GetVersion failed: 0x${lastSw.toString(16)} (0x917e = length error)")
    }

    /**
     * Verify the card is NTAG 424 DNA (or TagTamper). Throws if not.
     * When GetVersion returns 0x917E (length error) on some readers, skips verification and proceeds.
     */
    @Throws(Exception::class)
    fun requireNtag424Dna() {
        val version = try {
            getVersion()
        } catch (e: IllegalArgumentException) {
            if (e.message?.contains("917e", ignoreCase = true) == true) {
                // GetVersion 0x917E on some Android readers; skip chip check, rely on SelectApplication+Auth
                return
            }
            throw e
        }
        require(version.size >= 7) {
            "Card identification failed: GetVersion returned ${version.size} bytes (expected >= 7)"
        }
        val productionType = version[6].toInt() and 0xFF
        require(productionType == 0x04) {
            "Not an NTAG 424 DNA card. Production type 0x${productionType.toString(16)} (expected 0x04). " +
                "This app only supports NTAG 424 DNA / NTAG 424 DNA TagTamper."
        }
    }

    /**
     * SelectApplication. Must be called before AuthenticateEV2First when supported.
     * NTAG 424 DNA: try AID 0xDF0300 (NDEF app). Some variants return 0x911c (cmd not supported).
     */
    @Throws(Exception::class)
    fun selectApplication(aid: ByteArray = byteArrayOf(0xDF.toByte(), 0x03.toByte(), 0x00)) {
        require(aid.size == 3) { "AID must be 3 bytes" }
        val apdu = byteArrayOf(
            0x90.toByte(), 0x5A.toByte(), 0x00, 0x00, 0x03,
            aid[0], aid[1], aid[2], 0x00
        )
        val (_, sw) = splitStatus(transceive(apdu))
        require(sw == 0x9100) {
            "SelectApplication failed: 0x${sw.toString(16)}. Use AID 0xDF0300 for NTAG 424 DNA NDEF."
        }
    }

    /**
     * Select application before auth. Try native 0x5A first; if 0x911c, try ISO 7816-4 SELECT (00 A4).
     * Auth fails with 0x9140 if app not selected.
     */
    @Throws(Exception::class)
    fun selectApplicationIfSupported() {
        val apdus = listOf(
            // Native DESFire SelectApplication (0x5A) with AID 0xDF0300
            byteArrayOf(0x90.toByte(), 0x5A.toByte(), 0x00, 0x00, 0x03, 0xDF.toByte(), 0x03.toByte(), 0x00, 0x00),
            // ISO 7816-4 SELECT by AID (00 A4 04 00)
            byteArrayOf(0x00, 0xA4.toByte(), 0x04, 0x00, 0x03, 0xDF.toByte(), 0x03.toByte(), 0x00, 0x00),
            // NFC Forum NDEF application AID (7 bytes)
            byteArrayOf(0x00, 0xA4.toByte(), 0x04, 0x00, 0x07, 0xD2.toByte(), 0x76, 0x00, 0x00, 0x85.toByte(), 0x01, 0x01, 0x00)
        )
        var lastSw = 0
        for (apdu in apdus) {
            val (_, sw) = splitStatus(transceive(apdu))
            when (sw) {
                0x9100, 0x9000 -> return  // success
                0x911c, 0x6A82 -> { lastSw = sw; continue }  // try next
                else -> throw IllegalArgumentException("SelectApplication failed: 0x${sw.toString(16)}")
            }
        }
        throw IllegalArgumentException("SelectApplication failed (last: 0x${lastSw.toString(16)}). Auth requires app selection.")
    }

    /**
     * Strictly select the NTAG native NDEF application (AID DF0300).
     * Do not fall back to the NFC Forum ISO AID here, because native 0xBD/0xF5/0x5F commands
     * must stay in the native app context.
     */
    @Throws(Exception::class)
    fun selectNdefApplicationStrict() {
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
            val (body, sw) = splitStatus(transceive(apdu))
            if (sw == 0x9100 || sw == 0x91AF) {
                return body + byteArrayOf(((sw shr 8) and 0xFF).toByte(), (sw and 0xFF).toByte())
            }
            lastSw = sw
            val shouldRetryWithoutLe = sw == 0x917E && data.isNotEmpty() && index == 0
            if (!shouldRetryWithoutLe) {
                require(sw == 0x9100 || sw == 0x91AF) { "Unexpected status: ${sw.toString(16)}" }
            }
        }
        error("Unexpected status: ${lastSw.toString(16)}")
    }

    /**
     * AuthenticateEV2First. Ported from android-NDEF Ntag424Ev2.
     */
    @Throws(Exception::class)
    fun authenticateEv2First(keyNo: Int, key: ByteArray) {
        require(key.size == 16) { "key must be 16 bytes" }

        val apdu1 = byteArrayOf(
            0x90.toByte(), 0x71.toByte(), 0x00, 0x00, 0x02,
            keyNo.toByte(), 0x00, 0x00
        )
        val resp1 = transceive(apdu1)
        val (data1, sw1) = splitStatus(resp1)
        require(sw1 == 0x91AF) {
            val hint = if (sw1 == 0x9140) " (no such key: call SelectApplication before auth)" else ""
            "Auth step1 failed: 0x${sw1.toString(16)}$hint"
        }
        require(data1.size == 16) { "Auth step1 bad length" }

        // Step1 decrypt: IV = 0 (first block from card, EV2 spec)
        val zeroIv = ByteArray(16)
        val rndB = Crypto.aesCbcDecrypt(data1, key, zeroIv)
        val rndA = Crypto.randomBytes(16)
        val rndBRot = rotl1(rndB)
        val ab = rndA + rndBRot

        require(ab.copyOfRange(0, 16).contentEquals(rndA)) {
            "ab head != rndA\nrndA=${rndA.toHex()}\nabHead=${ab.copyOfRange(0, 16).toHex()}"
        }

        val encAB = Crypto.aesCbcEncrypt(ab, key, zeroIv)

        val apdu2 = byteArrayOf(0x90.toByte(), 0xAF.toByte(), 0x00, 0x00, 0x20) + encAB + byteArrayOf(0x00)

        val resp2 = transceive(apdu2)
        val (data2, sw2) = splitStatus(resp2)
        require(sw2 == 0x9100) { "Auth step2 failed: 0x${sw2.toString(16)}" }

        // Step2: IV = 0 per NTAG 424 DNA. Plain = TI(4) || RndA'(16) || PDcap2(6) || PCDcap2(6).
        require(data2.size == 32) {
            "step2 enc len=${data2.size}, data2=${data2.toHex()}"
        }
        val plain2 = Crypto.aesCbcDecrypt(data2, key, zeroIv)
        require(plain2.size == 32) {
            "step2 plain len=${plain2.size}, plain2=${plain2.toHex()}"
        }
        val ti = plain2.copyOfRange(0, 4)
        val rndARot = plain2.copyOfRange(4, 20)
        val pdCap2 = plain2.copyOfRange(20, 26)
        val pcdCap2 = plain2.copyOfRange(26, 32)
        val recoveredRndA = rotr1(rndARot)

        val expectedRndARot = rotl1(rndA)
        if (!recoveredRndA.contentEquals(rndA)) {
            throw IllegalArgumentException(
                "Auth rndA mismatch" +
                    "\nrndA(gen)=${rndA.toHex()}" +
                    "\nab(before enc)=${ab.toHex()}" +
                    "\nrndA(after enc)=${rndA.toHex()}" +
                    "\nexpectedRndARot=${expectedRndARot.toHex()}" +
                    "\ncardRndARot=${rndARot.toHex()}" +
                    "\nkeyNo=${"%02X".format(keyNo)}" +
                    "\nkey=${key.toHex()}" +
                    "\nrecoveredRndA=${recoveredRndA.toHex()}" +
                    "\nstep1enc=${data1.toHex()}" +
                    "\nstep2enc=${data2.toHex()}" +
                    "\nstep2plain=${plain2.toHex()}"
            )
        }

        val (sv1, sv2) = buildSessionVectorsEV2(rndA, rndB)
        val sesEnc = Crypto.aesCmac(sv1, key)
        val sesMac = Crypto.aesCmac(sv2, key)

        session = Ev2Session(ti = ti, sesAuthEncKey = sesEnc, sesAuthMacKey = sesMac, cmdCtr = 0)
    }

    private fun rotl1(d: ByteArray): ByteArray {
        if (d.isEmpty()) return d
        return d.copyOfRange(1, d.size) + byteArrayOf(d[0])
    }

    private fun rotr1(d: ByteArray): ByteArray {
        if (d.isEmpty()) return d
        return byteArrayOf(d[d.size - 1]) + d.copyOfRange(0, d.size - 1)
    }

    /** NXP SV1/SV2: MSB first. RndA[15:14]=rndA[0..2], RndA[13:8]=rndA[2..8], RndB[15:10]=rndB[0..6], RndB[9:0]=rndB[6..16], RndA[7:0]=rndA[8..16]. */
    private fun buildSessionVectorsEV2(rndA: ByteArray, rndB: ByteArray): Pair<ByteArray, ByteArray> {
        require(rndA.size == 16 && rndB.size == 16)
        val a1514 = rndA.copyOfRange(0, 2)
        val a138 = rndA.copyOfRange(2, 8)
        val b1510 = rndB.copyOfRange(0, 6)
        val b90 = rndB.copyOfRange(6, 16)
        val a70 = rndA.copyOfRange(8, 16)
        val x = ByteArray(6) { i -> (a138[i].toInt() xor b1510[i].toInt()).toByte() }
        val context = a1514 + x + b90 + a70
        val sv1 = byteArrayOf(0xA5.toByte(), 0x5A.toByte(), 0x00, 0x01, 0x00, 0x80.toByte()) + context
        val sv2 = byteArrayOf(0x5A.toByte(), 0xA5.toByte(), 0x00, 0x01, 0x00, 0x80.toByte()) + context
        return sv1 to sv2
    }

    @Throws(Exception::class)
    fun changeKey(
        authenticatedKeyNo: Int,
        changingKeyNo: Int,
        oldKey: ByteArray? = null,
        newKey: ByteArray,
        newKeyVersion: Int
    ) {
        require(newKey.size == 16) { "newKey must be 16 bytes" }
        val s = session ?: throw IllegalStateException("No EV2 session")

        val cmdCtr = s.cmdCtr

        val cmdHeader = byteArrayOf(changingKeyNo.toByte())
        val plainCmdData = if (authenticatedKeyNo == changingKeyNo) {
            var plain = newKey + byteArrayOf(newKeyVersion.toByte(), 0x80.toByte())
            while (plain.size % 16 != 0) plain += byteArrayOf(0x00)
            plain
        } else {
            val prevKey = oldKey ?: throw IllegalArgumentException("oldKey required when changing a different key")
            require(prevKey.size == 16) { "oldKey must be 16 bytes" }

            val xoredKey = ByteArray(16) { i ->
                (newKey[i].toInt() xor prevKey[i].toInt()).toByte()
            }
            val crc = ntag424Crc32(newKey)
            var plain = xoredKey + byteArrayOf(newKeyVersion.toByte()) + crc + byteArrayOf(0x80.toByte())
            while (plain.size % 16 != 0) plain += byteArrayOf(0x00)
            plain
        }

        val ivInputBytes = byteArrayOf(0xA5.toByte(), 0x5A) + s.ti + byteArrayOf(
            (cmdCtr and 0xFF).toByte(),
            ((cmdCtr ushr 8) and 0xFF).toByte()
        ) + ByteArray(8)
        val ivc = Crypto.aesEcbEncrypt(ivInputBytes, s.sesAuthEncKey)
        val encCmdData = Crypto.aesCbcEncrypt(plainCmdData, s.sesAuthEncKey, ivc)

        val cmdCtrLE = byteArrayOf((cmdCtr and 0xFF).toByte(), ((cmdCtr ushr 8) and 0xFF).toByte())
        val macInput = byteArrayOf(0xC4.toByte()) + cmdCtrLE + s.ti + cmdHeader + encCmdData
        val fullMac = Crypto.aesCmac(macInput, s.sesAuthMacKey)
        val truncMac = truncateMac16To8(fullMac)

        val lc = (1 + encCmdData.size + truncMac.size).toByte()
        val apdu = byteArrayOf(0x90.toByte(), 0xC4.toByte(), 0x00, 0x00, lc) + cmdHeader + encCmdData + truncMac + byteArrayOf(0x00)

        val resp = transceive(apdu)

        val (_, sw) = splitStatus(resp)
        if (sw != 0x9100) {
            session = null
            throw IllegalArgumentException(
                "ChangeKey failed: 0x${"%04X".format(sw)}" +
                    "\nSesAuthENCKey=${s.sesAuthEncKey.toHex()}" +
                    "\nSesAuthMACKey=${s.sesAuthMacKey.toHex()}" +
                    "\nfullMac=${fullMac.toHex()}" +
                    "\nivInput=${ivInputBytes.toHex()}" +
                    "\nCmdCtr(before)=$cmdCtr" +
                    "\nTI=${s.ti.toHex()}" +
                    "\ncmdHeader=${cmdHeader.toHex()}" +
                    "\nplainCmdData=${plainCmdData.toHex()}" +
                    "\nIVc=${ivc.toHex()}" +
                    "\nencCmdData=${encCmdData.toHex()}" +
                    "\nmacInput=${macInput.toHex()}" +
                    "\ntruncMac=${truncMac.toHex()}" +
                    "\nisoApdu=${apdu.toHex()}"
            )
        }
        s.cmdCtr = cmdCtr + 1
    }

    /** MAC truncation: use indices 1,3,5,7,9,11,13,15. */
    private fun truncateMac16To8(full: ByteArray): ByteArray {
        require(full.size == 16) { "full MAC must be 16 bytes" }
        return byteArrayOf(
            full[1], full[3], full[5], full[7],
            full[9], full[11], full[13], full[15]
        )
    }

    private fun ivInput(label: ByteArray, ti: ByteArray, cmdCtr: Int): ByteArray {
        return label + ti + byteArrayOf((cmdCtr and 0xFF).toByte(), ((cmdCtr ushr 8) and 0xFF).toByte()) + ByteArray(8)
    }

    /** NTAG 424 CRC32 = IEEE 802.3 polynomial, little-endian, without final complement. */
    private fun ntag424Crc32(data: ByteArray): ByteArray {
        var crc = 0xFFFFFFFF.toInt()
        for (b in data) {
            crc = crc xor (b.toInt() and 0xFF)
            repeat(8) {
                crc = if ((crc and 1) != 0) {
                    (crc ushr 1) xor 0xEDB88320.toInt()
                } else {
                    crc ushr 1
                }
            }
        }
        return byteArrayOf(
            (crc and 0xFF).toByte(),
            ((crc ushr 8) and 0xFF).toByte(),
            ((crc ushr 16) and 0xFF).toByte(),
            ((crc ushr 24) and 0xFF).toByte()
        )
    }

    @Throws(Exception::class)
    fun changeFileSettings(fileNo: Int, fileSettings: ByteArray) {
        val s = session ?: throw IllegalStateException("No EV2 session")

        var plain = fileSettings + byteArrayOf(0x80.toByte())
        while (plain.size % 16 != 0) plain += byteArrayOf(0x00)
        sendSecureCommand(s, 0x5F, byteArrayOf(fileNo.toByte()), plain)
    }

    private fun sendSecureCommand(s: Ev2Session, cmd: Int, header: ByteArray, cmdDataPlain: ByteArray): ByteArray {
        val cmdCtr = s.cmdCtr
        val ivInputBytes = ivInput(byteArrayOf(0xA5.toByte(), 0x5A), s.ti, cmdCtr)
        val ivc = Crypto.aesEcbEncrypt(ivInputBytes, s.sesAuthEncKey)
        val encCmdData = Crypto.aesCbcEncrypt(cmdDataPlain, s.sesAuthEncKey, ivc)
        val cmdCtrLE = byteArrayOf((cmdCtr and 0xFF).toByte(), ((cmdCtr ushr 8) and 0xFF).toByte())
        val macInput = byteArrayOf(cmd.toByte()) + cmdCtrLE + s.ti + header + encCmdData
        val fullMac = Crypto.aesCmac(macInput, s.sesAuthMacKey)
        val macT = truncateMac16To8(fullMac)
        val lc = (header.size + encCmdData.size + macT.size).toByte()
        val apdu = byteArrayOf(0x90.toByte(), cmd.toByte(), 0x00, 0x00, lc) + header + encCmdData + macT + byteArrayOf(0x00)
        val (data, sw) = splitStatus(transceive(apdu))
        if (sw != 0x9100) {
            session = null
            throw IllegalArgumentException(
                "Secure cmd 0x${cmd.toString(16)} failed: 0x${"%04X".format(sw)}" +
                    "\nCmdCtr(before)=$cmdCtr" +
                    "\nTI=${s.ti.toHex()}" +
                    "\nheader=${header.toHex()}" +
                    "\nplain=${cmdDataPlain.toHex()}" +
                    "\nIVc=${ivc.toHex()}" +
                    "\nencCmdData=${encCmdData.toHex()}" +
                    "\nmacInput=${macInput.toHex()}" +
                    "\ntruncMac=${macT.toHex()}" +
                    "\nisoApdu=${apdu.toHex()}"
            )
        }
        s.cmdCtr = cmdCtr + 1
        return data
    }

    @Throws(Exception::class)
    fun getFileIds(): IntArray {
        return try {
            val resp = sendPlain(0x6F)
            val (data, sw) = splitStatus(resp)
            require(sw == 0x9100) { "GetFileIDs failed" }
            data.map { it.toInt() and 0xFF }.toIntArray()
        } catch (e: IllegalArgumentException) {
            if (e.message?.contains("911c", ignoreCase = true) != true) throw e
            selectNdefApplicationStrict()
            val resp = sendPlain(0x6F)
            val (data, sw) = splitStatus(resp)
            require(sw == 0x9100) { "GetFileIDs failed" }
            data.map { it.toInt() and 0xFF }.toIntArray()
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
            val resp = sendPlain(0xBD, data)
            val (body, sw) = splitStatus(resp)
            require(sw == 0x9100) { "ReadData failed" }
            body
        } catch (e: IllegalArgumentException) {
            if (e.message?.contains("911c", ignoreCase = true) != true) throw e
            selectNdefApplicationStrict()
            val resp = sendPlain(0xBD, data)
            val (body, sw) = splitStatus(resp)
            require(sw == 0x9100) { "ReadData failed" }
            body
        }
    }

    @Throws(Exception::class)
    fun getFileSettingsPlain(fileNo: Int): ByteArray {
        return try {
            val resp = sendPlain(0xF5, byteArrayOf(fileNo.toByte()))
            val (body, sw) = splitStatus(resp)
            require(sw == 0x9100) { "GetFileSettings failed" }
            body
        } catch (e: IllegalArgumentException) {
            if (e.message?.contains("911c", ignoreCase = true) != true) throw e
            selectNdefApplicationStrict()
            val resp = sendPlain(0xF5, byteArrayOf(fileNo.toByte()))
            val (body, sw) = splitStatus(resp)
            require(sw == 0x9100) { "GetFileSettings failed" }
            body
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

    /**
     * Write NDEF URI template via secure WriteData (0x8D).
     */
    @Throws(Exception::class)
    fun writeNdefUriTemplate(fileNo: Int, url: String) {
        writeNdefFileBytes(fileNo, buildUriNdefFile(url))
    }

    /**
     * Write full NDEF file bytes via secure WriteData (0x8D).
     */
    @Throws(Exception::class)
    fun writeNdefFileBytes(fileNo: Int, ndef: ByteArray) {
        writeDataBytes(fileNo = fileNo, offset = 0, data = ndef)
    }

    @Throws(Exception::class)
    fun writeNdefFileBytesChunked(fileNo: Int, ndef: ByteArray, chunkSize: Int = 16) {
        require(chunkSize > 0 && chunkSize % 16 == 0) { "chunkSize must be a positive multiple of 16" }
        var padded = ndef.copyOf()
        while (padded.size % 16 != 0) padded += byteArrayOf(0x00)
        var offset = 0
        while (offset < padded.size) {
            val end = minOf(offset + chunkSize, padded.size)
            val chunk = padded.copyOfRange(offset, end)
            writeDataBytes(fileNo = fileNo, offset = offset, data = chunk)
            offset = end
        }
    }

    /**
     * Write arbitrary bytes into a StandardData file via secure WriteData (0x8D).
     */
    @Throws(Exception::class)
    fun writeDataBytes(fileNo: Int, offset: Int, data: ByteArray) {
        val s = session ?: throw IllegalStateException("No EV2 session")

        var plain = data.copyOf()
        while (plain.size % 16 != 0) plain += byteArrayOf(0x00)

        val writeLength = plain.size
        val header = byteArrayOf(fileNo.toByte()) +
            byteArrayOf(
                (offset and 0xFF).toByte(),
                ((offset shr 8) and 0xFF).toByte(),
                ((offset shr 16) and 0xFF).toByte()
            ) +
            byteArrayOf(
                (writeLength and 0xFF).toByte(),
                ((writeLength shr 8) and 0xFF).toByte(),
                ((writeLength shr 16) and 0xFF).toByte()
            )

        sendSecureCommand(s, 0x8D, header, plain)
    }

    fun buildBeamioPreparedNdefFile(url: String, encryptedFilePlaintext: ByteArray): ByteArray {
        require(encryptedFilePlaintext.isNotEmpty()) { "encryptedFilePlaintext must not be empty" }
        val ndef = buildUriNdefFile(url)
        val offsets = computeBeamioSdmOffsets(url)
        require(offsets.encOffset + encryptedFilePlaintext.size <= ndef.size) {
            "Encrypted file plaintext does not fit in NDEF file"
        }
        val out = ndef.copyOf()
        System.arraycopy(encryptedFilePlaintext, 0, out, offsets.encOffset, encryptedFilePlaintext.size)
        return out
    }

    /**
     * 自动从 live NDEF 里找 e/c/m offsets，并 patch raw GetFileSettings
     */
    @Throws(Exception::class)
    fun patchSdmFileSettingsFromLiveNdef(
        fileNo: Int,
        expectedEncHexLen: Int
    ): ByteArray {
        val fileBytes = readDataPlain(fileNo, 0, 300)
        val rawSettings = getFileSettingsPlain(fileNo)

        val offsets = computeOffsetsFromNdefFileBytes(
            fileBytes = fileBytes,
            expectedEncHexLen = expectedEncHexLen
        )

        return patchFileSettingsRaw(rawSettings, offsets)
    }

    data class SdmOffsets(
        val uidOffset: Int,
        val ctrOffset: Int,
        val macInputOffset: Int,
        val encOffset: Int,
        val encLen: Int,
        val macOffset: Int
    )

    private fun le3(v: Int) = byteArrayOf(
        (v and 0xFF).toByte(),
        ((v shr 8) and 0xFF).toByte(),
        ((v shr 16) and 0xFF).toByte()
    )

    private fun computeOffsetsFromNdefFileBytes(
        fileBytes: ByteArray,
        expectedEncHexLen: Int
    ): SdmOffsets {
        require(fileBytes.size >= 8) { "NDEF file too short" }

        val recordStart = 2
        val header = fileBytes[recordStart].toInt() and 0xFF
        val sr = (header and 0x10) != 0
        require(sr) { "Only short-record URI NDEF is supported in this helper" }

        val typeLen = fileBytes[recordStart + 1].toInt() and 0xFF
        val payloadLen = fileBytes[recordStart + 2].toInt() and 0xFF
        require(typeLen == 1) { "Unexpected typeLen" }

        val type = fileBytes[recordStart + 3].toInt().toChar()
        require(type == 'U') { "First record is not URI" }

        val payloadStart = recordStart + 4
        val payload = fileBytes.copyOfRange(payloadStart, payloadStart + payloadLen)

        require(payload.isNotEmpty()) { "URI payload empty" }

        val uriBytes = payload.copyOfRange(1, payload.size) // skip prefix byte
        val uidStart = findValueStart(uriBytes, "uid")
        val cStart = findValueStart(uriBytes, "c")
        val eStart = findValueStart(uriBytes, "e")
        val mStart = findValueStart(uriBytes, "m")

        require(uidStart >= 0 && cStart >= 0 && eStart >= 0 && mStart >= 0) {
            "Cannot locate uid/c/e/m markers"
        }

        return SdmOffsets(
            uidOffset = payloadStart + 1 + uidStart,
            ctrOffset = payloadStart + 1 + cStart,
            macInputOffset = payloadStart + 1 + uidStart,
            encOffset = payloadStart + 1 + eStart,
            encLen = expectedEncHexLen,
            macOffset = payloadStart + 1 + mStart
        )
    }

    private fun findValueStart(uriBytes: ByteArray, key: String): Int {
        val needle = "$key=".toByteArray()
        for (i in 0..(uriBytes.size - needle.size)) {
            var ok = true
            for (j in needle.indices) {
                if (uriBytes[i + j] != needle[j]) {
                    ok = false
                    break
                }
            }
            if (ok) return i + needle.size
        }
        return -1
    }

    private fun patchFileSettingsRaw(raw: ByteArray, offsets: SdmOffsets): ByteArray {
        require(raw.size >= 7) { "Unexpected FileSettings layout" }

        val preservedCommMode = raw[1].toInt() and 0x03
        val fileOption = preservedCommMode or 0x40
        val perm2 = raw[2]
        val perm1 = raw[3]
        val sdmOptions = 0x51
        val sdmRights2 = 0xFF
        val sdmRights1 = 0xE2

        return byteArrayOf(
            fileOption.toByte(),
            perm2,
            perm1,
            sdmOptions.toByte(),
            sdmRights2.toByte(),
            sdmRights1.toByte()
        ) +
            le3(offsets.ctrOffset) +
            le3(offsets.macInputOffset) +
            le3(offsets.encOffset) +
            le3(offsets.encLen) +
            le3(offsets.macOffset)
    }

    private fun putLe3(buf: ByteArray, idx: Int, v: Int) {
        buf[idx] = (v and 0xFF).toByte()
        buf[idx + 1] = ((v shr 8) and 0xFF).toByte()
        buf[idx + 2] = ((v shr 16) and 0xFF).toByte()
    }

    fun computeBeamioSdmOffsets(url: String): SdmOffsets {
        val fileBytes = buildUriNdefFile(url)
        return computeOffsetsFromNdefFileBytes(
            fileBytes = fileBytes,
            expectedEncHexLen = 64
        )
    }

    fun buildBeamioCompactSdmSettings(
        url: String,
        changeKeyNo: Int = 0x00,
        readWriteKeyNo: Int = 0x00,
        readKeyNo: Int = 0x0E,
        writeKeyNo: Int = 0x00,
        ctrRetKeyNo: Int = 0x0F,
        metaReadKeyNo: Int = 0x0E,
        fileReadKeyNo: Int = 0x02
    ): ByteArray {
        val offsets = computeBeamioSdmOffsets(url)
        val fileOption = 0x40
        val accessRights = byteArrayOf(
            (((readWriteKeyNo and 0x0F) shl 4) or (changeKeyNo and 0x0F)).toByte(),
            (((readKeyNo and 0x0F) shl 4) or (writeKeyNo and 0x0F)).toByte()
        )
        val sdmOptions = byteArrayOf(0x51)
        val sdmAccessRights = byteArrayOf(
            (((0x0F and 0x0F) shl 4) or (ctrRetKeyNo and 0x0F)).toByte(),
            (((metaReadKeyNo and 0x0F) shl 4) or (fileReadKeyNo and 0x0F)).toByte()
        )
        return byteArrayOf(fileOption.toByte()) +
            accessRights +
            sdmOptions +
            sdmAccessRights +
            le3(offsets.ctrOffset) +
            le3(offsets.macInputOffset) +
            le3(offsets.encOffset) +
            le3(offsets.encLen) +
            le3(offsets.macOffset)
    }

    fun buildBeamioExtendedSdmSettings(
        url: String,
        changeKeyNo: Int = 0x00,
        readWriteKeyNo: Int = 0x00,
        readKeyNo: Int = 0x0E,
        writeKeyNo: Int = 0x00,
        ctrRetKeyNo: Int = 0x0F,
        metaReadKeyNo: Int = 0x0E,
        fileReadKeyNo: Int = 0x02
    ): ByteArray {
        val offsets = computeBeamioSdmOffsets(url)
        val fileOption = 0x40
        val accessRights = byteArrayOf(
            (((readWriteKeyNo and 0x0F) shl 4) or (changeKeyNo and 0x0F)).toByte(),
            (((readKeyNo and 0x0F) shl 4) or (writeKeyNo and 0x0F)).toByte()
        )
        val sdmOptions = byteArrayOf(0xD1.toByte())
        val sdmAccessRights = byteArrayOf(
            (((0x0F and 0x0F) shl 4) or (ctrRetKeyNo and 0x0F)).toByte(),
            (((metaReadKeyNo and 0x0F) shl 4) or (fileReadKeyNo and 0x0F)).toByte()
        )
        return byteArrayOf(fileOption.toByte()) +
            accessRights +
            sdmOptions +
            sdmAccessRights +
            le3(offsets.uidOffset) +
            le3(offsets.ctrOffset) +
            le3(offsets.macInputOffset) +
            le3(offsets.encOffset) +
            le3(offsets.encLen) +
            le3(offsets.macOffset)
    }

    /**
     * 构造 URI NDEF file bytes:
     * [NLEN(2 bytes BE)] + [D1 01 payloadLen 'U' 0x04 <uri-bytes-without-https://>]
     */
    fun buildUriNdefFile(url: String): ByteArray {
        val normalized = require(url.startsWith("https://")) { "Only https:// is supported here" }
        val uriRemainder = url.removePrefix("https://").toByteArray(Charsets.UTF_8)

        val payload = byteArrayOf(0x04) + uriRemainder
        val record = byteArrayOf(
            0xD1.toByte(), // MB ME SR TNF=1
            0x01,          // type length
            payload.size.toByte(),
            'U'.code.toByte()
        ) + payload

        val nlen = record.size
        return byteArrayOf(
            ((nlen shr 8) and 0xFF).toByte(),
            (nlen and 0xFF).toByte()
        ) + record
    }
}