package com.beamio.beamiondefinit

import android.content.ClipData
import android.content.ClipboardManager
import android.content.Context
import android.content.Intent
import android.util.Log
import androidx.core.view.WindowCompat
import androidx.core.view.WindowInsetsCompat
import androidx.core.view.WindowInsetsControllerCompat
import android.nfc.NfcAdapter
import android.nfc.NdefMessage
import android.nfc.NdefRecord
import android.nfc.Tag
import android.os.Build
import android.os.Build.VERSION_CODES
import android.os.Bundle
import android.os.VibrationEffect
import android.os.Vibrator
import androidx.activity.ComponentActivity
import androidx.activity.compose.setContent
import androidx.activity.enableEdgeToEdge
import androidx.compose.animation.core.RepeatMode
import androidx.compose.animation.core.animateFloat
import androidx.compose.animation.core.infiniteRepeatable
import androidx.compose.animation.core.rememberInfiniteTransition
import androidx.compose.animation.core.tween
import androidx.compose.foundation.BorderStroke
import androidx.compose.foundation.Canvas
import androidx.compose.foundation.background
import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.heightIn
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.layout.statusBars
import androidx.compose.foundation.layout.windowInsetsPadding
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.WindowInsets
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.verticalScroll
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.foundation.text.selection.SelectionContainer
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.filled.ChevronLeft
import androidx.compose.material.icons.filled.ArrowDropDown
import androidx.compose.material.icons.filled.ArrowDropUp
import androidx.compose.material.icons.filled.Check
import androidx.compose.material.icons.filled.ChevronRight
import androidx.compose.material.icons.filled.Nfc
import androidx.compose.material.icons.outlined.Build
import androidx.compose.material.icons.outlined.QrCode2
import androidx.compose.material3.Button
import androidx.compose.material3.OutlinedButton
import androidx.compose.material3.Card
import androidx.compose.material3.OutlinedTextField
import androidx.compose.material3.CardDefaults
import androidx.compose.material3.ExperimentalMaterial3Api
import androidx.compose.foundation.Image
import androidx.compose.material3.IconButton
import androidx.compose.material3.Icon
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.getValue
import androidx.compose.runtime.remember
import androidx.compose.runtime.saveable.rememberSaveable
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.geometry.Offset
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.graphicsLayer
import androidx.compose.ui.graphics.vector.ImageVector
import androidx.compose.ui.layout.ContentScale
import androidx.compose.ui.res.painterResource
import androidx.compose.ui.text.font.FontFamily
import androidx.compose.ui.text.style.TextAlign
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.tooling.preview.Preview
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import app.beamio.nfc.BeamioLocalSunDecoder
import app.beamio.nfc.BeamioNtagProvisioner
import app.beamio.nfc.BeamioNtagReader
import com.beamio.beamiondefinit.R
import com.beamio.beamiondefinit.ui.theme.BeamioNDEFInitTheme
import org.json.JSONArray
import org.json.JSONObject
import java.net.HttpURLConnection
import java.net.URL

private fun performButtonHaptic(context: Context) {
    val vibrator = context.getSystemService(Context.VIBRATOR_SERVICE) as? Vibrator ?: return
    if (Build.VERSION.SDK_INT >= VERSION_CODES.O) {
        vibrator.vibrate(VibrationEffect.createOneShot(50, VibrationEffect.DEFAULT_AMPLITUDE))
    } else {
        @Suppress("DEPRECATION")
        vibrator.vibrate(50)
    }
}

@OptIn(ExperimentalMaterial3Api::class)
class MainActivity : ComponentActivity(), NfcAdapter.ReaderCallback {
    private var showKeyInitScreen by mutableStateOf(true)
    private var showTapCardScreen by mutableStateOf(false)
    private var tapCardMode by mutableStateOf("check")
    private var cardReadResult by mutableStateOf<BeamioNtagReader.ReadResult?>(null)
    private var cardReadError by mutableStateOf<String?>(null)
    private var initResult by mutableStateOf<BeamioNtagProvisioner.ProvisionResult?>(null)
    private var initError by mutableStateOf<String?>(null)
    private var nfcAdapter: NfcAdapter? = null
    private val reader = BeamioNtagReader()
    private var lastIntentDiscoveredUrl: String? = null

