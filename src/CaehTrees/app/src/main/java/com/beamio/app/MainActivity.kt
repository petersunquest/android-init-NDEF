package com.beamio.app

import android.Manifest
import android.annotation.SuppressLint
import android.app.PendingIntent
import android.content.Context
import android.content.Intent
import android.content.pm.PackageManager
import android.net.Uri
import android.provider.Settings
import android.nfc.NfcAdapter
import android.nfc.Tag
import android.nfc.tech.Ndef
import android.os.Environment
import android.os.Build
import android.os.Bundle
import android.util.Log
import android.os.Handler
import android.os.Looper
import android.os.SystemClock
import android.graphics.Color
import android.util.Base64
import android.webkit.JavascriptInterface
import android.widget.FrameLayout
import android.webkit.PermissionRequest
import android.webkit.RenderProcessGoneDetail
import android.webkit.WebChromeClient
import android.webkit.ValueCallback
import android.webkit.WebResourceRequest
import android.webkit.WebSettings
import android.webkit.WebView
import android.webkit.WebViewClient
import androidx.activity.ComponentActivity
import androidx.activity.OnBackPressedCallback
import androidx.activity.enableEdgeToEdge
import androidx.activity.result.contract.ActivityResultContracts
import androidx.core.content.ContextCompat
import androidx.core.content.FileProvider
import androidx.core.view.WindowCompat
import androidx.core.view.WindowInsetsCompat
import androidx.core.view.WindowInsetsControllerCompat
import androidx.lifecycle.Lifecycle
import android.view.ViewGroup
import com.beamio.app.embedded.EmbeddedPwaConstants
import com.beamio.app.embedded.EmbeddedPwaHost
import java.util.concurrent.Callable
import java.util.concurrent.Executors
import java.util.concurrent.TimeUnit
import java.io.File
import org.json.JSONArray
import org.json.JSONObject

/**
 * Main document only: forces revalidation so WebView does not reuse a stale index.html from disk
 * (Android WebView often ignores response Cache-Control for the first load compared to Chrome).
 */
private val HOME_DOCUMENT_REQUEST_HEADERS = mapOf(
    "Cache-Control" to "no-cache",
    "Pragma" to "no-cache",
)

/**
 * SUN params from NDEF URL（与 android-NDEF MainActivity.readSunParamsFromNdef 一致）.
 * Template（e/c/m 全 0）返回 null。
 */
private data class SunParams(val uid: String, val e: String, val c: String, val m: String)

/** Return values for [CashTreesJsBridge.getNfcStatus] — consumed by PWA */
private object NfcStatusStrings {
    const val READY = "ready"
    const val NO_HARDWARE = "no_hardware"
    const val DISABLED = "disabled"
    /** Manifest 未声明 [android.Manifest.permission.NFC] 或安装包过旧时；需重装应用。 */
    const val PERMISSION_DENIED = "nfc_permission_denied"
}

class MainActivity : ComponentActivity() {

    companion object {
        @Volatile
        private var activeInstance: MainActivity? = null

        /** True while the WebView activity exists in this process. A cold FCM wake has no instance. */
        fun isRunning(): Boolean = activeInstance != null

        /**
         * Bring the Consumer shell to the foreground so its PWA can reconnect
         * to the mailbox and report a verified voice offer through the bridge.
         *
         * This deliberately carries no call identity or offer data. The native
         * side only wakes the shell; caller identity remains PWA-decrypted and
         * is delivered one-way through reportIncomingSystemCall().
         */
        fun wakeConsumerShell(context: Context) {
            if (isRunning()) {
                requestMailboxWake()
                Log.i("BeamioVoiceCall", "Mailbox wake delivered without covering the incoming window")
                return
            }
            Log.i("BeamioVoiceCall", "Shell start waits until the incoming window is showing")
        }

        /** Wake the PWA mailbox listener without reordering activities. */
        fun requestMailboxWake() {
            val activity = activeInstance ?: return
            activity.runOnUiThread {
                activity.intent.putExtra(BeamioTelecomService.EXTRA_WAKE_FOR_CALL, true)
                activity.mailboxWakeDispatchAttempt = 0
                activity.pendingSystemCallHandler.removeCallbacks(activity.mailboxWakeDispatchRunnable)
                activity.pendingSystemCallHandler.post(activity.mailboxWakeDispatchRunnable)
            }
        }

        fun dispatchSystemCallAction(
            action: String,
            callId: String,
            sessionId: String = "",
            context: Context? = null,
        ) {
            // Persist user actions until the PWA listener is ready. Caller
            // identity is never requested from or supplied by the native side;
            // it arrives only through reportIncomingSystemCall from the PWA.
            val activity = activeInstance
            if (activity == null) {
                if (context != null) {
                    BeamioTelecomService.savePendingSystemCallAction(
                        context,
                        action,
                        callId,
                        sessionId,
                    )
                    Log.i(
                        "BeamioVoiceCall",
                        "queued system call action before WebView activity " +
                            "action=$action callIdPresent=${callId.isNotBlank()}",
                    )
                } else {
                    Log.w(
                        "BeamioVoiceCall",
                        "dropped system call action without context action=$action",
                    )
                }
                return
            }
            activity.runOnUiThread {
                // Keep the action persisted until the WebView has actually
                // accepted the event. Cold starts and an uninitialised
                // WebView must be retried by the pending-action dispatcher.
                if (!activity::webView.isInitialized) return@runOnUiThread
                activity.dispatchAndroidBridgeJsonToWeb(
                    JSONObject()
                        .put("action", action)
                        .put("callId", callId)
                        .put("sessionId", sessionId),
                ) {
                    context?.let { BeamioTelecomService.clearPendingSystemCallAction(it) }
                }
            }
        }

        private val ALLOWED_EXTERNAL_URL_SCHEMES = setOf(
            "http", "https", "mailto", "tel",
            "metamask", "cbwallet", "coinbase", "base",
            "okx", "okex", "tpdapp", "tpoutside", "phantom",
        )
    }

    private lateinit var webView: WebView
    private lateinit var embeddedPwaHost: EmbeddedPwaHost
    private lateinit var rootLayout: FrameLayout
    private val pendingSystemCallHandler = Handler(Looper.getMainLooper())
    private var pendingSystemCallDispatchAttempt = 0
    private var embeddedPwaUpdateReplayAttempt = 0
    private val embeddedPwaUpdateReplayRunnable = object : Runnable {
        override fun run() {
            if (!useEmbeddedPwa || !::webView.isInitialized || !::embeddedPwaHost.isInitialized) {
                embeddedPwaUpdateReplayAttempt = 0
                return
            }
            val pending = embeddedPwaHost.bundleStore.pendingUpdateVersion()
            if (pending.isNullOrBlank() || embeddedPwaUpdateReplayAttempt >= 8) {
                embeddedPwaUpdateReplayAttempt = 0
                return
            }
            embeddedPwaUpdateReplayAttempt += 1
            Log.i(
                "BeamioEmbeddedPwa",
                "replaying pending OTA event attempt=$embeddedPwaUpdateReplayAttempt pending=$pending",
            )
            dispatchEmbeddedPwaUpdateAvailable(
                embeddedPwaHost.bundleStore.activeVersion(),
                pending,
            )
            pendingSystemCallHandler.postDelayed(
                this,
                minOf(2000L, 250L + embeddedPwaUpdateReplayAttempt * 250L),
            )
        }
    }
    private var mailboxWakeDispatchAttempt = 0
    private val mailboxWakeDispatchRunnable = object : Runnable {
        override fun run() {
            if (!intent.getBooleanExtra(BeamioTelecomService.EXTRA_WAKE_FOR_CALL, false)) {
                mailboxWakeDispatchAttempt = 0
                return
            }
            if (mailboxWakeDispatchAttempt >= 12) {
                Log.w("BeamioVoiceCall", "mailbox wake dispatch exhausted")
                intent.removeExtra(BeamioTelecomService.EXTRA_WAKE_FOR_CALL)
                mailboxWakeDispatchAttempt = 0
                return
            }
            mailboxWakeDispatchAttempt += 1
            if (::webView.isInitialized) {
                Log.i(
                    "BeamioVoiceCall",
                    "dispatching mailbox wake attempt=$mailboxWakeDispatchAttempt",
                )
                dispatchAndroidBridgeJsonToWeb(
                    JSONObject()
                        .put("action", "mailboxWake")
                        .put("reason", "incomingCall"),
                )
            }
            pendingSystemCallHandler.postDelayed(
                this,
                minOf(1500L, 250L + mailboxWakeDispatchAttempt * 125L),
            )
        }
    }
    private var showActiveCallDispatchAttempt = 0
    private val showActiveCallRunnable = object : Runnable {
        override fun run() {
            if (!intent.getBooleanExtra(BeamioTelecomService.EXTRA_SHOW_ACTIVE_CALL, false)) {
                showActiveCallDispatchAttempt = 0
                return
            }
            if (!::webView.isInitialized) {
                showActiveCallDispatchAttempt += 1
                if (showActiveCallDispatchAttempt >= 12) {
                    intent.removeExtra(BeamioTelecomService.EXTRA_SHOW_ACTIVE_CALL)
                    showActiveCallDispatchAttempt = 0
                } else {
                    pendingSystemCallHandler.postDelayed(this, 250L)
                }
                return
            }
            showActiveCallDispatchAttempt += 1
            Log.i(
                "BeamioVoiceCall",
                "dispatching showActiveVoiceCall attempt=$showActiveCallDispatchAttempt",
            )
            dispatchAndroidBridgeJsonToWeb(
                JSONObject()
                    .put("action", "showActiveVoiceCall")
                    .put("callId", intent.getStringExtra(BeamioTelecomService.EXTRA_CALL_ID).orEmpty())
                    .put("sessionId", intent.getStringExtra(BeamioTelecomService.EXTRA_SESSION_ID).orEmpty()),
            )
            if (showActiveCallDispatchAttempt >= 4) {
                intent.removeExtra(BeamioTelecomService.EXTRA_SHOW_ACTIVE_CALL)
                showActiveCallDispatchAttempt = 0
                return
            }
            pendingSystemCallHandler.postDelayed(this, 350L)
        }
    }

