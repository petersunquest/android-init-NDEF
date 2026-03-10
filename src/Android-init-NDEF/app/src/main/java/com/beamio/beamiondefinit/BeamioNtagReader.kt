package app.beamio.nfc

import android.nfc.Tag
import android.nfc.NdefMessage
import android.nfc.NdefRecord
import android.nfc.tech.IsoDep
import android.nfc.tech.Ndef
import java.nio.charset.Charset

class BeamioNtagReader {

    private data class ProbeCandidate(
        val fileNo: Int,
        val settingsHex: String?,
        val parsedUrl: String?,
        val error: String?
    )

    private data class IsoReadCandidate(
        val ndefFileId: Int?,
        val maxSize: Int?,
        val parsedUrl: String?,
        val error: String?
    )

    data class ReadResult(
        val uidHex: String,
        val ndefFileNo: Int?,
        val ndefUrl: String?,
        val storedNdefUrl: String? = null,
        val urlSource: String? = null,
        val eHex: String?,
        val cHex: String?,
        val mHex: String?,
        val isTemplatePlaceholder: Boolean = false,
        val decodedTagIdHex: String? = null,
        val decodedCounterHex: String? = null,
        val serverTagIdHex: String? = null,
        val serverCounterHex: String? = null,
        val serverValid: Boolean? = null,
        val serverMacValid: Boolean? = null,
        val serverStatus: String? = null,
        val serverRawJson: String? = null,
        val checkStatus: String? = null,
        val rawFileSettingsHex: String?,
        val notes: List<String>
    )

    @Throws(Exception::class)
    fun readCard(tag: Tag): ReadResult {
        val notes = mutableListOf<String>()

        val uid = tag.id ?: ByteArray(0)
        val uidHex = uid.toHex()

        var ndefUrl: String? = null
        var ndefFileNo: Int? = null
        var rawFileSettingsHex: String? = null

        // 1) 优先通过 Ndef 读取动态 URL
        try {
            val ndef = Ndef.get(tag)
            if (ndef != null) {
                ndef.connect()
                val message = ndef.ndefMessage
                if (message != null) {
                    ndefUrl = extractFirstUri(message)
                    if (ndefUrl != null) {
                        notes += "NDEF URI read success"
                    } else {
                        notes += "NDEF present, but no URI record found"
                    }
                } else {
                    notes += "NDEF tech present, but ndefMessage is null"
                }
                ndef.close()
            } else {
                notes += "Ndef tech not available"
            }
        } catch (e: Exception) {
            notes += "NDEF read failed: ${e.message}"
        }

        // 2) 用 IsoDep 获取 fileNo / raw settings
        try {
            val isoDep = IsoDep.get(tag)
            if (isoDep != null) {
                isoDep.connect()
                isoDep.timeout = 5000

                val ev2 = AndroidNtagPlainReader(isoDep)

                if (ndefUrl == null) {
                    val isoRead = readStoredUrlViaIso(isoDep, ev2)
                    if (isoRead.parsedUrl != null) {
                        ndefUrl = isoRead.parsedUrl
                        notes += "ISO READ BINARY parsed stored URL"
                    } else {
                        notes += "ISO READ BINARY fallback failed: ${isoRead.error ?: "url_not_found"}"
                    }
                }

                val preferredCandidates = listOf(0x02, 0x04)

                val selectedFileNo = runCatching {
                    ev2.autoDetectNdefFileNo().also {
                        notes += "Auto-detected NDEF fileNo = 0x%02X".format(it)
                    }
                }.getOrElse { autoDetectError ->
                    notes += "Auto-detect NDEF fileNo failed: ${autoDetectError.message ?: autoDetectError.javaClass.simpleName}"
                    val probes = preferredCandidates.map { fileNo ->
                        runCatching {
                            val rawFs = ev2.getFileSettingsPlain(fileNo)
                            val settingsHex = rawFs.toHex()
                            val rawFile = runCatching { ev2.readDataPlain(fileNo, 0, 300) }.getOrNull()
                            val parsedUrl = rawFile?.let(ev2::tryParseUriFromNdefFile)
                            ProbeCandidate(
                                fileNo = fileNo,
                                settingsHex = settingsHex,
                                parsedUrl = parsedUrl,
                                error = null
                            )
                        }.getOrElse { probeError ->
                            ProbeCandidate(
                                fileNo = fileNo,
                                settingsHex = null,
                                parsedUrl = null,
                                error = probeError.message ?: probeError.javaClass.simpleName
                            )
                        }
                    }
                    notes += "Fallback probe: " + probes.joinToString(" | ") {
                        "fileNo=0x%02X settings=%s url=%s error=%s".format(
                            it.fileNo,
                            it.settingsHex ?: "null",
                            it.parsedUrl ?: "null",
                            it.error ?: "null"
                        )
                    }
                    val selectedProbe = probes.firstOrNull { it.parsedUrl != null }
                        ?: probes.firstOrNull { it.settingsHex != null }
                        ?: throw autoDetectError
                    if (ndefUrl == null) {
                        ndefUrl = selectedProbe.parsedUrl
                    }
                    rawFileSettingsHex = selectedProbe.settingsHex
                    notes += "Fallback-selected NDEF fileNo = 0x%02X".format(selectedProbe.fileNo)
                    selectedProbe.fileNo
                }

                ndefFileNo = selectedFileNo

                if (rawFileSettingsHex == null) {
                    val rawFs = ev2.getFileSettingsPlain(selectedFileNo)
                    rawFileSettingsHex = rawFs.toHex()
                }

                if (ndefUrl == null) {
                    val rawFile = ev2.readDataPlain(selectedFileNo, 0, 300)
                    ndefUrl = ev2.tryParseUriFromNdefFile(rawFile)
                    if (ndefUrl != null) {
                        notes += "URI parsed from raw NDEF file bytes"
                    } else {
                        notes += "Could not parse URI from raw NDEF file bytes"
                    }
                }

                isoDep.close()
            } else {
                notes += "IsoDep not available"
            }
        } catch (e: Exception) {
            notes += "IsoDep/plain read failed: ${e.message ?: e.javaClass.simpleName}"
        }

        // 3) 解析 e/c/m
        val eHex = ndefUrl?.let { extractQueryParam(it, "e") }
        val cHex = ndefUrl?.let { extractQueryParam(it, "c") }
        val mHex = ndefUrl?.let { extractQueryParam(it, "m") }
        val resolvedUidHex = uidHex.ifBlank {
            ndefUrl?.let { extractQueryParam(it, "uid") }?.uppercase() ?: ""
        }

        return ReadResult(
            uidHex = resolvedUidHex,
            ndefFileNo = ndefFileNo,
            ndefUrl = ndefUrl,
            storedNdefUrl = ndefUrl,
            urlSource = "stored_ndef",
            eHex = eHex,
            cHex = cHex,
            mHex = mHex,
            rawFileSettingsHex = rawFileSettingsHex,
            notes = notes
        )
    }