    private data class SunDebugResult(
        val requestUrl: String,
        val httpStatus: Int,
        val valid: Boolean?,
        val macValid: Boolean?,
        val counterHex: String?,
        val tagIdHex: String?,
        val rawJson: String
    )

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        logStartupSelfCheck()
        showKeyInitScreen = !KeyStorageManager.hasKeys(this)
        nfcAdapter = NfcAdapter.getDefaultAdapter(this)
        enableEdgeToEdge()
        hideNavigationBar()
        setContent {
            BeamioNDEFInitTheme {
                when {
                    showKeyInitScreen -> KeyInitScreen(
                        onKeysSaved = { showKeyInitScreen = false },
                        modifier = Modifier.fillMaxSize()
                    )
                    showTapCardScreen -> TapCardScreen(
                        mode = tapCardMode,
                        result = cardReadResult,
                        error = cardReadError,
                        initResult = initResult,
                        initError = initError,
                        onBack = {
                            showTapCardScreen = false
                            cardReadResult = null
                            cardReadError = null
                            initResult = null
                            initError = null
                        },
                        onReadAnother = {
                            cardReadResult = null
                            cardReadError = null
                            initResult = null
                            initError = null
                        },
                        modifier = Modifier.fillMaxSize()
                    )
                    else -> Box(modifier = Modifier.fillMaxSize()) {
                        Column(
                            modifier = Modifier
                                .fillMaxWidth()
                                .align(Alignment.TopCenter)
                                .padding(top = 96.dp, bottom = 16.dp),
                            horizontalAlignment = Alignment.CenterHorizontally,
                            verticalArrangement = Arrangement.spacedBy(8.dp)
                        ) {
                            Card(
                                modifier = Modifier.size(78.dp),
                                shape = RoundedCornerShape(14.dp),
                                colors = CardDefaults.cardColors(containerColor = Color.White),
                                elevation = CardDefaults.cardElevation(defaultElevation = 6.dp)
                            ) {
                                Box(
                                    modifier = Modifier.fillMaxSize(),
                                    contentAlignment = Alignment.Center
                                ) {
                                    Image(
                                        painter = painterResource(R.drawable.ic_launcher_adaptive),
                                        contentDescription = "Beamio app icon",
                                        contentScale = ContentScale.Crop,
                                        modifier = Modifier
                                            .fillMaxSize()
                                            .graphicsLayer(
                                                scaleX = 1.2f,
                                                scaleY = 1.2f
                                            )
                                    )
                                }
                            }
                            Text(
                                "NFC Initialization",
                                style = MaterialTheme.typography.titleLarge,
                                modifier = Modifier.padding(top = 48.dp)
                            )
                        }
                        Column(
                            modifier = Modifier
                                .align(Alignment.Center)
                                .fillMaxWidth()
                                .padding(horizontal = 16.dp),
                            verticalArrangement = Arrangement.spacedBy(12.dp),
                            horizontalAlignment = Alignment.CenterHorizontally
                        ) {
                            MenuButton(
                                title = "Initialization",
                                subtitle = "Configure Beamio Card Settings",
                                icon = Icons.Outlined.Build,
                                onClick = {
                                    tapCardMode = "init"
                                    initResult = null
                                    initError = null
                                    showTapCardScreen = true
                                }
                            )
                            MenuButton(
                                title = "Check",
                                subtitle = "Show Card Information",
                                icon = Icons.Outlined.QrCode2,
                                onClick = {
                                    tapCardMode = "check"
                                    cardReadResult = null
                                    cardReadError = null
                                    showTapCardScreen = true
                                }
                            )
                        }
                    }
                }
            }
        }
    }

    private fun performCompletionVibration() {
        val vibrator = getSystemService(Context.VIBRATOR_SERVICE) as? Vibrator ?: return
        if (Build.VERSION.SDK_INT >= VERSION_CODES.O) {
            vibrator.vibrate(VibrationEffect.createOneShot(80, VibrationEffect.DEFAULT_AMPLITUDE))
        } else {
            @Suppress("DEPRECATION")
            vibrator.vibrate(80)
        }
    }

    private fun hideNavigationBar() {
        WindowCompat.getInsetsController(window, window.decorView).apply {
            hide(WindowInsetsCompat.Type.navigationBars())
            systemBarsBehavior = WindowInsetsControllerCompat.BEHAVIOR_SHOW_TRANSIENT_BARS_BY_SWIPE
        }
    }

    private fun logStartupSelfCheck() {
        val pkgInfo = packageManager.getPackageInfo(packageName, 0)
        val requestedPermissions = pkgInfo.requestedPermissions?.toList().orEmpty()
        val hasInternetPermission = requestedPermissions.contains(android.Manifest.permission.INTERNET)
        val versionCode = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.P) {
            pkgInfo.longVersionCode.toString()
        } else {
            @Suppress("DEPRECATION")
            pkgInfo.versionCode.toString()
        }
        Log.d(
            "NFC",
            "startup package=$packageName versionName=${pkgInfo.versionName} versionCode=$versionCode INTERNET_declared=$hasInternetPermission"
        )
    }

    private fun fetchSunDebugResult(url: String): SunDebugResult {
        val debugUrl = if (url.contains("debug=")) {
            url
        } else {
            val separator = if (url.contains("?")) "&" else "?"
            "${url}${separator}debug=1"
        }
        val connection = (URL(debugUrl).openConnection() as HttpURLConnection).apply {
            requestMethod = "GET"
            connectTimeout = 8000
            readTimeout = 8000
            setRequestProperty("Accept", "application/json")
        }
        return try {
            val status = connection.responseCode
            val body = (if (status >= 400) connection.errorStream else connection.inputStream)
                ?.bufferedReader()
                ?.use { it.readText() }
                .orEmpty()
            val json = JSONObject(body.ifBlank { "{}" })
            SunDebugResult(
                requestUrl = debugUrl,
                httpStatus = status,
                valid = json.takeIf { it.has("valid") }?.optBoolean("valid"),
                macValid = json.takeIf { it.has("macValid") }?.optBoolean("macValid"),
                counterHex = json.optString("counterHex").ifBlank { json.optString("cHex").ifBlank { null } },
                tagIdHex = json.optString("tagIdHex").ifBlank { null },
                rawJson = json.toString(2)
            )
        } finally {
            connection.disconnect()
        }
    }

    override fun onResume() {
        super.onResume()
        hideNavigationBar()
        val adapter = nfcAdapter ?: return
        val options = Bundle().apply {
            putInt(NfcAdapter.EXTRA_READER_PRESENCE_CHECK_DELAY, 250)
        }
        adapter.enableReaderMode(
            this,
            this,
            NfcAdapter.FLAG_READER_NFC_A or
                NfcAdapter.FLAG_READER_NO_PLATFORM_SOUNDS,
            options
        )
    }

    override fun onPause() {
        nfcAdapter?.disableReaderMode(this)
        super.onPause()
    }

    override fun onTagDiscovered(tag: Tag) {
        runOnUiThread {
            handleTagDiscovered(tag, discoveredUrl = null)
        }
    }

    private fun handleTagDiscovered(tag: Tag, discoveredUrl: String? = null) {
        if (!showTapCardScreen) return
        when (tapCardMode) {
            "init" -> runProvision(tag)
            "check" -> runReadCard(tag, discoveredUrl)
        }
    }

    private fun runReadCard(tag: Tag, discoveredUrl: String?) {
        cardReadError = null
        val k2 = KeyStorageManager.loadGlobalKey2(this)
        Thread {
            try {
                val baseResult = reader.readCard(tag)
                val effectiveUrl = discoveredUrl ?: baseResult.ndefUrl
                val effectiveE = effectiveUrl?.let { extractQueryParam(it, "e") }
                val effectiveC = effectiveUrl?.let { extractQueryParam(it, "c") }
                val effectiveM = effectiveUrl?.let { extractQueryParam(it, "m") }
                val effectiveUid = effectiveUrl?.let { extractQueryParam(it, "uid") }?.uppercase()
                val notes = baseResult.notes.toMutableList()

                val urlSource = when {
                    discoveredUrl != null -> "intent_ndef_discovered"
                    effectiveUrl != null -> "stored_ndef"
                    else -> "none"
                }

                if (discoveredUrl != null) {
                    notes += "Intent URL read success"
                    if (baseResult.ndefUrl != null && baseResult.ndefUrl != discoveredUrl) {
                        notes += "Stored NDEF template differs from discovered tap URL"
                    }
                }

                val isTemplatePlaceholder = looksLikeTemplatePlaceholder(effectiveUrl)
                val malformedDynamicUrl = effectiveUrl != null &&
                    !isTemplatePlaceholder &&
                    !hasValidSunHexPayload(effectiveUrl)
                var decodedTagIdHex: String? = null
                var decodedCounterHex: String? = null
                var serverTagIdHex: String? = null
                var serverCounterHex: String? = null
                var serverValid: Boolean? = null
                var serverMacValid: Boolean? = null
                var serverStatus: String? = null
                var serverRawJson: String? = null
                var checkStatus: String? = null

                when {
                    effectiveUrl == null -> {
                        checkStatus = "No URL detected from tag"
                    }
                    isTemplatePlaceholder -> {
                        checkStatus = "Static template placeholder read. e/c/m are zero because this is the stored NDEF template, not a dynamic SUN tap result."
                    }
                    malformedDynamicUrl -> {
                        checkStatus = "Malformed SUN URL detected. Card SDM payload is corrupted; rerun init."
                    }
                    k2 == null -> {
                        checkStatus = "Dynamic URL detected, but globalKey2 is not configured locally."
                    }
                    k2.size != 16 -> {
                        checkStatus = "Dynamic URL detected, but globalKey2 length is ${k2.size} bytes (expected 16)."
                    }
                    else -> {
                        runCatching {
                            val decoded = BeamioLocalSunDecoder.decodeFromTagAndUrl(
                                tag = tag,
                                url = effectiveUrl,
                                globalKey2Hex = bytesToHex(k2)
                            )
                            decodedTagIdHex = decoded.tagIdHex
                            decodedCounterHex = decoded.counterHex
                            checkStatus = "Dynamic SUN URL decoded successfully."
                        }.onFailure {
                            checkStatus = "Dynamic URL detected, but local decode failed: ${it.message ?: it}"
                        }
                    }
                }

                if (effectiveUrl != null && !isTemplatePlaceholder) {
                    runCatching {
                        fetchSunDebugResult(effectiveUrl)
                    }.onSuccess { debug ->
                        serverTagIdHex = debug.tagIdHex
                        serverCounterHex = debug.counterHex
                        serverValid = debug.valid
                        serverMacValid = debug.macValid
                        serverStatus = "Server debug request completed (${debug.httpStatus})."
                        serverRawJson = debug.rawJson
                        notes += serverStatus!!

                        val localMatchesServer =
                            !decodedTagIdHex.isNullOrBlank() &&
                                !decodedCounterHex.isNullOrBlank() &&
                                decodedTagIdHex.equals(serverTagIdHex, ignoreCase = true) &&
                                decodedCounterHex.equals(serverCounterHex, ignoreCase = true)

                        checkStatus = when {
                            localMatchesServer && debug.valid == true ->
                                "Dynamic SUN URL decoded successfully. Server verification matched."
                            localMatchesServer ->
                                "Dynamic SUN URL decoded successfully. Server fields matched."
                            !decodedTagIdHex.isNullOrBlank() &&
                                !decodedCounterHex.isNullOrBlank() &&
                                (!serverTagIdHex.isNullOrBlank() || !serverCounterHex.isNullOrBlank()) ->
                                "Dynamic SUN URL decoded locally, but server verification mismatched."
                            checkStatus != null -> "$checkStatus Server debug completed."
                            else -> "Server debug request completed (${debug.httpStatus})."
                        }
                    }.onFailure {
                        serverStatus = "Server debug request failed: ${it.message ?: it}"
                        notes += serverStatus!!
                        if (checkStatus == null) {
                            checkStatus = serverStatus
                        } else if (checkStatus?.contains("decoded successfully") == true) {
                            checkStatus = "$checkStatus ${serverStatus}"
                        }
                    }
                }

                val displayNotes = buildUserFacingCheckNotes(
                    notes = notes,
                    urlSource = urlSource,
                    checkStatus = checkStatus,
                    serverStatus = serverStatus
                )

                val result = baseResult.copy(
                    uidHex = baseResult.uidHex.ifBlank { effectiveUid ?: "" },
                    ndefUrl = effectiveUrl,
                    storedNdefUrl = baseResult.ndefUrl,
                    urlSource = urlSource,
                    eHex = effectiveE,
                    cHex = effectiveC,
                    mHex = effectiveM,
                    isTemplatePlaceholder = isTemplatePlaceholder,
                    decodedTagIdHex = decodedTagIdHex,
                    decodedCounterHex = decodedCounterHex,
                    serverTagIdHex = serverTagIdHex,
                    serverCounterHex = serverCounterHex,
                    serverValid = serverValid,
                    serverMacValid = serverMacValid,
                    serverStatus = serverStatus,
                    serverRawJson = serverRawJson,
                    checkStatus = checkStatus,
                    notes = displayNotes
                )
                runOnUiThread {
                    cardReadResult = result
                    performCompletionVibration()
                    Log.d("NFC", "UID=${result.uidHex}")
                    Log.d("NFC", "fileNo=${result.ndefFileNo}")
                    Log.d("NFC", "urlSource=${result.urlSource}")
                    Log.d("NFC", "url=${result.ndefUrl}")
                    Log.d("NFC", "storedUrl=${result.storedNdefUrl}")
                    Log.d("NFC", "e=${result.eHex}")
                    Log.d("NFC", "c=${result.cHex}")
                    Log.d("NFC", "m=${result.mHex}")
                    Log.d("NFC", "decodedTagId=${result.decodedTagIdHex}")
                    Log.d("NFC", "decodedCounter=${result.decodedCounterHex}")
                    Log.d("NFC", "checkStatus=${result.checkStatus}")
                    Log.d("NFC", "fs=${result.rawFileSettingsHex}")
                    Log.d("NFC", "notes=${result.notes.joinToString(" | ")}")
                }
            } catch (e: Exception) {
                Log.e("NFC", "read failed", e)
                runOnUiThread {
                    cardReadError = e.message ?: "Read failed"
                }
            }
        }.start()
    }

    private fun runProvision(tag: Tag) {
        initError = null
        val k0 = KeyStorageManager.loadGlobalKey0(this)
        val k2 = KeyStorageManager.loadGlobalKey2(this)
        if (k0 == null || k2 == null) {
            initError = "Keys not configured. Please save globalKey0 and globalKey2 first."
            return
        }
        Thread {
            try {
                val provisioner = BeamioNtagProvisioner(
                    sunBaseUrl = "https://beamio.app/api/sun",
                    globalKey0 = k0,
                    globalKey2 = k2
                )
                val result = provisioner.provision(tag, defaultKey0 = ByteArray(16))
                val readback = provisioner.verifyReadback(tag)
                val rewrittenDynamicActive = result.route == "rewritten" &&
                    isValidRewrittenDynamicReadback(
                        provisionResult = result,
                        readback = readback
                    )
                val verifiedResult = result.copy(
                    readbackUrl = readback.ndefUrl,
                    sdmStatus = if (rewrittenDynamicActive) "rewritten_dynamic_sdm_active" else result.sdmStatus
                )
                require(isVerifiedInitReadback(result, readback)) {
                    buildString {
                        append("Provision verification failed")
                        append("\nroute=")
                        append(result.route)
                        append("\nuid=")
                        append(readback.uidHex)
                        append("\nndefUrl=")
                        append(readback.ndefUrl ?: "null")
                        append("\ne=")
                        append(readback.eHex ?: "null")
                        append("\nc=")
                        append(readback.cHex ?: "null")
                        append("\nm=")
                        append(readback.mHex ?: "null")
                        append("\nsdmStatus=")
                        append(result.sdmStatus ?: "null")
                        append("\nexpectedTemplateUrl=")
                        append(result.templateUrl)
                        append("\nnotes=")
                        append(readback.notes.joinToString(" | "))
                    }
                }
                runOnUiThread {
                    initResult = verifiedResult
                    performCompletionVibration()
                    Log.d("NFC", "Provision: $verifiedResult")
                }
            } catch (e: Exception) {
                Log.e("NFC", "provision failed", e)
                runOnUiThread {
                    initError = buildDetailedError(e, "Provision failed")
                }
            }
        }.start()
    }

    private fun isVerifiedInitReadback(
        provisionResult: BeamioNtagProvisioner.ProvisionResult,
        readback: BeamioNtagProvisioner.ReadbackResult
    ): Boolean {
        if (provisionResult.route == "fresh") {
            val url = readback.ndefUrl ?: return false
            if (url == provisionResult.templateUrl) return true
            // After SDM (fresh_offsets_applied), readback is a dynamic SUN URL; templateUrl still has
            // placeholder e/c/m zeros — same check as rewritten dynamic readback.
            if (provisionResult.sdmStatus == "fresh_offsets_applied") {
                return isValidRewrittenDynamicReadback(
                    provisionResult = provisionResult,
                    readback = readback
                )
            }
            return false
        }
        if (isValidRewrittenDynamicReadback(
            provisionResult = provisionResult,
            readback = readback
        )) {
            return true
        }
        if (readback.uidHex.isBlank()) return false
        val sdmStatus = provisionResult.sdmStatus ?: return false
        val rewrittenRepairSucceeded =
            (sdmStatus.startsWith("rewritten_static_uid_ok") || sdmStatus.startsWith("rewritten_uid_mirror_ok")) &&
                (
                    sdmStatus.contains("ndef=chunked_write_ok") ||
                        sdmStatus.contains("prewrite=") && sdmStatus.contains("settings=") && !sdmStatus.contains("failed") ||
                        sdmStatus.contains("iso=") && sdmStatus.contains("_ok")
                )
        return when {
            sdmStatus == "rewritten_dynamic_payload_patched" -> true
            sdmStatus == "rewritten_iso_rewrite_ok" -> true
            sdmStatus == "rewritten_existing_dynamic_sdm_preserved" -> true
            sdmStatus == "rewritten_existing_settings_chunked_write_ok" -> true
            sdmStatus.startsWith("rewritten_live_patch_ok") -> true
            rewrittenRepairSucceeded -> true
            else -> false
        }
    }

    private fun isValidRewrittenDynamicReadback(
        provisionResult: BeamioNtagProvisioner.ProvisionResult,
        readback: BeamioNtagProvisioner.ReadbackResult
    ): Boolean {
        val url = readback.ndefUrl ?: return false
        if (url.substringBefore('?') != provisionResult.templateUrl.substringBefore('?')) return false
        val readbackUid = extractQueryParam(url, "uid")?.uppercase()
        if (readbackUid.isNullOrBlank()) return false
        if (readbackUid != readback.uidHex.uppercase()) return false
        val e = extractQueryParam(url, "e")
        val c = extractQueryParam(url, "c")
        val m = extractQueryParam(url, "m")
        if (e.isNullOrBlank() || c.isNullOrBlank() || m.isNullOrBlank()) return false
        if (looksLikeTemplatePlaceholder(url)) return false
        return e.any { it != '0' } && c.any { it != '0' } && m.any { it != '0' }
    }

    private fun hasValidSunHexPayload(url: String): Boolean {
        val e = extractQueryParam(url, "e") ?: return false
        val c = extractQueryParam(url, "c") ?: return false
        val m = extractQueryParam(url, "m") ?: return false
        return e.matches(Regex("^[0-9A-Fa-f]{64}$")) &&
            c.matches(Regex("^[0-9A-Fa-f]{6}$")) &&
            m.matches(Regex("^[0-9A-Fa-f]{16}$"))
    }

    private fun buildUserFacingCheckNotes(
        notes: List<String>,
        urlSource: String,
        checkStatus: String?,
        serverStatus: String?
    ): List<String> {
        val localDecodeSucceeded = checkStatus?.contains("decoded successfully", ignoreCase = true) == true
        if (!localDecodeSucceeded) return notes.distinct()

        val compact = mutableListOf<String>()
        if (notes.any { it == "NDEF URI read success" }) {
            compact += "NDEF URI read success"
        }
        if (urlSource == "intent_ndef_discovered" && notes.any { it == "Intent URL read success" }) {
            compact += "Intent URL read success"
        }
        if (notes.any { it == "Stored NDEF template differs from discovered tap URL" }) {
            compact += "Stored NDEF template differs from discovered tap URL"
        }
        val serverMatched = checkStatus.contains("Server verification matched", ignoreCase = true)
        if (!serverMatched && !serverStatus.isNullOrBlank()) {
            compact += serverStatus
        }
        return compact.distinct()
    }

    private fun buildDetailedError(e: Exception, defaultMsg: String): String {
        return buildString {
            append(e.javaClass.simpleName)
            append(": ")
            append(e.message ?: defaultMsg)
            var cause = e.cause
            var depth = 0
            while (cause != null && depth < 3) {
                append("\n\nCaused by: ")
                append(cause.javaClass.simpleName)
                append(": ")
                append(cause.message ?: cause.toString())
                cause = cause.cause
                depth++
            }
            if (e.stackTrace.isNotEmpty()) {
                append("\n\nStack trace:")
                e.stackTrace.take(8).forEach { ste ->
                    append("\n  at ")
                    append(ste.className)
                    append(".")
                    append(ste.methodName)
                    append("(")
                    append(ste.fileName ?: "?")
                    append(":")
                    append(ste.lineNumber)
                    append(")")
                }
            }
        }
    }

    override fun onNewIntent(intent: Intent) {
        super.onNewIntent(intent)
        setIntent(intent)
        val action = intent.action ?: return
        if (action != NfcAdapter.ACTION_TAG_DISCOVERED &&
            action != NfcAdapter.ACTION_TECH_DISCOVERED &&
            action != NfcAdapter.ACTION_NDEF_DISCOVERED
        ) {
            return
        }
        lastIntentDiscoveredUrl = extractUrlFromIntent(intent) ?: intent.dataString
        val tag: Tag? = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.TIRAMISU) {
            intent.getParcelableExtra(NfcAdapter.EXTRA_TAG, Tag::class.java)
        } else {
            @Suppress("DEPRECATION")
            intent.getParcelableExtra(NfcAdapter.EXTRA_TAG)
        }
        val discoveredUrl = lastIntentDiscoveredUrl
        lastIntentDiscoveredUrl = null
        tag?.let { handleTagDiscovered(it, discoveredUrl) }
    }

    private fun extractUrlFromIntent(intent: Intent): String? {
        val rawMessages = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.TIRAMISU) {
            intent.getParcelableArrayExtra(NfcAdapter.EXTRA_NDEF_MESSAGES, android.os.Parcelable::class.java)
        } else {
            @Suppress("DEPRECATION")
            intent.getParcelableArrayExtra(NfcAdapter.EXTRA_NDEF_MESSAGES)
        } ?: return null
        val messages = rawMessages.mapNotNull { it as? NdefMessage }
        for (message in messages) {
            for (record in message.records) {
                val uri = parseUriRecord(record)
                if (uri != null) return uri
            }
        }
        return null
    }

    private fun parseUriRecord(record: NdefRecord): String? {
        if (record.tnf != NdefRecord.TNF_WELL_KNOWN) return null
        if (!record.type.contentEquals(NdefRecord.RTD_URI)) return null
        if (record.payload.isEmpty()) return null
        val prefixCode = record.payload[0].toInt() and 0xFF
        val suffix = String(record.payload.copyOfRange(1, record.payload.size), Charsets.UTF_8)
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

    private fun looksLikeTemplatePlaceholder(url: String?): Boolean {
        if (url == null) return false
        val e = extractQueryParam(url, "e")
        val c = extractQueryParam(url, "c")
        val m = extractQueryParam(url, "m")
        return e != null && c != null && m != null &&
            e.all { it == '0' } &&
            c.all { it == '0' } &&
            m.all { it == '0' }
    }

    private fun extractQueryParam(url: String, key: String): String? {
        val marker = "$key="
        val idx = url.indexOf(marker)
        if (idx < 0) return null
        val start = idx + marker.length
        val end = url.indexOf('&', start).let { if (it < 0) url.length else it }
        return url.substring(start, end)
    }

    private fun bytesToHex(bytes: ByteArray): String =
        buildString(bytes.size * 2) {
            bytes.forEach { byte ->
                append("%02X".format(byte.toInt() and 0xFF))
            }
        }
}