    private var lastShowActiveCallRequestAt = 0L

    private fun requestShowActiveCall(source: Intent?) {
        if (source?.getBooleanExtra(BeamioTelecomService.EXTRA_SHOW_ACTIVE_CALL, false) != true) return
        val now = SystemClock.elapsedRealtime()
        if (now - lastShowActiveCallRequestAt < 1500L) return
        lastShowActiveCallRequestAt = now
        intent.putExtra(
            BeamioTelecomService.EXTRA_SHOW_ACTIVE_CALL,
            true,
        )
        intent.putExtra(
            BeamioTelecomService.EXTRA_CALL_ID,
            source.getStringExtra(BeamioTelecomService.EXTRA_CALL_ID).orEmpty(),
        )
        intent.putExtra(
            BeamioTelecomService.EXTRA_SESSION_ID,
            source.getStringExtra(BeamioTelecomService.EXTRA_SESSION_ID).orEmpty(),
        )
        showActiveCallDispatchAttempt = 0
        pendingSystemCallHandler.removeCallbacks(showActiveCallRunnable)
        pendingSystemCallHandler.post(showActiveCallRunnable)
    }
    private val pendingSystemCallDispatchRunnable = object : Runnable {
        override fun run() {
            val pending = BeamioTelecomService.peekPendingSystemCallAction(this@MainActivity)
            if (pending == null || pendingSystemCallDispatchAttempt >= 12) {
                pendingSystemCallDispatchAttempt = 0
                return
            }
            pendingSystemCallDispatchAttempt += 1
            dispatchPendingSystemCallAction()
            pendingSystemCallHandler.postDelayed(
                this,
                minOf(1500L, 250L + pendingSystemCallDispatchAttempt * 125L),
            )
        }
    }

    @Volatile
    private var useEmbeddedPwa = false

    /** Consumer `beamio://open?…` → HTTPS `/app/` until WebView is mounted. */
    @Volatile
    private var pendingDeepLinkHttps: Uri? = null

    /** An explicit intent deep link already drove the WebView; a later install-referrer link must not replace it. */
    @Volatile
    private var deepLinkApplied = false

    private val bootstrapExecutor = Executors.newSingleThreadExecutor()

    private var fullScreenIntentSettingsLaunched = false

    /** WebView getUserMedia 与 [onPermissionRequest] 同时到达时需先跑完系统 CAMERA / RECORD_AUDIO */
    private var pendingWebPermissionRequest: PermissionRequest? = null
    private var pendingFileBytes: ByteArray? = null
    private var pendingFileRequestId: String = ""
    private var pendingFileChooserCallback: ValueCallback<Array<Uri>>? = null
    private var pendingFileChooserCameraUri: Uri? = null
    private var pendingCameraRequestId: String = ""
    private var pendingCameraOutputUri: Uri? = null

    private var nfcAdapter: NfcAdapter? = null

    /** 前台优先接收 NFC，阻断系统 Tag Dispatcher（避免后台打开浏览器等）；未在 PWA 发起的读卡会话中时仅消费、不冒泡。 */
    private var nfcForegroundPendingIntent: PendingIntent? = null

    @Volatile
    private var nfcBindSessionActive: Boolean = false

    /**
     * PWA asked to link an NFC card. [onPause] drops the radio (required while
     * not resumed) but must not tell the page the scan ended — that callback is
     * often dropped while the WebView is pausing, which left “Waiting...” up
     * forever with the reader already off. [onResume] re-arms until a tag,
     * cancel, or [onStop].
     */
    @Volatile
    private var nfcBindKeepAlive: Boolean = false

    private var nfcRearmBurst: Int = 0
    private var nfcLastArmElapsedMs: Long = 0L
    private val nfcReadExecutor = Executors.newSingleThreadExecutor()

    @Volatile
    private var pendingQrScanRequestId: String? = null

    @Volatile
    private var pendingQrScanAction: String = "scanQr"

    @Volatile
    private var pendingQrScanFilter: String = GeneralQRScannerActivity.FILTER_ANY

    private var pendingQrScanStartedAtMs: Long = 0L
    private var pendingQrScanTransientRetryCount: Int = 0
    private val mainHandler = Handler(Looper.getMainLooper())

    private val enableNfcForegroundDispatchRunnable = Runnable { maybeEnableNfcForegroundDispatch() }

    private val requestWebViewMediaPermissions = registerForActivityResult(
        ActivityResultContracts.RequestMultiplePermissions(),
    ) { _ ->
        val req = pendingWebPermissionRequest
        pendingWebPermissionRequest = null
        if (req == null) return@registerForActivityResult
        grantWebViewMediaRequest(req)
    }

    private val requestNativeCameraPermission = registerForActivityResult(
        ActivityResultContracts.RequestPermission(),
    ) { granted ->
        val requestId = pendingCameraRequestId
        pendingCameraRequestId = ""
        if (granted) {
            launchNativeVideoCapture(requestId)
        } else {
            dispatchAndroidBridgeJsonToWeb(
                JSONObject().put("action", "cameraCapture").put("ok", false)
                    .put("requestId", requestId).put("error", "camera_permission_denied"),
            )
        }
    }

    private val nativeCameraLauncher = registerForActivityResult(
        ActivityResultContracts.StartActivityForResult(),
    ) { result ->
        val requestId = pendingCameraRequestId
        val outputUri = pendingCameraOutputUri
        pendingCameraRequestId = ""
        pendingCameraOutputUri = null
        if (result.resultCode != RESULT_OK || outputUri == null) {
            dispatchAndroidBridgeJsonToWeb(
                JSONObject().put("action", "cameraCapture").put("ok", false)
                    .put("requestId", requestId).put("error", "cancelled"),
            )
            return@registerForActivityResult
        }
        dispatchVideoUriToWeb(outputUri, requestId)
    }

    private val fileChooserLauncher = registerForActivityResult(
        ActivityResultContracts.StartActivityForResult(),
    ) { result ->
        val callback = pendingFileChooserCallback
        pendingFileChooserCallback = null
        val cameraUri = pendingFileChooserCameraUri
        pendingFileChooserCameraUri = null
        if (result.resultCode != RESULT_OK) {
            callback?.onReceiveValue(null)
            return@registerForActivityResult
        }
        if (cameraUri != null) {
            callback?.onReceiveValue(arrayOf(cameraUri))
            return@registerForActivityResult
        }
        val data = result.data
        val selectedUris = buildList {
            val clipData = data?.clipData
            if (clipData != null) {
                for (index in 0 until clipData.itemCount) {
                    clipData.getItemAt(index).uri?.let(::add)
                }
            } else {
                data?.data?.let(::add)
            }
        }
        callback?.onReceiveValue(selectedUris.takeIf { it.isNotEmpty() }?.toTypedArray())
    }

    private val generalQrScannerLauncher = registerForActivityResult(
        ActivityResultContracts.StartActivityForResult(),
    ) { result ->
        val requestId = pendingQrScanRequestId.orEmpty()
        val bridgeAction = pendingQrScanAction
        val filter = pendingQrScanFilter
        val elapsedMs = SystemClock.elapsedRealtime() - pendingQrScanStartedAtMs
        val explicitError = result.data?.getStringExtra(GeneralQRScannerActivity.RESULT_ERROR)
        pendingQrScanRequestId = null
        pendingQrScanAction = "scanQr"
        pendingQrScanFilter = GeneralQRScannerActivity.FILTER_ANY

        when {
            result.resultCode == RESULT_OK -> {
                pendingQrScanTransientRetryCount = 0
                val text = result.data?.getStringExtra(GeneralQRScannerActivity.RESULT_TEXT)?.trim().orEmpty()
                if (text.isNotEmpty()) {
                    dispatchAndroidBridgeJsonToWeb(
                        JSONObject()
                            .put("action", bridgeAction)
                            .put("ok", true)
                            .put("requestId", requestId)
                            .apply {
                                if (bridgeAction == "scanRecoveryQr") {
                                    put("recoveryCode", text)
                                } else {
                                    put("text", text)
                                }
                            },
                    )
                } else {
                    dispatchAndroidBridgeScanError(requestId, bridgeAction, "qr_not_found")
                }
            }
            explicitError == null && elapsedMs in 0L..1200L && pendingQrScanTransientRetryCount < 1 -> {
                pendingQrScanTransientRetryCount += 1
                mainHandler.post {
                    launchGeneralQrScanner(
                        requestId = requestId,
                        bridgeAction = bridgeAction,
                        filter = filter,
                    )
                }
            }
            else -> {
                pendingQrScanTransientRetryCount = 0
                dispatchAndroidBridgeScanError(requestId, bridgeAction, explicitError ?: "cancelled")
            }
        }
    }