    private fun extractFirstUri(message: NdefMessage): String? {
        for (record in message.records) {
            val uri = parseUriRecord(record)
            if (uri != null) return uri
        }
        return null
    }

    private fun parseUriRecord(record: NdefRecord): String? {
        if (record.tnf != NdefRecord.TNF_WELL_KNOWN) return null
        if (!record.type.contentEquals(NdefRecord.RTD_URI)) return null
        if (record.payload.isEmpty()) return null

        val prefixCode = record.payload[0].toInt() and 0xFF
        val suffix = String(record.payload.copyOfRange(1, record.payload.size), Charset.forName("UTF-8"))

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

    private fun extractQueryParam(url: String, key: String): String? {
        val marker = "$key="
        val idx = url.indexOf(marker)
        if (idx < 0) return null

        val start = idx + marker.length
        val end = url.indexOf('&', start).let { if (it < 0) url.length else it }
        return url.substring(start, end)
    }

    private fun splitSw(resp: ByteArray): Pair<ByteArray, Int> {
        require(resp.size >= 2) { "Bad response length" }
        val sw1 = resp[resp.size - 2].toInt() and 0xFF
        val sw2 = resp[resp.size - 1].toInt() and 0xFF
        return resp.copyOfRange(0, resp.size - 2) to ((sw1 shl 8) or sw2)
    }

    private fun transceiveIso(isoDep: IsoDep, apdu: ByteArray): ByteArray {
        val (body, sw) = splitSw(isoDep.transceive(apdu))
        require(sw == 0x9000) { "ISO cmd failed: 0x%04X apdu=%s".format(sw, apdu.toHex()) }
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

    private fun readStoredUrlViaIso(isoDep: IsoDep, ev2: AndroidNtagPlainReader): IsoReadCandidate {
        return runCatching {
            selectIsoAid(isoDep, byteArrayOf(0xD2.toByte(), 0x76, 0x00, 0x00, 0x85.toByte(), 0x01, 0x01))
            selectIsoFile(isoDep, 0xE103)
            val cc = readBinary(isoDep, 0, 15)
            require(cc.size >= 15) { "CC file too short: ${cc.size}" }
            require((cc[7].toInt() and 0xFF) == 0x04 && (cc[8].toInt() and 0xFF) == 0x06) {
                "Unexpected CC layout: ${cc.toHex()}"
            }
            val ndefFileId = ((cc[9].toInt() and 0xFF) shl 8) or (cc[10].toInt() and 0xFF)
            val maxSize = ((cc[11].toInt() and 0xFF) shl 8) or (cc[12].toInt() and 0xFF)
            selectIsoFile(isoDep, ndefFileId)
            val fileBytes = readBinary(isoDep, 0, maxSize)
            IsoReadCandidate(
                ndefFileId = ndefFileId,
                maxSize = maxSize,
                parsedUrl = ev2.tryParseUriFromNdefFile(fileBytes),
                error = null
            )
        }.getOrElse {
            IsoReadCandidate(
                ndefFileId = null,
                maxSize = null,
                parsedUrl = null,
                error = it.message ?: it.javaClass.simpleName
            )
        }
    }
}

private fun ByteArray.toHex(): String =
    buildString(size * 2) {
        forEach { append("%02X".format(it)) }
    }