@Composable
fun KeyInitScreen(
    onKeysSaved: () -> Unit,
    modifier: Modifier = Modifier
) {
    var key0Input by remember { mutableStateOf("") }
    var key2Input by remember { mutableStateOf("") }
    var errorMsg by remember { mutableStateOf<String?>(null) }
    val context = androidx.compose.ui.platform.LocalContext.current

    Column(
        modifier = modifier
            .fillMaxSize()
            .background(Color(0xFFf5f5f7))
            .windowInsetsPadding(WindowInsets.statusBars)
            .padding(24.dp)
            .verticalScroll(rememberScrollState())
    ) {
        Text(
            "Initialize Keys",
            style = MaterialTheme.typography.titleLarge,
            modifier = Modifier.padding(top = 24.dp, bottom = 8.dp)
        )
        Text(
            "Input 16-byte globalKey0 and globalKey2. Format: Base64 or JSON array [0, 91, 232, ...]",
            fontSize = 13.sp,
            color = Color(0xFF86868b),
            modifier = Modifier.padding(bottom = 24.dp)
        )
        OutlinedTextField(
            value = key0Input,
            onValueChange = { key0Input = it; errorMsg = null },
            label = { Text("globalKey0") },
            modifier = Modifier
                .fillMaxWidth()
                .padding(bottom = 16.dp),
            singleLine = false,
            minLines = 2,
            maxLines = 4
        )
        OutlinedTextField(
            value = key2Input,
            onValueChange = { key2Input = it; errorMsg = null },
            label = { Text("globalKey2") },
            modifier = Modifier
                .fillMaxWidth()
                .padding(bottom = 16.dp),
            singleLine = false,
            minLines = 2,
            maxLines = 4
        )
        errorMsg?.let { msg ->
            Text(
                "❌ $msg",
                fontSize = 13.sp,
                color = Color(0xFFef4444),
                modifier = Modifier.padding(bottom = 16.dp)
            )
        }
        Button(
            onClick = {
                performButtonHaptic(context)
                val k0 = KeyStorageManager.parseKeyInput(key0Input)
                val k2 = KeyStorageManager.parseKeyInput(key2Input)
                when {
                    k0 == null -> errorMsg = "globalKey0: invalid format or not 16 bytes"
                    k2 == null -> errorMsg = "globalKey2: invalid format or not 16 bytes"
                    else -> {
                        KeyStorageManager.saveKeys(context, k0, k2)
                        onKeysSaved()
                    }
                }
            },
            modifier = Modifier.fillMaxWidth()
        ) {
            Text("Save Keys")
        }
    }
}

