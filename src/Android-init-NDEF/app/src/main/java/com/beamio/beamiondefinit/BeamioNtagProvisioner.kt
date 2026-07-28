package app.beamio.nfc

import android.nfc.Tag
import android.nfc.TagLostException
import android.nfc.tech.IsoDep
import java.io.IOException
import java.security.SecureRandom
import java.nio.charset.StandardCharsets

class BeamioNtagProvisioner(
    private val sunBaseUrl: String,
    private val globalKey0: ByteArray,
    private val globalKey2: ByteArray
) {
    private enum class CardRoute {
        FRESH,
        REWRITTEN
    }

    private data class NdefProbeResult(
        val fileNo: Int,
        val fileSize: Int?,
        val looksLikeNdef: Boolean,
        val source: String,
        val settingsHex: String?,
        val headHex: String?,
        val probeError: String?
    ) {
        fun canFit(requiredSize: Int): Boolean = fileSize == null || fileSize >= requiredSize
        fun hasUsableMetadata(): Boolean = fileSize != null || settingsHex != null || headHex != null
    }

    private data class IsoNdefProbeResult(
        val ccFileId: Int?,
        val ndefFileId: Int?,
        val maxSize: Int?,
        val nlen: Int?,
        val url: String?,
        val error: String?
    )

    private data class SdmEncLayout(
        val encOffset: Int,
        val encLength: Int,
        val writeKeyNo: Int
    )

    companion object {
        private val rng = SecureRandom()

        fun random16(): ByteArray = ByteArray(16).also { rng.nextBytes(it) }
        fun random8(): ByteArray = ByteArray(8).also { rng.nextBytes(it) }

        fun toHex(data: ByteArray): String =
            buildString(data.size * 2) {
                data.forEach { append("%02X".format(it)) }
            }

        fun ByteArray.toHexString(): String = toHex(this)

        fun fromHex(hex: String): ByteArray {
            val s = hex.trim()
            require(s.length % 2 == 0) { "hex length must be even" }
            return ByteArray(s.length / 2) { i ->
                s.substring(i * 2, i * 2 + 2).toInt(16).toByte()
            }
        }

        fun buildSunTemplateUrl(base: String, uidHex: String): String {
            val uid = uidHex.uppercase()
            require(uid.length == 14) { "uidHex must be 14 hex chars" }
            val e = "0".repeat(64)
            val c = "0".repeat(6)
            val m = "0".repeat(16)

            val sep = if (base.contains("?")) {
                if (base.endsWith("?") || base.endsWith("&")) "" else "&"
            } else {
                "?"
            }

            return "$base${sep}uid=$uid&c=$c&e=$e&m=$m"
        }

        fun buildSunTemplateUrlLegacyCompatible(base: String, uidHex: String): String {
            val uid = uidHex.uppercase()
            require(uid.length == 14) { "uidHex must be 14 hex chars" }
            val e = "0".repeat(64)
            val c = "0".repeat(6)
            val m = "0".repeat(16)

            val sep = if (base.contains("?")) {
                if (base.endsWith("?") || base.endsWith("&")) "" else "&"
            } else {
                "?"
            }

            return "$base${sep}e=$e&c=$c&m=$m&uid=$uid"
        }

        /**
         * 32-byte plain layout:
         * UID 7
         * CTR 3
         * TAGID 8
         * VER 1
         * PAD 13
         */
        fun buildEncPayload(
            uid7: ByteArray,
            ctr3: ByteArray,
            tagId8: ByteArray,
            ver: Byte = 0x01
        ): ByteArray {
            require(uid7.size == 7) { "uid must be 7 bytes" }
            require(ctr3.size == 3) { "ctr must be 3 bytes" }
            require(tagId8.size == 8) { "tagId must be 8 bytes" }

            val out = ByteArray(32)
            System.arraycopy(uid7, 0, out, 0, 7)
            System.arraycopy(ctr3, 0, out, 7, 3)
            System.arraycopy(tagId8, 0, out, 10, 8)
            out[18] = ver
            // 19..31 keep zero
            return out
        }

        fun buildTagIdOnlyPayload(
            tagId8: ByteArray,
            ver: Byte = 0x01
        ): ByteArray {
            require(tagId8.size == 8) { "tagId must be 8 bytes" }
            val out = ByteArray(32)
            System.arraycopy(tagId8, 0, out, 0, 8)
            out[8] = ver
            return out
        }
    }

    data class ProvisionResult(
        val uidHex: String,
        val tagIdHex: String,
        val key0Hex: String,
        val key2Hex: String,
        val ndefFileNo: Int,
        val templateUrl: String,
        val route: String,
        val readbackUrl: String? = null,
        val sdmStatus: String? = null
    )

    data class ReadbackResult(
        val uidHex: String,
        val ndefUrl: String?,
        val eHex: String?,
        val cHex: String?,
        val mHex: String?,
        val notes: List<String>
    )

    private fun parseStandardFileSize(rawSettings: ByteArray): Int? {
        if (rawSettings.size < 7) return null
        return (rawSettings[4].toInt() and 0xFF) or
            ((rawSettings[5].toInt() and 0xFF) shl 8) or
            ((rawSettings[6].toInt() and 0xFF) shl 16)
    }

    private fun parseLe3(raw: ByteArray, offset: Int): Int? {
        if (offset + 2 >= raw.size) return null
        return (raw[offset].toInt() and 0xFF) or
            ((raw[offset + 1].toInt() and 0xFF) shl 8) or
            ((raw[offset + 2].toInt() and 0xFF) shl 16)
    }

    private fun parseSdmEncLayout(settingsHex: String?): SdmEncLayout? {
        if (settingsHex.isNullOrBlank()) return null
        val raw = runCatching { fromHex(settingsHex) }.getOrNull() ?: return null
        if (raw.size < 10) return null
        val fileOption = raw[1].toInt() and 0xFF
        if ((fileOption and 0x40) == 0) return null
        val perm1 = raw[3].toInt() and 0xFF
        val writeKeyNo = perm1 and 0x0F
        val sdmOptions = raw[7].toInt() and 0xFF
        val base = 10 + if ((sdmOptions and 0x80) != 0) 3 else 0
        val encOffset = parseLe3(raw, base + 6) ?: return null
        val encLength = parseLe3(raw, base + 9) ?: return null
        return SdmEncLayout(
            encOffset = encOffset,
            encLength = encLength,
            writeKeyNo = writeKeyNo
        )
    }

    private fun buildChangeFileSettingsPayloadFromGetSettings(settingsHex: String?): ByteArray? {
        if (settingsHex.isNullOrBlank()) return null
        val raw = runCatching { fromHex(settingsHex) }.getOrNull() ?: return null
        if (raw.size < 10) return null
        val out = ArrayList<Byte>(raw.size - 4)
        out += raw[1]
        out += raw[2]
        out += raw[3]
        for (i in 7 until raw.size) out += raw[i]
        return out.toByteArray()
    }

    private fun looksLikeNdefFileHead(head: ByteArray): Boolean {
        if (head.size < 4) return false
        val nlen = ((head[0].toInt() and 0xFF) shl 8) or (head[1].toInt() and 0xFF)
        val hdr = head[2].toInt() and 0xFF
        return nlen in 0..8192 && hdr in setOf(0xD1, 0xD2, 0x91, 0x51)
    }

    private fun probeNdefFile(ev2: AndroidNtag424Ev2, fileNo: Int, source: String): NdefProbeResult {
        return try {
            val settingsResult = runCatching { ev2.getFileSettingsPlain(fileNo) }
            val settings = settingsResult.getOrNull()
            val fileSize = settings?.let(::parseStandardFileSize)
            val readLen = when {
                fileSize == null -> 32
                fileSize <= 0 -> 0
                else -> minOf(fileSize, 32)
            }
            val headResult = if (readLen > 0) {
                runCatching { ev2.readDataPlain(fileNo, 0, readLen) }
            } else {
                runCatching { null }
            }
            val head = headResult.getOrNull()
            val errors = listOfNotNull(
                settingsResult.exceptionOrNull()?.message?.let { "getFileSettings=$it" },
                headResult.exceptionOrNull()?.message?.let { "readHead=$it" }
            ).joinToString("; ").ifEmpty { null }
            NdefProbeResult(
                fileNo = fileNo,
                fileSize = fileSize,
                looksLikeNdef = head?.let(::looksLikeNdefFileHead) == true,
                source = source,
                settingsHex = settings?.let(::toHex),
                headHex = head?.let(::toHex),
                probeError = errors
            )
        } catch (e: Exception) {
            NdefProbeResult(
                fileNo = fileNo,
                fileSize = null,
                looksLikeNdef = false,
                source = source,
                settingsHex = null,
                headHex = null,
                probeError = e.message ?: e.toString()
            )
        }
    }

    private fun splitSw(resp: ByteArray): Pair<ByteArray, Int> {
        require(resp.size >= 2) { "Bad response length" }
        val sw1 = resp[resp.size - 2].toInt() and 0xFF
        val sw2 = resp[resp.size - 1].toInt() and 0xFF
        return resp.copyOfRange(0, resp.size - 2) to ((sw1 shl 8) or sw2)
    }

    private fun transceiveIso(isoDep: IsoDep, apdu: ByteArray): ByteArray {
        val (body, sw) = splitSw(isoDep.transceive(apdu))
        require(sw == 0x9000) { "ISO cmd failed: 0x${"%04X".format(sw)} apdu=${toHex(apdu)}" }
        return body
    }

    private fun selectIsoAid(isoDep: IsoDep, aid: ByteArray) {
        val apdu = byteArrayOf(0x00, 0xA4.toByte(), 0x04, 0x00, aid.size.toByte()) + aid + byteArrayOf(0x00)
        transceiveIso(isoDep, apdu)
    }

    private fun selectIsoFile(isoDep: IsoDep, fileId: Int) {
        val apdu = byteArrayOf(
            0x00, 0xA4.toByte(), 0x00, 0x0C,
            0x02,
            ((fileId shr 8) and 0xFF).toByte(),
            (fileId and 0xFF).toByte(),
            0x00
        )
        transceiveIso(isoDep, apdu)
    }

    private fun readBinary(isoDep: IsoDep, offset: Int, length: Int): ByteArray {
        val apdu = byteArrayOf(
            0x00, 0xB0.toByte(),
            ((offset shr 8) and 0xFF).toByte(),
            (offset and 0xFF).toByte(),
            length.toByte()
        )
        return transceiveIso(isoDep, apdu)
    }

    private fun updateBinary(isoDep: IsoDep, offset: Int, data: ByteArray) {
        require(data.size <= 255) { "UPDATE BINARY payload too large: ${data.size}" }
        val apdu = byteArrayOf(
            0x00, 0xD6.toByte(),
            ((offset shr 8) and 0xFF).toByte(),
            (offset and 0xFF).toByte(),
            data.size.toByte()
        ) + data
        transceiveIso(isoDep, apdu)
    }

    private fun tryParseUriFromNdefFile(fileBytes: ByteArray): String? {
        if (fileBytes.size < 8) return null
        val recordStart = 2
        val header = fileBytes[recordStart].toInt() and 0xFF
        if ((header and 0x10) != 0) {
            val typeLen = fileBytes[recordStart + 1].toInt() and 0xFF
            val payloadLen = fileBytes[recordStart + 2].toInt() and 0xFF
            if (typeLen == 1 && fileBytes[recordStart + 3].toInt().toChar() == 'U') {
                val payloadStart = recordStart + 4
                if (payloadStart + payloadLen <= fileBytes.size) {
                    val payload = fileBytes.copyOfRange(payloadStart, payloadStart + payloadLen)
                    if (payload.isNotEmpty()) {
                        val prefix = when (payload[0].toInt() and 0xFF) {
                            0x00 -> ""
                            0x01 -> "http://www."
                            0x02 -> "https://www."
                            0x03 -> "http://"
                            0x04 -> "https://"
                            else -> ""
                        }
                        return prefix + String(payload.copyOfRange(1, payload.size), StandardCharsets.UTF_8)
                    }
                }
            }
        }

        // Some rewritten cards expose a broken NLEN during ISO read. Fall back to scanning
        // the raw payload bytes for the URI remainder and restore the https:// prefix.
        val uriRemainderNeedle = "beamio.app/api/sun".toByteArray(StandardCharsets.UTF_8)
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
            val remainder = String(fileBytes.copyOfRange(i, end), StandardCharsets.UTF_8).trim()
            if (remainder.isNotBlank()) {
                return "https://$remainder"
            }
        }
        return null
    }

    private fun extractQueryParam(url: String, key: String): String? {
        val marker = "$key="
        val idx = url.indexOf(marker)
        if (idx < 0) return null
        val start = idx + marker.length
        val end = url.indexOf('&', start).let { if (it < 0) url.length else it }
        return url.substring(start, end)
    }

    private fun hasDynamicSunPayload(url: String?): Boolean {
        if (url.isNullOrBlank()) return false
        val e = extractQueryParam(url, "e")
        val c = extractQueryParam(url, "c")
        val m = extractQueryParam(url, "m")
        val uid = extractQueryParam(url, "uid")
        if (e.isNullOrBlank() || c.isNullOrBlank() || m.isNullOrBlank() || uid.isNullOrBlank()) return false
        return e.any { it != '0' } && c.any { it != '0' } && m.any { it != '0' }
    }

    private fun hasExpectedSunBase(url: String?, expectedBase: String): Boolean {
        if (url.isNullOrBlank()) return false
        return url.substringBefore('?') == expectedBase.substringBefore('?')
    }

    private fun isPlaceholderTagId(tagIdHex: String?): Boolean {
        if (tagIdHex.isNullOrBlank()) return true
        val normalized = tagIdHex.uppercase()
        return normalized == "0000000000000000" || normalized == "3030303030303030"
    }

    private fun hasMeaningfulDynamicPayload(url: String?): Boolean {
        if (!hasDynamicSunPayload(url)) return false
        val decoded = runCatching {
            BeamioLocalSunDecoder.decodeFromUrl(url = url!!, globalKey2Hex = toHex(globalKey2))
        }.getOrNull() ?: return false
        return !isPlaceholderTagId(decoded.tagIdHex)
    }

    private fun isTagLostError(message: String?): Boolean =
        message?.contains("Tag was lost", ignoreCase = true) == true

    private fun probeIsoNdef(isoDep: IsoDep): IsoNdefProbeResult {
        return runCatching {
            selectIsoAid(isoDep, byteArrayOf(0xD2.toByte(), 0x76, 0x00, 0x00, 0x85.toByte(), 0x01, 0x01))
            selectIsoFile(isoDep, 0xE103)
            val cc = readBinary(isoDep, 0, 15)
            require(cc.size >= 15) { "CC file too short: ${cc.size}" }
            require((cc[7].toInt() and 0xFF) == 0x04 && (cc[8].toInt() and 0xFF) == 0x06) {
                "Unexpected CC layout: ${toHex(cc)}"
            }
            val ndefFileId = ((cc[9].toInt() and 0xFF) shl 8) or (cc[10].toInt() and 0xFF)
            val maxSize = ((cc[11].toInt() and 0xFF) shl 8) or (cc[12].toInt() and 0xFF)

            selectIsoFile(isoDep, ndefFileId)
            val nlenBytes = readBinary(isoDep, 0, 2)
            val nlen = ((nlenBytes[0].toInt() and 0xFF) shl 8) or (nlenBytes[1].toInt() and 0xFF)
            val totalToRead = minOf(maxSize, nlen + 2)
            val fileBytes = if (totalToRead >= 2) readBinary(isoDep, 0, totalToRead) else nlenBytes
            IsoNdefProbeResult(
                ccFileId = 0xE103,
                ndefFileId = ndefFileId,
                maxSize = maxSize,
                nlen = nlen,
                url = tryParseUriFromNdefFile(fileBytes),
                error = null
            )
        }.getOrElse {
            IsoNdefProbeResult(
                ccFileId = null,
                ndefFileId = null,
                maxSize = null,
                nlen = null,
                url = null,
                error = it.message ?: it.toString()
            )
        }
    }

    private fun rewriteIsoNdefFile(isoDep: IsoDep, ndefFileId: Int, fileBytes: ByteArray) {
        require(fileBytes.size >= 2) { "NDEF file bytes too short" }
        val nlen = fileBytes.copyOfRange(0, 2)
        val body = fileBytes.copyOfRange(2, fileBytes.size)
        selectIsoAid(isoDep, byteArrayOf(0xD2.toByte(), 0x76, 0x00, 0x00, 0x85.toByte(), 0x01, 0x01))
        selectIsoFile(isoDep, ndefFileId)
        updateBinary(isoDep, 0, byteArrayOf(0x00, 0x00))
        if (body.isNotEmpty()) {
            updateBinary(isoDep, 2, body)
        }
        updateBinary(isoDep, 0, nlen)
    }

    private fun isLikelyTagLostError(t: Throwable): Boolean {
        if (t is TagLostException) return true
        val msg = t.message.orEmpty()
        if (msg.contains("Tag was lost", ignoreCase = true)) return true
        if (msg.contains("TagLost", ignoreCase = true)) return true
        if (msg.contains("Connection lost", ignoreCase = true)) return true
        val c = t.cause
        return c != null && isLikelyTagLostError(c)
    }

    /**
     * ISO UPDATE BINARY after a long EV2 session can hit transient "Tag was lost" on some phones.
     * Retry a few times with backoff before failing.
     */
    private fun rewriteIsoNdefFileWithRetries(
        isoDep: IsoDep,
        ndefFileId: Int,
        fileBytes: ByteArray,
        maxAttempts: Int = 3
    ) {
        var last: Throwable? = null
        repeat(maxAttempts) { attempt ->
            val result = runCatching {
                if (!isoDep.isConnected) {
                    isoDep.connect()
                }
                rewriteIsoNdefFile(isoDep, ndefFileId, fileBytes)
            }
            if (result.isSuccess) return
            val err = result.exceptionOrNull()
            last = err
            if (err != null && !isLikelyTagLostError(err)) {
                throw err
            }
            if (attempt < maxAttempts - 1) {
                try {
                    Thread.sleep(120L * (attempt + 1))
                } catch (_: InterruptedException) {
                    Thread.currentThread().interrupt()
                }
            }
        }
        throw last ?: IllegalStateException("ISO NDEF rewrite failed after retries")
    }

    /**
     * Try native secure NDEF replace before switching the tag to ISO UPDATE BINARY (avoids app-context
     * churn and often survives when ISO path loses the RF field).
     */
    private fun tryRewrittenNativeNdefReplace(
        ev2: AndroidNtag424Ev2,
        ndefFileNo: Int,
        preparedNdefBytes: ByteArray,
        labelPrefix: String,
        authKey0: (String) -> Unit,
        authKey2: (String) -> Unit,
    ): Throwable? {
        return runCatching {
            runCatching { ev2.selectNdefApplicationStrict() }
            authKey2("${labelPrefix}_k2_c32")
            ev2.writeNdefFileBytesChunked(fileNo = ndefFileNo, ndef = preparedNdefBytes, chunkSize = 32)
        }.recoverCatching {
            runCatching { ev2.selectApplicationIfSupported() }
            authKey0("${labelPrefix}_k0_c32")
            ev2.writeNdefFileBytesChunked(fileNo = ndefFileNo, ndef = preparedNdefBytes, chunkSize = 32)
        }.recoverCatching {
            runCatching { ev2.selectNdefApplicationStrict() }
            authKey2("${labelPrefix}_k2_full")
            ev2.writeNdefFileBytes(fileNo = ndefFileNo, ndef = preparedNdefBytes)
        }.recoverCatching {
            runCatching { ev2.selectApplicationIfSupported() }
            authKey0("${labelPrefix}_k0_full")
            ev2.writeNdefFileBytes(fileNo = ndefFileNo, ndef = preparedNdefBytes)
        }.exceptionOrNull()
    }

    @Throws(Exception::class)
    fun verifyReadback(tag: Tag): ReadbackResult {
        val uidHex = tag.id?.let(::toHex) ?: ""
        val isoDep = IsoDep.get(tag) ?: error("IsoDep not supported")
        isoDep.connect()
        isoDep.timeout = 5000
        var isoDepClosed = false
        return try {
            val probe = probeIsoNdef(isoDep)
            val fallbackRead = if (probe.url == null) {
                try {
                    isoDep.close()
                    isoDepClosed = true
                } catch (_: IOException) {
                }
                runCatching { BeamioNtagReader().readCard(tag) }.getOrNull()
            } else {
                null
            }
            val url = probe.url ?: fallbackRead?.storedNdefUrl ?: fallbackRead?.ndefUrl
            val resolvedUidHex = uidHex.ifBlank {
                url?.let { extractQueryParam(it, "uid") }?.uppercase() ?: ""
            }
            ReadbackResult(
                uidHex = resolvedUidHex,
                ndefUrl = url,
                eHex = url?.let { extractQueryParam(it, "e") },
                cHex = url?.let { extractQueryParam(it, "c") },
                mHex = url?.let { extractQueryParam(it, "m") },
                notes = listOf(
                    "ISO probe maxSize=${probe.maxSize}",
                    "ISO probe nlen=${probe.nlen}",
                    "ISO probe ndefFileId=${probe.ndefFileId}",
                    "ISO probe error=${probe.error}"
                ) + (fallbackRead?.notes?.map { "fallback=$it" } ?: emptyList())
            )
        } finally {
            if (!isoDepClosed) {
                try {
                    isoDep.close()
                } catch (_: IOException) {
                }
            }
        }
    }

    /**
     * Map ISO 7816-4 NDEF file id (from CC) to native DESFire FileNo.
     * NFC Forum T4T NDEF file id 0xE104 is the standard NDEF EF on NTAG 424 DNA and maps to
     * native Standard Data File 0x02 — not to low-byte 0x04 (E104 & 0xFF).
     */
    private fun inferNativeFileNoFromIsoFileId(isoFileId: Int?): Int? {
        if (isoFileId == null) return null
        val fid = isoFileId and 0xFFFF
        if (fid == 0xE104) return 0x02
        val low = isoFileId and 0xFF
        return if (low in 0x00..0x1F) low else null
    }

    /**
     * 主流程：
     * 1) 连接 IsoDep
     * 2) 读 UID
     * 3) EV2First(defaultKey0)
     * 4) ChangeKey(0x00 -> globalKey0)
     * 5) EV2First(globalKey0)
     * 6) ChangeKey(0x02 -> globalKey2)
     * 7) 自动找 NDEF fileNo
     * 8) 根据模板 URL 自动 patch SDM offsets
     * 9) ChangeFileSettings
     * 10) 写 NDEF URL 模板
     */
    @Throws(Exception::class)
    fun provision(tag: Tag, defaultKey0: ByteArray): ProvisionResult {
        val isoDep = IsoDep.get(tag) ?: error("IsoDep not supported")
        isoDep.connect()
        isoDep.timeout = 12000

        var route: CardRoute? = null
        var authKeyLabel = "uninitialized"
        var key2OldKeyLabel = "not_attempted"
        val preferredNdefFileNo = 0x02
        var ndefDecision = "not_checked"
        var ndefProbeSummary = "not_checked"
        var detectedProbeAttempt = "not_attempted"
        var sdmStatus = "not_checked"
        var key2RewriteStatus = "not_checked"
        var rewrittenSelectedProbe: NdefProbeResult? = null
            var rewrittenTagLostFastPath = false

        try {
            val uid = tag.id ?: error("UID not found")
            require(uid.size == 7) { "Expected 7-byte UID, got ${uid.size}" }
            val uidHex = toHex(uid)

            val tagId = random8()
            val tagIdHex = toHex(tagId)

            lateinit var ev2: AndroidNtag424Ev2

            fun authWithCandidate(label: String, key: ByteArray) {
                try {
                    ev2.authenticateEv2First(keyNo = 0x00, key = key)
                    authKeyLabel = label
                } catch (e: IllegalArgumentException) {
                    if (e.message?.contains("9140", ignoreCase = true) == true) {
                        ev2.selectApplicationIfSupported()
                        ev2.authenticateEv2First(keyNo = 0x00, key = key)
                        authKeyLabel = "$label+select"
                    } else {
                        throw e
                    }
                }
            }

            fun authWithKey(label: String, keyNo: Int, key: ByteArray) {
                try {
                    ev2.authenticateEv2First(keyNo = keyNo, key = key)
                    authKeyLabel = label
                } catch (e: IllegalArgumentException) {
                    if (e.message?.contains("9140", ignoreCase = true) == true) {
                        ev2.selectApplicationIfSupported()
                        ev2.authenticateEv2First(keyNo = keyNo, key = key)
                        authKeyLabel = "$label+select"
                    } else {
                        throw e
                    }
                }
            }

            // Blank cards / first tap: RF can drop before route is chosen; TagLostException is not
            // IllegalArgumentException. Reconnect + fresh AndroidNtag424Ev2 session and retry.
            repeat(5) { attempt ->
                val step = runCatching {
                    if (!isoDep.isConnected) isoDep.connect()
                    ev2 = AndroidNtag424Ev2(isoDep)
                    ev2.requireNtag424Dna()
                    try {
                        authWithCandidate("globalKey0", globalKey0)
                        route = CardRoute.REWRITTEN
                    } catch (e: IllegalArgumentException) {
                        val shouldFallback = e.message?.contains("91ae", ignoreCase = true) == true &&
                            !globalKey0.contentEquals(defaultKey0)
                        if (!shouldFallback) throw e
                        authWithCandidate("defaultKey0", defaultKey0)
                        route = CardRoute.FRESH
                    }
                }
                if (step.isSuccess) return@repeat
                val err = step.exceptionOrNull()!!
                if (!isLikelyTagLostError(err) || attempt == 4) throw err
                try {
                    Thread.sleep(120L * (attempt + 1))
                } catch (_: InterruptedException) {
                    Thread.currentThread().interrupt()
                }
                try {
                    isoDep.close()
                } catch (_: IOException) {
                }
                try {
                    isoDep.connect()
                } catch (_: IOException) {
                }
            }

            val resolvedRoute = route ?: error("Card route not determined")

            when (resolvedRoute) {
                CardRoute.FRESH -> {
            ev2.changeKey(
                authenticatedKeyNo = 0x00,
                changingKeyNo = 0x00,
                        oldKey = null,
                newKey = globalKey0,
                newKeyVersion = 0x01
            )
                    authWithCandidate("globalKey0_after_write", globalKey0)

                    key2OldKeyLabel = "default_zero"
                    ev2.changeKey(
                        authenticatedKeyNo = 0x00,
                        changingKeyNo = 0x02,
                        oldKey = ByteArray(16),
                        newKey = globalKey2,
                        newKeyVersion = 0x01
                    )
                }
                CardRoute.REWRITTEN -> {
                    key2RewriteStatus = runCatching {
                        key2OldKeyLabel = "globalKey2"
                        ev2.changeKey(
                            authenticatedKeyNo = 0x00,
                            changingKeyNo = 0x02,
                            oldKey = globalKey2,
                            newKey = globalKey2,
                            newKeyVersion = 0x01
                        )
                        "same_key_refresh_ok_globalKey2"
                    }.recoverCatching { first ->
                        val shouldRetryWithDefault = first.message?.contains("911e", ignoreCase = true) == true ||
                            first.message?.contains("917e", ignoreCase = true) == true ||
                            first.message?.contains("91ae", ignoreCase = true) == true
                        if (!shouldRetryWithDefault) {
                            throw first
                        }
                        key2OldKeyLabel = "default_zero_fallback"
                        ev2.selectApplicationIfSupported()
                        authWithCandidate("globalKey0_after_key2_retry", globalKey0)
            ev2.changeKey(
                authenticatedKeyNo = 0x00,
                changingKeyNo = 0x02,
                            oldKey = ByteArray(16),
                newKey = globalKey2,
                newKeyVersion = 0x01
                        )
                        "same_key_refresh_ok_default_zero_fallback"
                    }.getOrElse {
                        "non_fatal_skip:${it.message ?: it}"
                    }
                }
            }

            var templateUrl = buildSunTemplateUrl(sunBaseUrl, uidHex)
            val encPayload = buildTagIdOnlyPayload(
                tagId8 = tagId
            )
            val preparedNdefBytes = ev2.buildBeamioPreparedNdefFile(
                url = templateUrl,
                encryptedFilePlaintext = encPayload
            )

            val isoProbe = if (resolvedRoute == CardRoute.REWRITTEN) probeIsoNdef(isoDep) else null
            val rewrittenDynamicTemplatePresent =
                resolvedRoute == CardRoute.REWRITTEN &&
                    hasExpectedSunBase(isoProbe?.url, sunBaseUrl) &&
                    hasDynamicSunPayload(isoProbe?.url)
            val rewrittenDynamicAlreadyActive =
                rewrittenDynamicTemplatePresent &&
                    hasMeaningfulDynamicPayload(isoProbe?.url)

            val ndefFileNo = if (resolvedRoute == CardRoute.REWRITTEN) {
                val nativeFileNoFromIso = inferNativeFileNoFromIsoFileId(isoProbe?.ndefFileId)
                ndefDecision = "rewritten_native_probe_pending"
                if (isoProbe?.maxSize != null && preparedNdefBytes.size > isoProbe.maxSize) {
                    throw IllegalArgumentException(
                        "Rewritten card NDEF capacity too small" +
                            "\nrequiredNdefSize=${preparedNdefBytes.size}" +
                            "\nisoMaxSize=${isoProbe.maxSize}" +
                            "\nisoNlen=${isoProbe.nlen}" +
                            "\nisoNdefFileId=${isoProbe.ndefFileId}" +
                            "\nisoUrl=${isoProbe.url}" +
                            "\nisoProbeError=${isoProbe.error}"
                    )
                }
                // For rewritten cards, an extra re-auth right after the ISO probe often causes
                // TagLost on some phones. Delay re-auth until we actually need secure commands.
                val selectedProbe: NdefProbeResult?
                val rewrittenNativeFileNo: Int
                if (isTagLostError(isoProbe?.error)) {
                    rewrittenTagLostFastPath = true
                    selectedProbe = null
                    rewrittenNativeFileNo = nativeFileNoFromIso ?: preferredNdefFileNo
                    ndefProbeSummary =
                        "rewritten_native_candidates=skipped_due_to_tag_lost" +
                            " iso[maxSize=${isoProbe?.maxSize},nlen=${isoProbe?.nlen},ndefFileId=${isoProbe?.ndefFileId},nativeFileNoHint=${nativeFileNoFromIso},url=${isoProbe?.url},error=${isoProbe?.error}]"
                    ndefDecision = "rewritten_native_fileNo=0x${"%02X".format(rewrittenNativeFileNo)} fast_path=tag_lost_probe"
                } else {
                    runCatching { ev2.selectNdefApplicationStrict() }
                    val rewrittenCandidates = listOf(nativeFileNoFromIso, preferredNdefFileNo)
                        .filterNotNull()
                        .distinct()
                    val rewrittenProbes = rewrittenCandidates.map { candidate ->
                        probeNdefFile(ev2, candidate, "rewritten_candidate")
                    }
                    selectedProbe = rewrittenProbes
                        .sortedWith(
                            compareByDescending<NdefProbeResult> { it.fileNo == preferredNdefFileNo }
                                .thenByDescending { it.looksLikeNdef }
                                .thenByDescending { it.hasUsableMetadata() }
                                .thenByDescending { it.fileSize ?: -1 }
                        )
                        .firstOrNull { it.canFit(preparedNdefBytes.size) && it.hasUsableMetadata() }
                        ?: rewrittenProbes.firstOrNull { it.canFit(preparedNdefBytes.size) }
                        ?: rewrittenProbes.firstOrNull()
                    rewrittenSelectedProbe = selectedProbe
                    ndefProbeSummary =
                        "rewritten_native_candidates=${
                            rewrittenProbes.joinToString(" | ") {
                                "fileNo=0x${"%02X".format(it.fileNo)} fileSize=${it.fileSize} looksLikeNdef=${it.looksLikeNdef} error=${it.probeError} settings=${it.settingsHex} head=${it.headHex}"
                            }
                        }" +
                            " iso[maxSize=${isoProbe?.maxSize},nlen=${isoProbe?.nlen},ndefFileId=${isoProbe?.ndefFileId},nativeFileNoHint=${nativeFileNoFromIso},url=${isoProbe?.url},error=${isoProbe?.error}]"
                    rewrittenNativeFileNo = selectedProbe?.fileNo ?: nativeFileNoFromIso ?: preferredNdefFileNo
                    ndefDecision = "rewritten_native_fileNo=0x${"%02X".format(rewrittenNativeFileNo)}"
                }
                rewrittenNativeFileNo
            } else {
                val preferredProbe = probeNdefFile(ev2, preferredNdefFileNo, "preferred")
                val detectedProbe: NdefProbeResult? = null
                detectedProbeAttempt = "skipped"
                val selectedProbe = when {
                    preferredProbe.looksLikeNdef && preferredProbe.canFit(preparedNdefBytes.size) -> preferredProbe
                    preferredProbe.canFit(preparedNdefBytes.size) -> preferredProbe
                    else -> throw IllegalArgumentException(
                        "NDEF target precheck failed" +
                            "\nroute=${route.name.lowercase()}" +
                            "\nrequiredNdefSize=${preparedNdefBytes.size}" +
                            "\npreferredProbe=fileNo=0x${"%02X".format(preferredProbe.fileNo)} source=${preferredProbe.source} fileSize=${preferredProbe.fileSize} looksLikeNdef=${preferredProbe.looksLikeNdef} error=${preferredProbe.probeError} settings=${preferredProbe.settingsHex} head=${preferredProbe.headHex}" +
                            "\ndetectedProbe=${detectedProbe?.let { "fileNo=0x${"%02X".format(it.fileNo)} source=${it.source} fileSize=${it.fileSize} looksLikeNdef=${it.looksLikeNdef} error=${it.probeError} settings=${it.settingsHex} head=${it.headHex}" } ?: "none"}" +
                            "\ndetectedProbeAttempt=$detectedProbeAttempt"
                    )
                }

                ndefDecision = "fileNo=0x${"%02X".format(selectedProbe.fileNo)} source=${selectedProbe.source}"
                ndefProbeSummary =
                    "preferred[fileSize=${preferredProbe.fileSize},looksLikeNdef=${preferredProbe.looksLikeNdef},error=${preferredProbe.probeError}]" +
                    " detected[none] attempt[$detectedProbeAttempt]"
                selectedProbe.fileNo
            }

            // 7) write URL template first, so offsets can be computed from live content
            if (resolvedRoute == CardRoute.REWRITTEN) {
                val selectedSdmLayout = parseSdmEncLayout(rewrittenSelectedProbe?.settingsHex)
                val currentChangeSettingsPayload =
                    buildChangeFileSettingsPayloadFromGetSettings(rewrittenSelectedProbe?.settingsHex)
                val currentNoopChangeProbe = if (currentChangeSettingsPayload != null) {
                    runCatching {
                        authWithCandidate("globalKey0_noop_change_probe", globalKey0)
                        ev2.changeFileSettings(fileNo = ndefFileNo, fileSettings = currentChangeSettingsPayload)
                        "noop_change_key0_ok"
                    }.recoverCatching {
                        authWithKey("globalKey2_noop_change_probe", keyNo = 0x02, key = globalKey2)
                        ev2.changeFileSettings(fileNo = ndefFileNo, fileSettings = currentChangeSettingsPayload)
                        "noop_change_key2_ok"
                    }.getOrElse {
                        "noop_change_failed:${it.message ?: it.javaClass.simpleName}"
                    }
                } else {
                    "noop_change_unavailable"
                }
                ndefDecision += " -> $currentNoopChangeProbe"
                if (rewrittenDynamicAlreadyActive) {
                    templateUrl = isoProbe?.url ?: templateUrl
                    ndefDecision += " -> existing_dynamic_url_preserved"
                } else if (selectedSdmLayout != null) {
                    val sameSessionRewriteFailure = runCatching {
                        ev2.writeNdefFileBytesChunked(fileNo = ndefFileNo, ndef = preparedNdefBytes)
                    }.exceptionOrNull()
                    if (sameSessionRewriteFailure == null) {
                        ndefDecision += " -> rewritten_existing_settings_chunked_write_ok"
                        sdmStatus = "rewritten_existing_settings_chunked_write_ok"
                    } else if (rewrittenDynamicTemplatePresent && isoProbe?.url != null) {
                        templateUrl = isoProbe.url
                        val encOffset = ev2.computeBeamioSdmOffsets(templateUrl).encOffset
                        runCatching { ev2.selectNdefApplicationStrict() }
                        val payloadPatchFailure = runCatching {
                            authWithKey("globalKey2_payload_patch", keyNo = 0x02, key = globalKey2)
                            ev2.writeDataBytes(
                                fileNo = ndefFileNo,
                                offset = encOffset,
                                data = encPayload
                            )
                        }.recoverCatching { first ->
                            authWithCandidate("globalKey0_payload_patch_fallback", globalKey0)
                            ev2.writeDataBytes(
                                fileNo = ndefFileNo,
                                offset = encOffset,
                                data = encPayload
                            )
                        }.exceptionOrNull()
                        if (payloadPatchFailure == null) {
                            ndefDecision += " -> rewritten_payload_patch_ok(offset=$encOffset)"
                            sdmStatus = "rewritten_dynamic_payload_patched"
                        } else {
                            ndefDecision += " -> rewritten_payload_patch_failed(${payloadPatchFailure.message ?: payloadPatchFailure.javaClass.simpleName})"
                        }
                    } else if (selectedSdmLayout.encLength >= encPayload.size) {
                        val layout = selectedSdmLayout
                        val payloadPatchFailure = runCatching {
                            runCatching { ev2.selectNdefApplicationStrict() }
                            when (layout.writeKeyNo) {
                                0x02 -> authWithKey("globalKey2_payload_patch_from_settings", keyNo = 0x02, key = globalKey2)
                                else -> authWithCandidate("globalKey0_payload_patch_from_settings", globalKey0)
                            }
                            ev2.writeDataBytes(
                                fileNo = ndefFileNo,
                                offset = layout.encOffset,
                                data = encPayload
                            )
                        }.recoverCatching {
                            authWithKey("globalKey2_payload_patch_settings_fallback", keyNo = 0x02, key = globalKey2)
                            ev2.writeDataBytes(
                                fileNo = ndefFileNo,
                                offset = layout.encOffset,
                                data = encPayload
                            )
                        }.exceptionOrNull()
                        if (payloadPatchFailure == null) {
                            ndefDecision += " -> rewritten_payload_patch_from_settings_ok(offset=${layout.encOffset},len=${layout.encLength},writeKey=${layout.writeKeyNo})"
                            sdmStatus = "rewritten_dynamic_payload_patched"
                        } else {
                            ndefDecision += " -> rewritten_payload_patch_from_settings_failed(${payloadPatchFailure.message ?: payloadPatchFailure.javaClass.simpleName})"
                            val isoRewriteFailure = if (isoProbe?.ndefFileId != null) {
                                runCatching {
                                    rewriteIsoNdefFileWithRetries(isoDep, isoProbe.ndefFileId, preparedNdefBytes)
                                }.exceptionOrNull()
                            } else {
                                null
                            }
                            if (isoProbe?.ndefFileId != null && isoRewriteFailure == null) {
                                ndefDecision += " -> rewritten_iso_rewrite_after_payload_patch_ok(fileId=0x${"%04X".format(isoProbe.ndefFileId)})"
                                sdmStatus = "rewritten_iso_rewrite_ok"
                            } else if (isoRewriteFailure != null) {
                                ndefDecision += " -> rewritten_iso_rewrite_after_payload_patch_failed(${isoRewriteFailure.message ?: isoRewriteFailure.javaClass.simpleName})"
                            }
                        }
                    } else if (isoProbe?.ndefFileId != null) {
                        val nativePreIsoErr = tryRewrittenNativeNdefReplace(
                            ev2 = ev2,
                            ndefFileNo = ndefFileNo,
                            preparedNdefBytes = preparedNdefBytes,
                            labelPrefix = "rewritten_enc_tight",
                            authKey0 = { authWithCandidate(it, globalKey0) },
                            authKey2 = { authWithKey(it, keyNo = 0x02, key = globalKey2) }
                        )
                        if (nativePreIsoErr == null) {
                            ndefDecision += " -> rewritten_native_pre_iso_enc_tight_ok"
                            sdmStatus = "rewritten_native_pre_iso_enc_tight_ok"
                        } else {
                            val isoRewriteFailure = runCatching {
                                rewriteIsoNdefFileWithRetries(isoDep, isoProbe.ndefFileId, preparedNdefBytes)
                            }.exceptionOrNull()
                            if (isoRewriteFailure == null) {
                                ndefDecision += " -> iso_update_binary_preferred(fileId=0x${"%04X".format(isoProbe.ndefFileId)})"
                                sdmStatus = "rewritten_iso_update_binary_preferred"
                            } else {
                                ndefDecision += " -> iso_update_binary_failed(${isoRewriteFailure.message ?: isoRewriteFailure.javaClass.simpleName})"
                                runCatching {
                                    runCatching { ev2.selectNdefApplicationStrict() }
                                    authWithKey("globalKey2_before_native_write_fallback", keyNo = 0x02, key = globalKey2)
                                    ev2.writeNdefFileBytes(fileNo = ndefFileNo, ndef = preparedNdefBytes)
                                }.recoverCatching {
                                    runCatching { ev2.selectApplicationIfSupported() }
                                    authWithCandidate("globalKey0_before_native_write_fallback", globalKey0)
                                    ev2.writeNdefFileBytes(fileNo = ndefFileNo, ndef = preparedNdefBytes)
                                }.onSuccess {
                                    ndefDecision += " -> native_write_fallback_ok"
                                }.onFailure { nativeFailure ->
                                    throw IllegalArgumentException(
                                        "Rewritten NDEF rewrite failed" +
                                            "\nexistingSettingsWrite=${sameSessionRewriteFailure.message ?: sameSessionRewriteFailure}" +
                                            "\nisoRewrite=${isoRewriteFailure.message ?: isoRewriteFailure}" +
                                            "\nnativeRewrite=${nativeFailure.message ?: nativeFailure}"
                                    )
                                }
                            }
                        }
                    } else {
                        ndefDecision += " -> rewritten_existing_settings_write_failed(${sameSessionRewriteFailure.message ?: sameSessionRewriteFailure.javaClass.simpleName})"
                    }
                } else if (isoProbe?.ndefFileId != null) {
                    val nativePreIsoErr = tryRewrittenNativeNdefReplace(
                        ev2 = ev2,
                        ndefFileNo = ndefFileNo,
                        preparedNdefBytes = preparedNdefBytes,
                        labelPrefix = "rewritten_no_sdm",
                        authKey0 = { authWithCandidate(it, globalKey0) },
                        authKey2 = { authWithKey(it, keyNo = 0x02, key = globalKey2) }
                    )
                    if (nativePreIsoErr == null) {
                        ndefDecision += " -> rewritten_native_no_sdm_layout_ok"
                        sdmStatus = "rewritten_native_no_sdm_layout_write_ok"
                    } else {
                        val isoRewriteFailure = runCatching {
                            rewriteIsoNdefFileWithRetries(isoDep, isoProbe.ndefFileId, preparedNdefBytes)
                        }.exceptionOrNull()
                        if (isoRewriteFailure == null) {
                            ndefDecision += " -> iso_update_binary_preferred(fileId=0x${"%04X".format(isoProbe.ndefFileId)})"
                            sdmStatus = "rewritten_iso_update_binary_preferred"
                        } else {
                            ndefDecision += " -> iso_update_binary_failed(${isoRewriteFailure.message ?: isoRewriteFailure.javaClass.simpleName})"
                            runCatching {
                                runCatching { ev2.selectNdefApplicationStrict() }
                                authWithKey("globalKey2_before_native_write_fallback", keyNo = 0x02, key = globalKey2)
                                ev2.writeNdefFileBytes(fileNo = ndefFileNo, ndef = preparedNdefBytes)
                            }.recoverCatching {
                                runCatching { ev2.selectApplicationIfSupported() }
                                authWithCandidate("globalKey0_before_native_write_fallback", globalKey0)
                                ev2.writeNdefFileBytes(fileNo = ndefFileNo, ndef = preparedNdefBytes)
                            }.onSuccess {
                                ndefDecision += " -> native_write_fallback_ok"
                            }.onFailure { nativeFailure ->
                                throw IllegalArgumentException(
                                    "Rewritten NDEF rewrite failed" +
                                        "\nisoRewrite=${isoRewriteFailure.message ?: isoRewriteFailure}" +
                                        "\nnativeRewrite=${nativeFailure.message ?: nativeFailure}"
                                )
                            }
                        }
                    }
                } else {
                    if (rewrittenTagLostFastPath) {
                        runCatching {
                            ev2.writeNdefFileBytesChunked(fileNo = ndefFileNo, ndef = preparedNdefBytes, chunkSize = 32)
                        }.onSuccess {
                            ndefDecision += " -> fast_path_chunked_write_ok"
                        }.onFailure {
                            ev2.writeNdefFileBytes(fileNo = ndefFileNo, ndef = preparedNdefBytes)
                            ndefDecision += " -> fast_path_full_write_ok"
                        }
                    } else {
                        ev2.writeNdefFileBytes(fileNo = ndefFileNo, ndef = preparedNdefBytes)
                        ndefDecision += " -> native_write_ok"
                    }
                }
            } else {
                val freshWriteStatus = runCatching {
                    ev2.writeNdefFileBytesChunked(fileNo = ndefFileNo, ndef = preparedNdefBytes, chunkSize = 32)
                    "fresh_chunked_write_32_ok"
                }.recoverCatching {
                    runCatching { ev2.selectApplicationIfSupported() }
                    authWithCandidate("globalKey0_before_fresh_chunked16_retry", globalKey0)
                    ev2.writeNdefFileBytesChunked(fileNo = ndefFileNo, ndef = preparedNdefBytes, chunkSize = 16)
                    "fresh_chunked_write_16_ok"
                }.recoverCatching {
                    val freshIsoProbe = probeIsoNdef(isoDep)
                    val ndefFileId = freshIsoProbe.ndefFileId
                        ?: throw IllegalArgumentException("fresh_iso_probe_missing_ndef_file_id")
                    rewriteIsoNdefFile(isoDep, ndefFileId, preparedNdefBytes)
                    "fresh_iso_write_ok(fileId=0x${"%04X".format(ndefFileId)})"
                }.recoverCatching {
                    runCatching { ev2.selectApplicationIfSupported() }
                    authWithCandidate("globalKey0_before_fresh_full_write_retry", globalKey0)
                    ev2.writeNdefFileBytes(fileNo = ndefFileNo, ndef = preparedNdefBytes)
                    "fresh_full_write_ok"
                }.getOrThrow()
                ndefDecision += " -> $freshWriteStatus"
            }

            if (resolvedRoute == CardRoute.FRESH) {
                // After ISO UPDATE BINARY (fresh_iso_write_ok), the tag may still be in ISO NFC Forum
                // context. Previously select was wrapped in runCatching and failures were ignored,
                // so ChangeFileSettings (0x5F) could return 0x919E on the first init; a second init
                // then took the REWRITTEN path and succeeded. Force native NDEF app selection.
                try {
                    ev2.selectNdefApplicationStrict()
                } catch (_: Exception) {
                    ev2.selectApplicationIfSupported()
                }
                authWithCandidate("globalKey0_before_fresh_settings", globalKey0)
                // 1) Offsets from live NDEF on card (ISO write can differ slightly from preparedNdefBytes).
                // 2) preserveAccessRights=false so Change is allowed with key0 after provisioning.
                // 3) If compact SDM (0x51) still returns 0x91AE, fall back to extended layout (0xD1 + uid offset).
                fun buildFreshSdmPayloadPrimary(): ByteArray {
                    return runCatching {
                        ev2.patchSdmFileSettingsFromLiveNdef(
                            fileNo = ndefFileNo,
                            expectedEncHexLen = 64,
                            preserveAccessRights = false
                        )
                    }.getOrElse {
                        runCatching {
                            val raw = ev2.getFileSettingsPlain(ndefFileNo)
                            ev2.buildBeamioSdmFileSettingsFromRawSettings(
                                raw,
                                preparedNdefBytes,
                                64,
                                preserveAccessRights = false
                            )
                        }.getOrElse {
                            ev2.buildBeamioCompactSdmSettings(templateUrl)
                        }
                    }
                }

                var patchedSettings = buildFreshSdmPayloadPrimary()

                fun isFreshCfsRetryable(e: Throwable): Boolean {
                    val msg = e.message.orEmpty()
                    return msg.contains("91AE", ignoreCase = true) || msg.contains("919E", ignoreCase = true)
                }

                runCatching {
                    ev2.changeFileSettings(fileNo = ndefFileNo, fileSettings = patchedSettings)
                }.recoverCatching { e ->
                    if (!isFreshCfsRetryable(e)) throw e
                    authWithKey("globalKey2_before_fresh_settings_retry", keyNo = 0x02, key = globalKey2)
                    ev2.changeFileSettings(fileNo = ndefFileNo, fileSettings = patchedSettings)
                }.recoverCatching { e ->
                    if (!isFreshCfsRetryable(e)) throw e
                    try {
                        ev2.selectNdefApplicationStrict()
                    } catch (_: Exception) {
                        ev2.selectApplicationIfSupported()
                    }
                    patchedSettings = ev2.buildBeamioExtendedSdmSettings(templateUrl)
                    authWithCandidate("globalKey0_before_fresh_extended_sdm", globalKey0)
                    ev2.changeFileSettings(fileNo = ndefFileNo, fileSettings = patchedSettings)
                }.recoverCatching { e ->
                    if (!isFreshCfsRetryable(e)) throw e
                    authWithKey("globalKey2_before_fresh_extended_sdm", keyNo = 0x02, key = globalKey2)
                    ev2.changeFileSettings(fileNo = ndefFileNo, fileSettings = patchedSettings)
                }.getOrThrow()
                sdmStatus = "fresh_offsets_applied"
            } else {
                if (rewrittenDynamicAlreadyActive) {
                    sdmStatus = "rewritten_existing_dynamic_sdm_preserved"
                    return ProvisionResult(
                        uidHex = uidHex,
                        tagIdHex = tagIdHex,
                        key0Hex = toHex(globalKey0),
                        key2Hex = toHex(globalKey2),
                        ndefFileNo = ndefFileNo,
                        templateUrl = templateUrl,
                        route = resolvedRoute.name.lowercase(),
                        sdmStatus = sdmStatus
                    )
                }

                if (
                    sdmStatus == "rewritten_dynamic_payload_patched" ||
                    sdmStatus == "rewritten_existing_settings_chunked_write_ok" ||
                    sdmStatus == "rewritten_iso_rewrite_ok"
                ) {
                    return ProvisionResult(
                        uidHex = uidHex,
                        tagIdHex = tagIdHex,
                        key0Hex = toHex(globalKey0),
                        key2Hex = toHex(globalKey2),
                        ndefFileNo = ndefFileNo,
                        templateUrl = templateUrl,
                        route = resolvedRoute.name.lowercase(),
                        sdmStatus = sdmStatus
                    )
                }

                val repairAttempts = mutableListOf<String>()
                var repaired = false

                runCatching {
                    runCatching { ev2.selectApplicationIfSupported() }
                    authWithCandidate("globalKey0_before_rewritten_live_patch", globalKey0)
                    val patchedSettings = ev2.patchSdmFileSettingsFromLiveNdef(
                        fileNo = ndefFileNo,
                        expectedEncHexLen = 64
                    )
            ev2.changeFileSettings(fileNo = ndefFileNo, fileSettings = patchedSettings)
                    sdmStatus = "rewritten_live_patch_ok payload=${toHex(patchedSettings)}"
                    repaired = true
                }.onFailure {
                    repairAttempts += "live_patch:${it.message}"
                }

                if (!repaired) {
                    val candidates = listOf(
                        Triple(
                            "static_uid",
                            ev2.buildBeamioCompactSdmSettings(templateUrl),
                            ev2.buildBeamioCompactSdmSettings(templateUrl, writeKeyNo = 0x0E)
                        ),
                        Triple(
                            "uid_mirror",
                            ev2.buildBeamioExtendedSdmSettings(templateUrl),
                            ev2.buildBeamioExtendedSdmSettings(templateUrl, writeKeyNo = 0x0E)
                        )
                    )
                    for ((label, candidate, isoWritableCandidate) in candidates) {
                        if (repaired) break
                        runCatching {
                            runCatching { ev2.selectApplicationIfSupported() }
                            authWithCandidate("globalKey0_before_rewritten_$label", globalKey0)
                            val prewriteStatus = runCatching {
                                ev2.writeNdefFileBytesChunked(fileNo = ndefFileNo, ndef = preparedNdefBytes)
                                "same_session_prewrite_ok"
                            }.recoverCatching {
                                runCatching { ev2.selectNdefApplicationStrict() }
                                authWithCandidate("globalKey0_before_rewritten_${label}_prewrite", globalKey0)
                                ev2.writeNdefFileBytesChunked(fileNo = ndefFileNo, ndef = preparedNdefBytes)
                                "reauth_key0_prewrite_ok"
                            }.recoverCatching {
                                authWithKey("globalKey2_before_rewritten_${label}_prewrite", keyNo = 0x02, key = globalKey2)
                                ev2.writeNdefFileBytesChunked(fileNo = ndefFileNo, ndef = preparedNdefBytes)
                                "reauth_key2_prewrite_ok"
                            }.fold(
                                onSuccess = { it },
                                onFailure = { "prewrite_failed:${it.message ?: it.javaClass.simpleName}" }
                            )
                            if (prewriteStatus.startsWith("prewrite_failed:")) {
                                val isoRewriteStatus = if (isoProbe?.ndefFileId != null) {
                                    runCatching {
                                        ev2.changeFileSettings(fileNo = ndefFileNo, fileSettings = isoWritableCandidate)
                                        rewriteIsoNdefFile(isoDep, isoProbe.ndefFileId, preparedNdefBytes)
                                        ev2.changeFileSettings(fileNo = ndefFileNo, fileSettings = candidate)
                                        "same_session_iso_rewrite_ok"
                                    }.recoverCatching {
                                        runCatching { ev2.selectApplicationIfSupported() }
                                        authWithCandidate("globalKey0_before_rewritten_${label}_iso_rewrite", globalKey0)
                                        ev2.changeFileSettings(fileNo = ndefFileNo, fileSettings = isoWritableCandidate)
                                        rewriteIsoNdefFile(isoDep, isoProbe.ndefFileId, preparedNdefBytes)
                                        ev2.changeFileSettings(fileNo = ndefFileNo, fileSettings = candidate)
                                        "reauth_key0_iso_rewrite_ok"
                                    }.recoverCatching {
                                        authWithKey("globalKey2_before_rewritten_${label}_iso_rewrite", keyNo = 0x02, key = globalKey2)
                                        ev2.changeFileSettings(fileNo = ndefFileNo, fileSettings = isoWritableCandidate)
                                        rewriteIsoNdefFile(isoDep, isoProbe.ndefFileId, preparedNdefBytes)
                                        authWithCandidate("globalKey0_finalize_rewritten_${label}_iso_rewrite", globalKey0)
                                        ev2.changeFileSettings(fileNo = ndefFileNo, fileSettings = candidate)
                                        "reauth_key2_iso_rewrite_ok"
                                    }.fold(
                                        onSuccess = { it },
                                        onFailure = { "iso_rewrite_failed:${it.message ?: it.javaClass.simpleName}" }
                                    )
                                } else {
                                    "iso_rewrite_skipped"
                                }
                                if (isoRewriteStatus != "iso_rewrite_skipped" && !isoRewriteStatus.startsWith("iso_rewrite_failed:")) {
                                    sdmStatus = "rewritten_${label}_ok payload=${toHex(candidate)} prewrite=$prewriteStatus iso=$isoRewriteStatus"
                                    repaired = true
                                } else {
                                    val postwriteStatus = runCatching {
                                    ev2.changeFileSettings(fileNo = ndefFileNo, fileSettings = candidate)
                                    ev2.writeNdefFileBytesChunked(fileNo = ndefFileNo, ndef = preparedNdefBytes)
                                    "same_session_postwrite_ok"
                                    }.recoverCatching {
                                    runCatching { ev2.selectNdefApplicationStrict() }
                                    authWithCandidate("globalKey0_before_rewritten_${label}_postwrite", globalKey0)
                                    ev2.changeFileSettings(fileNo = ndefFileNo, fileSettings = candidate)
                                    ev2.writeNdefFileBytesChunked(fileNo = ndefFileNo, ndef = preparedNdefBytes)
                                    "reauth_key0_postwrite_ok"
                                    }.recoverCatching {
                                    authWithKey("globalKey2_before_rewritten_${label}_postwrite", keyNo = 0x02, key = globalKey2)
                                    ev2.writeNdefFileBytesChunked(fileNo = ndefFileNo, ndef = preparedNdefBytes)
                                    "reauth_key2_postwrite_ok"
                                    }.fold(
                                    onSuccess = { it },
                                    onFailure = { "postwrite_failed:${it.message ?: it.javaClass.simpleName}" }
                                    )
                                    if (postwriteStatus.startsWith("postwrite_failed:")) {
                                        repairAttempts += "$label:payload=${toHex(candidate)} prewrite=$prewriteStatus iso=$isoRewriteStatus postwrite=$postwriteStatus"
                                    } else {
                                        sdmStatus = "rewritten_${label}_ok payload=${toHex(candidate)} prewrite=$prewriteStatus iso=$isoRewriteStatus postwrite=$postwriteStatus"
                                        repaired = true
                                    }
                                }
                            } else {
                                val settingsStatus = runCatching {
                                    ev2.changeFileSettings(fileNo = ndefFileNo, fileSettings = candidate)
                                    "same_session_settings_ok"
                                }.recoverCatching {
                                    runCatching { ev2.selectApplicationIfSupported() }
                                    authWithCandidate("globalKey0_before_rewritten_${label}_settings", globalKey0)
                                    ev2.changeFileSettings(fileNo = ndefFileNo, fileSettings = candidate)
                                    "reauth_key0_settings_ok"
                                }.fold(
                                    onSuccess = { it },
                                    onFailure = { "settings_failed:${it.message ?: it.javaClass.simpleName}" }
                                )
                                if (settingsStatus.startsWith("settings_failed:")) {
                                    repairAttempts += "$label:payload=${toHex(candidate)} prewrite=$prewriteStatus settings=$settingsStatus"
                                } else {
                                    sdmStatus = "rewritten_${label}_ok payload=${toHex(candidate)} prewrite=$prewriteStatus settings=$settingsStatus"
                                    repaired = true
                                }
                            }
                        }.onFailure {
                            repairAttempts += "$label:${it.message} payload=${toHex(candidate)}"
                        }
                    }
                }

                if (!repaired) {
                    val finalReadback = runCatching {
                        try {
                            isoDep.close()
                        } catch (_: IOException) {
                        }
                        verifyReadback(tag)
                    }.getOrNull()
                    val finalUrl = finalReadback?.ndefUrl
                    if (
                        hasExpectedSunBase(finalUrl, sunBaseUrl) &&
                        hasMeaningfulDynamicPayload(finalUrl)
                    ) {
                        sdmStatus = "rewritten_dynamic_sdm_active"
                        templateUrl = finalUrl ?: templateUrl
                        return ProvisionResult(
                            uidHex = uidHex,
                            tagIdHex = tagIdHex,
                            key0Hex = toHex(globalKey0),
                            key2Hex = toHex(globalKey2),
                            ndefFileNo = ndefFileNo,
                            templateUrl = templateUrl,
                            route = resolvedRoute.name.lowercase(),
                            sdmStatus = sdmStatus
                        )
                    }
                    throw IllegalArgumentException(
                        "Rewritten card SDM repair failed\nattempts=${repairAttempts.joinToString(" | ")}"
                    )
                }
            }

            return ProvisionResult(
                uidHex = uidHex,
                tagIdHex = tagIdHex,
                key0Hex = toHex(globalKey0),
                key2Hex = toHex(globalKey2),
                ndefFileNo = ndefFileNo,
                templateUrl = templateUrl,
                route = resolvedRoute.name.lowercase(),
                sdmStatus = sdmStatus
            )
        } catch (e: Exception) {
            throw IllegalArgumentException(
                buildString {
                    append("Provision route=")
                    append(route?.name?.lowercase() ?: "unknown")
                    append("\nauthKey=")
                    append(authKeyLabel)
                    append("\nkey2OldKeyCandidate=")
                    append(key2OldKeyLabel)
                    append("\nkey2RewriteStatus=")
                    append(key2RewriteStatus)
                    append("\npreferredNdefFileNo=0x")
                    append("%02X".format(preferredNdefFileNo))
                    append("\nndefDecision=")
                    append(ndefDecision)
                    append("\nndefProbeSummary=")
                    append(ndefProbeSummary)
                    append("\nsdmStatus=")
                    append(sdmStatus)
                    append("\n")
                    append(e.message ?: e.toString())
                    val lost = e is TagLostException || e.cause is TagLostException ||
                        isLikelyTagLostError(e)
                    if (lost) {
                        append("\nKeep the card flat on the NFC sensor until the operation finishes.")
                    }
                },
                e
            )
        } finally {
            try {
                isoDep.close()
            } catch (_: IOException) {
            }
        }
    }
}