    private val createFileDocumentLauncher = registerForActivityResult(
        ActivityResultContracts.CreateDocument("application/octet-stream"),
    ) { uri ->
        val bytes = pendingFileBytes
        pendingFileBytes = null
        val requestId = pendingFileRequestId
        pendingFileRequestId = ""
        if (uri != null && bytes != null) {
            try {
                contentResolver.openOutputStream(uri)?.use { it.write(bytes) }
                dispatchAndroidBridgeJsonToWeb(JSONObject().put("action", "saveFile").put("ok", true).put("requestId", requestId))
            } catch (_: Exception) {
                dispatchAndroidBridgeJsonToWeb(JSONObject().put("action", "saveFile").put("ok", false).put("requestId", requestId).put("error", "file_write_failed"))
            }
        } else {
            dispatchAndroidBridgeJsonToWeb(JSONObject().put("action", "saveFile").put("ok", false).put("requestId", requestId).put("error", "cancelled"))
        }
    }

    private fun androidPermissionsForWebMedia(request: PermissionRequest): List<String> {
        val perms = linkedSetOf<String>()
        for (res in request.resources) {
            when (res) {
                PermissionRequest.RESOURCE_VIDEO_CAPTURE -> perms.add(Manifest.permission.CAMERA)
                PermissionRequest.RESOURCE_AUDIO_CAPTURE -> perms.add(Manifest.permission.RECORD_AUDIO)
            }
        }
        return perms.toList()
    }

    private fun hasOsPermission(permission: String): Boolean {
        return ContextCompat.checkSelfPermission(this, permission) == PackageManager.PERMISSION_GRANTED
    }

    private fun grantWebViewMediaRequest(request: PermissionRequest) {
        val allow = request.resources.filter { res ->
            when (res) {
                PermissionRequest.RESOURCE_VIDEO_CAPTURE -> hasOsPermission(Manifest.permission.CAMERA)
                PermissionRequest.RESOURCE_AUDIO_CAPTURE -> hasOsPermission(Manifest.permission.RECORD_AUDIO)
                else -> false
            }
        }.toTypedArray()
        if (allow.isEmpty()) {
            request.deny()
        } else {
            request.grant(allow)
        }
    }

    private val webChromeClient: WebChromeClient = object : WebChromeClient() {
        override fun onShowFileChooser(
            webView: WebView?,
            filePathCallback: ValueCallback<Array<Uri>>?,
            fileChooserParams: FileChooserParams?,
        ): Boolean {
            pendingFileChooserCallback?.onReceiveValue(null)
            pendingFileChooserCallback = filePathCallback
            pendingFileChooserCameraUri = null
            if (filePathCallback == null || fileChooserParams == null) {
                pendingFileChooserCallback = null
                return false
            }
            return try {
                val acceptsVideo = fileChooserParams.acceptTypes.any {
                    it.lowercase().contains("video")
                }
                val intent = if (fileChooserParams.isCaptureEnabled && acceptsVideo) {
                    createVideoCaptureIntent().also { pendingFileChooserCameraUri = pendingCameraOutputUri }
                } else {
                    fileChooserParams.createIntent().apply {
                        addFlags(Intent.FLAG_GRANT_READ_URI_PERMISSION)
                    }
                }
                fileChooserLauncher.launch(intent)
                true
            } catch (_: Exception) {
                pendingFileChooserCallback = null
                pendingFileChooserCameraUri = null
                false
            }
        }

        override fun onPermissionRequest(request: PermissionRequest) {
            runOnUiThread {
                val needed = androidPermissionsForWebMedia(request)
                if (needed.isEmpty()) {
                    request.deny()
                    return@runOnUiThread
                }
                val missing = needed.filterNot(::hasOsPermission)
                if (missing.isEmpty()) {
                    grantWebViewMediaRequest(request)
                } else {
                    pendingWebPermissionRequest = request
                    requestWebViewMediaPermissions.launch(missing.toTypedArray())
                }
            }
        }

        /** Fallback: Chromium-native console lines (subframes / pre-bridge). */
        override fun onConsoleMessage(consoleMessage: android.webkit.ConsoleMessage?): Boolean {
            consoleMessage ?: return false
            CashTreesWebConsoleRelay.handleWebViewConsoleMessage(
                line = consoleMessage.message() ?: "",
                level = consoleMessage.messageLevel(),
                source = consoleMessage.sourceId(),
                lineNumber = consoleMessage.lineNumber(),
            )
            return false
        }
    }

    private fun createVideoCaptureIntent(): Intent {
        val directory = getExternalFilesDir(Environment.DIRECTORY_MOVIES) ?: filesDir
        val outputFile = File.createTempFile("beamio-camera-", ".mp4", directory)
        val outputUri = FileProvider.getUriForFile(
            this,
            "${applicationContext.packageName}.fileprovider",
            outputFile,
        )
        pendingCameraOutputUri = outputUri
        return Intent(android.provider.MediaStore.ACTION_VIDEO_CAPTURE).apply {
            putExtra(android.provider.MediaStore.EXTRA_OUTPUT, outputUri)
            putExtra(android.provider.MediaStore.EXTRA_VIDEO_QUALITY, 1)
            addFlags(Intent.FLAG_GRANT_WRITE_URI_PERMISSION or Intent.FLAG_GRANT_READ_URI_PERMISSION)
        }
    }

    private fun launchNativeVideoCapture(requestId: String) {
        try {
            val intent = createVideoCaptureIntent().apply {
                putExtra("android.intent.extra.durationLimit", 120)
            }
            pendingCameraRequestId = requestId
            nativeCameraLauncher.launch(intent)
        } catch (_: Exception) {
            pendingCameraRequestId = ""
            pendingCameraOutputUri = null
            dispatchAndroidBridgeJsonToWeb(
                JSONObject().put("action", "cameraCapture").put("ok", false)
                    .put("requestId", requestId).put("error", "camera_unavailable"),
            )
        }
    }

    private fun dispatchVideoUriToWeb(uri: Uri, requestId: String) {
        // Do not inject the complete video data URL into WebView. Large
        // evaluateJavascript payloads can be rejected after recording, leaving
        // the PWA with a generic camera error. Read off the UI thread, then
        // deliver the base64 body using the same chunk protocol as iOS.
        Thread {
            try {
                val bytes = contentResolver.openInputStream(uri)?.use { it.readBytes() }
                if (bytes == null || bytes.isEmpty()) throw IllegalStateException("empty_video")
                val mime = contentResolver.getType(uri) ?: "video/mp4"
                val encoded = Base64.encodeToString(bytes, Base64.NO_WRAP)
                val chunkSize = 64 * 1024

                val payloads = mutableListOf<JSONObject>()
                payloads += JSONObject()
                    .put("action", "cameraCaptureStart")
                    .put("ok", true)
                    .put("requestId", requestId)
                    .put("mimeType", mime)
                    var offset = 0
                    var chunkIndex = 0
                    while (offset < encoded.length) {
                        val end = minOf(offset + chunkSize, encoded.length)
                        payloads += JSONObject()
                            .put("action", "cameraCaptureChunk")
                            .put("requestId", requestId)
                            .put("index", chunkIndex)
                            .put("data", encoded.substring(offset, end))
                        offset = end
                        chunkIndex += 1
                    }
                    payloads += JSONObject()
                        .put("action", "cameraCaptureEnd")
                        .put("ok", true)
                        .put("requestId", requestId)
                    runOnUiThread { dispatchAndroidBridgeJsonSequenceToWeb(payloads) }
            } catch (_: Exception) {
                runOnUiThread {
                    dispatchAndroidBridgeJsonToWeb(
                        JSONObject().put("action", "cameraCapture").put("ok", false)
                            .put("requestId", requestId).put("error", "video_read_failed"),
                    )
                }
            } finally {
                try {
                    contentResolver.delete(uri, null, null)
                } catch (_: Exception) {
                }
            }
        }.start()
    }

    private fun hasNfcPermission(): Boolean =
        ContextCompat.checkSelfPermission(this, Manifest.permission.NFC) ==
            PackageManager.PERMISSION_GRANTED

    private fun queryNfcStatus(): String {
        if (!hasNfcPermission()) return NfcStatusStrings.PERMISSION_DENIED
        val adapter = NfcAdapter.getDefaultAdapter(this) ?: return NfcStatusStrings.NO_HARDWARE
        return if (adapter.isEnabled) NfcStatusStrings.READY else NfcStatusStrings.DISABLED
    }

    /** @return `PendingIntent.FLAG_ALLOW_BACKGROUND_ACTIVITY_START` if present on device, else 0 */
    private fun pendingIntentAllowBackgroundActivityStartFlag(): Int {
        if (Build.VERSION.SDK_INT < 34) return 0
        return try {
            PendingIntent::class.java.getField("FLAG_ALLOW_BACKGROUND_ACTIVITY_START").getInt(null)
        } catch (_: Throwable) {
            0
        }
    }