@Composable
fun TapCardScreen(
    mode: String,
    result: BeamioNtagReader.ReadResult?,
    error: String?,
    initResult: BeamioNtagProvisioner.ProvisionResult?,
    initError: String?,
    onBack: () -> Unit,
    onReadAnother: () -> Unit,
    modifier: Modifier = Modifier
) {
    val context = androidx.compose.ui.platform.LocalContext.current
    val scanLineY by rememberInfiniteTransition(label = "nfcScanLine").animateFloat(
        initialValue = 0f,
        targetValue = 1f,
        animationSpec = infiniteRepeatable(
            animation = tween(durationMillis = 1600),
            repeatMode = RepeatMode.Reverse
        ),
        label = "nfcScanLineY"
    )
    Box(
        modifier = modifier
            .fillMaxSize()
            .background(Color(0xFFf5f5f7))
            .windowInsetsPadding(WindowInsets.statusBars)
    ) {
        Card(
            modifier = Modifier
                .align(Alignment.TopStart)
                .padding(16.dp)
                .size(44.dp),
            shape = RoundedCornerShape(22.dp),
            colors = CardDefaults.cardColors(containerColor = Color.White),
            elevation = CardDefaults.cardElevation(defaultElevation = 6.dp)
        ) {
            IconButton(
                onClick = {
                    performButtonHaptic(context)
                    onBack()
                },
                modifier = Modifier.fillMaxSize()
            ) {
                Icon(
                    imageVector = Icons.Filled.ChevronLeft,
                    contentDescription = "Back",
                    tint = Color(0xFF1c1c1e)
                )
            }
        }
        when {
            mode == "init" && initResult != null -> InitSuccessContent(
                result = initResult,
                onReadAnother = onReadAnother,
                modifier = Modifier
                    .fillMaxSize()
                    .padding(16.dp)
                    .padding(top = 56.dp)
            )
            mode == "init" && initError != null -> CardErrorContent(
                title = "Init failed",
                error = initError,
                onReadAnother = onReadAnother,
                modifier = Modifier
                    .fillMaxSize()
                    .padding(16.dp)
                    .padding(top = 56.dp)
            )
            result != null -> CardInfoContent(
                result = result,
                onReadAnother = onReadAnother,
                modifier = Modifier
                    .fillMaxSize()
                    .padding(16.dp)
                    .padding(top = 56.dp)
            )
            mode == "check" && error != null -> CardErrorContent(
                title = "Read failed",
                error = error,
                onReadAnother = onReadAnother,
                modifier = Modifier
                    .fillMaxSize()
                    .padding(16.dp)
                    .padding(top = 56.dp)
            )
            else -> Box(
                modifier = Modifier
                    .fillMaxSize()
                    .padding(16.dp),
                contentAlignment = Alignment.Center
            ) {
                Box(modifier = Modifier.size(280.dp)) {
                    Card(
                        modifier = Modifier.fillMaxSize(),
                        shape = RoundedCornerShape(32.dp),
                        colors = CardDefaults.cardColors(containerColor = Color.White),
                        border = BorderStroke(2.dp, Color.Black.copy(alpha = 0.1f))
                    ) {
                        Box(
                            modifier = Modifier
                                .fillMaxSize()
                                .padding(24.dp)
                        ) {
                            Icon(
                                Icons.Filled.Nfc,
                                contentDescription = null,
                                modifier = Modifier
                                    .size(96.dp)
                                    .align(Alignment.Center),
                                tint = Color(0xFF86868b).copy(alpha = 0.1f)
                            )
                            Text(
                                "Hold the card near the NFC sensor to read card information.",
                                fontSize = 12.sp,
                                color = Color(0xFF86868b),
                                textAlign = TextAlign.Center,
                                modifier = Modifier
                                    .align(Alignment.BottomCenter)
                                    .padding(bottom = 8.dp)
                            )
                        }
                    }
                    Canvas(
                        modifier = Modifier
                            .fillMaxSize()
                            .padding(2.dp)
                    ) {
                        val y = scanLineY * (size.height - 2f)
                        drawLine(
                            color = Color(0xFF1562F0),
                            start = Offset(0f, y),
                            end = Offset(size.width, y),
                            strokeWidth = 2f
                        )
                    }
                }
            }
        }
    }
}

@Composable
private fun CardInfoContent(
    result: BeamioNtagReader.ReadResult,
    onReadAnother: () -> Unit,
    modifier: Modifier = Modifier
) {
    val context = androidx.compose.ui.platform.LocalContext.current
    val clipboard = context.getSystemService(Context.CLIPBOARD_SERVICE) as ClipboardManager
    val detectedDynamicUrl = result.ndefUrl?.takeIf { !result.isTemplatePlaceholder }
    val storedTemplateUrl = when {
        result.isTemplatePlaceholder -> result.ndefUrl
        result.storedNdefUrl != null && result.storedNdefUrl != detectedDynamicUrl -> result.storedNdefUrl
        else -> null
    }
    val showBeamioIcon = listOf(detectedDynamicUrl, storedTemplateUrl).any {
        it?.startsWith("https://beamio.app/api/sun") == true
    } || !result.decodedTagIdHex.isNullOrBlank() || !result.decodedCounterHex.isNullOrBlank()
    val rawJson = remember(result, detectedDynamicUrl, storedTemplateUrl) {
        buildPrettyJson(
            "uid" to result.uidHex,
            "ndefFileNo" to result.ndefFileNo?.let { "0x%02X".format(it) },
            "detectedDynamicUrl" to detectedDynamicUrl,
            "storedTemplateUrl" to storedTemplateUrl,
            "decodedCounter" to result.decodedCounterHex,
            "decodedTagId" to result.decodedTagIdHex,
            "serverCounter" to result.serverCounterHex,
            "serverTagId" to result.serverTagIdHex,
            "serverValid" to result.serverValid,
            "serverMacValid" to result.serverMacValid,
            "serverStatus" to result.serverStatus,
            "serverRawJson" to result.serverRawJson,
            "urlSource" to result.urlSource,
            "e" to result.eHex,
            "c" to result.cHex,
            "m" to result.mHex,
            "checkStatus" to result.checkStatus,
            "fs" to result.rawFileSettingsHex,
            "notes" to result.notes
        )
    }
    ResultSuccessContent(
        title = null,
        uid = result.uidHex,
        tagId = result.decodedTagIdHex,
        counter = result.decodedCounterHex,
        showBeamioIcon = showBeamioIcon,
        rawJson = rawJson,
        copyLabel = "Copy JSON",
        primaryActionLabel = "Read Another",
        onCopy = {
            clipboard.setPrimaryClip(ClipData.newPlainText("check_result", rawJson))
        },
        onPrimaryAction = { onReadAnother() },
        modifier = modifier
    )
}