    private fun createNfcForegroundPendingIntent(): PendingIntent {
        nfcForegroundPendingIntent?.let { return it }
        val launch = Intent(this, javaClass).addFlags(Intent.FLAG_ACTIVITY_SINGLE_TOP)
        var flags = PendingIntent.FLAG_UPDATE_CURRENT
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.S) {
            flags = flags or PendingIntent.FLAG_MUTABLE
        }
        // Android 14+ OEM：NFC 服务用本 PI 投递 NDEF 时可能出现 BAL_BLOCK（logcat「Background activity launch blocked」）。
        // 该 flag 在部分 SDK 的公开 android.jar 中不可见，故用反射读取运行时 framework 字段。
        flags = flags or pendingIntentAllowBackgroundActivityStartFlag()
        val pi = PendingIntent.getActivity(this, 0, launch, flags)
        nfcForegroundPendingIntent = pi
        return pi
    }

    /** 与 Reader Mode 互斥：同时注册会导致部分机型上标签仍被系统 Tag Dispatcher 处理。 */
    private fun disableNfcForegroundDispatchQuiet() {
        try {
            NfcAdapter.getDefaultAdapter(this)?.disableForegroundDispatch(this)
        } catch (_: Exception) {
        }
    }

    /**
     * App 在前台且非读卡会话时注册 Foreground Dispatch，优先于系统默认识别/浏览器打开 NDEF URI。
     * 纯 PWA 流程外的贴卡仅在 [onNewIntent] 内消费，不向下游冒泡。
     */
    private fun maybeEnableNfcForegroundDispatch() {
        if (!hasNfcPermission()) return
        if (nfcBindSessionActive) return
        if (!lifecycle.currentState.isAtLeast(Lifecycle.State.RESUMED)) return
        val adapter = nfcAdapter ?: NfcAdapter.getDefaultAdapter(this) ?: return
        if (!adapter.isEnabled) return
        try {
            adapter.enableForegroundDispatch(
                this,
                createNfcForegroundPendingIntent(),
                null,
                null,
            )
        } catch (_: Exception) {
        }
    }

    /**
     * Reader 结束后立刻重新注册前台分发（下一消息循环即执行），避免出现「Reader 已关、FD 尚未开」的空窗：
     * 该窗口内系统 Tag Dispatcher 会处理 NDEF https URI，常表现为**外部浏览器**打开 beamio.app。
     * 再在稍晚补一次 enable，减轻部分机型 HAL 释放 RF 与 enableForegroundDispatch 的竞态。
     */
    private fun reclaimNfcForegroundDispatchAfterReader() {
        mainHandler.removeCallbacks(enableNfcForegroundDispatchRunnable)
        mainHandler.post {
            maybeEnableNfcForegroundDispatch()
            mainHandler.postDelayed(enableNfcForegroundDispatchRunnable, 450L)
        }
    }

    /** Called from JS on UI thread */
    private fun armNfcPhysicalCardRead() {
        Log.i("BeamioNfc", "arm keepAlive=$nfcBindKeepAlive session=$nfcBindSessionActive")
        val now = SystemClock.elapsedRealtime()
        nfcRearmBurst = if (now - nfcLastArmElapsedMs < 500L) nfcRearmBurst + 1 else 0
        nfcLastArmElapsedMs = now
        if (nfcRearmBurst > 3) {
            Log.i("BeamioNfc", "arm aborted rearm burst=$nfcRearmBurst")
            nfcBindKeepAlive = false
            nfcBindSessionActive = false
            dispatchNfcJsonToWeb(JSONObject().put("ok", false).put("error", "nfc_reader_failed"))
            reclaimNfcForegroundDispatchAfterReader()
            return
        }
        val adapter = NfcAdapter.getDefaultAdapter(this)
        if (adapter == null) {
            nfcBindKeepAlive = false
            dispatchNfcJsonToWeb(JSONObject().put("ok", false).put("error", "no_hardware"))
            return
        }
        if (!adapter.isEnabled) {
            nfcBindKeepAlive = false
            dispatchNfcJsonToWeb(JSONObject().put("ok", false).put("error", "nfc_disabled"))
            return
        }
        if (!hasNfcPermission()) {
            nfcBindKeepAlive = false
            dispatchNfcJsonToWeb(
                JSONObject().put("ok", false).put("error", "nfc_permission_denied"),
            )
            return
        }
        nfcBindKeepAlive = true
        nfcBindSessionActive = true
        disableNfcForegroundDispatchQuiet()
        // 不得使用 FLAG_READER_SKIP_NDEF_CHECK：该标志会使标签像无 NDEF 一样交付，
        // Ndef.get(tag) 读不到 SUN（e,c,m），仅余硬件 UID；getUIDAssets 对 NTAG 类 UID 需 SUN，会与 android-NDEF 前台分发行为不一致。
        var readerFlags =
            NfcAdapter.FLAG_READER_NFC_A or
                NfcAdapter.FLAG_READER_NFC_B or
                NfcAdapter.FLAG_READER_NFC_F or
                NfcAdapter.FLAG_READER_NFC_V
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q) {
            readerFlags = readerFlags or NfcAdapter.FLAG_READER_NO_PLATFORM_SOUNDS
        }
        val extras = Bundle().apply {
            putInt(NfcAdapter.EXTRA_READER_PRESENCE_CHECK_DELAY, 250)
        }
        try {
            adapter.enableReaderMode(
                this,
                { tag -> onNfcTagForBind(tag) },
                readerFlags,
                extras,
            )
        } catch (t: Throwable) {
            Log.i("BeamioNfc", "enableReaderMode failed", t)
            nfcBindKeepAlive = false
            nfcBindSessionActive = false
            dispatchNfcJsonToWeb(JSONObject().put("ok", false).put("error", "nfc_reader_failed"))
            reclaimNfcForegroundDispatchAfterReader()
        }
    }

    private fun onNfcTagForBind(tag: Tag) {
        Log.i("BeamioNfc", "tag callback session=$nfcBindSessionActive keepAlive=$nfcBindKeepAlive")
        if (!nfcBindSessionActive && !nfcBindKeepAlive) return
        // Stop re-arm before the NDEF read. A pause during connect must not
        // start a second reader session and drop this tag.
        nfcBindKeepAlive = false
        nfcBindSessionActive = false
        // 在 Reader 回调线程立刻读 NDEF；若推迟到主线程，部分机型上标签已 deactivate，SUN 丢失并触发 logcat「tag already deactivated」。
        val tagUidHex = tag.id?.joinToString("") { b -> "%02X".format(b) }.orEmpty()
        val (ndefUri, sun) =
            if (tagUidHex.isNotEmpty()) {
                readNdefUriAndSun(tag)
            } else {
                null to null
            }
        runOnUiThread {
            nfcAdapter?.disableReaderMode(this@MainActivity)
            try {
                if (tagUidHex.isEmpty()) {
                    dispatchNfcJsonToWeb(JSONObject().put("ok", false).put("error", "empty_tag_uid"))
                    return@runOnUiThread
                }
                val queryUid = sun?.uid ?: tagUidHex
                val json = JSONObject()
                    .put("ok", true)
                    .put("tagUidHex", tagUidHex)
                    .put("queryUid", queryUid)
                if (ndefUri != null) {
                    json.put("ndefUri", ndefUri)
                }
                if (sun != null) {
                    json.put(
                        "sun",
                        JSONObject()
                            .put("uid", sun.uid)
                            .put("e", sun.e)
                            .put("c", sun.c)
                            .put("m", sun.m),
                    )
                }
                dispatchNfcJsonToWeb(json)
            } finally {
                reclaimNfcForegroundDispatchAfterReader()
            }
        }
    }

    /** 从 NDEF URI 记录解析 SUN；模板（e/c/m 全 0）返回 null。 */
    private fun parseSunParamsFromNdefUrl(url: String): SunParams? {
        val uri = Uri.parse(url)
        val uid = uri.getQueryParameter("uid")?.trim() ?: return null
        val e = uri.getQueryParameter("e")?.trim() ?: return null
        val c = uri.getQueryParameter("c")?.trim() ?: return null
        val m = uri.getQueryParameter("m")?.trim() ?: return null
        if (e.length != 64 || c.length != 6 || m.length != 16) return null
        if (!e.matches(Regex("^[0-9a-fA-F]+$")) ||
            !c.matches(Regex("^[0-9a-fA-F]+$")) ||
            !m.matches(Regex("^[0-9a-fA-F]+$"))
        ) {
            return null
        }
        if (e.all { it == '0' } && c.all { it == '0' } && m.all { it == '0' }) {
            return null
        }
        return SunParams(uid, e, c, m)
    }

    /** Prefer the message already cached by reader mode. `Ndef.connect()` can hang and leave the link sheet on “Waiting...”. */
    private fun readNdefUriAndSun(tag: Tag): Pair<String?, SunParams?> {
        val ndef = Ndef.get(tag) ?: return null to null
        val cachedUrl = ndefRecordUrl(try { ndef.cachedNdefMessage } catch (_: Exception) { null })
        if (cachedUrl != null) return cachedUrl to parseSunParamsFromNdefUrl(cachedUrl)
        val future = nfcReadExecutor.submit(Callable { readConnectedNdef(ndef) })
        return try {
            future.get(1200, TimeUnit.MILLISECONDS)
        } catch (_: Exception) {
            future.cancel(true)
            null to null
        }
    }

    private fun readConnectedNdef(ndef: Ndef): Pair<String?, SunParams?> {
        return try {
            ndef.connect()
            val url = ndefRecordUrl(ndef.ndefMessage) ?: return null to null
            url to parseSunParamsFromNdefUrl(url)
        } catch (_: Exception) {
            null to null
        } finally {
            try {
                ndef.close()
            } catch (_: Exception) {
            }
        }
    }

    private fun ndefRecordUrl(message: android.nfc.NdefMessage?): String? {
        return message?.records?.firstNotNullOfOrNull { record ->
            try {
                record.toUri()?.toString()
            } catch (_: Exception) {
                null
            }
        }
    }

    private fun disarmNfcReader(notifyWeb: Boolean, error: String?) {
        Log.i("BeamioNfc", "disarm notify=$notifyWeb error=$error")
        nfcBindKeepAlive = false
        nfcBindSessionActive = false
        runOnUiThread {
            try {
                NfcAdapter.getDefaultAdapter(this@MainActivity)?.disableReaderMode(this@MainActivity)
                if (notifyWeb && error != null) {
                    dispatchNfcJsonToWeb(JSONObject().put("ok", false).put("error", error))
                }
            } finally {
                reclaimNfcForegroundDispatchAfterReader()
            }
        }
    }

    private fun dispatchNfcJsonToWeb(json: JSONObject) {
        if (!::webView.isInitialized) return
        val payload = json.toString()
        val js =
            "(function(){try{var d=" + payload + ";" +
                "try{if(typeof window.__cashTreesNfcBindResult==='function'){window.__cashTreesNfcBindResult(d);}}catch(e){}" +
                "window.dispatchEvent(new CustomEvent('cashtreesnfc',{detail:d}));" +
                "}catch(e){}})();"
        webView.evaluateJavascript(js, null)
    }

    private fun dispatchAndroidBridgeScanError(requestId: String, action: String, error: String) {
        dispatchAndroidBridgeJsonToWeb(
            JSONObject()
                .put("action", action)
                .put("ok", false)
                .put("requestId", requestId)
                .put("error", error),
        )
    }

    /** PWA bridge results — same shape as iOS `cashtreesios` CustomEvent detail. */
    private fun dispatchAndroidBridgeJsonToWeb(json: JSONObject, completion: (() -> Unit)? = null) {
        if (!::webView.isInitialized) return
        val payload = json.toString()
        val js =
            "(function(){try{var d=" + payload + ";" +
                "window.dispatchEvent(new CustomEvent('cashtreesandroid',{detail:d}));" +
                "if(d&&d.ok&&(d.action==='scanQr'||d.action==='scanRecoveryQr')){try{window.focus&&window.focus();}catch(e){}}" +
                "}catch(e){}})();"
        webView.evaluateJavascript(js) { completion?.invoke() }
    }

    private fun dispatchAndroidBridgeJsonSequenceToWeb(payloads: List<JSONObject>) {
        if (payloads.isEmpty() || !::webView.isInitialized) return
        var index = 0
        fun sendNext() {
            if (index >= payloads.size) return
            val payload = payloads[index++]
            dispatchAndroidBridgeJsonToWeb(payload) { sendNext() }
        }
        sendNext()
    }

    private fun launchGeneralQrScanner(requestId: String, bridgeAction: String, filter: String) {
        pendingQrScanRequestId = requestId
        pendingQrScanAction = bridgeAction
        pendingQrScanFilter = filter
        pendingQrScanStartedAtMs = SystemClock.elapsedRealtime()
        generalQrScannerLauncher.launch(
            GeneralQRScannerActivity.launchIntent(this, filter),
        )
    }

    private inner class CashTreesJsBridge {
        @JavascriptInterface
        fun getNfcStatus(): String = queryNfcStatus()

        @JavascriptInterface
        fun startPhysicalCardBind() {
            Log.i("BeamioNfc", "js startPhysicalCardBind")
            runOnUiThread { armNfcPhysicalCardRead() }
        }

        @JavascriptInterface
        fun cancelPhysicalCardBind() {
            disarmNfcReader(true, "cancelled")
        }

        /** Raw QR payload for global search / deep links — mirrors iOS `CashTreesIOS.scanQr`. */
        @JavascriptInterface
        fun scanQr(requestId: String) {
            runOnUiThread {
                launchGeneralQrScanner(
                    requestId = requestId.trim(),
                    bridgeAction = "scanQr",
                    filter = GeneralQRScannerActivity.FILTER_ANY,
                )
            }
        }

        /** Recovery-code-only filter — mirrors iOS `CashTreesIOS.scanRecoveryQr`. */
        @JavascriptInterface
        fun scanRecoveryQr(requestId: String) {
            runOnUiThread {
                launchGeneralQrScanner(
                    requestId = requestId.trim(),
                    bridgeAction = "scanRecoveryQr",
                    filter = GeneralQRScannerActivity.FILTER_RECOVERY,
                )
            }
        }

        /** Open http(s)/mailto/tel or catalog wallet schemes — mirrors iOS `CashTreesIOS.openURL`. */
        @JavascriptInterface
        fun openURL(url: String) {
            runOnUiThread { openExternalUrlFromBridge(url) }
        }

        /** Save a PWA blob through Android's system document picker. */
        @JavascriptInterface
        fun saveFile(json: String) {
            runOnUiThread { saveFileFromBridge(json) }
        }

        @JavascriptInterface
        fun startSystemCall(json: String) {
            runOnUiThread {
                val body = runCatching { JSONObject(json) }.getOrNull() ?: return@runOnUiThread
                BeamioTelecomService.startOutgoing(
                    this@MainActivity,
                    body.optString("callId"),
                    body.optString("displayName").ifBlank { body.optString("peerAddress") },
                )
            }
        }

        @JavascriptInterface
        fun reportIncomingSystemCall(json: String) {
            Log.i("BeamioVoiceCall", "WebView reportIncomingSystemCall received")
            runOnUiThread {
                val body = runCatching { JSONObject(json) }.getOrElse {
                    Log.e("BeamioVoiceCall", "Invalid reportIncomingSystemCall JSON", it)
                    return@runOnUiThread
                }
                Log.i(
                    "BeamioVoiceCall",
                    "WebView incoming call payload parsed callIdPresent=" +
                        body.optString("callId").isNotBlank() +
                        " sessionIdPresent=" + body.optString("sessionId").isNotBlank(),
                )
                Log.i(
                    "BeamioVoiceCall",
                    "WebView incoming caller fields displayNamePresent=" +
                        body.optString("displayName").isNotBlank() +
                        " peerAddressPresent=" +
                        body.optString("peerAddress").isNotBlank() +
                        " claimedTagPresent=" +
                        body.optString("claimedTag").isNotBlank(),
                )
                BeamioTelecomService.reportIncoming(
                    this@MainActivity,
                    body.optString("callId"),
                    body.optString("peerAddress"),
                    body.optString("displayName").ifBlank { body.optString("peerAddress") },
                    body.optString("sessionId"),
                    body.optString("claimedTag"),
                    body.optString("claimedAddress"),
                    body.optString("identityWarning"),
                )
            }
        }

        /** Called by the PWA after its cashtreesandroid listener is mounted. */
        @JavascriptInterface
        fun requestPendingSystemCallAction() {
            runOnUiThread {
                Log.i("BeamioVoiceCall", "PWA requested pending system call action")
                dispatchPendingSystemCallAction()
            }
        }

        @JavascriptInterface
        fun endSystemCall(json: String) {
            runOnUiThread {
                val body = runCatching { JSONObject(json) }.getOrNull() ?: return@runOnUiThread
                val callId = body.optString("callId")
                val sessionId = body.optString("sessionId")
                BeamioTelecomService.end(
                    this@MainActivity,
                    callId.ifBlank { sessionId },
                    sessionId,
                )
            }
        }

        /** Native video capture for the Chat Camera action. Android JS interfaces receive strings only. */
        @JavascriptInterface
        fun requestCameraCapture(json: String) {
            runOnUiThread {
                val requestId = try {
                    JSONObject(json).optString("requestId", "")
                } catch (_: Exception) {
                    ""
                }
                if (!hasOsPermission(Manifest.permission.CAMERA)) {
                    pendingCameraRequestId = requestId
                    requestNativeCameraPermission.launch(Manifest.permission.CAMERA)
                } else {
                    launchNativeVideoCapture(requestId)
                }
            }
        }

        /**
         * PWA catalog install probe. JSON `{ requestId, queries:[{ id, schemes[], packages[] }] }`.
         * Returns a JSON array of installed `id`s. Empty / bad JSON → MetaMask / Coinbase Wallet.
         */
        @JavascriptInterface
        fun queryInstalledApps(json: String): String {
            return try {
                val obj = JSONObject(json)
                val queries = obj.optJSONArray("queries")
                if (queries == null || queries.length() == 0) {
                    return legacyInstalledWalletIds().toString()
                }
                val ids = JSONArray()
                for (i in 0 until queries.length()) {
                    val q = queries.optJSONObject(i) ?: continue
                    val id = q.optString("id").trim().lowercase()
                    if (id.isEmpty()) continue
                    val packages = q.optJSONArray("packages") ?: continue
                    var installed = false
                    var j = 0
                    while (j < packages.length()) {
                        val pkg = packages.optString(j).trim()
                        if (pkg.isNotEmpty() && isWalletPackageInstalled(pkg)) {
                            installed = true
                            break
                        }
                        j += 1
                    }
                    if (installed) ids.put(id)
                }
                ids.toString()
            } catch (_: Exception) {
                legacyInstalledWalletIds().toString()
            }
        }

        /** Legacy no-arg probe — MetaMask / Coinbase Wallet only. */
        @JavascriptInterface
        fun listInstalledWalletApps(): String {
            return legacyInstalledWalletIds().toString()
        }

        /** Embedded PWA OTA — mirrors iOS `CashTreesIOS.getEmbeddedPwaVersion`. */
        @JavascriptInterface
        fun getEmbeddedPwaVersion(): String {
            if (!useEmbeddedPwa || !::embeddedPwaHost.isInitialized) return ""
            return embeddedPwaHost.bundleStore.activeVersion()
        }

        /** Embedded PWA OTA — mirrors iOS `CashTreesIOS.getEmbeddedPwaPendingVersion`. */
        @JavascriptInterface
        fun getEmbeddedPwaPendingVersion(): String {
            if (!useEmbeddedPwa || !::embeddedPwaHost.isInitialized) return ""
            return embeddedPwaHost.bundleStore.pendingUpdateVersion() ?: ""
        }

        /** Promote staged bundle and reload local PWA. */
        @JavascriptInterface
        fun applyEmbeddedPwaUpdate() {
            runOnUiThread { applyEmbeddedPwaUpdateFromBridge() }
        }

        /**
         * PWA → Native generic app state (footer badges, launcher icon badge).
         * Payload: JSON string `{ action:'publishAppState', state:{...} }` — mirrors iOS bridge.
         */
        @JavascriptInterface
        fun publishAppState(json: String) {
            runOnUiThread {
                CashTreesNativeAppStateBridge.applyFromJsonString(this@MainActivity, json)
            }
        }

        /**
         * PWA entered Chat (already foreground): drop offline FCM / local chat tray alerts.
         * Does not change unread — caller re-`publishAppState` badge if needed.
         */
        @JavascriptInterface
        fun clearOfflineChatAlerts() {
            runOnUiThread {
                CashTreesNativeAppStateBridge.clearOfflineChatAlerts(this@MainActivity)
            }
        }

        /**
         * PWA still running behind Home: local system notification + badge (not FCM).
         * Payload: JSON string `{ badge, title?, body? }`.
         */
        @JavascriptInterface
        fun notifyBackgroundChat(json: String) {
            runOnUiThread {
                CashTreesNativeAppStateBridge.notifyBackgroundChatFromJson(this@MainActivity, json)
            }
        }

        /**
         * Bind EOA for FCM registration — mirrors iOS `CashTreesIOS.bindPushIdentity`.
         * Payload: JSON string `{ eoa, pgpKeyId? }`.
         */
        @JavascriptInterface
        fun bindPushIdentity(json: String) {
            runOnUiThread {
                CashTreesPushRegistration.bindIdentityFromJson(this@MainActivity, json)
            }
        }

        /** PWA debug log → logcat (`PWA-JS` tag); mirrors iOS `CashTreesIOS.debugLog`. */
        @JavascriptInterface
        fun debugLog(level: String, message: String) {
            CashTreesWebConsoleRelay.handleBridgeConsoleLog(level, message)
        }
    }

    private fun isWalletPackageInstalled(packageName: String): Boolean {
        return try {
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.TIRAMISU) {
                packageManager.getPackageInfo(packageName, PackageManager.PackageInfoFlags.of(0))
            } else {
                @Suppress("DEPRECATION")
                packageManager.getPackageInfo(packageName, 0)
            }
            true
        } catch (_: PackageManager.NameNotFoundException) {
            false
        }
    }

    private fun legacyInstalledWalletIds(): JSONArray {
        val ids = JSONArray()
        if (isWalletPackageInstalled("io.metamask")) ids.put("metamask")
        if (
            isWalletPackageInstalled("org.toshi") ||
            isWalletPackageInstalled("com.coinbase.wallet")
        ) {
            ids.put("base")
        }
        return ids
    }

    private fun saveFileFromBridge(raw: String) {
        try {
            val body = JSONObject(raw)
            val dataUrl = body.optString("dataUrl", "")
            val comma = dataUrl.indexOf(',')
            val encoded = if (comma >= 0) dataUrl.substring(comma + 1) else dataUrl
            val bytes = Base64.decode(encoded, Base64.DEFAULT)
            if (bytes.isEmpty()) return
            pendingFileBytes = bytes
            pendingFileRequestId = body.optString("requestId", "")
            val filename = body.optString("filename", "download")
                .substringAfterLast('/')
                .substringAfterLast('\\')
                .ifBlank { "download" }
            createFileDocumentLauncher.launch(filename)
        } catch (_: Exception) {
            dispatchAndroidBridgeJsonToWeb(JSONObject().put("action", "saveFile").put("ok", false).put("error", "invalid_file_data"))
        }
    }

    private fun openExternalUrlFromBridge(raw: String) {
        val trimmed = raw.trim()
        if (trimmed.isEmpty()) return
        try {
            val uri = Uri.parse(trimmed)
            val scheme = uri.scheme?.lowercase() ?: return
            if (scheme !in ALLOWED_EXTERNAL_URL_SCHEMES) return
            startActivity(Intent(Intent.ACTION_VIEW, uri))
        } catch (_: Exception) {
        }
    }

    /**
     * Android 14+ protects USE_FULL_SCREEN_INTENT as a special app access.
     * It cannot be granted silently by an APK, so take the user directly to
     * Beamio's system-controlled permission page on the first launch.
     */
    private fun maybeOpenFullScreenIntentSettings() {
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.UPSIDE_DOWN_CAKE) return
        if (fullScreenIntentSettingsLaunched) return

        val notificationManager = getSystemService(android.app.NotificationManager::class.java)
            ?: return
        if (notificationManager.canUseFullScreenIntent()) return

        fullScreenIntentSettingsLaunched = true
        val intent = Intent(Settings.ACTION_MANAGE_APP_USE_FULL_SCREEN_INTENT).apply {
            data = Uri.parse("package:$packageName")
        }
        try {
            startActivity(intent)
            Log.i("BeamioVoiceCall", "Opened full-screen intent access for first launch")
        } catch (error: Exception) {
            Log.w("BeamioVoiceCall", "Full-screen intent settings unavailable", error)
            BeamioTelecomService.openIncomingCallSettings(this)
        }
    }

    private fun applyEmbeddedPwaUpdateFromBridge() {
        if (!useEmbeddedPwa || !::webView.isInitialized || !::embeddedPwaHost.isInitialized) {
            dispatchAndroidBridgeJsonToWeb(
                JSONObject()
                    .put("action", "applyEmbeddedPwaUpdate")
                    .put("ok", false)
                    .put("error", "embedded_pwa_unavailable"),
            )
            return
        }
        try {
            embeddedPwaHost.bundleStore.promoteStagingToActive()
            embeddedPwaHost.rebuildAssetLoader()
            val ver = embeddedPwaHost.bundleStore.activeVersion()
            embeddedPwaHost.injectVersionGlobals(webView)
            webView.loadUrl(EmbeddedPwaConstants.entryUrl, HOME_DOCUMENT_REQUEST_HEADERS)
            dispatchAndroidBridgeJsonToWeb(
                JSONObject()
                    .put("action", "applyEmbeddedPwaUpdate")
                    .put("ok", true)
                    .put("ver", ver),
            )
        } catch (e: Exception) {
            dispatchAndroidBridgeJsonToWeb(
                JSONObject()
                    .put("action", "applyEmbeddedPwaUpdate")
                    .put("ok", false)
                    .put("error", e.message ?: "Update failed"),
            )
        }
    }

    private fun dispatchEmbeddedPwaUpdateAvailable(currentVer: String, pendingVer: String) {
        Log.i(
            "BeamioEmbeddedPwa",
            "dispatching OTA event current=$currentVer pending=$pendingVer",
        )
        dispatchAndroidBridgeJsonToWeb(
            JSONObject()
                .put("action", "embeddedPwaUpdateAvailable")
                .put("currentVer", currentVer)
                .put("pendingVer", pendingVer),
        )
        if (::webView.isInitialized && ::embeddedPwaHost.isInitialized) {
            embeddedPwaHost.injectVersionGlobals(webView)
        }
    }

    @SuppressLint("SetJavaScriptEnabled")
    override fun onCreate(savedInstanceState: Bundle?) {
        val wakeForCall = intent?.getBooleanExtra(BeamioTelecomService.EXTRA_WAKE_FOR_CALL, false) == true
        if (wakeForCall) {
            setTheme(R.style.Theme_CaehTrees_IncomingCall)
        }
        enableEdgeToEdge()
        super.onCreate(savedInstanceState)
        applyTransparentStatusBar()
        if (wakeForCall && IncomingCallActivity.isShowing()) {
            moveTaskToBack(true)
        }
        requestedOrientation = android.content.pm.ActivityInfo.SCREEN_ORIENTATION_PORTRAIT
        activeInstance = this
        allowShowOverLockScreenForVoiceWake(intent)
        BeamioTelecomService.ensurePhoneAccount(this)
        nfcAdapter = NfcAdapter.getDefaultAdapter(this)

        onBackPressedDispatcher.addCallback(
            this,
            object : OnBackPressedCallback(true) {
                override fun handleOnBackPressed() {
                    if (nfcBindSessionActive) {
                        disarmNfcReader(true, "cancelled")
                        return
                    }
                    if (::webView.isInitialized && webView.canGoBack()) {
                        webView.goBack()
                    } else {
                        finish()
                    }
                }
            },
        )

        val jsBridge = CashTreesJsBridge()
        CashTreesWebConsoleRelay.logAppBoot()
        CashTreesPushRegistration.hydrateFromPrefs(this)
        CashTreesPushRegistration.onTokenForWeb = { token ->
            runOnUiThread {
                dispatchAndroidBridgeJsonToWeb(
                    CashTreesPushRegistration.payloadForWebEvent(this, token),
                )
            }
        }
        embeddedPwaHost = EmbeddedPwaHost(this)
        rootLayout = FrameLayout(this).apply {
            if (!wakeForCall) {
                setBackgroundColor(Color.parseColor("#f8f9fa"))
            }
        }
        setContentView(rootLayout)
        hideBottomSystemBar()
        captureBeamioDeepLink(intent)
        // Fresh Play install: recover the merchant / coupon link the landing page stashed.
        InstallReferrerDeepLink.consumeOnce(this) { https ->
            runOnUiThread {
                if (deepLinkApplied || pendingDeepLinkHttps != null) return@runOnUiThread
                pendingDeepLinkHttps = https
                applyPendingDeepLinkIfReady()
            }
        }

        bootstrapExecutor.execute {
            try {
                embeddedPwaHost.bootstrapIfNeeded()
                runOnUiThread { mountEmbeddedWebView(jsBridge) }
            } catch (error: Exception) {
                // Never switch to the live website when the embedded bundle fails.
                // Doing so changes the storage/runtime source during startup and can
                // make a valid local wallet look like a fresh installation.
                Log.e("BeamioEmbeddedPwa", "embedded PWA bootstrap failed; remote fallback disabled", error)
                runOnUiThread { mountEmbeddedUnavailableWebView(jsBridge) }
            }
        }
    }

    private fun captureBeamioDeepLink(intent: Intent?) {
        val data = intent?.data ?: return
        val https = BeamioDeepLink.resolveCustomSchemeToHttps(data) ?: return
        pendingDeepLinkHttps = https
        applyPendingDeepLinkIfReady()
    }

    private fun applyPendingDeepLinkIfReady() {
        val https = pendingDeepLinkHttps ?: return
        if (!::webView.isInitialized) return
        pendingDeepLinkHttps = null
        deepLinkApplied = true
        try {
            if (useEmbeddedPwa && ::embeddedPwaHost.isInitialized) {
                embeddedPwaHost.mapBeamioAppUrlToLocal(https)?.let { local ->
                    webView.loadUrl(local.toString())
                    return
                }
            }
            // Consumer Android must never switch the WebView to the remote
            // /app/ origin: that creates a second IndexedDB/PouchDB namespace
            // and makes an existing wallet look like a fresh install.
            CashTreesWebConsoleRelay.logNative(
                "ignored remote deep link while embedded PWA is active: $https",
            )
        } catch (_: Exception) {
        }
    }

    private fun mountEmbeddedWebView(jsBridge: CashTreesJsBridge) {
        useEmbeddedPwa = true
        val wv = createEmbeddedWebView(jsBridge, embeddedPwaHost)
        webView = wv
        rootLayout.addView(wv)
        applyPendingDeepLinkIfReady()
        embeddedPwaHost.startUpdateDaemon { currentVer, pendingVer ->
            dispatchEmbeddedPwaUpdateAvailable(currentVer, pendingVer)
        }
        embeddedPwaHost.checkForUpdatesNow()
    }

    private fun mountEmbeddedUnavailableWebView(jsBridge: CashTreesJsBridge) {
        useEmbeddedPwa = false
        val wv = createBaseWebView(jsBridge)
        webView = wv
        rootLayout.addView(wv)
        wv.loadDataWithBaseURL(
            EmbeddedPwaConstants.ASSET_LOADER_ORIGIN,
            """
            <!doctype html><meta name="viewport" content="width=device-width,initial-scale=1">
            <body style="background:#000414;color:white;font:16px sans-serif;padding:32px">
            <h2>Beamio is starting</h2>
            <p>The local app bundle is unavailable. Please retry when the device is online.</p>
            </body>
            """.trimIndent(),
            "text/html",
            "UTF-8",
            null,
        )
    }

    /**
     * 主框架导航：拦截会被 NDEF 写入的 beamio SUN URL，防止 WebView 或外链拾取后跳出到系统浏览器。
     * [cashtrees.beamio.app] 为 PWA 宿主，必须放行。
     */
    private fun shouldBlockBeamioNdefTopLevelNavigation(u: Uri, isMainFrame: Boolean): Boolean {
        if (!isMainFrame) return false
        val host = u.host?.lowercase().orEmpty()
        if (!host.contains("beamio.app")) return false
        if (host.contains("cashtrees.beamio.app")) return false
        val path = u.path?.lowercase().orEmpty()
        if (path.contains("/api/sun") || path.contains("/sun")) return true
        val hasSunQueries =
            u.getQueryParameter("uid") != null &&
                u.getQueryParameter("e") != null &&
                u.getQueryParameter("c") != null &&
                u.getQueryParameter("m") != null
        return hasSunQueries
    }

    @SuppressLint("SetJavaScriptEnabled")
    private fun createEmbeddedWebView(jsBridge: CashTreesJsBridge, host: EmbeddedPwaHost): WebView {
        val loader = host.assetLoader
            ?: throw IllegalStateException("Embedded PWA asset loader not ready")
        return createBaseWebView(jsBridge).apply {
            webViewClient = object : WebViewClient() {
                override fun shouldInterceptRequest(
                    view: WebView,
                    request: WebResourceRequest,
                ): android.webkit.WebResourceResponse? {
                    val u = request.url ?: return null
                    if (host.shouldBypassEmbeddedAssetLoader(u)) {
                        return null
                    }
                    host.mapBeamioAppUrlToLocal(u)?.let { local ->
                        return loader.shouldInterceptRequest(local)
                    }
                    if (u.host?.lowercase() == EmbeddedPwaConstants.ASSET_LOADER_DOMAIN) {
                        return loader.shouldInterceptRequest(host.mapEmbeddedAssetUrlToLocal(u))
                    }
                    return null
                }

                override fun shouldOverrideUrlLoading(view: WebView, request: WebResourceRequest): Boolean {
                    val u = request.url ?: return false
                    if (shouldBlockBeamioNdefTopLevelNavigation(u, request.isForMainFrame)) return true
                    if (request.isForMainFrame) {
                        host.mapBeamioAppUrlToLocal(u)?.let { local ->
                            view.loadUrl(local.toString())
                            return true
                        }
                    }
                    return false
                }

                @Deprecated("Deprecated in Java")
                override fun shouldOverrideUrlLoading(view: WebView?, url: String?): Boolean {
                    if (url.isNullOrEmpty()) return false
                    val u = Uri.parse(url)
                    if (shouldBlockBeamioNdefTopLevelNavigation(u, true)) return true
                    host.mapBeamioAppUrlToLocal(u)?.let { local ->
                        view?.loadUrl(local.toString())
                        return true
                    }
                    return false
                }

                override fun onPageStarted(view: WebView, url: String?, favicon: android.graphics.Bitmap?) {
                    injectWebBridgeScripts(view, "onPageStarted")
                }

                override fun onPageFinished(view: WebView, url: String?) {
                    host.injectVersionGlobals(view)
                    injectWebBridgeScripts(view, "onPageFinished")
                    applyTransparentStatusBar()
                    embeddedPwaUpdateReplayAttempt = 0
                    pendingSystemCallHandler.removeCallbacks(embeddedPwaUpdateReplayRunnable)
                    pendingSystemCallHandler.postDelayed(
                        embeddedPwaUpdateReplayRunnable,
                        350L,
                    )
                    dispatchPendingSystemCallAction()
                    if (intent.getBooleanExtra(BeamioTelecomService.EXTRA_WAKE_FOR_CALL, false)) {
                        mailboxWakeDispatchAttempt = 0
                        pendingSystemCallHandler.removeCallbacks(mailboxWakeDispatchRunnable)
                        pendingSystemCallHandler.post(mailboxWakeDispatchRunnable)
                    }
                    requestShowActiveCall(intent)
                    pendingSystemCallDispatchAttempt = 0
                    pendingSystemCallHandler.removeCallbacks(pendingSystemCallDispatchRunnable)
                    pendingSystemCallHandler.postDelayed(
                        pendingSystemCallDispatchRunnable,
                        250L,
                    )
                }

                override fun onReceivedError(
                    view: WebView,
                    request: WebResourceRequest,
                    error: android.webkit.WebResourceError,
                ) {
                    if (request.isForMainFrame) {
                        CashTreesWebConsoleRelay.logNative(
                            "embedded main frame error url=${request.url} code=${error.errorCode} ${error.description}",
                        )
                    }
                }

                override fun onRenderProcessGone(view: WebView, detail: RenderProcessGoneDetail): Boolean {
                    view.loadUrl(EmbeddedPwaConstants.entryUrl, HOME_DOCUMENT_REQUEST_HEADERS)
                    return true
                }
            }
            CashTreesWebConsoleRelay.logNative("loading embedded PWA ${EmbeddedPwaConstants.entryUrl}")
            loadUrl(EmbeddedPwaConstants.entryUrl, HOME_DOCUMENT_REQUEST_HEADERS)
        }
    }

    @SuppressLint("SetJavaScriptEnabled")
    private fun createRemoteWebView(jsBridge: CashTreesJsBridge, startUrl: String): WebView {
        return createBaseWebView(jsBridge).apply {
            webViewClient = object : WebViewClient() {
                override fun shouldOverrideUrlLoading(view: WebView, request: WebResourceRequest): Boolean {
                    val u = request.url ?: return false
                    return shouldBlockBeamioNdefTopLevelNavigation(u, request.isForMainFrame)
                }

                @Deprecated("Deprecated in Java")
                override fun shouldOverrideUrlLoading(view: WebView?, url: String?): Boolean {
                    if (url.isNullOrEmpty()) return false
                    return shouldBlockBeamioNdefTopLevelNavigation(Uri.parse(url), true)
                }

                override fun onPageStarted(view: WebView, url: String?, favicon: android.graphics.Bitmap?) {
                    injectWebBridgeScripts(view, "remote-onPageStarted")
                }

                override fun onPageFinished(view: WebView, url: String?) {
                    injectWebBridgeScripts(view, "remote-onPageFinished")
                    applyTransparentStatusBar()
                }

                override fun onRenderProcessGone(view: WebView, detail: RenderProcessGoneDetail): Boolean {
                    view.loadUrl(startUrl, HOME_DOCUMENT_REQUEST_HEADERS)
                    return true
                }
            }
            loadUrl(startUrl, HOME_DOCUMENT_REQUEST_HEADERS)
        }
    }

    @SuppressLint("SetJavaScriptEnabled")
    private fun createBaseWebView(jsBridge: CashTreesJsBridge): WebView {
        return WebView(this).apply {
            layoutParams = FrameLayout.LayoutParams(
                ViewGroup.LayoutParams.MATCH_PARENT,
                ViewGroup.LayoutParams.MATCH_PARENT,
            )
            this.webChromeClient = this@MainActivity.webChromeClient
            settings.javaScriptEnabled = true
            settings.domStorageEnabled = true
            settings.mediaPlaybackRequiresUserGesture = false
            settings.cacheMode = WebSettings.LOAD_DEFAULT
            settings.loadWithOverviewMode = true
            settings.useWideViewPort = true
            settings.setSupportZoom(false)
            settings.builtInZoomControls = false
            isVerticalScrollBarEnabled = true
            isHorizontalScrollBarEnabled = false
            setBackgroundColor(Color.parseColor("#f8f9fa"))
            addJavascriptInterface(jsBridge, "CashTreesAndroid")
            addJavascriptInterface(CashTreesWebConsoleRelay.JsRelay(), CashTreesWebConsoleRelay.BRIDGE_NAME)
            CashTreesWebConsoleRelay.registerDocumentStartScript(this)
        }
    }

    private fun injectWebBridgeScripts(webView: WebView, reason: String) {
        CashTreesWebConsoleRelay.reinject(webView, reason)
    }

    private fun dispatchPendingSystemCallAction() {
        val pending = BeamioTelecomService.peekPendingSystemCallAction(this) ?: return
        Log.i(
            "BeamioVoiceCall",
            "dispatching pending action=${pending.getString("action").orEmpty()} " +
                "callIdPresent=${pending.getString("callId").orEmpty().isNotBlank()}",
        )
        dispatchAndroidBridgeJsonToWeb(
            JSONObject()
                .put("action", pending.getString("action").orEmpty())
                .put("callId", pending.getString("callId").orEmpty())
                .put("sessionId", pending.getString("sessionId").orEmpty()),
        ) {
            // The action has reached the WebView bridge. Remove it only after
            // evaluateJavascript completes, so a cold-start retry cannot
            // replay an already-consumed Telecom action.
            BeamioTelecomService.clearPendingSystemCallAction(this)
            pendingSystemCallDispatchAttempt = 0
        }
    }

    override fun onResume() {
        super.onResume()
        if (IncomingCallActivity.isShowing()) {
            IncomingCallActivity.bringToFront(this)
            return
        }
        if (::rootLayout.isInitialized) {
            rootLayout.setBackgroundColor(Color.parseColor("#f8f9fa"))
        }
        applyTransparentStatusBar()
        maybeOpenFullScreenIntentSettings()
        if (nfcBindKeepAlive) {
            armNfcPhysicalCardRead()
        } else {
            maybeEnableNfcForegroundDispatch()
        }
        // Launcher badge follows active notifications: drop stale offline alerts so the
        // PWA unread count (publishAppState) is the only badge source once we are visible.
        CashTreesNativeAppStateBridge.clearOfflineChatAlerts(this)
        if (useEmbeddedPwa && ::embeddedPwaHost.isInitialized) {
            embeddedPwaHost.checkForUpdatesNow()
        }
        dispatchAndroidBridgeJsonToWeb(
            JSONObject().put("action", "appLifecycle").put("phase", "active"),
        )
    }

    override fun onRequestPermissionsResult(
        requestCode: Int,
        permissions: Array<String>,
        grantResults: IntArray,
    ) {
        super.onRequestPermissionsResult(requestCode, permissions, grantResults)
        if (requestCode != CashTreesPushRegistration.REQUEST_POST_NOTIFICATIONS) return
        val granted =
            grantResults.isNotEmpty() && grantResults[0] == PackageManager.PERMISSION_GRANTED
        CashTreesPushRegistration.onPostNotificationsPermissionResult(this, granted)
    }

    override fun onNewIntent(intent: Intent) {
        super.onNewIntent(intent)
        setIntent(intent)
        allowShowOverLockScreenForVoiceWake(intent)
        captureBeamioDeepLink(intent)
        if (intent.getBooleanExtra(BeamioTelecomService.EXTRA_WAKE_FOR_CALL, false)) {
            mailboxWakeDispatchAttempt = 0
            pendingSystemCallHandler.removeCallbacks(mailboxWakeDispatchRunnable)
            pendingSystemCallHandler.post(mailboxWakeDispatchRunnable)
        }
        requestShowActiveCall(intent)
        val action = intent.action ?: return
        if (
            action != NfcAdapter.ACTION_TAG_DISCOVERED &&
            action != NfcAdapter.ACTION_TECH_DISCOVERED &&
            action != NfcAdapter.ACTION_NDEF_DISCOVERED
        ) {
            return
        }
        if (nfcBindKeepAlive || nfcBindSessionActive) {
            val tag = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.TIRAMISU) {
                intent.getParcelableExtra(NfcAdapter.EXTRA_TAG, Tag::class.java)
            } else {
                @Suppress("DEPRECATION")
                intent.getParcelableExtra(NfcAdapter.EXTRA_TAG)
            }
            if (tag != null) onNfcTagForBind(tag)
            return
        }
        // 未由 PWA 调用 startPhysicalCardBind：消费 Intent，不向系统/other app 冒泡。
    }

    override fun onPause() {
        try {
            NfcAdapter.getDefaultAdapter(this)?.disableForegroundDispatch(this)
        } catch (_: Exception) {
        }
        if (nfcBindKeepAlive) {
            Log.i("BeamioNfc", "onPause release reader")
            // Release the radio while not resumed. Keep the link request so
            // onResume can arm the reader again. Do not notify the page here.
            nfcBindSessionActive = false
            try {
                NfcAdapter.getDefaultAdapter(this)?.disableReaderMode(this)
            } catch (_: Exception) {
            }
        }
        dispatchAndroidBridgeJsonToWeb(
            JSONObject().put("action", "appLifecycle").put("phase", "inactive"),
        )
        super.onPause()
    }

    override fun onStop() {
        if (nfcBindKeepAlive) {
            disarmNfcReader(true, "paused")
        }
        dispatchAndroidBridgeJsonToWeb(
            JSONObject().put("action", "appLifecycle").put("phase", "background"),
        )
        super.onStop()
    }

    override fun onDestroy() {
        if (activeInstance === this) activeInstance = null
        pendingSystemCallHandler.removeCallbacksAndMessages(null)
        mainHandler.removeCallbacks(enableNfcForegroundDispatchRunnable)
        CashTreesPushRegistration.onTokenForWeb = null
        if (::embeddedPwaHost.isInitialized) {
            embeddedPwaHost.stopUpdateDaemon()
        }
        nfcReadExecutor.shutdownNow()
        bootstrapExecutor.shutdownNow()
        super.onDestroy()
    }

    override fun onWindowFocusChanged(hasFocus: Boolean) {
        super.onWindowFocusChanged(hasFocus)
        if (hasFocus) {
            hideBottomSystemBar()
            applyTransparentStatusBar()
        }
    }

    /** Let a lock-screen Open Beamio tap boot the WebView without dismissing the keyguard. */
    private fun allowShowOverLockScreenForVoiceWake(source: Intent?) {
        if (source?.getBooleanExtra(BeamioTelecomService.EXTRA_WAKE_FOR_CALL, false) != true) return
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O_MR1) {
            setShowWhenLocked(true)
            setTurnScreenOn(true)
        }
    }

    /** Status bar stays clear so the page shows through. No black strip above the home screen. */
    private fun applyTransparentStatusBar() {
        WindowCompat.setDecorFitsSystemWindows(window, false)
        window.statusBarColor = Color.TRANSPARENT
        window.navigationBarColor = Color.TRANSPARENT
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q) {
            window.isStatusBarContrastEnforced = false
            window.isNavigationBarContrastEnforced = false
        }
        WindowCompat.getInsetsController(window, window.decorView).isAppearanceLightStatusBars = true
    }

    /** Hide navigation bar; user can swipe edge to show it briefly (transient). */
    private fun hideBottomSystemBar() {
        val controller = WindowCompat.getInsetsController(window, window.decorView)
        controller.hide(WindowInsetsCompat.Type.navigationBars())
        controller.systemBarsBehavior =
            WindowInsetsControllerCompat.BEHAVIOR_SHOW_TRANSIENT_BARS_BY_SWIPE
    }
}