@Composable
private fun InitSuccessContent(
    result: BeamioNtagProvisioner.ProvisionResult,
    onReadAnother: () -> Unit,
    modifier: Modifier = Modifier
) {
    val context = androidx.compose.ui.platform.LocalContext.current
    val clipboard = context.getSystemService(Context.CLIPBOARD_SERVICE) as ClipboardManager
    val key2Hex = remember(context) {
        KeyStorageManager.loadGlobalKey2(context)?.let { bytes ->
            buildString(bytes.size * 2) {
                bytes.forEach { byte -> append("%02X".format(byte.toInt() and 0xFF)) }
            }
        }
    }
    val isPreservedDynamic = result.sdmStatus == "rewritten_existing_dynamic_sdm_preserved" ||
        result.sdmStatus == "rewritten_dynamic_sdm_active"
    val detectedDynamicUrl = if (isPreservedDynamic) (result.readbackUrl ?: result.templateUrl) else null
    val preservedDecodeResult = remember(detectedDynamicUrl, key2Hex, isPreservedDynamic) {
        if (!isPreservedDynamic || detectedDynamicUrl.isNullOrBlank() || key2Hex.isNullOrBlank()) {
            null
        } else {
            runCatching { BeamioLocalSunDecoder.decodeFromUrl(detectedDynamicUrl, key2Hex) }
        }
    }
    val preservedDecoded = preservedDecodeResult?.getOrNull()
    val preservedDecodeError = preservedDecodeResult?.exceptionOrNull()?.message
    val tagId = if (isPreservedDynamic) preservedDecoded?.tagIdHex else result.tagIdHex
    val counter = if (isPreservedDynamic) preservedDecoded?.counterHex else null
    val showBeamioIcon = isPreservedDynamic ||
        (!result.tagIdHex.isNullOrBlank() && result.tagIdHex != "0000000000000000")
    val rawJson = remember(result, detectedDynamicUrl, preservedDecoded, preservedDecodeError) {
        buildPrettyJson(
            "route" to result.route,
            "sdmStatus" to result.sdmStatus,
            "uid" to result.uidHex,
            "ndefFileNo" to "0x%02X".format(result.ndefFileNo),
            "detectedDynamicUrl" to detectedDynamicUrl,
            "decodedCounter" to preservedDecoded?.counterHex,
            "decodedTagId" to preservedDecoded?.tagIdHex,
            "decodeError" to preservedDecodeError,
            "tagId" to if (isPreservedDynamic) null else result.tagIdHex,
            "templateUrl" to if (isPreservedDynamic) null else result.templateUrl,
            "readbackUrl" to if (isPreservedDynamic) null else result.readbackUrl
        )
    }
    ResultSuccessContent(
        title = "Init Success",
        uid = result.uidHex,
        tagId = tagId,
        counter = counter,
        showBeamioIcon = showBeamioIcon,
        rawJson = rawJson,
        copyLabel = "Copy JSON",
        primaryActionLabel = "Init Another",
        onCopy = {
            clipboard.setPrimaryClip(ClipData.newPlainText("init_result", rawJson))
        },
        onPrimaryAction = { onReadAnother() },
        modifier = modifier
    )
}

@Composable
private fun ResultSuccessContent(
    title: String?,
    uid: String,
    tagId: String?,
    counter: String?,
    showBeamioIcon: Boolean,
    rawJson: String,
    copyLabel: String,
    primaryActionLabel: String,
    onCopy: () -> Unit,
    onPrimaryAction: () -> Unit,
    modifier: Modifier = Modifier
) {
    val context = androidx.compose.ui.platform.LocalContext.current
    var rawExpanded by remember { mutableStateOf(false) }
    var copied by remember(rawJson) { mutableStateOf(false) }

    Column(
        modifier = modifier
            .fillMaxSize()
            .verticalScroll(rememberScrollState()),
        verticalArrangement = Arrangement.spacedBy(16.dp)
    ) {
        if (!title.isNullOrBlank()) {
            Text(
                text = title,
                fontSize = 18.sp,
                color = Color(0xFF1c1c1e)
            )
        }
        Card(
            modifier = Modifier.fillMaxWidth(),
            shape = RoundedCornerShape(20.dp),
            colors = CardDefaults.cardColors(containerColor = Color.White),
            border = BorderStroke(1.dp, Color.Black.copy(alpha = 0.05f))
        ) {
            Box(
                modifier = Modifier
                    .fillMaxWidth()
                    .padding(20.dp)
            ) {
                Column(
                    verticalArrangement = Arrangement.spacedBy(16.dp)
                ) {
                    MajorValueBlock("UID", uid)
                    Row(
                        modifier = Modifier.fillMaxWidth(),
                        horizontalArrangement = Arrangement.spacedBy(12.dp)
                    ) {
                        MajorValueBlock(
                            label = "TagID",
                            value = formatTagIdHex(tagId),
                            valueFontSize = 14.sp,
                            modifier = Modifier.weight(0.7f)
                        )
                        MajorValueBlock(
                            label = "Counter",
                            value = counter ?: "--",
                            valueFontSize = 14.sp,
                            modifier = Modifier.weight(0.3f)
                        )
                    }
                }
                if (showBeamioIcon) {
                    Image(
                        painter = painterResource(R.drawable.ic_launcher_adaptive),
                        contentDescription = "Beamio initialized card",
                        modifier = Modifier
                            .align(Alignment.TopEnd)
                            .size(28.dp)
                    )
                }
            }
        }
        Row(
            modifier = Modifier.fillMaxWidth(),
            horizontalArrangement = Arrangement.spacedBy(12.dp)
        ) {
        OutlinedButton(
            onClick = {
                performButtonHaptic(context)
                copied = true
                onCopy()
            },
                modifier = Modifier.weight(1f)
            ) {
                Row(
                    verticalAlignment = Alignment.CenterVertically,
                    horizontalArrangement = Arrangement.spacedBy(6.dp)
                ) {
                    if (copied) {
                        Icon(
                            imageVector = Icons.Filled.Check,
                            contentDescription = null,
                            tint = Color(0xFF16A34A)
                        )
                    }
                    Text(copyLabel)
                }
            }
            Button(
                onClick = {
                    performButtonHaptic(context)
                    onPrimaryAction()
                },
                modifier = Modifier.weight(1f)
            ) {
                Text(primaryActionLabel)
            }
        }
        OutlinedButton(
            onClick = {
                performButtonHaptic(context)
                rawExpanded = !rawExpanded
            },
            modifier = Modifier.fillMaxWidth()
        ) {
            Row(
                verticalAlignment = Alignment.CenterVertically,
                horizontalArrangement = Arrangement.Center
            ) {
                Icon(
                    imageVector = if (rawExpanded) Icons.Filled.ArrowDropUp else Icons.Filled.ArrowDropDown,
                    contentDescription = null
                )
                Text(if (rawExpanded) "Hide Raw Data" else "Show Raw Data")
            }
        }
        if (rawExpanded) {
            Card(
                modifier = Modifier.fillMaxWidth(),
                shape = RoundedCornerShape(20.dp),
                colors = CardDefaults.cardColors(containerColor = Color(0xFF13151A))
            ) {
                SelectionContainer {
                    Text(
                        text = rawJson,
                        modifier = Modifier
                            .fillMaxWidth()
                            .heightIn(min = 220.dp, max = 520.dp)
                            .verticalScroll(rememberScrollState())
                            .padding(16.dp),
                        color = Color(0xFF4ADE80),
                        fontSize = 8.sp,
                        lineHeight = 8.sp,
                        fontFamily = FontFamily.Monospace
                    )
                }
            }
        }
    }
}

@Composable
private fun MajorValueBlock(
    label: String,
    value: String,
    valueFontSize: androidx.compose.ui.unit.TextUnit = 24.sp,
    modifier: Modifier = Modifier
) {
    Column(
        modifier = modifier.fillMaxWidth(),
        verticalArrangement = Arrangement.spacedBy(6.dp)
    ) {
        Text(
            text = label,
            fontSize = 12.sp,
            color = Color(0xFF86868B)
        )
    Text(
            text = value,
            fontSize = valueFontSize,
            color = Color.Black,
            maxLines = 1,
            overflow = TextOverflow.Ellipsis,
            fontFamily = FontFamily.Monospace
        )
    }
}

private fun formatTagIdHex(tagId: String?): String {
    if (tagId.isNullOrBlank() || tagId == "--") return "--"
    val normalized = tagId.removePrefix("0x").removePrefix("0X").uppercase()
    return "0x$normalized"
}

private fun buildPrettyJson(vararg entries: Pair<String, Any?>): String {
    val json = JSONObject()
    entries.forEach { (key, value) ->
        when (value) {
            null -> Unit
            is List<*> -> json.put(key, JSONArray(value))
            else -> json.put(key, value)
        }
    }
    return json.toString(2)
}

private fun buildErrorSummary(error: String): Pair<String, List<String>> {
    val lines = error.lines().map { it.trim() }.filter { it.isNotEmpty() }
    val title = when {
        error.contains("Provision verification failed", ignoreCase = true) -> "Provision verification failed"
        error.contains("Provision route=", ignoreCase = true) -> "Card provisioning failed"
        error.contains("Read failed", ignoreCase = true) -> "Read failed"
        else -> lines.firstOrNull() ?: "Operation failed"
    }
    val summary = mutableListOf<String>()

    fun addLine(prefix: String, label: String) {
        lines.firstOrNull { it.startsWith(prefix) }
            ?.removePrefix(prefix)
            ?.trim()
            ?.takeIf { it.isNotEmpty() }
            ?.let { summary += "$label: $it" }
    }

    addLine("route=", "Route")
    addLine("uid=", "UID")
    addLine("sdmStatus=", "SDM status")
    addLine("checkStatus=", "Status")

    val rootCause = lines.firstOrNull { it.startsWith("Caused by:") }
        ?.removePrefix("Caused by:")
        ?.trim()
        ?: lines.firstOrNull {
            it !in summary &&
                !it.startsWith("authKey=") &&
                !it.startsWith("key2OldKeyCandidate=") &&
                !it.startsWith("key2RewriteStatus=") &&
                !it.startsWith("preferredNdefFileNo=") &&
                !it.startsWith("ndefDecision=") &&
                !it.startsWith("ndefProbeSummary=") &&
                !it.startsWith("Stack trace:")
        }
    rootCause?.let {
        if (it != title && !it.startsWith("route=") && !it.startsWith("uid=") && !it.startsWith("sdmStatus=") && !it.startsWith("checkStatus=")) {
            summary += "Cause: $it"
        }
    }

    return title to summary.distinct()
}

@Composable
private fun CardErrorContent(
    title: String,
    error: String,
    onReadAnother: () -> Unit,
    modifier: Modifier = Modifier
) {
    val context = androidx.compose.ui.platform.LocalContext.current
    val clipboard = context.getSystemService(Context.CLIPBOARD_SERVICE) as ClipboardManager
    var showDiagnostics by rememberSaveable(error) { mutableStateOf(false) }
    val (summaryTitle, summaryLines) = remember(error) { buildErrorSummary(error) }
    Column(
        modifier = modifier
            .fillMaxSize()
            .verticalScroll(rememberScrollState())
            .padding(16.dp)
    ) {
        Text(
            "❌ $title",
            fontSize = 16.sp,
            color = Color(0xFFef4444),
            modifier = Modifier.padding(bottom = 12.dp)
        )
        Card(
            modifier = Modifier
                .fillMaxWidth()
                .padding(bottom = 16.dp),
            shape = RoundedCornerShape(16.dp),
            colors = CardDefaults.cardColors(containerColor = Color.White)
        ) {
            Column(
                modifier = Modifier
                    .fillMaxWidth()
                    .padding(16.dp),
                verticalArrangement = Arrangement.spacedBy(8.dp)
            ) {
                Text(
                    text = summaryTitle,
                    fontSize = 14.sp,
                    color = Color(0xFF1c1c1e)
                )
                summaryLines.forEach { line ->
                    Text(
                        text = line,
                        fontSize = 12.sp,
                        color = Color(0xFF3a3a3c)
                    )
                }
            }
        }
        OutlinedButton(
            onClick = {
                performButtonHaptic(context)
                showDiagnostics = !showDiagnostics
            },
            modifier = Modifier
                .fillMaxWidth()
                .padding(bottom = 16.dp)
        ) {
            Icon(
                imageVector = if (showDiagnostics) Icons.Filled.ArrowDropUp else Icons.Filled.ArrowDropDown,
                contentDescription = null
            )
            Text(if (showDiagnostics) "Hide detailed diagnostics" else "Show detailed diagnostics")
        }
        if (showDiagnostics) {
            SelectionContainer {
                Text(
                    error,
                    fontSize = 12.sp,
                    color = Color(0xFF1c1c1e),
                    modifier = Modifier
                        .fillMaxWidth()
                        .padding(bottom = 24.dp),
                    textAlign = TextAlign.Start
                )
            }
        }
        Row(
            modifier = Modifier.fillMaxWidth(),
            horizontalArrangement = Arrangement.spacedBy(12.dp)
        ) {
            OutlinedButton(
                onClick = {
                    performButtonHaptic(context)
                    clipboard.setPrimaryClip(ClipData.newPlainText("error", error))
                },
                modifier = Modifier.weight(1f)
            ) {
                Text("Copy diagnostics")
            }
            Button(
                onClick = {
                    performButtonHaptic(context)
                    onReadAnother()
                },
                modifier = Modifier.weight(1f)
            ) {
                Text("Try Again")
            }
        }
    }
}

@Composable
fun MenuButton(
    title: String,
    subtitle: String,
    icon: ImageVector,
    onClick: () -> Unit = {},
    modifier: Modifier = Modifier
) {
    val context = androidx.compose.ui.platform.LocalContext.current
    Card(
        modifier = modifier
            .fillMaxWidth()
            .clickable {
                performButtonHaptic(context)
                onClick()
            },
        shape = RoundedCornerShape(12.dp),
        colors = CardDefaults.cardColors(
            containerColor = Color.White
        ),
        elevation = CardDefaults.cardElevation(defaultElevation = 2.dp)
    ) {
        Row(
            modifier = Modifier
                .fillMaxWidth()
                .padding(16.dp),
            verticalAlignment = Alignment.CenterVertically,
            horizontalArrangement = Arrangement.spacedBy(16.dp)
        ) {
            Box(
                modifier = Modifier
                    .size(48.dp)
                    .background(
                        color = Color(0xFFE3F2FD),
                        shape = RoundedCornerShape(10.dp)
                    ),
                contentAlignment = Alignment.Center
            ) {
                Icon(
                    imageVector = icon,
                    contentDescription = null,
                    tint = Color(0xFF1976D2),
                    modifier = Modifier.size(28.dp)
                )
            }
            Column(
                modifier = Modifier.weight(1f),
                verticalArrangement = Arrangement.spacedBy(4.dp)
            ) {
                Text(
                    text = title,
                    style = MaterialTheme.typography.titleMedium,
                    color = Color.Black
                )
                Text(
                    text = subtitle,
                    style = MaterialTheme.typography.bodySmall,
                    color = Color.Gray
                )
            }
            Icon(
                imageVector = Icons.Filled.ChevronRight,
                contentDescription = null,
                tint = Color.Gray,
                modifier = Modifier.size(24.dp)
            )
        }
    }
}

@Preview(showBackground = true)
@Composable
fun MainScreenPreview() {
    BeamioNDEFInitTheme {
        Box(modifier = Modifier.fillMaxSize()) {
            Column(
                modifier = Modifier
                    .align(Alignment.Center)
                    .fillMaxWidth()
                    .padding(horizontal = 16.dp),
                verticalArrangement = Arrangement.spacedBy(12.dp),
                horizontalAlignment = Alignment.CenterHorizontally
            ) {
                MenuButton(
                    title = "Initialization",
                    subtitle = "Configure NFC settings",
                    icon = Icons.Outlined.Build,
                    onClick = {}
                )
                MenuButton(
                    title = "Charge",
                    subtitle = "Accept NFC or QR code",
                    icon = Icons.Outlined.QrCode2,
                    onClick = {}
                )
            }
        }
    }
}